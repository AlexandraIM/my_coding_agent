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

    test "context_opts зберігаються у стані" do
      {:ok, pid} = Agent.start_link(context_budget: 5_000, keep_recent: 3)
      state = :sys.get_state(pid)

      assert state.context_opts[:context_budget] == 5_000
      assert state.context_opts[:keep_recent] == 3

      GenServer.stop(pid)
    end

    test "облік токенів стартує з нуля" do
      {:ok, pid} = Agent.start_link()
      refute Ella.Llm.Usage.known?(Agent.usage(pid))

      GenServer.stop(pid)
    end
  end

  describe "skills" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "ella_agent_skills_#{System.unique_integer([:positive])}")

      skills_dir = Path.join(root, ".ella/skills")
      File.mkdir_p!(skills_dir)

      File.write!(Path.join(skills_dir, "testing.md"), """
      ---
      name: Testing
      description: How tests are written in this project
      tools: [read_file, system_exec]
      ---
      Run the suite with `mix test`.
      """)

      previous = Application.get_env(:ella, :sandbox_root)
      Application.put_env(:ella, :sandbox_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if is_nil(previous) do
          Application.delete_env(:ella, :sandbox_root)
        else
          Application.put_env(:ella, :sandbox_root, previous)
        end
      end)

      {:ok, root: root}
    end

    test "завантажує навички з .ella/skills при старті" do
      {:ok, pid} = Agent.start_link()

      assert [{"Testing", description}] = Agent.skills(pid)
      assert description =~ "How tests are written"

      GenServer.stop(pid)
    end

    test "каталог навичок потрапляє в системний промпт" do
      {:ok, pid} = Agent.start_link()
      [system | _] = :sys.get_state(pid).messages

      assert system["content"] =~ "PROJECT SKILLS"
      assert system["content"] =~ "Testing"
      assert system["content"] =~ "How tests are written"
      # Повний текст навички в промпт не потрапляє.
      assert system["content"] =~ "load_skill"
      refute system["content"] =~ "Run the suite with"

      GenServer.stop(pid)
    end

    test "load_skill активує навичку і повертає її інструкції" do
      {:ok, pid} = Agent.start_link()

      assert Agent.active_skill(pid) == nil

      assert {:ok, skill} = GenServer.call(pid, {:activate_skill, "Testing"})
      assert skill.instructions =~ "Run the suite with"
      assert Agent.active_skill(pid) == "Testing"

      GenServer.stop(pid)
    end

    test "перемикання режиму не знімає активну навичку" do
      {:ok, pid} = Agent.start_link()
      GenServer.call(pid, {:activate_skill, "Testing"})
      Agent.set_mode(pid, :build)

      assert Agent.active_skill(pid) == "Testing"

      GenServer.stop(pid)
    end

    test "reload_skills скидає активну навичку" do
      {:ok, pid} = Agent.start_link()
      GenServer.call(pid, {:activate_skill, "Testing"})

      assert ["Testing"] = Agent.reload_skills(pid)
      assert Agent.active_skill(pid) == nil

      GenServer.stop(pid)
    end

    test "невідома навичка не активується" do
      {:ok, pid} = Agent.start_link()

      assert {:error, _} = GenServer.call(pid, {:activate_skill, "Nope"})
      assert Agent.active_skill(pid) == nil

      GenServer.stop(pid)
    end
  end

  describe "context_info/1" do
    test "повертає кількість повідомлень і бюджет" do
      {:ok, pid} = Agent.start_link(context_budget: 9_000)
      info = Agent.context_info(pid)

      assert info.messages == 1
      assert info.budget == 9_000
      assert is_integer(info.estimated_tokens)

      GenServer.stop(pid)
    end
  end

  describe "reset_usage/1" do
    test "скидає накопичений облік" do
      {:ok, pid} = Agent.start_link()

      :sys.replace_state(pid, fn state ->
        %{state | usage: %Ella.Llm.Usage{prompt_tokens: 500, completion_tokens: 100}}
      end)

      assert Agent.usage(pid).prompt_tokens == 500

      Agent.reset_usage(pid)
      refute Ella.Llm.Usage.known?(Agent.usage(pid))

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
