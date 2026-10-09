defmodule Ella.MixProject do
  use Mix.Project

  def project do
    [
      app: :ella,
      version: "0.2.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:json, "~> 1.4"},
      {:owl, "~> 0.11.0"}
    ]
  end
end
