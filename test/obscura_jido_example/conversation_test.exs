defmodule ObscuraJidoExample.ConversationTest do
  use ExUnit.Case, async: true

  alias ObscuraJidoExample.Conversation
  alias ObscuraJidoExample.Conversation.Turn

  @raw_email "rachel.chen@example.test"

  test "projects only protected turn representations into provider history" do
    turns =
      Conversation.append([], %Turn{
        id: 1,
        trusted_prompt: "Find #{@raw_email}",
        protected_prompt: "Find <<EMAIL_001>>",
        provider_answer: "Found <<EMAIL_001>>",
        display_html: "Found #{@raw_email}"
      })

    assert Conversation.provider_messages(turns) == [
             %{role: :user, content: "Find <<EMAIL_001>>"},
             %{role: :assistant, content: "Found <<EMAIL_001>>"}
           ]

    refute inspect(Conversation.provider_messages(turns)) =~ @raw_email
  end

  test "keeps only the six most recent complete turns" do
    turns =
      Enum.reduce(1..7, [], fn id, turns ->
        Conversation.append(turns, turn(id))
      end)

    assert Enum.map(turns, & &1.id) == [2, 3, 4, 5, 6, 7]
    assert Conversation.count(turns) == 6
    assert Conversation.provider_message_count(turns) == 12
  end

  test "drops the oldest complete turns when protected context reaches its byte budget" do
    turns =
      Enum.reduce(1..5, [], fn id, turns ->
        turn = %Turn{
          turn(id)
          | protected_prompt: String.duplicate("p", 8_000),
            provider_answer: String.duplicate("a", 8_000)
        }

        Conversation.append(turns, turn)
      end)

    assert Enum.map(turns, & &1.id) == [2, 3, 4, 5]
    assert Conversation.provider_message_count(turns) == 8
  end

  defp turn(id) do
    %Turn{
      id: id,
      trusted_prompt: "Trusted request #{id}",
      protected_prompt: "Protected request #{id}",
      provider_answer: "Provider answer #{id}",
      display_html: "Display answer #{id}"
    }
  end
end
