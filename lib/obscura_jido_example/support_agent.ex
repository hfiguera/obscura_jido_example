defmodule ObscuraJidoExample.SupportAgent do
  @moduledoc "A narrowly scoped, read-only support agent."

  alias ObscuraJidoExample.Support.Actions.{
    FindCustomer,
    IgnoreObservation,
    ListCustomerCases
  }

  use Jido.AI.Agent,
    name: "privacy_safe_support_agent",
    description: "Looks up synthetic support records without receiving raw PII.",
    model: :fast,
    tools: [FindCustomer, ListCustomerCases],
    signal_routes: [
      {"ai.tool.started", IgnoreObservation},
      {"ai.tool.result", IgnoreObservation}
    ],
    max_iterations: 5,
    max_tokens: 700,
    streaming: true,
    request_policy: :reject,
    tool_max_retries: 0,
    observability: %{
      emit_telemetry?: true,
      emit_lifecycle_signals?: false,
      emit_llm_deltas?: false,
      redact_tool_args?: true
    },
    llm_opts: [reasoning_effort: :low, telemetry: [payloads: :none]],
    system_prompt: """
    You are a support assistant operating only on pseudonymized data.

    Tokens such as <<EMAIL_001>> and <<PERSON_001>> are stable session
    pseudonyms. Preserve them exactly. Never request or invent raw personal
    data, and never claim to reveal a vault mapping.

    When the user supplies an email pseudonym, call find_customer with that
    exact token. Use the returned customer_ref with list_customer_cases when
    case details are requested. Keep answers concise and factual. The tools are
    read-only and contain synthetic data.
    """
end
