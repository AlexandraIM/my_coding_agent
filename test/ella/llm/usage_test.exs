defmodule Ella.Llm.UsageTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.Usage

  describe "empty/0 і known?/1" do
    test "порожній підрахунок не вважається відомим" do
      refute Usage.known?(Usage.empty())
    end

    test "підрахунок без даних не відомий" do
      refute Usage.known?(%Usage{prompt_tokens: nil, completion_tokens: nil})
    end

    test "підрахунок з даними відомий" do
      assert Usage.known?(%Usage{prompt_tokens: 10, completion_tokens: 0})
    end
  end

  describe "total/1" do
    test "сумає вхідні та вихідні токени" do
      assert Usage.total(%Usage{prompt_tokens: 100, completion_tokens: 50}) == 150
    end

    test "nil вважається нулем" do
      assert Usage.total(%Usage{prompt_tokens: nil, completion_tokens: nil}) == 0
    end
  end

  describe "add/2" do
    test "сумує два підрахунки" do
      a = %Usage{prompt_tokens: 10, completion_tokens: 5}
      b = %Usage{prompt_tokens: 20, completion_tokens: 7}

      assert Usage.add(a, b) == %Usage{prompt_tokens: 30, completion_tokens: 12}
    end

    test "ігнорує nil" do
      a = %Usage{prompt_tokens: 10, completion_tokens: 5}
      assert Usage.add(a, nil) == a
    end

    test "додає вартість, коли є в обох" do
      a = %Usage{prompt_tokens: 10, completion_tokens: 0, cost: 0.1}
      b = %Usage{prompt_tokens: 10, completion_tokens: 0, cost: 0.2}

      assert Usage.add(a, b).cost == 0.30000000000000004
    end

    test "бере модель з того, де вона є" do
      a = %Usage{prompt_tokens: 1, completion_tokens: 0, model: "gpt-4o"}
      b = %Usage{prompt_tokens: 1, completion_tokens: 0}

      assert Usage.add(a, b).model == "gpt-4o"
    end
  end

  describe "from_response/1" do
    test "читає стандартний формат usage" do
      body = %{
        "model" => "gpt-4o",
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 50}
      }

      usage = Usage.from_response(body)

      assert usage.prompt_tokens == 100
      assert usage.completion_tokens == 50
      assert usage.model == "gpt-4o"
    end

    test "повертає nil, коли usage немає" do
      assert Usage.from_response(%{"model" => "gpt-4o"}) == nil
      assert Usage.from_response("not a map") == nil
    end

    test "повертає nil для полів не-числового типу" do
      body = %{"usage" => %{"prompt_tokens" => "many"}}
      assert Usage.from_response(body).prompt_tokens == nil
    end
  end

  describe "estimate/1" do
    test "груба оцінка за розміром" do
      assert Usage.estimate(String.duplicate("a", 400)) == 100
    end

    test "nil дає нуль" do
      assert Usage.estimate(nil) == 0
    end
  end

  describe "with_cost/1" do
    test "рахує вартість для відомої моделі" do
      usage = %Usage{prompt_tokens: 1_000_000, completion_tokens: 0, model: "gpt-4o"}

      assert Usage.with_cost(usage).cost == 2.5
    end

    test "не вигадує вартість для невідомої моделі" do
      usage = %Usage{prompt_tokens: 1_000_000, completion_tokens: 0, model: "unknown-model"}

      assert Usage.with_cost(usage).cost == nil
    end

    test "пропускає підрахунок без моделі" do
      assert Usage.with_cost(%Usage{prompt_tokens: 10, completion_tokens: 0}).cost == nil
    end
  end

  describe "format/1" do
    test "форматує відомий підрахунок" do
      usage = %Usage{prompt_tokens: 100, completion_tokens: 50}

      assert Usage.format(usage) =~ "150 tokens"
      assert Usage.format(usage) =~ "100 in"
    end

    test "каже, що невідомо" do
      assert Usage.format(Usage.empty()) =~ "unknown"
    end

    test "додає вартість, якщо є" do
      usage = %Usage{prompt_tokens: 1_000_000, completion_tokens: 0, cost: 2.5}
      assert Usage.format(usage) =~ "$2.5000"
    end
  end
end
