defmodule ObscuraJidoExample.ConfigurationTest do
  use ExUnit.Case, async: true

  test "dependency observability remains payload-free" do
    assert Application.get_env(:jido, :telemetry)[:log_args] == :none
    assert Application.get_env(:jido, :observability)[:debug_events] == :off
    assert Application.get_env(:jido, :observability)[:redact_sensitive]
    assert Application.get_env(:req_llm, :telemetry)[:payloads] == :none
  end

  test "Phoenix filters application values and CSRF tokens" do
    raw = "Find private-person@example.test"
    csrf = "csrf-secret-canary"

    filtered =
      Phoenix.Logger.filter_values(%{
        "agent" => %{"prompt" => raw},
        "_csrf_token" => csrf,
        "_mounts" => "0"
      })

    assert filtered["agent"]["prompt"] == "[FILTERED]"
    assert filtered["_csrf_token"] == "[FILTERED]"
    assert filtered["_mounts"] == "0"
    refute inspect(filtered) =~ raw
    refute inspect(filtered) =~ csrf
  end

  test "the sensitive LiveView disables lifecycle logging" do
    assert ObscuraJidoExampleWeb.AgentLive.__live__().log == false
  end
end
