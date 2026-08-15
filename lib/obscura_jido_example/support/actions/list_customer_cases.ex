defmodule ObscuraJidoExample.Support.Actions.ListCustomerCases do
  @moduledoc false

  use Jido.Action,
    name: "list_customer_cases",
    description: "List support cases for a synthetic non-PII customer reference.",
    category: "support",
    tags: ["read_only", "privacy_safe"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        customer_ref: Zoi.string(description: "The CUS reference returned by find_customer.")
      })

  alias ObscuraJidoExample.{Privacy, Support.Store}

  @impl true
  def run(%{customer_ref: customer_ref}, %{vault: vault} = context) do
    with {:ok, cases} <- Store.list_cases(customer_ref),
         {:ok, protected} <- Privacy.protect_cases(cases, vault) do
      audit(context, :ok, length(protected))
      {:ok, %{cases: protected, count: length(protected)}}
    else
      _reason ->
        audit(context, :not_found, 0)
        {:error, :customer_not_found}
    end
  end

  def run(_params, context) do
    audit(context, :invalid_request, 0)
    {:error, :invalid_case_lookup}
  end

  defp audit(%{audit_pid: pid}, outcome, count) when is_pid(pid),
    do: send(pid, {:tool_audit, "list_customer_cases", outcome, count})

  defp audit(_context, _outcome, _count), do: :ok
end
