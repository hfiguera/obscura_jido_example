defmodule ObscuraJidoExample.OpenAICredentialStore do
  @moduledoc """
  Keeps browser-session OpenAI credentials in ephemeral, process-owned memory.

  Callers receive only opaque references. Credentials are copied away from the
  HTTP request body, wrapped in a redacted term for process messages, and
  removed after the configured idle timeout or an explicit delete.
  """

  use GenServer

  alias __MODULE__.Secret

  @default_ttl_ms :timer.minutes(30)
  @min_key_bytes 8
  @max_key_bytes 512

  @type credential_ref :: String.t()

  defmodule Secret do
    @moduledoc false

    @enforce_keys [:value]
    defstruct [:value]

    @type t :: %__MODULE__{value: binary()}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec put(binary(), GenServer.server()) :: {:ok, credential_ref()} | {:error, :invalid_key}
  def put(key, server \\ __MODULE__) do
    with {:ok, secret} <- normalize_key(key) do
      GenServer.call(server, {:put, secret})
    end
  end

  @spec available?(credential_ref() | nil, GenServer.server()) :: boolean()
  def available?(credential_ref, server \\ __MODULE__)

  def available?(credential_ref, server) when is_binary(credential_ref),
    do: GenServer.call(server, {:available?, credential_ref})

  def available?(_credential_ref, _server), do: false

  @spec with_key(credential_ref(), (binary() -> result), GenServer.server()) ::
          result | {:error, :credential_unavailable}
        when result: term()
  def with_key(credential_ref, fun, server \\ __MODULE__)

  def with_key(credential_ref, fun, server)
      when is_binary(credential_ref) and is_function(fun, 1) do
    case GenServer.call(server, {:fetch, credential_ref}) do
      {:ok, %Secret{value: key}} -> fun.(key)
      :error -> {:error, :credential_unavailable}
    end
  end

  def with_key(_credential_ref, _fun, _server), do: {:error, :credential_unavailable}

  @spec delete(credential_ref() | nil, GenServer.server()) :: :ok
  def delete(credential_ref, server \\ __MODULE__)

  def delete(credential_ref, server) when is_binary(credential_ref),
    do: GenServer.call(server, {:delete, credential_ref})

  def delete(_credential_ref, _server), do: :ok

  @impl true
  def init(opts) do
    ttl_ms = Keyword.get(opts, :ttl_ms, configured_ttl_ms())

    if is_integer(ttl_ms) and ttl_ms > 0 do
      table = :ets.new(__MODULE__, [:set, :private])
      {:ok, %{table: table, expirations: %{}, ttl_ms: ttl_ms}}
    else
      {:stop, :invalid_ttl}
    end
  end

  @impl true
  def handle_call({:put, %Secret{} = secret}, _from, state) do
    credential_ref = new_credential_ref(state)
    true = :ets.insert(state.table, {credential_ref, secret})
    {:reply, {:ok, credential_ref}, refresh_expiration(state, credential_ref)}
  end

  def handle_call({:available?, credential_ref}, _from, state) do
    {:reply, :ets.member(state.table, credential_ref), state}
  end

  def handle_call({:fetch, credential_ref}, _from, state) do
    case :ets.lookup(state.table, credential_ref) do
      [{^credential_ref, %Secret{} = secret}] ->
        {:reply, {:ok, secret}, refresh_expiration(state, credential_ref)}

      [] ->
        {:reply, :error, state}
    end
  end

  def handle_call({:delete, credential_ref}, _from, state) do
    {:reply, :ok, remove_credential(state, credential_ref)}
  end

  @impl true
  def handle_info({:expire, credential_ref, nonce}, state) do
    case Map.get(state.expirations, credential_ref) do
      {_timer, ^nonce} -> {:noreply, remove_credential(state, credential_ref)}
      _stale_or_missing -> {:noreply, state}
    end
  end

  defp normalize_key(key) when is_binary(key) do
    cond do
      byte_size(key) < @min_key_bytes -> {:error, :invalid_key}
      byte_size(key) > @max_key_bytes -> {:error, :invalid_key}
      not String.valid?(key) -> {:error, :invalid_key}
      String.trim(key) != key -> {:error, :invalid_key}
      not printable_ascii?(key) -> {:error, :invalid_key}
      true -> {:ok, %Secret{value: :binary.copy(key)}}
    end
  end

  defp normalize_key(_key), do: {:error, :invalid_key}

  defp printable_ascii?(key),
    do: key |> :binary.bin_to_list() |> Enum.all?(&(&1 in 33..126))

  defp configured_ttl_ms do
    Application.get_env(:obscura_jido_example, __MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end

  defp new_credential_ref(state) do
    credential_ref = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    if :ets.member(state.table, credential_ref),
      do: new_credential_ref(state),
      else: credential_ref
  end

  defp refresh_expiration(state, credential_ref) do
    state = cancel_expiration(state, credential_ref)
    nonce = make_ref()
    timer = Process.send_after(self(), {:expire, credential_ref, nonce}, state.ttl_ms)
    put_in(state.expirations[credential_ref], {timer, nonce})
  end

  defp remove_credential(state, credential_ref) do
    true = :ets.delete(state.table, credential_ref)
    cancel_expiration(state, credential_ref)
  end

  defp cancel_expiration(state, credential_ref) do
    case Map.pop(state.expirations, credential_ref) do
      {nil, expirations} ->
        %{state | expirations: expirations}

      {{timer, _nonce}, expirations} ->
        _ = Process.cancel_timer(timer)
        %{state | expirations: expirations}
    end
  end
end

defimpl Inspect, for: ObscuraJidoExample.OpenAICredentialStore.Secret do
  def inspect(_secret, _opts), do: "#OpenAIKey<redacted>"
end
