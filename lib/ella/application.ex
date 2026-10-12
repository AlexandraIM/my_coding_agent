defmodule Ella.Application do
  @moduledoc """
  Точка входу застосунку.

  Burrito запускає саме її, а не `Ella.main/1`: реліс без `mod` не
  знає, що робити. При цьому запуск відбувається лише у standalone
  бінарнику — під час `mix test` або `iex -S mix` інтерактивний цикл
  лише заважав би, а в тестах ще й заблокував би процес.
  """

  use Application

  # Burrito шукає ERTS за замовчуванням у своєму сховищі; наш
  # резолвер бере його з установленого Erlang. Реєстрація мусить
  # бути умовною: burrito — інструмент пакування з runtime: false,
  # у самому бінарнику такого модуля немає.
  if Code.ensure_loaded?(Burrito) do
    Burrito.register_erts_resolver(Ella.ErtsResolver)
  end

  @impl true
  def start(_type, _args) do
    if standalone?() do
      run_cli()
    end

    {:ok, self()}
  end

  @doc """
  Запускає CLI і зупиняє VM після завершення сесії.

  `System.halt/0` тут обов'язковий: без нього VM житиме далі, бо
  жоден процес не завершиться — цикл чекає на введення.
  """
  def run_cli do
    Ella.start_cli()
    System.halt(0)
  catch
    kind, reason ->
      IO.puts(:stderr, "Ella exited unexpectedly: #{Exception.format(kind, reason, [])}\n")
      System.halt(1)
  end

  # Burritory позначає середовище змінною __BURRITO. Дивимосься на неї
  # напряму, а не через Burrito.Util: залежність burrito має
  # runtime: false і в бінарнику її немає.
  defp standalone?, do: System.get_env("__BURRITO") != nil
end