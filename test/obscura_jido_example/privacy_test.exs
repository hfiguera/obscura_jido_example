defmodule ObscuraJidoExample.PrivacyTest do
  use ExUnit.Case, async: true

  alias ObscuraJidoExample.Privacy

  setup do
    start_supervised!(Obscura.Vault.Memory)
    |> then(&{:ok, vault: &1})
  end

  test "pseudonymizes provider-bound text and restores it only through the vault", %{vault: vault} do
    raw = "Contact privacy-canary@example.test at +1 202-555-0199."

    assert {:ok, protected} = Privacy.protect_prompt(raw, vault)
    refute protected =~ "privacy-canary@example.test"
    refute protected =~ "+1 202-555-0199"
    assert protected =~ "<<EMAIL_001>>"
    assert protected =~ "<<PHONE_001>>"

    assert {:ok, restored} = Privacy.restore(protected, vault)
    assert restored == raw
  end

  test "accepts token-free provider responses", %{vault: vault} do
    assert {:ok, "How can I help?"} = Privacy.restore("How can I help?", vault)
  end

  test "rejects provider tokens that have no session mapping", %{vault: vault} do
    assert {:error, :unknown_provider_token} =
             Privacy.restore("Provide <<EMAIL_001>>.", vault)
  end

  test "applies an explicit field policy to trusted customer records", %{vault: vault} do
    customer = %{
      customer_ref: "CUS-1",
      name: "Private Person",
      email: "private.person@example.test",
      phone: "+1 303-555-0108",
      plan: "Pro",
      status: "active"
    }

    assert {:ok, protected} = Privacy.protect_customer(customer, vault)
    protected_blob = inspect(protected)

    refute protected_blob =~ customer.name
    refute protected_blob =~ customer.email
    refute protected_blob =~ customer.phone
    assert protected.name == "<<PERSON_001>>"
    assert protected.email == "<<EMAIL_001>>"
    assert protected.phone == "<<PHONE_001>>"
    assert protected.customer_ref == "CUS-1"
  end
end
