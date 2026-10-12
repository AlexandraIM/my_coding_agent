defmodule Ella.MixProject do
  use Mix.Project

  def project do
    [
      app: :ella,
      version: "0.2.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Ella.Application, []},
      extra_applications: [:logger, :ssl, :crypto, :inets, :public_key]
    ]
  end

  # `mix escript.build` пакує застосунок і його залежності в один
  # виконуваний файл. Erlang при цьому має бути встановлений у
  # користувача — `mix burrito.build` збирає версію без нього.
  defp escript do
    [
      main_module: Ella,
      app: :ella,
      name: "ella"
      # Без emu_args: "-noinput" від'єднав би stdin, а CLI читає
      # команди користувача через Owl.IO.input і потребує TTY.
    ]
  end

  # Burrito пакує реліз разом з ERTS у самодостатній бінарник:
  # тестувальнику не потрібен ані Erlang, ані Elixir.
  #
  # ERTS береться з установленого Erlang (Ella.ErtsResolver), а не
  # завантажується з beam-machine: це робить збірку можливою без
  # доступу до CDN. Плата — бінарник гарантовано працює лише на тих
  # платформах, де його збирали.
  def releases do
    [
      ella: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_silicon: [os: :darwin, cpu: :aarch64],
            macos: [os: :darwin, cpu: :x86_64],
            linux: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Burrito — інструмент пакування, а не залежність застосунку:
  # `mix compile` і тести працюють як завжди, аж до появи deps.
  defp aliases do
    []
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:owl, "~> 0.11.0"},
      # Тільки для пакування: `mix release` збирає з неї
      # самодостатній бінарник, у самому застосунку вона не потрібна.
      {:burrito, "~> 1.6", runtime: false}
    ]
  end
end
