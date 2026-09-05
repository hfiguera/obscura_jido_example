defmodule ObscuraJidoExample.Privacy do
  @moduledoc """
  Owns the privacy boundary between trusted application code and the agent.

  Free-form text uses the configured fast or efficient profile. Domain records use an
  explicit field policy so names returned by trusted tools are also tokenized.
  """

  alias Obscura.Vault
  alias ObscuraJidoExample.PrivacyProfile

  @text_entities [:email, :phone, :credit_card, :us_ssn, :iban, :ip_address]

  @spec protect_prompt(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def protect_prompt(prompt, vault) when is_binary(prompt) do
    messages = [%{role: :user, content: prompt}]

    with {:ok, options} <- text_options(vault),
         {:ok, [%{content: protected}], ^vault} <-
           Obscura.LLM.redact_messages(messages, options) do
      {:ok, protected}
    end
  end

  @spec protect_customer(map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def protect_customer(customer, vault) when is_map(customer) do
    with {:ok, name} <- token(vault, :person, customer.name),
         {:ok, email} <- token(vault, :email, customer.email),
         {:ok, phone} <- token(vault, :phone, customer.phone) do
      {:ok,
       %{
         customer_ref: customer.customer_ref,
         name: name,
         email: email,
         phone: phone,
         plan: customer.plan,
         status: customer.status
       }}
    end
  end

  @spec protect_cases([map()], GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def protect_cases(cases, vault) when is_list(cases) do
    Enum.reduce_while(cases, {:ok, []}, fn item, {:ok, acc} ->
      case protect_text(item.note, vault) do
        {:ok, note} ->
          safe = Map.take(item, [:case_ref, :subject, :status]) |> Map.put(:note, note)
          {:cont, {:ok, [safe | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  @spec restore(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def restore(text, vault) when is_binary(text) do
    case Obscura.LLM.rehydrate_response(text, vault: vault, unknown: :error) do
      {:error, {:token_not_found, _shape}} -> {:error, :unknown_provider_token}
      result -> result
    end
  end

  @spec restore_identifier(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, atom()}
  def restore_identifier(identifier, vault) when is_binary(identifier) do
    case Vault.rehydrate(vault, identifier) do
      {:ok, restored} -> {:ok, restored}
      {:error, _reason} -> {:error, :identifier_unavailable}
    end
  end

  @spec vault_size(GenServer.server()) :: non_neg_integer()
  def vault_size(vault) do
    case Vault.info(vault) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp protect_text(text, vault) do
    with {:ok, options} <- text_options(vault),
         {:ok, result} <- Obscura.redact(text, options) do
      {:ok, result.text}
    end
  end

  defp text_options(vault) do
    with {:ok, profile} <- PrivacyProfile.reference() do
      entities =
        if profile == :fast, do: @text_entities, else: @text_entities ++ [:person, :location]

      {:ok,
       [
         profile: profile,
         entities: entities,
         vault: vault,
         operators: %{default: %{type: :pseudonymize}}
       ]}
    end
  end

  defp token(vault, entity, value), do: Vault.get_or_create(vault, entity, value)
end
