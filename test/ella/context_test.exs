defmodule Ella.ContextTest do
  use ExUnit.Case, async: true

  alias Ella.Context

  defp user(text), do: %{"role" => "user", "content" => text}
  defp system(text), do: %{"role" => "system", "content" => text}

  defp tool(id, text) do
    %{"role" => "tool", "tool_call_id" => id, "content" => text}
  end

  defp assistant(text), do: %{"role" => "assistant", "content" => text}

  describe "estimate/1" do
    test "порожня історія має нульовий розмір" do
      assert Context.estimate([]) == 0
    end

    test "рахує розмір контенту" do
      assert Context.estimate([user(String.duplicate("a", 400))]) > 90
    end

    test "враховує ім'я ролі та tool_call_id" do
      with_id = Context.estimate([tool("call_12345", "x")])
      without = Context.estimate([tool("c", "x")])
      assert with_id > without
    end

    test "рахує розмір tool_calls" do
      call = %{
        "id" => "1",
        "function" => %{"name" => "grep", "arguments" => ~s({"pattern":"defmodule"})}
      }

      assert Context.estimate([%{"role" => "assistant", "tool_calls" => [call]}]) > 5
    end

    test "не падає на невідомому форматі" do
      assert Context.estimate([%{"role" => "x", "content" => nil}]) >= 0
    end
  end

  describe "over_budget?/2" do
    test "визначає перевищення бюджету" do
      messages = [user(String.duplicate("word ", 5_000))]

      assert Context.over_budget?(messages, context_budget: 100)
      refute Context.over_budget?([user("hi")], context_budget: 10_000)
    end
  end

  describe "compact/2 — нічого не робить" do
    test "повертає історію як є, коли вона вміщається" do
      messages = [system("sys"), user("hi"), assistant("hello")]
      assert {:ok, ^messages} = Context.compact(messages, context_budget: 100_000)
    end
  end

  describe "compact/2 — стискання" do
    test "скорочує історію, що перевищує бюджет" do
      messages =
        [system("system prompt")] ++
          for i <- 1..40 do
            if rem(i, 2) == 0 do
              tool("call_#{i}", String.duplicate("result ", 50))
            else
              user("запит #{i}: " <> String.duplicate("x", 400))
            end
          end

      assert {:ok, compacted} = Context.compact(messages, context_budget: 2_000)
      assert Context.estimate(compacted) <= 2_000
      assert length(compacted) < length(messages)
    end

    test "зберігає системний промпт" do
      messages =
        [system("IMPORTANT SYSTEM PROMPT")] ++
          for i <- 1..40, do: tool("call_#{i}", String.duplicate("result ", 100))

      assert {:ok, compacted} = Context.compact(messages, context_budget: 1_500)

      assert Enum.any?(compacted, fn m -> m["role"] == "system" end)

      assert Enum.any?(compacted, fn m ->
               m["role"] == "system" and String.contains?(m["content"] || "", "IMPORTANT")
             end)
    end

    test "зберігає останні повідомлення недоторканими" do
      messages =
        for i <- 1..30, do: tool("call_#{i}", String.duplicate("data ", 100))

      {:ok, compacted} = Context.compact(messages, context_budget: 1_000, keep_recent: 5)

      recent = Enum.take(compacted, -5)
      assert Enum.any?(recent, fn m -> m["tool_call_id"] == "call_30" end)
    end

    test "додає підсумок замість старих повідомлень" do
      messages =
        [system("s")] ++
          for i <- 1..40,
              do: tool("call_#{i}", "read file #{i}.ex " <> String.duplicate("z", 200))

      {:ok, compacted} = Context.compact(messages, context_budget: 800)

      assert Enum.any?(compacted, fn m ->
               m["role"] == "system" and
                 String.contains?(m["content"] || "", "Summary of earlier")
             end)
    end

    test "підсумок не дублює однакові записи" do
      # Усі 40 повідомлень ідентичні — підсумок має лишити один рядок.
      messages =
        [system("s")] ++
          for _ <- 1..40, do: tool("call_same", String.duplicate("identical result ", 20))

      {:ok, compacted} = Context.compact(messages, context_budget: 800)

      summary =
        compacted
        |> Enum.find(fn m -> String.contains?(m["content"] || "", "Summary of earlier") end)

      # Унікалізація: 40 однакових результатів лишаються одним рядком.
      assert length(String.split(summary["content"], "tool ")) <= 2
    end

    test "обрізає довгі tool-результати, коли історію стискати нікуди" do
      messages =
        for i <- 1..5, do: tool("call_#{i}", String.duplicate("A", 20_000))

      assert {:ok, compacted} =
               Context.compact(messages, context_budget: 2_000, keep_recent: 50)

      assert Context.estimate(compacted) <= 2_000

      assert Enum.any?(compacted, fn m -> String.ends_with?(m["content"] || "", "[truncated]") end)
    end

    test "повертає {:error, :too_large}, коли скоротити неможливо" do
      messages = [user(String.duplicate("a", 500_000))]

      assert {:error, :too_large} = Context.compact(messages, context_budget: 100)
    end
  end

  describe "калібрування оцінки" do
    test "коефіцієнт за замовчуванням — 1.0" do
      assert Context.factor([]) == 1.0
    end

    test "estimate/2 враховує коефіцієнт" do
      messages = [user(String.duplicate("a", 400))]

      assert Context.estimate(messages, estimate_factor: 2.0) ==
               round(Context.estimate(messages) * 2.0)
    end

    test "калібрування піднімає коефіцієнт, коли оцінка занижена" do
      # API порахував удвічі більше, ніж ми оцінили.
      updated = Context.calibrate(1.0, 200, last_estimate: 100)

      assert updated > 1.0
      assert updated < 2.0
    end

    test "калібрування опускає коефіцієнт, коли оцінка завищена" do
      updated = Context.calibrate(2.0, 50, last_estimate: 100)

      assert updated < 2.0
    end

    test "без реальних даних коефіцієнт не змінюється" do
      assert Context.calibrate(1.0, nil, last_estimate: 100) == 1.0
      assert Context.calibrate(1.0, 0, last_estimate: 100) == 1.0
      assert Context.calibrate(1.0, 100, []) == 1.0
      assert Context.calibrate(1.0, 100, last_estimate: 0) == 1.0
    end

    test "коефіцієнт затискається, щоб виняток не зруйнував сесію" do
      assert Context.calibrate(1.0, 100_000, last_estimate: 1) <= 4.0
      assert Context.calibrate(1.0, 1, last_estimate: 100_000) >= 0.5
    end

    test "стискання враховує калібрований розмір" do
      messages =
        for i <- 1..30, do: tool("call_#{i}", String.duplicate("data ", 100))

      budget = Context.estimate(messages)

      # Без коефіцієнта історія точно вміщається...
      assert {:ok, ^messages} = Context.compact(messages, context_budget: budget)

      # ...а з ним — ні, і агент стискає.
      assert {:ok, compacted} =
               Context.compact(messages, context_budget: budget, estimate_factor: 3.0)

      assert length(compacted) < length(messages)
    end
  end

  describe "budget/1 за замовчуванням" do
    test "використовує max_context_tokens, якщо заданий" do
      assert Context.budget(max_context_tokens: 4_321) == 4_321
    end

    test "інакше використовує розумний дефолт" do
      assert Context.budget([]) == 120_000
    end
  end
end
