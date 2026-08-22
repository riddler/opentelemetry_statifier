defmodule OpentelemetryStatifier.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/riddler/opentelemetry_statifier"

  def project do
    [
      app: :opentelemetry_statifier,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "OpentelemetryStatifier",
      description:
        "OpenTelemetry instrumentation for the Statifier family of statechart packages",
      source_url: @source_url,
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:ex_unit]],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OpentelemetryStatifier.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      statifier_dep(),
      {:opentelemetry_api, "~> 1.4"},
      {:telemetry, "~> 1.0"},

      # Test-only: the SDK, so tests can start a tracer and capture what the
      # bridge emits. The library itself depends only on the API.
      {:opentelemetry, "~> 1.5", only: :test},

      # Dev / test
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  # Statifier is not on Hex - it has no tags - so the default is a git dep
  # whose SHA mix.lock pins, under the documented pinning contract
  # (st-ADR-0061). Note the consequence: Hex refuses to publish a package
  # that carries a git dependency, so this package cannot ship until
  # statifier is published. That is recorded, not accidental - see
  # st-ADR-0062 and this repo's ADR-0002.
  #
  # Export STATIFIER_PATH to point at a local checkout while co-developing a
  # change that spans both repos. It is an env var rather than a mix.exs edit
  # so the override never lands in a commit by accident.
  defp statifier_dep do
    case System.get_env("STATIFIER_PATH") do
      nil -> {:statifier, github: "riddler/statifier-ex", branch: "main"}
      path -> {:statifier, path: path, override: true}
    end
  end
end
