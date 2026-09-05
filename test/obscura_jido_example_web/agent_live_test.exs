defmodule ObscuraJidoExampleWeb.AgentLiveTest do
  use ObscuraJidoExampleWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias ObscuraJidoExample.OpenAICredentialStore

  defmodule PausedRunner do
    @moduledoc false

    alias ObscuraJidoExample.AgentRunner

    def run(_prompt, _vault, opts) do
      {live_view, run_ref} = Keyword.fetch!(opts, :progress_to)
      test_pid = Application.fetch_env!(:obscura_jido_example, :streaming_test_pid)
      protected_prompt = "Find <<EMAIL_001>> and summarize the support cases."
      provider_answer = "Found **<<EMAIL_001>>**."

      progress(live_view, run_ref, {:phase, :protecting})
      progress(live_view, run_ref, {:protected_prompt, protected_prompt})
      progress(live_view, run_ref, {:phase, :requesting})
      pause(test_pid, :requesting)

      progress(live_view, run_ref, {:phase, :tools})
      progress(live_view, run_ref, {:tool_started, "find_customer"})
      pause(test_pid, :tool_running)

      progress(live_view, run_ref, {:tool_completed, "find_customer", :ok})
      progress(live_view, run_ref, {:phase, :streaming})
      progress(live_view, run_ref, {:provider_delta, "Found **<<EMAIL_"})
      pause(test_pid, :streaming)

      progress(live_view, run_ref, {:provider_delta, "001>>**."})
      progress(live_view, run_ref, {:provider_text, provider_answer})
      progress(live_view, run_ref, {:phase, :restoring})
      pause(test_pid, :restoring)

      {:ok,
       %AgentRunner.Result{
         mode: :deterministic,
         model: "Paused test boundary",
         protected_prompt: protected_prompt,
         provider_answer: provider_answer,
         display_answer: "Found **rachel.chen@example.test**.",
         tool_steps: [%{tool: "find_customer", outcome: :ok}],
         vault_size: 1,
         elapsed_ms: 200
       }}
    end

    defp progress(live_view, run_ref, event),
      do: send(live_view, {AgentRunner, run_ref, event})

    defp pause(test_pid, stage) do
      send(test_pid, {:runner_paused, stage, self()})

      receive do
        {:continue_runner, ^stage} -> :ok
      after
        5_000 -> exit(:streaming_test_timeout)
      end
    end
  end

  defmodule UnknownTokenRunner do
    @moduledoc false

    def run(_prompt, _vault, _opts), do: {:error, :unknown_provider_token}
  end

  defmodule TimeoutRunner do
    @moduledoc false

    def run(_prompt, _vault, _opts), do: {:error, :agent_timeout}
  end

  defmodule HistoryRunner do
    @moduledoc false

    alias ObscuraJidoExample.AgentRunner

    def run(prompt, _vault, opts) do
      history = Keyword.fetch!(opts, :history)
      test_pid = Application.fetch_env!(:obscura_jido_example, :history_test_pid)
      send(test_pid, {:runner_history, prompt, history})

      {protected_prompt, provider_answer, display_answer} = response(prompt)

      {:ok,
       %AgentRunner.Result{
         mode: :deterministic,
         model: "History test boundary",
         protected_prompt: protected_prompt,
         provider_answer: provider_answer,
         display_answer: display_answer,
         tool_steps: [],
         vault_size: if(history == [], do: 1, else: 3),
         elapsed_ms: 10
       }}
    end

    defp response(prompt) do
      if String.contains?(prompt, "rachel.chen@example.test") do
        {
          "Find <<EMAIL_001>>",
          "Found <<EMAIL_001>>.",
          "Found rachel.chen@example.test."
        }
      else
        {prompt, "The case is still waiting on support.", "The case is still waiting on support."}
      end
    end
  end

  @prompt "Find rachel.chen@example.test and summarize her support cases. Her phone is +1 202-555-0188."

  test "offers the synthetic case only after a conversation has not used tools", %{conn: conn} do
    Application.put_env(:obscura_jido_example, :agent_runner, HistoryRunner)
    Application.put_env(:obscura_jido_example, :history_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:obscura_jido_example, :agent_runner)
      Application.delete_env(:obscura_jido_example, :history_test_pid)
    end)

    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="agent_prompt_0")
    assert html =~ @prompt
    refute has_element?(view, "#use-synthetic-case")

    view
    |> form("#agent-form", agent: %{prompt: "Hello"})
    |> render_submit()

    assert_receive {:runner_history, "Hello", []}, 1_000
    assert render_async(view, 1_000) =~ "1 turn · 1 mapping"
    assert has_element?(view, "#use-synthetic-case", "Try the synthetic support case")

    html =
      view
      |> element("#use-synthetic-case")
      |> render_click()

    assert html =~ ~s(id="agent_prompt_1")
    assert html =~ @prompt
    refute has_element?(view, "#use-synthetic-case")
  end

  test "runs the deterministic agent and exposes both sides of the privacy boundary", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/")

    assert has_element?(view, "#privacy-profile", "Fast · deterministic identifiers")
    assert has_element?(view, ~s([role="status"][aria-label="Session vault ready"]))
    assert has_element?(view, ~s(textarea[phx-hook="ComposerInput"]))
    assert has_element?(view, ~s(.runtime-status[role="status"][aria-live="polite"]))
    assert has_element?(view, ".safe-label.pending", "Awaiting run")
    assert has_element?(view, ".safe-label.pending", "Awaiting response")
    refute has_element?(view, "#openai-credentials")

    assert has_element?(
             view,
             ~s(.run-command[title="Send message"][aria-label="Send message"]),
             "Send"
           )

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    html = render_async(view, 5_000)

    assert html =~ "&lt;&lt;EMAIL_001&gt;&gt;"
    assert html =~ "rachel.chen@example.test"
    assert html =~ "Rachel Chen"
    assert html =~ "2 read-only tools completed"
    assert html =~ "3 mappings"
    assert has_element?(view, ".safe-label:not(.pending)", "Tokenized")
    refute has_element?(view, "#use-synthetic-case")
  end

  test "renders real progress, tool activity, and tokenized streaming before restoration", %{
    conn: conn
  } do
    Application.put_env(:obscura_jido_example, :agent_runner, PausedRunner)
    Application.put_env(:obscura_jido_example, :streaming_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:obscura_jido_example, :agent_runner)
      Application.delete_env(:obscura_jido_example, :streaming_test_pid)
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    assert_receive {:runner_paused, :requesting, runner}, 1_000
    html = render_until(view, "Waiting for the model")
    assert html =~ "&lt;&lt;EMAIL_001&gt;&gt;"
    assert html =~ ~s(phx-hook="ElapsedTime")
    assert html =~ ~s(aria-hidden="true")
    refute has_element?(view, "#openai-credentials")
    assert has_element?(view, ".safe-label:not(.pending)", "Tokenized")
    assert has_element?(view, ".safe-label.pending", "Awaiting response")

    assert has_element?(
             view,
             ~s(#cancel-agent-run[title="Stop agent run"][aria-label="Stop agent run"]),
             "Stop"
           )

    refute html =~ "rachel.chen@example.test"

    send(runner, {:continue_runner, :requesting})
    assert_receive {:runner_paused, :tool_running, ^runner}, 1_000
    html = render_until(view, "Running trusted tools")
    assert html =~ "Find customer"
    assert html =~ "Running"

    send(runner, {:continue_runner, :tool_running})
    assert_receive {:runner_paused, :streaming, ^runner}, 1_000
    html = render_until(view, "Receiving the answer")
    assert html =~ "Provider response · tokenized"
    assert has_element?(view, ~s(.streaming-response[aria-live="off"]))
    refute has_element?(view, ".safe-label.pending")
    assert html =~ "Found **&lt;&lt;EMAIL_"
    refute html =~ "rachel.chen@example.test"

    send(runner, {:continue_runner, :streaming})
    assert_receive {:runner_paused, :restoring, ^runner}, 1_000
    html = render_until(view, "Restoring known tokens")
    assert html =~ "Complete"
    assert html =~ "Found **&lt;&lt;EMAIL_001&gt;&gt;**."
    refute html =~ "rachel.chen@example.test"

    send(runner, {:continue_runner, :restoring})
    html = render_async(view, 1_000)

    assert html =~ "Trusted UI response"
    assert html =~ "<strong>rachel.chen@example.test</strong>"
    assert html =~ "Found **&lt;&lt;EMAIL_001&gt;&gt;**."
    refute html =~ ~s(id="active-agent-run")
  end

  test "stops a running agent and restores the submitted request", %{conn: conn} do
    Application.put_env(:obscura_jido_example, :agent_runner, PausedRunner)
    Application.put_env(:obscura_jido_example, :streaming_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:obscura_jido_example, :agent_runner)
      Application.delete_env(:obscura_jido_example, :streaming_test_pid)
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    assert_receive {:runner_paused, :requesting, runner}, 1_000
    assert Process.alive?(runner)

    html = view |> element("#cancel-agent-run") |> render_click()

    assert html =~ "Agent run stopped. Your request is ready to send again."
    assert html =~ @prompt
    assert html =~ ~s(id="agent_prompt_1")
    assert has_element?(view, ".run-command", "Send")
    refute has_element?(view, "#active-agent-run")
    refute has_element?(view, "#cancel-agent-run")
    refute has_element?(view, ".safe-label:not(.pending)", "Tokenized")

    refute Process.alive?(runner)
  end

  test "restores the submitted request after the agent deadline expires", %{conn: conn} do
    Application.put_env(:obscura_jido_example, :agent_runner, TimeoutRunner)
    on_exit(fn -> Application.delete_env(:obscura_jido_example, :agent_runner) end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    html = render_async(view, 1_000)

    assert html =~ "The agent did not finish before the request deadline."
    assert html =~ "Your request is ready to send again."
    assert html =~ @prompt
    assert has_element?(view, ".run-command", "Send")
    refute has_element?(view, "#active-agent-run")
    refute has_element?(view, "#cancel-agent-run")
  end

  test "keeps real protected history and clears it with the session vault", %{conn: conn} do
    Application.put_env(:obscura_jido_example, :agent_runner, HistoryRunner)
    Application.put_env(:obscura_jido_example, :history_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:obscura_jido_example, :agent_runner)
      Application.delete_env(:obscura_jido_example, :history_test_pid)
    end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    assert_receive {:runner_history, @prompt, []}, 1_000
    assert render_async(view, 1_000) =~ "1 turn · 1 mapping"

    follow_up = "What is her current support case status?"

    view
    |> form("#agent-form", agent: %{prompt: follow_up})
    |> render_submit()

    assert_receive {:runner_history, ^follow_up, history}, 1_000

    assert history == [
             %{role: :user, content: "Find <<EMAIL_001>>"},
             %{role: :assistant, content: "Found <<EMAIL_001>>."}
           ]

    refute inspect(history) =~ "rachel.chen@example.test"

    html = render_async(view, 1_000)
    assert html =~ "2 turns · 3 mappings"
    assert html =~ "2 prior protected messages"
    assert html =~ @prompt
    assert html =~ follow_up
    assert html =~ "Found rachel.chen@example.test."
    assert html =~ "The case is still waiting on support."
    assert has_element?(view, "#conversation-turn-1")
    assert has_element?(view, "#conversation-turn-2")

    html = view |> element("#new-conversation") |> render_click()
    assert html =~ "Clear conversation?"
    assert html =~ "2 turns · 3 mappings"
    assert has_element?(view, "#confirm-new-conversation", "Clear")
    assert has_element?(view, "#cancel-new-conversation", "Keep")

    html = view |> element("#cancel-new-conversation") |> render_click()
    refute html =~ "Clear conversation?"
    assert html =~ "2 turns · 3 mappings"

    view |> element("#new-conversation") |> render_click()
    html = view |> element("#confirm-new-conversation") |> render_click()
    assert html =~ "0 turns · 0 mappings"
    refute html =~ "rachel.chen@example.test"
    refute html =~ follow_up

    view
    |> form("#agent-form", agent: %{prompt: "Hello"})
    |> render_submit()

    assert_receive {:runner_history, "Hello", []}, 1_000
    assert render_async(view, 1_000) =~ "1 turn · 1 mapping"
  end

  test "reveals OpenAI setup only when requested", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert has_element?(
             view,
             ~s(button[phx-value-mode="deterministic"][aria-pressed="true"])
           )

    assert has_element?(
             view,
             ~s(button[phx-value-mode="openai"][aria-pressed="false"][aria-expanded="false"][aria-describedby="openai-provider-help"])
           )

    refute html =~ ~s(id="openai-credentials")
    refute html =~ ~s(id="openai-key-form")

    html =
      view
      |> element(~s(button[phx-value-mode="openai"]))
      |> render_click()

    assert html =~ ~s(id="openai-credentials")
    assert html =~ ~s(id="openai-key-form")
    assert html =~ "Session-only access"
    assert has_element?(view, ~s(label[for="openai-api-key"]), "API key")
    assert has_element?(view, ~s(#openai-api-key[aria-label="OpenAI API key"]))
    assert has_element?(view, ~s(.credential-submit[aria-label="Enable OpenAI"]), "Enable")
    assert has_element?(view, ~s(button[phx-value-mode="openai"][aria-expanded="true"]))
    assert has_element?(view, ~s(button[phx-value-mode="deterministic"][aria-pressed="true"]))
    refute html =~ "OpenAI credentials"
    refute html =~ "Add a session key"
    refute html =~ ~s(id="clear-openai-key-form")
  end

  test "enables OpenAI from an opaque browser-session credential", %{conn: conn} do
    key = "sk-test-liveview-credential"
    assert {:ok, credential_ref} = OpenAICredentialStore.put(key)
    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    conn = init_test_session(conn, %{"openai_credential_ref" => credential_ref})
    {:ok, view, html} = live(conn, "/")

    refute has_element?(view, ~s(button[phx-value-mode="openai"][disabled]))
    refute html =~ ~s(id="openai-credentials")

    html =
      view
      |> element(~s(button[phx-value-mode="openai"]))
      |> render_click()

    assert has_element?(view, ~s(button[phx-value-mode="openai"][aria-pressed="true"]))
    assert html =~ "Session key ready"
    assert html =~ ~s(id="clear-openai-key-form")
    refute html =~ ~s(id="openai-key-form")
    refute html =~ key
  end

  test "keeps OpenAI selected after the credential redirect", %{conn: conn} do
    key = "sk-test-liveview-redirect-credential"
    assert {:ok, credential_ref} = OpenAICredentialStore.put(key)
    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    conn = init_test_session(conn, %{"openai_credential_ref" => credential_ref})
    {:ok, view, html} = live(conn, "/?provider=openai")

    assert has_element?(view, ~s(button[phx-value-mode="openai"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-mode="deterministic"][aria-pressed="false"]))
    assert html =~ "Session key ready"
    assert html =~ ~s(id="clear-openai-key-form")
    refute html =~ key
  end

  test "reopens setup without activating OpenAI when the credential is unavailable", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/?provider=openai")

    assert has_element?(view, ~s(button[phx-value-mode="deterministic"][aria-pressed="true"]))
    assert has_element?(view, ~s(button[phx-value-mode="openai"][aria-pressed="false"]))
    assert html =~ ~s(id="openai-key-form")
    assert html =~ "Session-only access"
  end

  test "fails closed when a session credential expires while the page remains open", %{conn: conn} do
    assert {:ok, credential_ref} =
             OpenAICredentialStore.put("sk-test-expired-liveview-credential")

    conn = init_test_session(conn, %{"openai_credential_ref" => credential_ref})
    {:ok, view, _html} = live(conn, "/")

    view
    |> element(~s(button[phx-value-mode="openai"]))
    |> render_click()

    assert :ok = OpenAICredentialStore.delete(credential_ref)

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    html = render_async(view, 5_000)

    assert html =~ "The session OpenAI key is unavailable or expired."
    assert html =~ ~s(id="openai-key-form")
    assert html =~ @prompt
    assert html =~ ~s(id="agent_prompt_1")
    assert has_element?(view, ~s(button[phx-value-mode="deterministic"][aria-pressed="true"]))
    refute has_element?(view, ~s(button[phx-value-mode="openai"][disabled]))
  end

  test "does not render a trusted response for an unknown provider token", %{conn: conn} do
    Application.put_env(:obscura_jido_example, :agent_runner, UnknownTokenRunner)
    on_exit(fn -> Application.delete_env(:obscura_jido_example, :agent_runner) end)

    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#agent-form", agent: %{prompt: "Hello, I need some help."})
    |> render_submit()

    html = render_async(view, 1_000)

    assert html =~ "The model returned an unknown session reference."
    assert html =~ "Hello, I need some help."
    assert html =~ ~s(id="agent_prompt_1")
    refute html =~ "Trusted UI response"
  end

  test "does not emit Phoenix lifecycle logs for prompts", %{conn: conn} do
    %{level: previous_level} = :logger.get_primary_config()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :debug], fn ->
        {:ok, view, _html} = live(conn, "/")

        view
        |> form("#agent-form", agent: %{prompt: @prompt})
        |> render_submit()

        render_async(view, 5_000)
      end)

    refute log =~ "HANDLE EVENT"
    refute log =~ "MOUNT ObscuraJidoExampleWeb.AgentLive"
    refute log =~ "rachel.chen@example.test"
    refute log =~ "+1 202-555-0188"
  end

  test "does not log the opaque credential reference during mount", %{conn: conn} do
    assert {:ok, credential_ref} =
             OpenAICredentialStore.put("sk-test-session-log-credential")

    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    conn = init_test_session(conn, %{"openai_credential_ref" => credential_ref})

    %{level: previous_level} = :logger.get_primary_config()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, _view, _html} = live(conn, "/")
      end)

    refute log =~ credential_ref
    refute log =~ "MOUNT ObscuraJidoExampleWeb.AgentLive"
  end

  defp render_until(view, expected, attempts \\ 50)

  defp render_until(view, expected, attempts) when attempts > 0 do
    html = render(view)

    if html =~ expected do
      html
    else
      Process.sleep(10)
      render_until(view, expected, attempts - 1)
    end
  end

  defp render_until(view, expected, 0) do
    flunk("expected LiveView to render #{inspect(expected)}; got: #{render(view)}")
  end
end
