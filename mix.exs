defmodule Ella.MixProject do
  use Mix.Project

  def project do
    [
      app: :ella,
      version: "0.2.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl, :crypto, :inets, :public_key]
    ]
  end

  # `mix escript.build` пакує застосунок і його залежності в один
  # виконуваний файл. Erlang при цьому має бути встановлений у
  # користувача — для повністю самодостатнього бінарника див. розділ
  # про Burrito у README.
  defp escript do
    [
      main_module: Ella,
      app: :ella,
      name: "ella"
      # Без emu_args: "-noinput" від'єднав би stdin, а CLI читає
      # команди користувача через Owl.IO.input і потребує TTY.
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
