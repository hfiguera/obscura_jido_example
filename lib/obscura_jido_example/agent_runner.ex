defmodule ObscuraJidoExample.AgentRunner do
  @moduledoc "Runs one isolated Jido request across the Obscura boundary."

  alias ObscuraJidoExample.{
    DemoScript,
    OpenAICredentialStore,
    Privacy,
    SupportAgent
  }

  defmodule Result do
    @moduledoc false

    @enforce_keys [
      :mode,
      :model,
      :protected_prompt,
      :provider_answer,
      :display_answer,
      :tool_steps,
      :vault_size,
      :elapsed_ms
    ]
    defstruct @enforce_keys
  end

  @max_prompt_bytes 4_000
  @allowed_tools ["find_customer", "list_customer_cases"]
  @credential_header "x-obscura-openai-credential-ref"
  @session_key_placeholder "obscura-session-key-resolved-at-request-time"
  @stream_flush_interval_ms 40
  @stream_flush_bytes 256

  @type mode :: :deterministic | :openai
  @type result :: %Result{}
  @type progress_event ::
          {:phase, :protecting | :requesting | :tools | :streaming | :restoring}
          | {:protected_prompt, String.t()}
          | {:provider_delta, String.t()}
          | {:provider_text, String.t()}
          | {:tool_started, String.t()}
          | {:tool_completed, String.t(), :ok | :error}

  @spec run(String.t(), GenServer.server(), keyword()) :: {:ok, result()} | {:error, atom()}
  def run(prompt, vault, opts \\ [])

  def run(prompt, vault, opts) when is_binary(prompt) do
    started_at = System.monotonic_time(:millisecond)
    mode = Keyword.get(opts, :mode, :deterministic)

    emit_progress(opts, {:phase, :protecting})

    with :ok <- validate_prompt(prompt),
         :ok <- validate_mode(mode),
         :ok <- ensure_provider(mode, opts),
         {:ok, protected_prompt} <- Privacy.protect_prompt(prompt, vault),
         :ok <- emit_protected_prompt(opts, protected_prompt),
         {:ok, provider_answer, tool_steps} <- execute(protected_prompt, vault, mode, opts),
         :ok <- emit_restoring(opts),
         {:ok, display_answer} <- Privacy.restore(provider_answer, vault) do
      {:ok,
       %Result{
         mode: mode,
         model: model_label(mode),
         protected_prompt: protected_prompt,
         provider_answer: provider_answer,
         display_answer: display_answer,
         tool_steps: tool_steps,
         vault_size: Privacy.vault_size(vault),
         elapsed_ms: System.monotonic_time(:millisecond) - started_at
       }}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
      _ -> {:error, :agent_failed}
    end
  rescue
    _error -> {:error, :agent_failed}
  catch
    :exit, _reason -> {:error, :agent_failed}
    _kind, _reason -> {:error, :agent_failed}
  end

  def run(_prompt, _vault, _opts), do: {:error, :invalid_prompt}

  @spec openai_available?(keyword()) :: boolean()
  def openai_available?(opts \\ []) do
    opts |> Keyword.get(:credential_ref) |> OpenAICredentialStore.available?()
  end

  @spec configured_model() :: String.t()
  def configured_model do
    agent_config() |> Keyword.get(:model, "openai:gpt-5.6-luna")
  end

  defp execute(protected_prompt, vault, mode, opts) do
    timeout = Keyword.get(opts, :timeout, agent_config() |> Keyword.get(:timeout, 60_000))
    progress_to = Keyword.get(opts, :progress_to)

    with {:ok, mode_opts} <- mode_options(mode, protected_prompt, vault, opts) do
      request_opts =
        Keyword.merge(mode_opts,
          allowed_tools: @allowed_tools,
          tool_context: %{vault: vault, audit_pid: self()},
          stream_event_timeout_ms: timeout,
          timeout: timeout
        )

      with {:ok, pid} <-
             Jido.AgentServer.start(jido: ObscuraJidoExample.Jido, agent: SupportAgent) do
        try do
          run_request(pid, protected_prompt, request_opts, timeout, progress_to)
        after
          stop_agent(pid)
        end
      else
        _ -> {:error, :agent_unavailable}
      end
    end
  end

  defp run_request(pid, prompt, request_opts, timeout, progress_to) do
    with {:ok, %{request: request, events: event_stream}} <-
           SupportAgent.ask_stream(pid, prompt, request_opts),
         :ok <- collect_events(event_stream, progress_to),
         {:ok, answer} <- SupportAgent.await(request, timeout: timeout),
         {:ok, text} <- answer_text(answer) do
      {:ok, text, collect_tool_audits([])}
    else
      _ -> {:error, :agent_failed}
    end
  end

  defp collect_events(stream, progress_to) do
    stream
    |> Enum.reduce(stream_state(), fn event, state -> consume_event(event, state, progress_to) end)
    |> flush_deltas(progress_to)

    :ok
  rescue
    _ -> {:error, :agent_failed}
  end

  defp stream_state do
    %{pending_deltas: [], pending_bytes: 0, last_flush_ms: monotonic_ms()}
  end

  defp consume_event(%{kind: :request_started}, state, progress_to) do
    state
    |> flush_deltas(progress_to)
    |> tap(fn _state -> emit_progress_to(progress_to, {:phase, :requesting}) end)
  end

  defp consume_event(%{kind: :llm_started}, state, progress_to) do
    state
    |> flush_deltas(progress_to)
    |> tap(fn _state -> emit_progress_to(progress_to, {:phase, :requesting}) end)
  end

  defp consume_event(%{kind: :llm_delta, data: data}, state, progress_to) do
    case safe_event_field(data, :chunk_type) do
      :content -> buffer_delta(state, safe_event_field(data, :delta), progress_to)
      _other -> state
    end
  end

  defp consume_event(%{kind: :llm_completed, data: data}, state, progress_to) do
    state = flush_deltas(state, progress_to)

    if safe_event_field(data, :turn_type) == :final_answer do
      case safe_event_field(data, :text) do
        text when is_binary(text) and text != "" ->
          emit_progress_to(progress_to, {:phase, :streaming})
          emit_progress_to(progress_to, {:provider_text, text})

        _empty_or_invalid ->
          :ok
      end
    end

    state
  end

  defp consume_event(%{kind: :tool_started, tool_name: name}, state, progress_to) do
    state = flush_deltas(state, progress_to)

    with {:ok, name} <- safe_tool_name(name) do
      emit_progress_to(progress_to, {:phase, :tools})
      emit_progress_to(progress_to, {:tool_started, name})
    end

    state
  end

  defp consume_event(%{kind: :tool_completed, tool_name: name, data: data}, state, progress_to) do
    state = flush_deltas(state, progress_to)

    with {:ok, name} <- safe_tool_name(name) do
      emit_progress_to(progress_to, {:tool_completed, name, tool_result_status(data)})
    end

    state
  end

  defp consume_event(_event, state, progress_to), do: flush_deltas(state, progress_to)

  defp buffer_delta(state, delta, progress_to) when is_binary(delta) and delta != "" do
    state = %{
      state
      | pending_deltas: [delta | state.pending_deltas],
        pending_bytes: state.pending_bytes + byte_size(delta)
    }

    if stream_flush_due?(state), do: flush_deltas(state, progress_to), else: state
  end

  defp buffer_delta(state, _delta, _progress_to), do: state

  defp stream_flush_due?(state) do
    state.pending_bytes >= @stream_flush_bytes or
      monotonic_ms() - state.last_flush_ms >= @stream_flush_interval_ms
  end

  defp flush_deltas(%{pending_bytes: 0} = state, _progress_to), do: state

  defp flush_deltas(state, progress_to) do
    delta = state.pending_deltas |> Enum.reverse() |> IO.iodata_to_binary()
    emit_progress_to(progress_to, {:phase, :streaming})
    emit_progress_to(progress_to, {:provider_delta, delta})

    %{state | pending_deltas: [], pending_bytes: 0, last_flush_ms: monotonic_ms()}
  end

  defp safe_tool_name(name) when name in @allowed_tools, do: {:ok, name}
  defp safe_tool_name(_name), do: :error

  defp tool_result_status(data) do
    case safe_event_field(data, :result) do
      {:ok, _value, _directives} -> :ok
      {:ok, _value} -> :ok
      _other -> :error
    end
  end

  defp safe_event_field(data, key) when is_map(data),
    do: Map.get(data, key, Map.get(data, Atom.to_string(key)))

  defp safe_event_field(_data, _key), do: nil

  defp emit_protected_prompt(opts, protected_prompt) do
    emit_progress(opts, {:protected_prompt, protected_prompt})
    emit_progress(opts, {:phase, :requesting})
    :ok
  end

  defp emit_restoring(opts) do
    emit_progress(opts, {:phase, :restoring})
    :ok
  end

  defp emit_progress(opts, event),
    do: opts |> Keyword.get(:progress_to) |> emit_progress_to(event)

  defp emit_progress_to({pid, run_ref}, event) when is_pid(pid) and is_reference(run_ref) do
    send(pid, {__MODULE__, run_ref, event})
    :ok
  end

  defp emit_progress_to(_progress_to, _event), do: :ok

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp collect_tool_audits(acc) do
    receive do
      {:tool_audit, name, outcome} ->
        collect_tool_audits([%{tool: name, outcome: outcome} | acc])

      {:tool_audit, name, outcome, count} ->
        collect_tool_audits([%{tool: name, outcome: outcome, count: count} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp answer_text(answer) when is_binary(answer), do: {:ok, answer}
  defp answer_text(%{result: answer}) when is_binary(answer), do: {:ok, answer}
  defp answer_text(%{"result" => answer}) when is_binary(answer), do: {:ok, answer}
  defp answer_text(_answer), do: {:error, :invalid_agent_answer}

  defp mode_options(:deterministic, prompt, vault, _opts),
    do: {:ok, DemoScript.request_options(prompt, vault)}

  defp mode_options(:openai, _prompt, _vault, opts) do
    credential_ref = Keyword.get(opts, :credential_ref)
    llm_opts = request_llm_opts(opts)

    if OpenAICredentialStore.available?(credential_ref) do
      {:ok,
       []
       |> Keyword.put(:req_http_options,
         headers: [{@credential_header, credential_ref}]
       )
       |> Keyword.put(
         :llm_opts,
         llm_opts
         |> Keyword.put(:api_key, @session_key_placeholder)
       )}
    else
      {:error, :openai_unavailable}
    end
  end

  defp validate_prompt(prompt) do
    cond do
      String.trim(prompt) == "" -> {:error, :empty_prompt}
      byte_size(prompt) > @max_prompt_bytes -> {:error, :prompt_too_large}
      not String.valid?(prompt) -> {:error, :invalid_prompt}
      true -> :ok
    end
  end

  defp validate_mode(mode) when mode in [:deterministic, :openai], do: :ok
  defp validate_mode(_mode), do: {:error, :invalid_mode}

  defp ensure_provider(:deterministic, _opts), do: :ok

  defp ensure_provider(:openai, opts),
    do: if(openai_available?(opts), do: :ok, else: {:error, :openai_unavailable})

  defp model_label(:deterministic), do: "Scripted Jido boundary"
  defp model_label(:openai), do: configured_model()

  defp normalize_error(reason)
       when reason in [
              :empty_prompt,
              :prompt_too_large,
              :invalid_prompt,
              :invalid_mode,
              :openai_unavailable,
              :agent_unavailable,
              :unknown_provider_token
            ],
       do: reason

  defp normalize_error(_reason), do: :agent_failed

  defp agent_config, do: Application.get_env(:obscura_jido_example, :agent, [])

  defp request_llm_opts(opts) do
    case Keyword.get(opts, :llm_opts, []) do
      llm_opts when is_list(llm_opts) -> llm_opts
      _invalid -> []
    end
  end

  defp stop_agent(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end
end
