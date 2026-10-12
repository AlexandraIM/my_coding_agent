defmodule Ella.Llm.ToolCallsTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.ToolCalls

  describe "merge/2 — фрагменти з індексом" do
    test "перший фрагмент створює виклик" do
      calls = ToolCalls.merge([], %{"index" => 0, "id" => "call_1"})

      assert [%{"index" => 0, "id" => "call_1"}] = calls
    end

    test "наступний фрагмент дописує аргументи до того ж виклику" do
      calls =
        []
        |> ToolCalls.merge(%{"index" => 0, "id" => "call_1", "function" => %{"name" => "grep"}})
        |> ToolCalls.merge(%{"index" => 0, "function" => %{"arguments" => "{\"pattern\":"}})
        |> ToolCalls.merge(%{"index" => 0, "function" => %{"arguments" => "\"def\"}"}})

      assert [call] = calls
      assert call["function"]["name"] == "grep"
      assert call["function"]["arguments"] == "{\"pattern\":\"def\"}"
    end

    test "різні індекси стають різними викликами" do
      calls =
        []
        |> ToolCalls.merge(%{"index" => 0, "function" => %{"name" => "grep"}})
        |> ToolCalls.merge(%{"index" => 1, "function" => %{"name" => "glob"}})

      assert length(calls) == 2
      assert Enum.map(calls, & &1["function"]["name"]) == ["grep", "glob"]
    end

    test "фрагмент без індексу додається в кінець" do
      calls =
        []
        |> ToolCalls.merge(%{"function" => %{"name" => "grep"}})
        |> ToolCalls.merge(%{"function" => %{"name" => "glob"}})

      assert length(calls) == 2
    end

    test "не змінює наявний виклик, прийшовши без корисних полів" do
      calls = ToolCalls.merge([%{"index" => 0, "id" => "x"}], %{"index" => 0, "usage" => nil})

      assert [%{"index" => 0, "id" => "x"}] = calls
    end
  end

  describe "render/1" do
    test "надає id за порядковим номером, якщо провайдер його не дав" do
      assert [call] = ToolCalls.render([%{"function" => %{"name" => "grep"}}])

      assert call["id"] == "call_1"
      assert call["type"] == "function"
    end

    test "зберігає id провайдера" do
      assert [call] = ToolCalls.render([%{"id" => "abc", "function" => %{"name" => "grep"}}])
      assert call["id"] == "abc"
    end

    test "підтримує плоску форму аргументів" do
      # Деякі провайдери кладуть ім'я та аргументи на верхній рівень.
      assert [call] = ToolCalls.render([%{"name" => "grep", "arguments" => ~s({"a":1})}])

      assert call["function"]["name"] == "grep"
      assert call["function"]["arguments"] == ~s({"a":1})
    end

    test "підставляє порожні аргументи, аби JSON завжди був валідним" do
      assert [call] = ToolCalls.render([%{"function" => %{"name" => "list_dir"}}])

      assert call["function"]["arguments"] == "{}"
    end

    test "нумерує кілька викликів поспіль" do
      calls =
        ToolCalls.render([
          %{"function" => %{"name" => "grep"}},
          %{"function" => %{"name" => "glob"}}
        ])

      assert Enum.map(calls, & &1["id"]) == ["call_1", "call_2"]
    end
  end
end
