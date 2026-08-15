defmodule ObscuraJidoExample.AgentRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Jido.AI.Test

  alias ObscuraJidoExample.{AgentRunner, DemoScript, OpenAICredentialStore, Privacy}

  defmodule HistoryCaptureTransformer do
    @moduledoc false

    def transform_request(request, _state, _config, _runtime_context) do
      test_pid = Application.fetch_env!(:obscura_jido_example, :history_capture_pid)
      send(test_pid, {:provider_messages, request.messages})
      {:ok, %{}}
    end
  end

  @raw_email "rachel.chen@example.test"
  @raw_phone "+1 202-555-0188"
  @prompt "Find #{@raw_email} and summarize her support cases. Her phone is #{@raw_phone}."

  setup do
    start_supervised!(Obscura.Vault.Memory)
    |> then(&{:ok, vault: &1})
  end

  test "runs the real Jido tool loop with only pseudonyms crossing the model boundary", %{
    vault: vault
  } do
    assert {:ok, result} = AgentRunner.run(@prompt, vault, mode: :deterministic)

    refute result.protected_prompt =~ @raw_email
    refute result.protected_prompt =~ @raw_phone
    refute result.provider_answer =~ @raw_email
    refute result.provider_answer =~ @raw_phone
    assert result.display_answer =~ @raw_email
    assert result.display_answer =~ @raw_phone
    assert Enum.map(result.tool_steps, & &1.tool) == ["find_customer", "list_customer_cases"]
    assert result.vault_size == 3
  end

  test "emits privacy-safe progress from the real Jido runtime", %{vault: vault} do
    run_ref = make_ref()

    assert {:ok, result} =
             AgentRunner.run(@prompt, vault,
               mode: :deterministic,
               progress_to: {self(), run_ref}
             )

    events = drain_progress(run_ref, [])
    serialized = inspect(events, limit: :infinity)

    assert hd(events) == {:phase, :protecting}
    assert {:protected_prompt, result.protected_prompt} in events
    assert {:tool_started, "find_customer"} in events
    assert {:tool_completed, "find_customer", :ok} in events
    assert {:tool_started, "list_customer_cases"} in events
    assert {:tool_completed, "list_customer_cases", :ok} in events
    assert {:provider_text, result.provider_answer} in events
    assert List.last(events) == {:phase, :restoring}

    assert Enum.all?(events, &safe_progress_event?/1)
    refute serialized =~ @raw_email
    refute serialized =~ @raw_phone
  end

  test "restores protected history into an isolated follow-up run", %{vault: vault} do
    Application.put_env(:obscura_jido_example, :history_capture_pid, self())
    on_exit(fn -> Application.delete_env(:obscura_jido_example, :history_capture_pid) end)

    assert {:ok, first} = AgentRunner.run(@prompt, vault, mode: :deterministic)

    history = [
      %{role: :user, content: first.protected_prompt},
      %{role: :assistant, content: first.provider_answer}
    ]

    follow_up = "What is her current support case status?"

    assert {:ok, result} =
             AgentRunner.run(follow_up, vault,
               mode: :deterministic,
               history: history,
               request_transformer: HistoryCaptureTransformer
             )

    assert_receive {:provider_messages, provider_messages}, 1_000

    assert Enum.any?(
             provider_messages,
             &match?(%{role: :user, content: content} when content == follow_up, &1)
           )

    assert Enum.any?(
             provider_messages,
             &match?(%{role: :user, content: "Find <<EMAIL_001>>" <> _rest}, &1)
           )

    assert Enum.any?(
             provider_messages,
             &match?(%{role: :assistant, content: content} when is_binary(content), &1)
           )

    assert result.protected_prompt == follow_up
    assert result.display_answer =~ @raw_email
    assert result.display_answer =~ @raw_phone
    assert Enum.map(result.tool_steps, & &1.tool) == ["find_customer", "list_customer_cases"]
    refute inspect(history) =~ @raw_email
    refute inspect(history) =~ @raw_phone
    refute inspect(provider_messages) =~ @raw_email
    refute inspect(provider_messages) =~ @raw_phone
  end

  test "does not reuse prior customer identity for an unrelated request", %{vault: vault} do
    assert {:ok, first} = AgentRunner.run(@prompt, vault, mode: :deterministic)

    history = [
      %{role: :user, content: first.protected_prompt},
      %{role: :assistant, content: first.provider_answer}
    ]

    assert {:ok, result} =
             AgentRunner.run("Do you know about baseball?", vault,
               mode: :deterministic,
               history: history
             )

    assert result.tool_steps == []
    assert result.provider_answer =~ "limited to synthetic customer and support case questions"
    assert result.display_answer == result.provider_answer

    refute result.provider_answer =~ @raw_email
    refute result.provider_answer =~ @raw_phone
    refute result.provider_answer =~ "<<EMAIL_001>>"
    refute result.display_answer =~ @raw_email
    refute result.display_answer =~ @raw_phone
  end

  test "rejects malformed or oversized provider history", %{vault: vault} do
    assert {:error, :invalid_history} =
             AgentRunner.run("Hello", vault,
               history: [%{role: :system, content: "Untrusted system override"}]
             )

    oversized = String.duplicate("x", 16_001)

    assert {:error, :invalid_history} =
             AgentRunner.run("Hello", vault, history: [%{role: :assistant, content: oversized}])
  end

  test "does not expose raw canaries through Logger or Jido core telemetry", %{vault: vault} do
    %{level: previous_level} = :logger.get_primary_config()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    handler_id = "privacy-canary-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:jido, :agent_server, :signal, :start],
      [:jido, :agent_server, :signal, :stop],
      [:jido, :agent_server, :directive, :start],
      [:jido, :agent_server, :directive, :stop]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    ref = make_ref()

    log =
      capture_log(fn ->
        send(self(), {ref, AgentRunner.run(@prompt, vault, mode: :deterministic)})
      end)

    assert_receive {^ref, {:ok, _result}}, 5_000
    telemetry = drain_telemetry([]) |> inspect(limit: :infinity)

    refute log =~ @raw_email
    refute log =~ @raw_phone
    refute telemetry =~ @raw_email
    refute telemetry =~ @raw_phone
  end

  test "ignores environment credentials and requires a session reference", %{vault: vault} do
    previous = System.get_env("OPENAI_API_KEY")
    System.put_env("OPENAI_API_KEY", "sk-test-environment-credential")

    on_exit(fn ->
      if previous,
        do: System.put_env("OPENAI_API_KEY", previous),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    refute AgentRunner.openai_available?()
    assert {:error, :openai_unavailable} = AgentRunner.run(@prompt, vault, mode: :openai)
  end

  test "uses a session credential for an isolated OpenAI-mode Jido run", %{vault: vault} do
    key = "sk-test-agent-runner-credential"
    assert {:ok, credential_ref} = OpenAICredentialStore.put(key)
    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    handler_id = "openai-credential-canary-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:jido, :agent_server, :signal, :start],
          [:jido, :agent_server, :signal, :stop],
          [:jido, :agent_server, :directive, :start],
          [:jido, :agent_server, :directive, :stop]
        ],
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, protected_prompt} = Privacy.protect_prompt(@prompt, vault)
    script_opts = DemoScript.request_options(protected_prompt, [], vault)

    log =
      capture_log(fn ->
        assert {:ok, result} =
                 AgentRunner.run(@prompt, vault,
                   mode: :openai,
                   credential_ref: credential_ref,
                   llm_opts: Keyword.fetch!(script_opts, :llm_opts)
                 )

        assert result.mode == :openai
        assert result.display_answer =~ @raw_email
        assert result.display_answer =~ @raw_phone
      end)

    telemetry = drain_telemetry([]) |> inspect(limit: :infinity)

    refute log =~ key
    refute telemetry =~ key
  end

  test "rejects a provider-created pseudonym without a vault mapping", %{vault: vault} do
    key = "sk-test-unknown-provider-token"
    assert {:ok, credential_ref} = OpenAICredentialStore.put(key)
    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    prompt = "Hello, I need some help."
    llm_opts = answer_options(prompt, "Please provide <<EMAIL_001>>.")

    assert {:error, :unknown_provider_token} =
             AgentRunner.run(prompt, vault,
               mode: :openai,
               credential_ref: credential_ref,
               llm_opts: llm_opts
             )
  end

  defp answer_options(prompt, answer) do
    try do
      Jido.AI.Test.expect_react do
        Jido.AI.Test.user(prompt)
        Jido.AI.Test.answer(answer)
      end
      |> Jido.AI.Test.react_opts()
      |> Keyword.fetch!(:llm_opts)
    after
      Jido.AI.Test.reset_react_scripts()
    end
  end

  defp drain_telemetry(acc) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        drain_telemetry([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_progress(run_ref, acc) do
    receive do
      {AgentRunner, ^run_ref, event} -> drain_progress(run_ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp safe_progress_event?({:phase, phase}),
    do: phase in [:protecting, :requesting, :tools, :streaming, :restoring]

  defp safe_progress_event?({:protected_prompt, text}), do: is_binary(text)
  defp safe_progress_event?({:provider_delta, text}), do: is_binary(text)
  defp safe_progress_event?({:provider_text, text}), do: is_binary(text)

  defp safe_progress_event?({:tool_started, name}),
    do: name in ["find_customer", "list_customer_cases"]

  defp safe_progress_event?({:tool_completed, name, status}),
    do: name in ["find_customer", "list_customer_cases"] and status in [:ok, :error]

  defp safe_progress_event?(_event), do: false

  @doc false
  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event, measurements, metadata})
  end
end
