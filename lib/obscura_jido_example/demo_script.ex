defmodule ObscuraJidoExample.DemoScript do
  @moduledoc """
  Builds a deterministic model script while preserving the real Jido runtime
  and tool execution path.
  """

  require Jido.AI.Test

  alias ObscuraJidoExample.{Privacy, Support.Store}

  @email_token ~r/<<EMAIL_\d{3}>>/

  @spec request_options(String.t(), GenServer.server()) :: keyword()
  def request_options(protected_prompt, vault) do
    try do
      protected_prompt
      |> build(vault)
      |> Jido.AI.Test.react_opts()
    after
      Jido.AI.Test.reset_react_scripts()
    end
  end

  defp build(protected_prompt, vault) do
    case Regex.run(@email_token, protected_prompt) do
      [email_token] -> build_customer_script(protected_prompt, email_token, vault)
      nil -> build_missing_identifier_script(protected_prompt)
    end
  end

  defp build_customer_script(protected_prompt, email_token, vault) do
    case known_customer(email_token, vault) do
      {:ok, customer} -> build_found_script(protected_prompt, email_token, customer)
      :error -> build_not_found_script(protected_prompt, email_token)
    end
  end

  defp build_found_script(protected_prompt, email_token, customer) do
    {:ok, cases} = Store.list_cases(customer.customer_ref)
    case_item = hd(cases)

    Jido.AI.Test.expect_react do
      Jido.AI.Test.user(protected_prompt)
      Jido.AI.Test.call("find_customer", %{identifier: email_token})

      Jido.AI.Test.call("list_customer_cases", %{
        customer_ref: customer.customer_ref
      })

      Jido.AI.Test.answer(
        "I found <<PERSON_001>> on the #{customer.plan} plan. " <>
          "#{case_item.case_ref} is #{human_status(case_item.status)}. " <>
          "Use #{email_token} or <<PHONE_001>> for the follow-up."
      )
    end
  end

  defp build_not_found_script(protected_prompt, email_token) do
    Jido.AI.Test.expect_react do
      Jido.AI.Test.user(protected_prompt)
      Jido.AI.Test.call("find_customer", %{identifier: email_token})
      Jido.AI.Test.answer("No synthetic customer matched #{email_token}.")
    end
  end

  defp build_missing_identifier_script(protected_prompt) do
    Jido.AI.Test.expect_react do
      Jido.AI.Test.user(protected_prompt)
      Jido.AI.Test.answer("Provide a customer email so I can run the support lookup.")
    end
  end

  defp known_customer(email_token, vault) do
    with {:ok, email} <- Privacy.restore_identifier(email_token, vault),
         {:ok, customer} <- Store.find_customer(email) do
      {:ok, customer}
    else
      _ -> :error
    end
  end

  defp human_status("waiting_on_support"), do: "waiting on support"
  defp human_status(status), do: String.replace(status, "_", " ")
end
