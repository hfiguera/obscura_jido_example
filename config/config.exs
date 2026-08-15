# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :obscura_jido_example,
  generators: [timestamp_type: :utc_datetime],
  agent: [
    model: "openai:gpt-5.6-luna",
    timeout: 60_000
  ]

config :jido_ai,
  model_aliases: %{fast: "openai:gpt-5.6-luna"}

# Agent data is already pseudonymized at the application boundary. These
# settings prevent dependencies from retaining or logging even that payload.
config :jido, :telemetry,
  log_level: :info,
  log_args: :none

config :jido, :observability,
  debug_events: :off,
  redact_sensitive: true

config :req_llm,
  telemetry: [payloads: :none],
  finch_request_adapter: ObscuraJidoExample.OpenAIRequestAdapter

# LiveView's default lifecycle logger includes event parameters. Keep only
# Phoenix's protocol metadata so support prompts are filtered before logging.
config :phoenix, :filter_parameters, {:keep, ["_mounts", "_track_static"]}

# Configure the endpoint
config :obscura_jido_example, ObscuraJidoExampleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ObscuraJidoExampleWeb.ErrorHTML, json: ObscuraJidoExampleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ObscuraJidoExample.PubSub,
  live_view: [signing_salt: "2vxB+4R7"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  obscura_jido_example: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  obscura_jido_example: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
