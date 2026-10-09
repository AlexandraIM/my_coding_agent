defmodule Ella.AgentTest do
  use ExUnit.Case, async: false

  alias Ella.Agent

  setup do
    # Не піднімати реальні MCP-процеси під час тестів.
    previous = Application.get_env(:ella, :restore_mcp)
    Application.put_env(:ella, :restore_mcp, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ella, :restore_mcp)
      else
        Application.put_env(:ella, :restore_mcp, previous)
      end
    end)

    :ok
  end

  describe "init/1" do
    test "за замовчуванням має ліміт ітерацій і стартує в plan mode" do
      {:ok, pid} = Agent.start_link()
      state = :sys.get_state(pid)

      assert state.mode == :plan
      assert state.max_iterations == Ella.Tool.max_iterations()

      GenServer.stop(pid)
    end

    test "max_iterations можна перевизначити через opts" do
      {:ok, pid} = Agent.start_link(max_iterations: 3)
      assert :sys.get_state(pid).max_iterations == 3

      GenServer.stop(pid)
    end

    test "llm_opts зберігаються у стані" do
      {:ok, pid} = Agent.start_link(llm_opts: [adapter: Ella.Llm.Adapters.Poolside])
      assert :sys.get_state(pid).llm_opts == [adapter: Ella.Llm.Adapters.Poolside]

      GenServer.stop(pid)
    end
  end

  describe "build_tool_schemas/1" do
    test "перетворює локальні модулі інструментів у схеми" do
      [schema] = Agent.build_tool_schemas([Ella.Tools.ReadFile])

      assert schema["function"]["name"] == "read_file"
    end

    test "перетворює MCP-інструменти у схеми з префіксом" do
      mcp_tool = %{
        type: :mcp,
        mcp_pid: self(),
        raw_name: "search",
        name: "mcp_search",
        description: "Searches docs",
        parameters: %{"type" => "object"}
      }

      [schema] = Agent.build_tool_schemas([mcp_tool])

      assert schema["function"]["name"] == "mcp_search"
      assert schema["function"]["description"] == "Searches docs"
    end
  end
end
