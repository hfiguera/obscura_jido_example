defmodule ObscuraJidoExampleWeb.ErrorJSONTest do
  use ObscuraJidoExampleWeb.ConnCase, async: true

  test "renders 404" do
    assert ObscuraJidoExampleWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert ObscuraJidoExampleWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
