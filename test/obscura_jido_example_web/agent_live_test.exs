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

  @prompt "Find rachel.chen@example.test and summarize her support cases. Her phone is +1 202-555-0188."

  test "runs the deterministic agent and exposes both sides of the privacy boundary", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Privacy-safe support agent"
    assert html =~ "Session boundary ready"

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    html = render_async(view, 5_000)

    assert html =~ "&lt;&lt;EMAIL_001&gt;&gt;"
    assert html =~ "rachel.chen@example.test"
    assert html =~ "Rachel Chen"
    assert html =~ "2 read-only tools completed"
    assert html =~ "3 mappings"
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
    assert has_element?(view, "#openai-api-key[disabled]")
    assert has_element?(view, "#openai-key-form button[type=submit][disabled]")
    assert has_element?(view, ".run-command.running[disabled]")
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

  test "clears session mappings and removes the restored conversation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#agent-form", agent: %{prompt: @prompt})
    |> render_submit()

    assert render_async(view, 5_000) =~ "3 mappings"
    assert view |> element("#clear-vault") |> render_click() =~ "0 mappings"
    refute render(view) =~ "Rachel Chen"
  end

  test "keeps OpenAI disabled when credentials are absent", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert has_element?(view, ~s(button[phx-value-mode="openai"][disabled]))
    assert html =~ ~s(id="openai-key-form")
    refute html =~ ~s(id="clear-openai-key-form")
  end

  test "enables OpenAI from an opaque browser-session credential", %{conn: conn} do
    key = "sk-test-liveview-credential"
    assert {:ok, credential_ref} = OpenAICredentialStore.put(key)
    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    conn = init_test_session(conn, %{"openai_credential_ref" => credential_ref})
    {:ok, view, html} = live(conn, "/")

    refute has_element?(view, ~s(button[phx-value-mode="openai"][disabled]))
    assert html =~ "Session key ready"
    assert html =~ ~s(id="clear-openai-key-form")
    refute html =~ ~s(id="openai-key-form")
    refute html =~ key
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
    assert has_element?(view, ~s(button[phx-value-mode="openai"][disabled]))
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
