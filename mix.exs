defmodule Genswarms.MixProject do
  use Mix.Project

  def project do
    [
      app: :genswarms,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      escript: escript()
    ]
  end

  defp escript do
    [
      main_module: Genswarms.CLI,
      name: "genswarms",
      # Don't auto-start the application
      app: nil
    ]
  end

  def application do
    [
      mod: {Genswarms.Application, []},
      # :ssh dropped — the SSH backend is unused in the :local dev path and
      # erlang-ssh isn't installed (apt split). Re-add it (+ `apt install
      # erlang-ssh`) if you need the SSH backend.
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix core (API only)
      {:phoenix, "~> 1.7.10"},
      {:phoenix_live_reload, "~> 1.4", only: :dev},
      {:phoenix_live_dashboard, "~> 0.8.2", only: :dev},

      # CORS support
      {:corsica, "~> 2.1"},

      # Telemetry
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # JSON & YAML
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.9"},

      # HTTP server
      {:bandit, "~> 1.0"},

      # SQLite for registry
      {:exqlite, "~> 0.13"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
