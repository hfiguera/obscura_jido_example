defmodule ObscuraJidoExample.Support.Actions.IgnoreObservation do
  @moduledoc false

  use Jido.Action,
    name: "ignore_observation",
    description: "Consumes internal tool lifecycle observations.",
    category: "internal",
    tags: ["internal"],
    vsn: "1.0.0",
    schema: Zoi.object(%{})

  @impl true
  def run(_params, _context), do: {:ok, %{}}
end
