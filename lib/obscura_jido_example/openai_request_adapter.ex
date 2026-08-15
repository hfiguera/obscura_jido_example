defmodule ObscuraJidoExample.OpenAIRequestAdapter do
  @moduledoc false

  @behaviour ReqLLM.FinchRequestAdapter

  alias ObscuraJidoExample.OpenAICredentialStore

  @credential_header "x-obscura-openai-credential-ref"
  @placeholder_authorization "Bearer obscura-session-key-resolved-at-request-time"
  @openai_destination {:https, "api.openai.com", 443}
  @allowed_paths ["/v1/chat/completions", "/v1/responses"]

  defmodule BoundaryError do
    @moduledoc false

    defexception message: "OpenAI credential boundary rejected the request"
  end

  @impl true
  def call(%Finch.Request{} = request) do
    case take_credential_reference(request.headers) do
      :unmarked ->
        request

      {:ok, credential_ref, headers} ->
        authorize(request, credential_ref, headers)

      :error ->
        reject()
    end
  end

  defp authorize(request, credential_ref, headers) do
    with true <- allowed_request?(request),
         {:ok, headers} <- take_placeholder_authorization(headers),
         %Finch.Request{} = request <-
           OpenAICredentialStore.with_key(credential_ref, fn key ->
             %{request | headers: [{"authorization", "Bearer " <> key} | headers]}
           end) do
      request
    else
      _unavailable_or_invalid -> reject()
    end
  end

  defp allowed_request?(%Finch.Request{
         method: "POST",
         scheme: scheme,
         host: host,
         port: port,
         path: path,
         query: query,
         unix_socket: nil
       }) do
    is_nil(query) and path in @allowed_paths and
      {scheme, host, port} in allowed_destinations()
  end

  defp allowed_request?(_request), do: false

  defp allowed_destinations do
    configured =
      Application.get_env(:obscura_jido_example, __MODULE__, [])
      |> Keyword.get(:additional_destinations, [])

    [@openai_destination | configured]
  end

  defp take_credential_reference(headers) do
    case take_header(headers, @credential_header) do
      {[], ^headers} ->
        :unmarked

      {[credential_ref], remaining} when is_binary(credential_ref) ->
        {:ok, credential_ref, remaining}

      _missing_or_ambiguous ->
        :error
    end
  end

  defp take_placeholder_authorization(headers) do
    case take_header(headers, "authorization") do
      {[@placeholder_authorization], remaining} -> {:ok, remaining}
      _missing_ambiguous_or_unexpected -> :error
    end
  end

  defp take_header(headers, expected_name) do
    Enum.reduce(headers, {[], []}, fn
      {name, value} = header, {values, remaining} when is_binary(name) ->
        if String.downcase(name) == expected_name,
          do: {[value | values], remaining},
          else: {values, [header | remaining]}

      header, {values, remaining} ->
        {values, [header | remaining]}
    end)
    |> then(fn {values, remaining} -> {Enum.reverse(values), Enum.reverse(remaining)} end)
  end

  defp reject, do: raise(BoundaryError)
end
