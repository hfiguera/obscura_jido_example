defmodule ObscuraJidoExampleWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias ObscuraJidoExampleWeb.Markdown

  test "renders common response Markdown" do
    html = Markdown.to_safe_html("Found **Rachel**\n\n- Open\n- Waiting") |> safe_html()

    assert html =~ "<strong>Rachel</strong>"
    assert html =~ "<ul>"
    assert html =~ "<li>Open</li>"
    refute html =~ "**"
  end

  test "preserves fenced Elixir code as a block" do
    markdown = """
    ```elixir
    defmodule Fibonacci do
      def fib(0), do: 0
    end
    ```
    """

    html = Markdown.to_safe_html(markdown) |> safe_html()

    assert html =~ "<pre><code"
    assert html =~ "defmodule Fibonacci do\n  def fib(0), do: 0\nend"
    assert html =~ "</code></pre>"
  end

  test "escapes embedded HTML and does not create unsafe links" do
    markdown = "<script>alert('x')</script> [unsafe](javascript:alert('x'))"
    html = Markdown.to_safe_html(markdown) |> safe_html()

    refute html =~ "<script>"
    refute html =~ ~r/href=[^>]*javascript:/i
    assert html =~ "&lt;script&gt;"
    assert html =~ "unsafe"
  end

  defp safe_html(value), do: value |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
end
