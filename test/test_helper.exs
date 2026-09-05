exclude = if System.get_env("OBSCURA_EFFICIENT_TEST") == "1", do: [], else: [efficient: true]
ExUnit.start(exclude: exclude)
