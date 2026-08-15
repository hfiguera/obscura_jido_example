defmodule ObscuraJidoExampleWeb.OpenAICredentialControllerTest do
  use ObscuraJidoExampleWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias ObscuraJidoExample.OpenAICredentialStore

  @key "sk-test-controller-credential"

  test "stores only an opaque credential reference in the session", %{conn: conn} do
    conn = post(conn, ~p"/session/openai-key", %{"openai_api_key" => @key})
    credential_ref = get_session(conn, :openai_credential_ref)
    on_exit(fn -> OpenAICredentialStore.delete(credential_ref) end)

    assert redirected_to(conn) == ~p"/?provider=openai"
    assert is_binary(credential_ref)
    refute credential_ref == @key
    assert OpenAICredentialStore.available?(credential_ref)
    refute conn.resp_body =~ @key
    refute inspect(conn.resp_cookies, limit: :infinity) =~ @key
  end

  test "clears the session credential and its in-memory value", %{conn: conn} do
    conn = post(conn, ~p"/session/openai-key", %{"openai_api_key" => @key})
    credential_ref = get_session(conn, :openai_credential_ref)

    conn = conn |> recycle() |> delete(~p"/session/openai-key")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :openai_credential_ref) == nil
    refute OpenAICredentialStore.available?(credential_ref)
  end

  test "rejects invalid credentials", %{conn: conn} do
    conn = post(conn, ~p"/session/openai-key", %{"openai_api_key" => "short"})

    assert redirected_to(conn) == ~p"/?provider=openai"
    assert get_session(conn, :openai_credential_ref) == nil
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Enter a valid OpenAI API key."
  end

  test "filters the submitted key from Phoenix logs", %{conn: conn} do
    %{level: previous_level} = :logger.get_primary_config()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :debug], fn ->
        conn = post(conn, ~p"/session/openai-key", %{"openai_api_key" => @key})
        credential_ref = get_session(conn, :openai_credential_ref)
        OpenAICredentialStore.delete(credential_ref)
      end)

    refute log =~ @key
  end
end
