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
  # Ціль лише нативна, і це свідомо: ERTS береться з машини збірки
  # (див. Ella.ErtsResolver), тож крос-білд зібрав би рантайм чужої
  # архітектури. Кожна платформа збирає власний бінарник — у CI це
  # просто матриця з трьох раннерів. Щойно для OTP 29.1.1 з'явиться
  # готовий ERTS на beam-machine, приберіть RegisterErtsResolver із
  # extra_steps, і тут можна буде перелічити будь-які цілі:
  #
  #     targets: [linux: [os: :linux, cpu: :x86_64]]
  def releases do
    [
      ella: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            native: [os: native_os(), cpu: native_cpu()],
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64]
          ],
          # Реєструє наш ERTS-резолвер: без нього Burrito завантажує
          # готовий ERTS із свого CDN, якого для OTP 29.1.1 немає.
          extra_steps: [
            fetch: [pre: [Ella.BuildSteps.RegisterErtsResolver]]
          ]
        ]
      ]
    ]
  end

  # Burrito без explicit targets ламається, а «яку платформу ми збираємо»
  # треба знати до компіляції залежностей, тож тут — сирий Erlang.
  defp native_os do
    case :os.type() do
      {:unix, :linux} -> :linux
      _ -> :darwin
    end
  end

  defp native_cpu do
    :erlang.system_info(:system_architecture)
    |> to_string()
    |> String.split("-")
    |> List.first()
    |> case do
      "x86_64" -> :x86_64
      "arm64" -> :aarch64
      "aarch64" -> :aarch64
      _ -> :x86_64
    end
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
