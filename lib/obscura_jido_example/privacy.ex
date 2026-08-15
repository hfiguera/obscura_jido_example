defmodule ObscuraJidoExample.Privacy do
  @moduledoc """
  Owns the privacy boundary between trusted application code and the agent.

  Free-form text uses Obscura's deterministic profile. Domain records use an
  explicit field policy so names returned by trusted tools are also tokenized.
  """

  alias Obscura.Vault

  @text_entities [:email, :phone, :credit_card, :us_ssn, :iban, :ip_address]
  @text_options [
    profile: :fast,
    entities: @text_entities,
    operators: %{default: %{type: :pseudonymize}}
  ]

  @spec protect_prompt(String.t(), GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def protect_prompt(prompt, vault) when is_binary(prompt) do
    messages = [%{role: :user, content: prompt}]

    with {:ok, [%{content: protected}], ^vault} <-
           Obscura.LLM.redact_messages(messages, Keyword.put(@text_options, :vault, vault)) do
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
    Obscura.LLM.rehydrate_response(text, vault: vault)
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
    case Obscura.redact(text, Keyword.put(@text_options, :vault, vault)) do
      {:ok, result} -> {:ok, result.text}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token(vault, entity, value), do: Vault.get_or_create(vault, entity, value)
end
