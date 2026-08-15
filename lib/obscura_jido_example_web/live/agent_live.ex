defmodule ObscuraJidoExampleWeb.AgentLive do
  @moduledoc false

  use ObscuraJidoExampleWeb, :live_view

  alias Obscura.Vault
  alias Obscura.Vault.Memory
  alias ObscuraJidoExample.{AgentRunner, OpenAICredentialStore}
  alias ObscuraJidoExampleWeb.Markdown

  @sample_prompt "Find rachel.chen@example.test and summarize her support cases. Her phone is +1 202-555-0188."
  @max_stream_bytes 64_000

  @impl true
  def mount(_params, session, socket) do
    credential_ref = session_credential_ref(session)
    openai_session? = OpenAICredentialStore.available?(credential_ref)

    socket =
      socket
      |> assign(:page_title, "Privacy-Safe Jido Agent")
      |> assign(:mode, :deterministic)
      |> assign(:openai_available?, openai_session?)
      |> assign(:openai_session?, openai_session?)
      |> assign(:openai_credential_ref, openai_session? && credential_ref)
      |> assign(:configured_model, AgentRunner.configured_model())
      |> assign(:running?, false)
      |> assign(:result, nil)
      |> assign(:messages, [])
      |> assign(:run_ref, nil)
      |> assign(:run_started_at, nil)
      |> assign(:activity_phase, nil)
      |> assign(:live_request, nil)
      |> assign(:provider_stream, "")
      |> assign(:tool_activity, [])
      |> assign(:error, nil)
      |> assign(:vault, nil)
      |> assign(:vault_size, 0)
      |> assign(:prompt_revision, 0)
      |> assign_form(@sample_prompt)
      |> maybe_start_vault()

    {:ok, socket}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => "deterministic"}, socket),
    do: {:noreply, assign(socket, mode: :deterministic, error: nil)}

  def handle_event(
        "set_mode",
        %{"mode" => "openai"},
        %{assigns: %{openai_available?: true}} = socket
      ),
      do: {:noreply, assign(socket, mode: :openai, error: nil)}

  def handle_event("set_mode", %{"mode" => "openai"}, socket),
    do:
      {:noreply,
       assign(socket, error: "Add a session OpenAI key before selecting this provider.")}

  def handle_event("use_sample", _params, socket) do
    {:noreply,
     socket
     |> update(:prompt_revision, &(&1 + 1))
     |> assign_form(@sample_prompt)}
  end

  def handle_event("run", %{"agent" => %{"prompt" => prompt}}, socket) do
    if socket.assigns.running? or is_nil(socket.assigns.vault) do
      {:noreply, socket}
    else
      vault = socket.assigns.vault
      mode = socket.assigns.mode
      credential_ref = socket.assigns.openai_credential_ref
      live_view = self()
      run_ref = make_ref()
      runner = runner_module()

      socket =
        socket
        |> assign(:running?, true)
        |> assign(:result, nil)
        |> assign(:messages, [])
        |> assign(:run_ref, run_ref)
        |> assign(:run_started_at, System.system_time(:millisecond))
        |> assign(:activity_phase, :protecting)
        |> assign(:live_request, nil)
        |> assign(:provider_stream, "")
        |> assign(:tool_activity, [])
        |> assign(:error, nil)
        |> assign_form("")
        |> start_async(:agent_run, fn ->
          runner.run(prompt, vault,
            mode: mode,
            credential_ref: credential_ref,
            progress_to: {live_view, run_ref}
          )
        end)

      {:noreply, socket}
    end
  end

  def handle_event("clear_vault", _params, %{assigns: %{running?: false, vault: vault}} = socket)
      when not is_nil(vault) do
    case Vault.clear(vault) do
      :ok ->
        {:noreply,
         socket
         |> assign(:result, nil)
         |> assign(:messages, [])
         |> assign(:vault_size, 0)
         |> assign(:error, nil)
         |> assign_form(@sample_prompt)}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "The session vault could not be cleared.")}
    end
  end

  def handle_event("clear_vault", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {AgentRunner, run_ref, event},
        %{assigns: %{running?: true, run_ref: run_ref}} = socket
      ) do
    {:noreply, apply_progress(socket, event)}
  end

  def handle_info({AgentRunner, _stale_run_ref, _event}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:agent_run, {:ok, {:ok, result}}, socket) do
    messages = [
      %{role: :user, content: result.protected_prompt, label: "Protected request"},
      %{
        role: :assistant,
        content: Markdown.to_safe_html(result.display_answer),
        label: "Trusted UI response"
      }
    ]

    {:noreply,
     assign(socket,
       running?: false,
       result: result,
       messages: messages,
       run_ref: nil,
       run_started_at: nil,
       activity_phase: nil,
       live_request: nil,
       provider_stream: "",
       tool_activity: [],
       vault_size: result.vault_size,
       error: nil
     )}
  end

  def handle_async(:agent_run, {:ok, {:error, :openai_unavailable}}, socket) do
    {:noreply,
     assign(socket,
       running?: false,
       run_ref: nil,
       run_started_at: nil,
       activity_phase: nil,
       mode: :deterministic,
       openai_available?: false,
       openai_session?: false,
       openai_credential_ref: nil,
       error: "The session OpenAI key is unavailable or expired."
     )}
  end

  def handle_async(:agent_run, {:ok, {:error, reason}}, socket) do
    {:noreply, finish_with_error(socket, error_message(reason))}
  end

  def handle_async(:agent_run, {:exit, _reason}, socket) do
    {:noreply, finish_with_error(socket, "The isolated agent run failed safely.")}
  end

  defp apply_progress(socket, {:phase, phase})
       when phase in [:protecting, :requesting, :tools, :streaming, :restoring],
       do: assign(socket, :activity_phase, phase)

  defp apply_progress(socket, {:protected_prompt, prompt}) when is_binary(prompt),
    do: assign(socket, :live_request, prompt)

  defp apply_progress(socket, {:provider_delta, delta}) when is_binary(delta) do
    current = socket.assigns.provider_stream
    remaining = max(@max_stream_bytes - byte_size(current), 0)
    assign(socket, :provider_stream, current <> safe_stream_prefix(delta, remaining))
  end

  defp apply_progress(socket, {:provider_text, text}) when is_binary(text),
    do: assign(socket, :provider_stream, truncate_stream(text))

  defp apply_progress(socket, {:tool_started, name}) when is_binary(name) do
    tool = %{name: name, status: :running}
    assign(socket, :tool_activity, socket.assigns.tool_activity ++ [tool])
  end

  defp apply_progress(socket, {:tool_completed, name, status})
       when is_binary(name) and status in [:ok, :error] do
    assign(socket, :tool_activity, complete_tool(socket.assigns.tool_activity, name, status))
  end

  defp apply_progress(socket, _event), do: socket

  defp complete_tool(tools, name, status) do
    {tools, _updated?} =
      Enum.map_reduce(tools, false, fn
        %{name: ^name, status: :running} = tool, false ->
          {%{tool | status: status}, true}

        tool, updated? ->
          {tool, updated?}
      end)

    tools
  end

  defp truncate_stream(text), do: safe_stream_prefix(text, @max_stream_bytes)

  defp safe_stream_prefix(text, max_bytes) when max_bytes > 0 do
    if String.valid?(text) do
      text
      |> binary_part(0, min(byte_size(text), max_bytes))
      |> trim_invalid_tail()
    else
      ""
    end
  end

  defp safe_stream_prefix(_text, _max_bytes), do: ""

  defp trim_invalid_tail(text) do
    if String.valid?(text),
      do: text,
      else: trim_invalid_tail(binary_part(text, 0, byte_size(text) - 1))
  end

  defp finish_with_error(socket, message) do
    assign(socket,
      running?: false,
      run_ref: nil,
      run_started_at: nil,
      activity_phase: nil,
      error: message
    )
  end

  defp maybe_start_vault(socket) do
    if connected?(socket) do
      case Memory.start_link() do
        {:ok, vault} -> assign(socket, vault: vault)
        {:error, _reason} -> assign(socket, error: "The session vault is unavailable.")
      end
    else
      socket
    end
  end

  defp session_credential_ref(%{"openai_credential_ref" => credential_ref})
       when is_binary(credential_ref),
       do: credential_ref

  defp session_credential_ref(_session), do: nil

  defp assign_form(socket, prompt) do
    assign(socket, :form, to_form(%{"prompt" => prompt}, as: :agent))
  end

  defp provider_label(:deterministic, _model), do: "Scripted model boundary"
  defp provider_label(:openai, model), do: model

  defp phase_title(:protecting), do: "Protecting identifiers"
  defp phase_title(:requesting), do: "Waiting for the model"
  defp phase_title(:tools), do: "Running trusted tools"
  defp phase_title(:streaming), do: "Receiving the answer"
  defp phase_title(:restoring), do: "Restoring known tokens"
  defp phase_title(_phase), do: "Preparing the agent"

  defp phase_description(:protecting), do: "Raw identifiers stay inside this session."
  defp phase_description(:requesting), do: "The provider sees pseudonyms, not raw PII."
  defp phase_description(:tools), do: "Read-only lookups are running locally."
  defp phase_description(:streaming), do: "Tokenized text is arriving from the provider."
  defp phase_description(:restoring), do: "The complete answer is being restored locally."
  defp phase_description(_phase), do: "The isolated request is starting."

  defp tool_label("find_customer"), do: "Find customer"
  defp tool_label("list_customer_cases"), do: "List customer cases"
  defp tool_label(_name), do: "Trusted tool"

  defp tool_status_label(:running), do: "Running"
  defp tool_status_label(:ok), do: "Complete"
  defp tool_status_label(:error), do: "Failed safely"

  defp tool_icon(:running), do: "hero-arrow-path"
  defp tool_icon(:ok), do: "hero-check"
  defp tool_icon(:error), do: "hero-exclamation-triangle"

  defp protected_payload(%{result: result}) when not is_nil(result),
    do: result.protected_prompt

  defp protected_payload(%{live_request: request}) when is_binary(request), do: request
  defp protected_payload(_assigns), do: "No payload sent"

  defp provider_payload(%{result: result}) when not is_nil(result),
    do: result.provider_answer

  defp provider_payload(%{provider_stream: text}) when is_binary(text) and text != "", do: text
  defp provider_payload(_assigns), do: "No response received"

  defp boundary_step_class(assigns, :trusted_ui) do
    if assigns.running? or assigns.result, do: "complete"
  end

  defp boundary_step_class(assigns, :obscura) do
    cond do
      assigns.result -> "complete"
      assigns.activity_phase == :protecting -> "active"
      assigns.live_request -> "complete"
      true -> nil
    end
  end

  defp boundary_step_class(assigns, :agent) do
    cond do
      assigns.result -> "complete"
      assigns.activity_phase in [:requesting, :streaming] -> "active"
      assigns.activity_phase in [:tools, :restoring] -> "complete"
      true -> nil
    end
  end

  defp boundary_step_class(assigns, :tools) do
    cond do
      assigns.result -> "complete"
      Enum.any?(assigns.tool_activity, &(&1.status == :running)) -> "active"
      assigns.tool_activity != [] -> "complete"
      true -> nil
    end
  end

  defp boundary_step_class(assigns, :restoration) do
    cond do
      assigns.result -> "complete"
      assigns.activity_phase == :restoring -> "active"
      true -> nil
    end
  end

  defp live_tool_summary(%{result: result}) when not is_nil(result), do: tool_summary(result)

  defp live_tool_summary(%{tool_activity: []}), do: "No tool execution yet"

  defp live_tool_summary(%{tool_activity: tools}) do
    completed = Enum.count(tools, &(&1.status == :ok))
    running = Enum.count(tools, &(&1.status == :running))

    cond do
      running > 0 ->
        "#{running} running, #{completed} complete"

      completed > 0 ->
        "#{completed} read-only #{if completed == 1, do: "tool", else: "tools"} complete"

      true ->
        "Tool execution failed safely"
    end
  end

  defp tool_summary(%{tool_steps: []}), do: "No tool selected"

  defp tool_summary(%{tool_steps: steps}) do
    count = length(steps)
    "#{count} read-only #{if count == 1, do: "tool", else: "tools"} completed"
  end

  defp error_message(:empty_prompt), do: "Enter a request before running the agent."
  defp error_message(:prompt_too_large), do: "The request exceeds the 4 KB boundary."
  defp error_message(:agent_unavailable), do: "The isolated agent process could not start."
  defp error_message(_reason), do: "The agent run failed without exposing request data."

  defp runner_module,
    do: Application.get_env(:obscura_jido_example, :agent_runner, AgentRunner)
end
