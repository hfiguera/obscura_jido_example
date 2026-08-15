defmodule ObscuraJidoExampleWeb.Markdown do
  @moduledoc false

  import Phoenix.HTML, only: [html_escape: 1, raw: 1]

  @spec to_safe_html(binary()) :: Phoenix.HTML.safe()
  def to_safe_html(markdown) when is_binary(markdown) do
    case MDEx.to_html(markdown, render: [escape: true], syntax_highlight: false) do
      {:ok, html} ->
        html
        |> HtmlSanitizeEx.markdown_html()
        |> raw()

      {:error, _reason} ->
        html_escape(markdown)
    end
  rescue
    _error -> html_escape(markdown)
  end

  def to_safe_html(_markdown), do: html_escape("")
end
