defmodule OpentelemetryStatifier.MixProject do
  use Mix.Project

  @version "0.3.0"
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
      docs: docs(),
      package: package(),
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

  # Hexdocs configuration. These paths are read off the publisher's disk at
  # `mix docs` time and need no entry in package()'s files: list - the docs
  # tarball hexdocs hosts is built separately from the package tarball
  # `mix deps.get` fetches.
  defp docs do
    [
      name: "OpentelemetryStatifier",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/opentelemetry_statifier",
      source_url: @source_url,
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    [
      name: "opentelemetry_statifier",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      statifier_dep(),
      {:opentelemetry_api, "~> 1.4"},
      {:telemetry, "~> 1.0"},

      # Test-only: the SDK, so tests can start a tracer and capture what the
      # bridge emits. The library itself depends only on the API.
      {:opentelemetry, "~> 1.5", only: :test},

      # Test-only: the sibling packages this bridge mirrors, so the drift
      # test can compare each literal event list against the sibling's own
      # `Telemetry.events/0`. They are `only: :test, runtime: false` - a
      # host that wants statechart tracing must never pull Ecto, a database
      # driver, or Oban in through this package (st-ADR-0062, ots-ADR-0004),
      # and the Hex package's requirements are unaffected because `only:`
      # deps are not published requirements.
      {:statifier_persistence, "~> 0.5", only: :test, runtime: false},
      {:statifier_oban, "~> 0.5", only: :test, runtime: false},

      # Dev / test
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  # Export STATIFIER_PATH to point at a local checkout while co-developing a
  # change that spans both repos. It is an env var rather than a mix.exs edit
  # so the override never lands in a commit by accident.
  defp statifier_dep do
    case System.get_env("STATIFIER_PATH") do
      nil -> {:statifier, "~> 2.4"}
      path -> {:statifier, path: path, override: true}
    end
  end
end
