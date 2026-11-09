defmodule Ella.Application do
  @moduledoc """
  Точка входу застосунку.

  Burrito запускає саме її, а не `Ella.main/1`: реліс без `mod` не
  знає, що робити. При цьому запуск відбувається лише у standalone
  бінарнику — під час `mix test` або `iex -S mix` інтерактивний цикл
  лише заважав би, а в тестах ще й заблокував би процес.
  """

  use Application

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
    tui? =
      case System.get_env("ELLA_TUI") do
        "0" -> false
        "1" -> true
        _ -> not mix_env?()
      end

    if tui? do
      Ella.Tui.run()
    else
      Ella.start_cli()
    end

    System.halt(0)
  catch
    kind, reason ->
      IO.puts(:stderr, "Ella exited unexpectedly: #{Exception.format(kind, reason, [])}\n")
      System.halt(1)
  end

  defp mix_env? do
    Code.ensure_loaded?(Mix)
  rescue
    _ -> false
  end

  # Burritory позначає середовище змінною __BURRITO. Дивимосься на неї
  # напряму, а не через Burrito.Util: залежність burrito має
  # runtime: false і в бінарнику її немає.
  defp standalone?, do: System.get_env("__BURRITO") != nil
end
