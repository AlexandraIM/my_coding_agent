defmodule Ella.AgentLoopTest do
  @moduledoc """
  Наскрізний тест агентного циклу.

  Модульні тести перевіряють інструменти, контекст і LLM-шар окремо.
  Тут перевіряється те, що жоден з них не бачить: що агент у реальному
  порядку викликає LLM, виконує інструмент, додає його результат у
  історію і продовжує цикл до фінальної відповіді.

  LLM замінено сценарієм, який керує тестовий процес: адаптер надсилає
  запит і чекає відповіді, тож крок видно Assert-ам, а не ховається
  всередині GenServer.
  """

  use ExUnit.Case, async: false

  alias Ella.Llm.Usage

  defmodule ScriptedAdapter do
    @behaviour Ella.Llm.Adapter

    @impl true
    def chat_completion(messages, tools, config) do
      # Лічильник кроків живе у тестовому процесі, а не тут: адаптер
      # виконується всередині GenServer агента.
      send(Keyword.fetch!(config, :test_pid), {:llm_called, self(), messages, tools})

      receive do
        {:llm_reply, result} -> result
      after
        5_000 -> {:error, Ella.Llm.Error.permanent("test script gave no reply")}
      end
    end

    @impl true
    def chat_completion_stream(messages, tools, config, _on_text) do
      chat_completion(messages, tools, config)
    end
  end

  defmodule EchoTool do
    @behaviour Ella.Tool

    @impl true
    def name, do: "echo"

    @impl true
    def description, do: "Echoes the given text back to the agent."

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
    end

    # Інструмент виконується у процесі агента, тому process dictionary
    # тесту тут не видно. Тест реєструє себе під іменем: пошта
    # зберігає порядок викликів, на відміну від ETS-набору.
    @impl true
    def execute(%{"text" => text}) do
      if pid = Process.whereis(:ella_e2e_test), do: send(pid, {:tool_called, text})
      {:ok, "echo: " <> text}
    end

    def execute(_args), do: {:error, "missing text"}
  end

  defmodule CrashingTool do
    @behaviour Ella.Tool

    @impl true
    def name, do: "crash"

    @impl true
    def description, do: "Always crashes."

    @impl true
    def parameters, do: %{"type" => "object"}

    @impl true
    def execute(_args), do: raise("tool crashed")
  end

  setup do
    previous_restore = Application.get_env(:ella, :restore_mcp)
    Application.put_env(:ella, :restore_mcp, false)

    on_exit(fn ->
      if is_nil(previous_restore) do
        Application.delete_env(:ella, :restore_mcp)
      else
        Application.put_env(:ella, :restore_mcp, previous_restore)
      end
    end)

    # Тест реєструє себе під іменем, щоб інструменти, які виконуються
    # у процесі агента, могли надсилати йому повідомлення.
    Process.register(self(), :ella_e2e_test)

    :ok
  end

  defp start_agent(opts \\ []) do
    defaults = [
      mode: :build,
      tools: [EchoTool],
      max_iterations: 10,
      llm_opts: [
        adapter: ScriptedAdapter,
        config: [test_pid: self()],
        max_attempts: 1,
        sleep_fn: fn _ -> :ok end
      ]
    ]

    {:ok, pid} = Ella.Agent.start_link(Keyword.merge(defaults, opts))
    pid
  end

  defp tool_calls do
    drain_tool_calls([])
  end

  defp drain_tool_calls(acc) do
    receive do
      {:tool_called, text} -> drain_tool_calls(acc ++ [text])
    after
      0 -> acc
    end
  end

  defp assert_tool_called(expected), do: assert(tool_calls() == [expected])

  defp assert_tool_calls(expected), do: assert(tool_calls() == expected)

  defp tool_call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
    }
  end

  # Запускає запит у фоні й відповідає на кожен виклик LLM за сценарієм.
  # Після відповіді очікуємо наступного виклику: так тест бачить
  # послідовність запитів, а не лише фінальний результат.
  defp ask_with_script(pid, prompt, script) do
    task = Task.async(fn -> Ella.Agent.ask(pid, prompt) end)

    run_script(script)

    Task.await(task, 5_000)
  end

  # LLM викликається у процесі агента (GenServer), а не у тому, де
  # запущено запит, тому конкретний pid не відомий наперед — ловимо
  # будь-який і відповідаємо саме йому.
  defp run_script([response]) do
    receive do
      {:llm_called, caller, messages, tools} ->
        send(self(), {:llm_seen, messages, tools})
        send(caller, {:llm_reply, response})
    after
      5_000 -> flunk("LLM was not called")
    end
  end

  defp run_script([response | rest]) do
    receive do
      {:llm_called, caller, messages, tools} ->
        send(self(), {:llm_seen, messages, tools})
        send(caller, {:llm_reply, response})

        run_script(rest)
    after
      5_000 -> flunk("LLM was not called")
    end
  end

  defp text_step(content) do
    {:ok, %{"content" => content}, %Usage{prompt_tokens: 20, completion_tokens: 5}}
  end

  defp tool_step(id, name, args) do
    {:ok, %{"tool_calls" => [tool_call(id, name, args)]}, %Usage{prompt_tokens: 30}}
  end

  describe "повний цикл" do
    test "виконує інструмент і доходить до фінальної відповіді" do
      pid = start_agent()

      script = [
        tool_step("call_1", "echo", %{"text" => "hi"}),
        text_step("All done.")
      ]

      assert {:ok, "All done."} = ask_with_script(pid, "say hi", script)
      assert_tool_called("hi")

      GenServer.stop(pid)
    end

    test "результат інструмента потрапляє в історію як tool-повідомлення" do
      pid = start_agent()

      script = [
        tool_step("call_1", "echo", %{"text" => "hi"}),
        text_step("done")
      ]

      assert {:ok, "done"} = ask_with_script(pid, "say hi", script)

      messages = :sys.get_state(pid).messages

      assert %{"role" => "tool", "tool_call_id" => "call_1", "content" => "echo: hi"} =
               Enum.find(messages, &(&1["role"] == "tool"))

      GenServer.stop(pid)
    end

    test "другий запит до LLM містить і виклик, і його результат" do
      pid = start_agent()

      script = [
        tool_step("call_1", "echo", %{"text" => "hi"}),
        text_step("done")
      ]

      assert {:ok, "done"} = ask_with_script(pid, "say hi", script)

      # Другий запит — той, що бачить модель після виконання інструмента.
      assert_received {:llm_seen, first_request, _tools}
      assert_received {:llm_seen, second_request, _tools}

      assert length(first_request) < length(second_request)

      roles = Enum.map(second_request, & &1["role"])

      assert roles == ["system", "user", "assistant", "tool"]

      GenServer.stop(pid)
    end

    test "викликає інструменти в порядку, у якому їх дав LLM" do
      pid = start_agent()

      two_calls =
        {:ok,
         %{
           "tool_calls" => [
             tool_call("call_a", "echo", %{"text" => "first"}),
             tool_call("call_b", "echo", %{"text" => "second"})
           ]
         }, %Usage{}}

      script = [two_calls, text_step("done")]

      assert {:ok, "done"} = ask_with_script(pid, "two things", script)

      assert_tool_calls(["first", "second"])

      GenServer.stop(pid)
    end

    test "цикл продовжується, поки LLM не поверне фінальний текст" do
      pid = start_agent(max_iterations: 10)

      script =
        Enum.map(1..3, fn n ->
          tool_step("call_#{n}", "echo", %{"text" => "step#{n}"})
        end) ++ [text_step("finished")]

      assert {:ok, "finished"} = ask_with_script(pid, "loop", script)

      assert_tool_calls(["step1", "step2", "step3"])

      GenServer.stop(pid)
    end

    test "виняток в інструменті не глушить агента" do
      pid = start_agent(tools: [CrashingTool])

      script = [
        tool_step("call_1", "crash", %{}),
        text_step("recovered")
      ]

      assert {:ok, "recovered"} = ask_with_script(pid, "boom", script)

      tool_message =
        :sys.get_state(pid).messages |> Enum.find(&(&1["role"] == "tool"))

      assert tool_message["content"] =~ "ERROR"

      GenServer.stop(pid)
    end

    test "невідомий інструмент повертає помилку моделі, а не зупиняє цикл" do
      pid = start_agent()

      script = [
        tool_step("call_1", "nonexistent", %{}),
        text_step("ok")
      ]

      assert {:ok, "ok"} = ask_with_script(pid, "go", script)

      tool_message =
        :sys.get_state(pid).messages |> Enum.find(&(&1["role"] == "tool"))

      assert tool_message["content"] =~ "ERROR"

      GenServer.stop(pid)
    end
  end

  describe "межі циклу" do
    test "зупиняється на max_iterations і пояснює чому" do
      pid = start_agent(max_iterations: 2)

      task = Task.async(fn -> Ella.Agent.ask(pid, "loop forever") end)

      # Відповідаємо на кожен запит, доки агент сам не зупиниться.
      reply_forever()

      assert {:ok, notice} = Task.await(task, 5_000)
      assert notice =~ "Iteration limit"

      GenServer.stop(pid)
    end

    defp reply_forever do
      receive do
        {:llm_called, caller, _messages, _tools} ->
          send(
            caller,
            {:llm_reply,
             {:ok, %{"tool_calls" => [tool_call("c", "echo", %{"text" => "x"})]}, %Usage{}}}
          )

          reply_forever()
      after
        1_000 -> :stop
      end
    end

    test "помилка LLM доходить до користувача" do
      pid = start_agent()

      task = Task.async(fn -> Ella.Agent.ask(pid, "hello") end)

      receive do
        {:llm_called, caller, _messages, _tools} ->
          send(
            caller,
            {:llm_reply, {:error, Ella.Llm.Error.permanent("API error 401", status: 401)}}
          )
      after
        5_000 -> flunk("LLM was not called")
      end

      assert {:error, message} = Task.await(task, 5_000)
      assert message =~ "401"

      GenServer.stop(pid)
    end
  end

  describe "доступність інструментів" do
    test "plan mode не віддає моделі інструмент поза плановим набором" do
      pid = start_agent(mode: :plan)

      task = Task.async(fn -> Ella.Agent.ask(pid, "try to echo") end)

      # Перший запит: перевіряємо набір інструментів і свідомо
      # просимо модель викликати заборонений інструмент.
      receive do
        {:llm_called, caller, _messages, tools} ->
          names = Enum.map(tools, & &1.name())

          refute "echo" in names

          send(
            caller,
            {:llm_reply,
             {:ok, %{"tool_calls" => [tool_call("c1", "echo", %{"text" => "x"})]}, %Usage{}}}
          )
      after
        5_000 -> flunk("LLM was not called")
      end

      # Другий запит доводить, що агент не впав, а пояснив моделі
      # помилку й продовжив роботу.
      receive do
        {:llm_called, caller, _messages, _tools} ->
          send(caller, {:llm_reply, text_step("cannot use that in plan mode")})
      after
        5_000 -> flunk("agent did not continue after the rejected tool")
      end

      assert {:ok, _reply} = Task.await(task, 5_000)

      tool_message = :sys.get_state(pid).messages |> Enum.find(&(&1["role"] == "tool"))

      assert tool_message["content"] =~ "ERROR"

      GenServer.stop(pid)
    end
  end
end
