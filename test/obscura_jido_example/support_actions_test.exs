defmodule ObscuraJidoExample.SupportActionsTest do
  use ExUnit.Case, async: true

  alias ObscuraJidoExample.Privacy
  alias ObscuraJidoExample.Support.Actions.{FindCustomer, ListCustomerCases}

  setup do
    start_supervised!(Obscura.Vault.Memory)
    |> then(&{:ok, vault: &1})
  end

  test "rehydrates identifiers only inside the lookup action and returns protected fields", %{
    vault: vault
  } do
    assert {:ok, protected_prompt} =
             Privacy.protect_prompt("Find rachel.chen@example.test", vault)

    [email_token] = Regex.run(~r/<<EMAIL_\d{3}>>/, protected_prompt)

    assert {:ok, customer} =
             FindCustomer.run(%{identifier: email_token}, %{vault: vault, audit_pid: self()})

    assert_receive {:tool_audit, "find_customer", :ok}
    assert customer.customer_ref == "CUS-1042"
    assert customer.name == "<<PERSON_001>>"
    assert customer.email == email_token

    customer_blob = inspect(customer)
    refute customer_blob =~ "Rachel Chen"
    refute customer_blob =~ "rachel.chen@example.test"
    refute customer_blob =~ "+1 202-555-0188"
  end

  test "pseudonymizes case notes before they return to Jido", %{vault: vault} do
    assert {:ok, %{cases: [case_item], count: 1}} =
             ListCustomerCases.run(
               %{customer_ref: "CUS-1042"},
               %{vault: vault, audit_pid: self()}
             )

    assert_receive {:tool_audit, "list_customer_cases", :ok, 1}
    refute case_item.note =~ "rachel.chen@example.test"
    refute case_item.note =~ "+1 202-555-0188"
    assert case_item.note =~ "<<EMAIL_001>>"
    assert case_item.note =~ "<<PHONE_001>>"
  end

  test "returns a bounded error for an unknown pseudonym", %{vault: vault} do
    assert {:error, :customer_not_found} =
             FindCustomer.run(%{identifier: "<<EMAIL_999>>"}, %{
               vault: vault,
               audit_pid: self()
             })

    assert_receive {:tool_audit, "find_customer", :not_found}
  end
end
