defmodule ObscuraJidoExampleWeb.Router do
  use ObscuraJidoExampleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ObscuraJidoExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ObscuraJidoExampleWeb do
    pipe_through :browser

    post "/session/openai-key", OpenAICredentialController, :create
    delete "/session/openai-key", OpenAICredentialController, :delete
    live "/", AgentLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ObscuraJidoExampleWeb do
  #   pipe_through :api
  # end
end
