defmodule ObscuraJidoExample.EfficientPrivacyTest do
  use ExUnit.Case, async: false

  @moduletag efficient: true
  alias Obscura.Profile.Preparer
  alias ObscuraJidoExample.{AgentRunner, Privacy, PrivacyProfile}

  setup do
    previous =
      Application.get_all_env(:obscura_jido_example)
      |> Keyword.take([:privacy_profile, :privacy_prepare_options])

    Application.put_env(:obscura_jido_example, :privacy_profile, :efficient)
    Application.put_env(:obscura_jido_example, :privacy_prepare_options, workers: 2)

    on_exit(fn ->
      for key <- [:privacy_profile, :privacy_prepare_options],
          do: Application.delete_env(:obscura_jido_example, key)

      for {key, value} <- previous, do: Application.put_env(:obscura_jido_example, key, value)
    end)

    [child] = PrivacyProfile.children()
    preparer = start_supervised!(child)
    assert {:ok, runtime} = Preparer.await(preparer)
    {:ok, runtime: runtime, vault: start_supervised!(Obscura.Vault.Memory)}
  end

  test "protects names and locations in prompts and notes while preserving exact rehydration", %{
    vault: vault,
    runtime: runtime
  } do
    raw = "José García lives in London. Email jose@example.test."
    assert {:ok, protected} = Privacy.protect_prompt(raw, vault)
    refute protected =~ "José García"
    refute protected =~ "London"
    refute protected =~ "jose@example.test"
    assert protected =~ "<<PERSON_"
    assert protected =~ "<<LOCATION_"
    assert {:ok, ^raw} = Privacy.restore(protected, vault)

    assert {:ok, [safe]} =
             Privacy.protect_cases(
               [%{case_ref: "C-1", subject: "Help", status: "open", note: raw}],
               vault
             )

    assert safe.note == protected
    assert {:ok, ^runtime} = PrivacyProfile.reference()

    other_vault = start_supervised!(Obscura.Vault.Memory, id: :other_vault)
    assert {:ok, other} = Privacy.protect_prompt("Alice Smith lives in Paris.", other_vault)
    assert other =~ "<<PERSON_001>>"
    assert {:ok, "José García"} = Privacy.restore("<<PERSON_001>>", vault)
    assert {:ok, "Alice Smith"} = Privacy.restore("<<PERSON_001>>", other_vault)
  end

  test "runs the real Jido loop with names and locations protected", %{vault: vault} do
    prompt =
      "Find rachel.chen@example.test for Rachel Chen in London and summarize her support cases."

    assert {:ok, result} = AgentRunner.run(prompt, vault, mode: :deterministic)
    refute result.protected_prompt =~ "Rachel Chen"
    refute result.protected_prompt =~ "London"
    refute result.protected_prompt =~ "rachel.chen@example.test"
    assert {:ok, ^prompt} = Privacy.restore(result.protected_prompt, vault)
    assert Enum.map(result.tool_steps, & &1.tool) == ["find_customer", "list_customer_cases"]
  end

  test "model limits and runtime shutdown return errors without fast fallback", %{vault: vault} do
    # Keep tokens short so OTP 27's regex engine reaches the native byte-limit check.
    oversized = String.duplicate("x ", 524_288) <> "x"

    assert {:error, {:recognizer_failed, :spacy_cpu, :spacy_input_limit}} =
             Privacy.protect_prompt(oversized, vault)

    assert {:error, :prompt_too_large} =
             AgentRunner.run(String.duplicate("x", 1_048_577), vault, mode: :deterministic)

    assert Privacy.vault_size(vault) == 0
    assert {:ok, _} = Privacy.protect_prompt("Alice Smith lives in London.", vault)
    assert :ok = stop_supervised(PrivacyProfile)
    assert {:error, :privacy_unavailable} = Privacy.protect_prompt("alice@example.test", vault)

    assert {:error, :privacy_unavailable} =
             AgentRunner.run("Find alice@example.test", vault, mode: :deterministic)
  end
end
