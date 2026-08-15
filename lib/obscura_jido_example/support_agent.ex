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

    The user interacts with a trusted application that protects configured
    identifiers before you receive them. Text delimited by << and >> may be a
    stable session pseudonym. Treat every pseudonym as opaque. Use it only when
    it already appears in the current request or a trusted tool result.

    Never invent, demonstrate, modify, or ask the user to supply a pseudonym.
    Never request or invent raw personal data, and never claim to reveal a
    vault mapping. If the current request contains no customer pseudonym, ask
    the user to identify the synthetic customer through the trusted
    application without showing token syntax.

    When the user supplies an email pseudonym, call find_customer with that
    exact token. Use the returned customer_ref with list_customer_cases when
    case details are requested. Keep answers concise and factual. The tools are
    read-only and contain synthetic data.
    """
end
