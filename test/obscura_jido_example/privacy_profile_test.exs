defmodule ObscuraJidoExample.PrivacyProfileTest do
  use ExUnit.Case, async: false

  alias ObscuraJidoExample.{AgentRunner, Privacy, PrivacyProfile}

  setup do
    previous =
      Application.get_all_env(:obscura_jido_example)
      |> Keyword.take([:privacy_profile, :privacy_prepare_options])

    on_exit(fn ->
      for key <- [:privacy_profile, :privacy_prepare_options],
          do: Application.delete_env(:obscura_jido_example, key)

      for {key, value} <- previous, do: Application.put_env(:obscura_jido_example, key, value)
    end)

    {:ok, vault: start_supervised!(Obscura.Vault.Memory)}
  end

  test "fast mode has no native runtime and remains available without model assets" do
    Application.put_env(:obscura_jido_example, :privacy_profile, :fast)
    assert PrivacyProfile.children() == []
    assert PrivacyProfile.reference() == {:ok, :fast}
  end

  test "efficient mode fails before running the agent when assets are missing", %{vault: vault} do
    Application.put_env(:obscura_jido_example, :privacy_profile, :efficient)

    Application.put_env(:obscura_jido_example, :privacy_prepare_options,
      model_dir: "/missing-obscura-test-assets",
      native_binary: "/missing-obscura-test-native"
    )

    [child] = PrivacyProfile.children()
    preparer = start_supervised!(child)
    assert {:error, %Obscura.Diagnostic{}} = Obscura.Profile.Preparer.await(preparer)

    assert {:error, :privacy_unavailable} =
             Privacy.protect_prompt("Alice Smith alice@example.test", vault)

    assert {:error, :privacy_unavailable} =
             AgentRunner.run("Find alice@example.test", vault, mode: :deterministic)

    assert {:error, :privacy_unavailable} =
             Privacy.protect_cases(
               [%{case_ref: "C-1", subject: "Help", status: "open", note: "Alice Smith"}],
               vault
             )

    assert Privacy.vault_size(vault) == 0
  end
end
