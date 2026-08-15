defmodule ObscuraJidoExample.OpenAIRequestAdapterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ObscuraJidoExample.{OpenAICredentialStore, OpenAIRequestAdapter}
  alias ObscuraJidoExample.OpenAIRequestAdapter.BoundaryError

  @credential_header "x-obscura-openai-credential-ref"
  @placeholder "Bearer obscura-session-key-resolved-at-request-time"
  @key "sk-test-streaming-adapter-credential"
  @first_chunk "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hel\"}\n\n"
  @second_chunk "data: {\"type\":\"response.completed\"}\n\n"

  setup do
    parent = self()

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {__MODULE__.FakeOpenAI, owner: parent},
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false},
          id: {Bandit, System.unique_integer([:positive])}
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    previous = Application.get_env(:obscura_jido_example, OpenAIRequestAdapter)

    Application.put_env(:obscura_jido_example, OpenAIRequestAdapter,
      additional_destinations: [{:http, "127.0.0.1", port}]
    )

    on_exit(fn -> restore_adapter_config(previous) end)

    assert {:ok, credential_ref} = OpenAICredentialStore.put(@key)
    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    %{credential_ref: credential_ref, url: "http://127.0.0.1:#{port}/v1/responses"}
  end

  test "ReqLLM streams directly through Finch with a transport-only credential", %{
    credential_ref: credential_ref,
    url: url
  } do
    assert Application.get_env(:req_llm, :finch_request_adapter) == OpenAIRequestAdapter

    stream_server = start_supervised!({__MODULE__.StreamReceiver, self()})
    body = Jason.encode!(%{model: "gpt-test", input: "<<EMAIL_001>>", stream: true})
    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, task_pid, http_context, canonical_json} =
                 ReqLLM.Streaming.FinchClient.start_stream(
                   __MODULE__.FakeProvider,
                   nil,
                   nil,
                   [url: url, body: body, credential_ref: credential_ref],
                   stream_server,
                   ReqLLM.Finch
                 )

        assert canonical_json == Jason.decode!(body)
        assert http_context.url == url
        assert http_context.req_headers["authorization"] == "[REDACTED:authorization]"
        refute Map.has_key?(http_context.req_headers, @credential_header)
        refute inspect(http_context) =~ credential_ref
        refute inspect(http_context) =~ @key

        task_ref = Process.monitor(task_pid)

        assert_receive {:upstream_request, upstream_pid, headers, ^body}, 1_000
        assert header?(headers, "authorization", "Bearer " <> @key)
        refute header?(headers, @credential_header)
        refute header?(headers, "authorization", @placeholder)

        assert_receive {:stream_event, {:data, @first_chunk}}, 1_000
        refute_received {:stream_event, {:data, @second_chunk}}

        send(upstream_pid, :continue_upstream)

        assert_receive {:stream_event, {:data, @second_chunk}}, 1_000
        assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}, 1_000

        send(parent, :stream_verified)
      end)

    assert_received :stream_verified
    refute log =~ @key
    refute log =~ credential_ref
  end

  test "an expired reference fails before Finch contacts the destination", %{
    credential_ref: credential_ref,
    url: url
  } do
    assert :ok = OpenAICredentialStore.delete(credential_ref)
    stream_server = start_supervised!({__MODULE__.StreamReceiver, self()})

    log =
      capture_log(fn ->
        assert {:error, {:build_request_failed, %BoundaryError{}}} =
                 ReqLLM.Streaming.FinchClient.start_stream(
                   __MODULE__.FakeProvider,
                   nil,
                   nil,
                   [url: url, body: "{}", credential_ref: credential_ref],
                   stream_server,
                   ReqLLM.Finch
                 )
      end)

    refute_received {:upstream_request, _pid, _headers, _body}
    refute log =~ @key
    refute log =~ credential_ref
  end

  test "a marked request fails closed for an unapproved destination", %{
    credential_ref: credential_ref
  } do
    request = marked_request("https://example.com/v1/responses", credential_ref)

    error = assert_raise BoundaryError, fn -> OpenAIRequestAdapter.call(request) end

    refute Exception.message(error) =~ credential_ref
    refute Exception.message(error) =~ @key
  end

  test "the production OpenAI Responses endpoint receives only bearer authorization", %{
    credential_ref: credential_ref
  } do
    request = marked_request("https://api.openai.com/v1/responses", credential_ref)

    adapted = OpenAIRequestAdapter.call(request)

    assert header?(adapted.headers, "authorization", "Bearer " <> @key)
    refute header?(adapted.headers, @credential_header)
    refute header?(adapted.headers, "authorization", @placeholder)
  end

  test "a marked request requires exactly one placeholder authorization", %{
    credential_ref: credential_ref,
    url: url
  } do
    request = marked_request(url, credential_ref)

    missing = %{
      request
      | headers: Enum.reject(request.headers, &header_name?(&1, "authorization"))
    }

    duplicate = %{request | headers: [{"authorization", @placeholder} | request.headers]}

    assert_raise BoundaryError, fn -> OpenAIRequestAdapter.call(missing) end
    assert_raise BoundaryError, fn -> OpenAIRequestAdapter.call(duplicate) end
  end

  test "unmarked Finch requests remain unchanged" do
    request = Finch.build(:post, "https://example.com/anything", [], "{}")

    assert OpenAIRequestAdapter.call(request) == request
  end

  defp marked_request(url, credential_ref) do
    Finch.build(
      :post,
      url,
      [
        {@credential_header, credential_ref},
        {"authorization", @placeholder},
        {"content-type", "application/json"}
      ],
      "{}"
    )
  end

  defp header?(headers, expected_name, expected_value \\ nil) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == expected_name and
        (is_nil(expected_value) or value == expected_value)
    end)
  end

  defp header_name?({name, _value}, expected_name) when is_binary(name),
    do: String.downcase(name) == expected_name

  defp header_name?(_header, _expected_name), do: false

  defp restore_adapter_config(nil),
    do: Application.delete_env(:obscura_jido_example, OpenAIRequestAdapter)

  defp restore_adapter_config(previous),
    do: Application.put_env(:obscura_jido_example, OpenAIRequestAdapter, previous)

  defmodule FakeProvider do
    @moduledoc false

    @credential_header "x-obscura-openai-credential-ref"
    @placeholder "Bearer obscura-session-key-resolved-at-request-time"

    def attach_stream(_model, _context, opts, _finch_name) do
      {:ok,
       Finch.build(
         :post,
         Keyword.fetch!(opts, :url),
         [
           {@credential_header, Keyword.fetch!(opts, :credential_ref)},
           {"authorization", @placeholder},
           {"content-type", "application/json"},
           {"accept", "text/event-stream"}
         ],
         Keyword.fetch!(opts, :body)
       )}
    end
  end

  defmodule StreamReceiver do
    @moduledoc false

    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call({:http_event, event}, _from, owner) do
      send(owner, {:stream_event, event})
      {:reply, :ok, owner}
    end
  end

  defmodule FakeOpenAI do
    @moduledoc false

    import Plug.Conn

    @first_chunk "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hel\"}\n\n"
    @second_chunk "data: {\"type\":\"response.completed\"}\n\n"

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(opts[:owner], {:upstream_request, self(), conn.req_headers, body})

      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> send_chunked(200)

      {:ok, conn} = chunk(conn, @first_chunk)

      receive do
        :continue_upstream -> :ok
      after
        1_000 -> :ok
      end

      {:ok, conn} = chunk(conn, @second_chunk)
      conn
    end
  end
end
