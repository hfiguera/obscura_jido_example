defmodule ObscuraJidoExample.OpenAICredentialStoreTest do
  use ExUnit.Case, async: true

  alias ObscuraJidoExample.OpenAICredentialStore
  alias ObscuraJidoExample.OpenAICredentialStore.Secret

  @key "sk-test-session-credential"

  test "stores an owned, inspect-redacted credential behind an opaque reference" do
    store = start_supervised!({OpenAICredentialStore, name: nil, ttl_ms: 1_000})
    source = String.duplicate("x", 1_000_000) <> @key <> String.duplicate("y", 1_000)
    key = binary_part(source, 1_000_000, byte_size(@key))

    assert {:ok, credential_ref} = OpenAICredentialStore.put(key, store)
    assert byte_size(credential_ref) == 43
    refute credential_ref == @key
    assert OpenAICredentialStore.available?(credential_ref, store)

    assert :owned =
             OpenAICredentialStore.with_key(
               credential_ref,
               fn stored_key ->
                 assert stored_key == @key
                 assert :binary.referenced_byte_size(stored_key) == byte_size(stored_key)
                 :owned
               end,
               store
             )

    refute inspect(:sys.get_state(store), limit: :infinity) =~ @key
    refute inspect(%Secret{value: @key}) =~ @key
    assert inspect(%Secret{value: @key}) == "#OpenAIKey<redacted>"
  end

  test "rejects malformed keys without storing them" do
    store = start_supervised!({OpenAICredentialStore, name: nil, ttl_ms: 1_000})

    assert {:error, :invalid_key} = OpenAICredentialStore.put("short", store)
    assert {:error, :invalid_key} = OpenAICredentialStore.put(" #{@key}", store)
    assert {:error, :invalid_key} = OpenAICredentialStore.put(@key <> "\n", store)
    assert {:error, :invalid_key} = OpenAICredentialStore.put(String.duplicate("x", 513), store)
  end

  test "expires and deletes credentials" do
    store = start_supervised!({OpenAICredentialStore, name: nil, ttl_ms: 25})

    assert {:ok, expired_ref} = OpenAICredentialStore.put(@key, store)
    assert eventually(fn -> not OpenAICredentialStore.available?(expired_ref, store) end)

    assert {:ok, deleted_ref} = OpenAICredentialStore.put(@key, store)
    assert :ok = OpenAICredentialStore.delete(deleted_ref, store)
    refute OpenAICredentialStore.available?(deleted_ref, store)

    assert {:error, :credential_unavailable} =
             OpenAICredentialStore.with_key(deleted_ref, fn _key -> :unexpected end, store)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(5)
        eventually(fun, attempts - 1)
    end
  end
end
