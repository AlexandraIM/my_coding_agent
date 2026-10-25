defmodule Ella.ApplicationTest do
  use ExUnit.Case, async: false

  describe "start/2" do
    test "не запускає CLI поза standalone-бінарником" do
      # Під час тестів __BURRITO немає: запуск інтерактивного циклу
      # заблокував би процес назавжди.
      refute System.get_env("__BURRITO")

      assert {:ok, _pid} = Ella.Application.start(:normal, [])
    end
  end
end
