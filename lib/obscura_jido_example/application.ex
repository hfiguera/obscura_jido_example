defmodule ObscuraJidoExample.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ObscuraJidoExampleWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:obscura_jido_example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ObscuraJidoExample.PubSub},
      ObscuraJidoExample.OpenAICredentialStore,
      ObscuraJidoExample.Jido,
      # Start a worker by calling: ObscuraJidoExample.Worker.start_link(arg)
      # {ObscuraJidoExample.Worker, arg},
      # Start to serve requests, typically the last entry
      ObscuraJidoExampleWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ObscuraJidoExample.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ObscuraJidoExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
