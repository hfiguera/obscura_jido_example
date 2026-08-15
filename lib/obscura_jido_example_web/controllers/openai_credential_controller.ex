defmodule ObscuraJidoExampleWeb.OpenAICredentialController do
  @moduledoc false

  use ObscuraJidoExampleWeb, :controller

  alias ObscuraJidoExample.OpenAICredentialStore

  @session_key :openai_credential_ref

  def create(conn, %{"openai_api_key" => key}) do
    case OpenAICredentialStore.put(key) do
      {:ok, credential_ref} ->
        delete_existing_credential(conn)

        conn
        |> configure_session(renew: true)
        |> put_session(@session_key, credential_ref)
        |> put_flash(:info, "OpenAI is enabled for this browser session.")
        |> redirect(to: ~p"/?provider=openai")

      {:error, :invalid_key} ->
        conn
        |> put_flash(:error, "Enter a valid OpenAI API key.")
        |> redirect(to: ~p"/?provider=openai")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Enter an OpenAI API key.")
    |> redirect(to: ~p"/?provider=openai")
  end

  def delete(conn, _params) do
    delete_existing_credential(conn)

    conn
    |> configure_session(renew: true)
    |> delete_session(@session_key)
    |> put_flash(:info, "The session OpenAI key was cleared.")
    |> redirect(to: ~p"/")
  end

  defp delete_existing_credential(conn) do
    conn
    |> get_session(@session_key)
    |> OpenAICredentialStore.delete()
  end
end
