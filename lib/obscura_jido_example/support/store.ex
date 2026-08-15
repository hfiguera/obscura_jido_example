defmodule ObscuraJidoExample.Support.Store do
  @moduledoc "A read-only synthetic support dataset used by the demonstration."

  @customers %{
    "rachel.chen@example.test" => %{
      customer_ref: "CUS-1042",
      name: "Rachel Chen",
      email: "rachel.chen@example.test",
      phone: "+1 202-555-0188",
      plan: "Pro",
      status: "active"
    },
    "marcus.lee@example.test" => %{
      customer_ref: "CUS-2084",
      name: "Marcus Lee",
      email: "marcus.lee@example.test",
      phone: "+1 415-555-0137",
      plan: "Starter",
      status: "active"
    }
  }

  @cases %{
    "CUS-1042" => [
      %{
        case_ref: "CASE-7301",
        subject: "Invoice copy requested",
        status: "waiting_on_support",
        note: "Send the corrected invoice to rachel.chen@example.test or call +1 202-555-0188."
      }
    ],
    "CUS-2084" => [
      %{
        case_ref: "CASE-8842",
        subject: "Workspace access restored",
        status: "resolved",
        note: "Confirmation was sent to marcus.lee@example.test."
      }
    ]
  }

  @spec find_customer(String.t()) :: {:ok, map()} | {:error, :customer_not_found}
  def find_customer(identifier) when is_binary(identifier) do
    normalized = identifier |> String.trim() |> String.downcase()

    case Map.fetch(@customers, normalized) do
      {:ok, customer} -> {:ok, customer}
      :error -> {:error, :customer_not_found}
    end
  end

  @spec list_cases(String.t()) :: {:ok, [map()]} | {:error, :customer_not_found}
  def list_cases(customer_ref) when is_binary(customer_ref) do
    case Map.fetch(@cases, customer_ref) do
      {:ok, cases} -> {:ok, cases}
      :error -> {:error, :customer_not_found}
    end
  end
end
