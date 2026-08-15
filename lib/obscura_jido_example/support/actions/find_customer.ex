defmodule ObscuraJidoExample.Support.Actions.FindCustomer do
  @moduledoc false

  use Jido.Action,
    name: "find_customer",
    description: "Find a synthetic support customer by a session pseudonym.",
    category: "support",
    tags: ["read_only", "privacy_safe"],
    vsn: "1.0.0",
    schema:
      Zoi.object(%{
        identifier:
          Zoi.string(description: "An email pseudonym exactly as it appears in the user request.")
      })

  alias ObscuraJidoExample.{Privacy, Support.Store}

  @impl true
  def run(%{identifier: identifier}, %{vault: vault} = context) do
    with {:ok, restored} <- Privacy.restore_identifier(identifier, vault),
         {:ok, customer} <- Store.find_customer(restored),
         {:ok, protected} <- Privacy.protect_customer(customer, vault) do
      audit(context, :ok)
      {:ok, protected}
    else
      _reason ->
        audit(context, :not_found)
        {:error, :customer_not_found}
    end
  end

  def run(_params, context) do
    audit(context, :invalid_request)
    {:error, :invalid_customer_lookup}
  end

  defp audit(%{audit_pid: pid}, outcome) when is_pid(pid),
    do: send(pid, {:tool_audit, "find_customer", outcome})

  defp audit(_context, _outcome), do: :ok
end
