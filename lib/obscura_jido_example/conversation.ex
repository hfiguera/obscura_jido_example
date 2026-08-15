defmodule ObscuraJidoExample.Conversation do
  @moduledoc """
  Keeps bounded trusted and provider-safe representations of completed turns.

  Raw prompts and restored answers belong to the trusted UI. Only protected
  prompts and tokenized provider answers are projected into Jido context.
  """

  alias __MODULE__.Turn

  @max_turns 6
  @max_provider_bytes 64_000

  defmodule Turn do
    @moduledoc false

    @enforce_keys [
      :id,
      :trusted_prompt,
      :protected_prompt,
      :provider_answer,
      :display_html
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: pos_integer(),
            trusted_prompt: String.t(),
            protected_prompt: String.t(),
            provider_answer: String.t(),
            display_html: Phoenix.HTML.safe()
          }
  end

  @type t :: [Turn.t()]

  @spec append(t(), Turn.t()) :: t()
  def append(turns, %Turn{} = turn) when is_list(turns) do
    turns
    |> Kernel.++([turn])
    |> Enum.take(-@max_turns)
    |> keep_within_provider_budget()
  end

  @spec provider_messages(t()) :: [%{role: :user | :assistant, content: String.t()}]
  def provider_messages(turns) when is_list(turns) do
    Enum.flat_map(turns, fn %Turn{} = turn ->
      [
        %{role: :user, content: turn.protected_prompt},
        %{role: :assistant, content: turn.provider_answer}
      ]
    end)
  end

  @spec count(t()) :: non_neg_integer()
  def count(turns) when is_list(turns), do: length(turns)

  @spec provider_message_count(t()) :: non_neg_integer()
  def provider_message_count(turns) when is_list(turns), do: count(turns) * 2

  defp keep_within_provider_budget(turns) do
    turns
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn turn, {kept, bytes} ->
      turn_bytes = provider_bytes(turn)

      if bytes + turn_bytes <= @max_provider_bytes do
        {:cont, {[turn | kept], bytes + turn_bytes}}
      else
        {:halt, {kept, bytes}}
      end
    end)
    |> elem(0)
  end

  defp provider_bytes(%Turn{} = turn),
    do: byte_size(turn.protected_prompt) + byte_size(turn.provider_answer)
end
