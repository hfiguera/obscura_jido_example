defmodule ObscuraJidoExampleWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ObscuraJidoExampleWeb.CoreComponents

  test "information flashes auto-dismiss and remain manually dismissible" do
    html =
      render_component(&CoreComponents.flash/1,
        kind: :info,
        flash: %{"info" => "OpenAI enabled"}
      )

    assert html =~ ~s(phx-hook="AutoDismissFlash")
    assert html =~ ~s(data-dismiss-after="5000")
    assert html =~ ~s(role="status")
    assert html =~ ~s(phx-click=)
  end

  test "error flashes remain visible until dismissed" do
    html =
      render_component(&CoreComponents.flash/1,
        kind: :error,
        flash: %{"error" => "Invalid key"}
      )

    refute html =~ "AutoDismissFlash"
    refute html =~ "data-dismiss-after"
    assert html =~ ~s(role="alert")
  end
end
