defmodule Ella.Agent do
  use GenServer

  alias Ella.LlmClient
  alias Ella.ProjectRules
  alias Ella.Mcp.ToolAdapter
  alias Ella.Storage
  alias Ella.Tool

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def ask(pid, user_prompt) do
    GenServer.call(pid, {:ask, user_prompt}, :infinity)
  end

  def set_mode(pid, mode) when mode in [:plan, :build] do
    GenServer.call(pid, {:set_mode, mode})
  end

  @doc "Реєстрація нового MCP-сервера в агента"
  def register_mcp(pid, executable, args) do
    GenServer.call(pid, {:register_mcp, executable, args}, :infinity)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    Storage.ensure_storage_created!()

    mode = Keyword.get(opts, :mode, :plan)

    all_tools =
      Keyword.get(opts, :tools, [
        Ella.Tools.ReadFile,
        Ella.Tools.WriteFile,
        Ella.Tools.ApplyPatch,
        Ella.Tools.SystemExec,
        Ella.Tools.DelegateTask
      ])

    llm_opts = Keyword.get(opts, :llm_opts, [])
    project_rules = ProjectRules.load_rules()

    state = %{
      mode: mode,
      messages: [],
      all_tools: all_tools,
      mcp_clients: [],
      mcp_tools: [],
      llm_opts: llm_opts,
      project_rules: project_rules,
      max_iterations: Keyword.get(opts, :max_iterations, Tool.max_iterations())
    }

    state = restore_saved_mcps(state)
    publish_context(state)

    {:ok, update_system_prompt(state)}
  end

  @impl true
  def handle_call({:set_mode, new_mode}, _from, state) do
    new_state = %{state | mode: new_mode} |> update_system_prompt()
    publish_context(new_state)
    mode_name = if new_mode == :plan, do: "PLANNING (Read-Only)", else: "BUILDING (Full Access)"

    Owl.IO.puts(Owl.Data.tag("Switched to #{mode_name} mode.", :magenta))
    {:reply, {:ok, new_mode}, new_state}
  end

  @impl true
  def handle_call({:register_mcp, executable, args}, _from, state) do
    case Ella.Mcp.Client.start_link(executable, args) do
      {:ok, mcp_pid} ->
        case Ella.Mcp.Client.list_tools(mcp_pid) do
          {:ok, %{"tools" => tools}} ->
            wrapped_tools = Enum.map(tools, &ToolAdapter.to_agent_tool(mcp_pid, &1))

            new_state = %{
              state
              | mcp_clients: [mcp_pid | state.mcp_clients],
                mcp_tools: state.mcp_tools ++ wrapped_tools
            }

            # ЗБЕРІГАЄМО У ПАПКУ .my_agent/mcp.json!
            server_name = Path.basename(executable) <> "_" <> Enum.join(args, "_")
            Storage.save_mcp_server(server_name, executable, args)

            Owl.IO.puts(
              Owl.Data.tag(
                "Зареєстровано та збережено #{length(wrapped_tools)} MCP tools",
                :green
              )
            )

            {:reply, {:ok, length(wrapped_tools)}, new_state}

          {:error, err} ->
            {:reply, {:error, err}, state}
        end

      {:error, err} ->
        {:reply, {:error, err}, state}
    end
  end

  @impl true
  def handle_call({:ask, user_prompt}, _from, state) do
    Owl.IO.puts([Owl.Data.tag("User: ", :green), user_prompt])

    new_messages = state.messages ++ [%{"role" => "user", "content" => user_prompt}]
    active_tools = get_active_tools(state)

    case run_loop(new_messages, active_tools, state, 0) do
      {:ok, final_messages, response_text} ->
        {:reply, {:ok, response_text}, %{state | messages: final_messages}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # --- Helper & Tool Execution ---

  defp get_active_tools(%{mode: :plan, all_tools: tools, mcp_tools: mcp_tools}) do
    plan_local = Enum.filter(tools, fn tool -> tool.name() in ["read_file", "delegate_task"] end)

    # MCP-інструменти додаються в plan mode лише тоді, коли сервер
    # явно підтвердив, що вони не змінюють стан.
    plan_mcp = Enum.filter(mcp_tools, & &1.read_only)

    dropped = length(mcp_tools) - length(plan_mcp)

    if dropped > 0 do
      Owl.IO.puts(
        Owl.Data.tag(
          "[plan mode] #{dropped} MCP tool(s) hidden: not marked read-only.",
          :yellow
        )
      )
    end

    plan_local ++ plan_mcp
  end

  defp get_active_tools(%{mode: :build, all_tools: tools, mcp_tools: mcp_tools}) do
    tools ++ mcp_tools
  end

  def build_tool_schemas(active_tools) do
    Enum.map(active_tools, fn
      %{type: :mcp, name: name, description: desc, parameters: params} ->
        %{
          "type" => "function",
          "function" => %{
            "name" => name,
            "description" => desc,
            "parameters" => params
          }
        }

      tool_module when is_atom(tool_module) ->
        Ella.Tool.to_schema(tool_module)
    end)
  end

  defp update_system_prompt(%{mode: :plan} = state) do
    prompt =
      """
      You are an AI Architect working in PLAN MODE.
      Your goal is to analyze the codebase, ask clarifying questions, and design a detailed, step-by-step implementation plan.

      STRICT RULES FOR PLAN MODE:
      1. DO NOT write or modify any files. File modification tools are DISABLED.
      2. Read files and analyze project structure using available tools.
      3. Output your plan in clean Markdown with numbered steps.
      4. Ask the user if they agree with the plan before proceeding to Build Mode.
      5. Always respond to the user in the language they used (e.g., Ukrainian).
      """ <> state.project_rules

    set_system_message(state, prompt)
  end

  defp update_system_prompt(%{mode: :build} = state) do
    prompt =
      """
      You are an AI Software Engineer working in BUILD MODE.
      Your goal is to execute the agreed implementation plan accurately.

      STRICT RULES FOR BUILD MODE:
      1. Inspect relevant files before editing.
      2. Prefer precise edits using `apply_patch` instead of overwriting files.
      3. Run checks/tests via `system_exec` after edits.
      4. Always respond to the user in the language they used (e.g., Ukrainian).
      """ <> state.project_rules

    set_system_message(state, prompt)
  end

  # Інструменти виконуються у процесі агента, а DelegateTask потребує
  # знати поточний режим і налаштування LLM. Process dictionary — найпростіший
  # спосіб це передати без розширення контракту інструментів.
  defp publish_context(state) do
    Process.put(:ella_agent_mode, state.mode)
    Process.put(:ella_agent_llm_opts, state.llm_opts)
  end

  defp set_system_message(state, prompt) do
    filtered_messages = Enum.reject(state.messages, fn m -> m["role"] == "system" end)
    %{state | messages: [%{"role" => "system", "content" => prompt} | filtered_messages]}
  end

  # --- Agentic Loop ---

  defp run_loop(_messages, _active_tools, state, current_iter)
       when current_iter >= state.max_iterations do
    notice =
      "Iteration limit reached (#{state.max_iterations}). " <>
        "Stopping the loop and returning control to the user."

    Owl.IO.puts(Owl.Data.tag(notice, :yellow))
    {:ok, notice}
  end

  defp run_loop(messages, active_tools, state, current_iter) do
    tool_map = build_tool_map(active_tools)
    Owl.IO.puts(Owl.Data.tag("Thinking (#{state.mode} mode)...", :cyan))

    case LlmClient.chat_completion(messages, active_tools, state.llm_opts) do
      {:ok, %{"tool_calls" => tool_calls} = message}
      when is_list(tool_calls) and length(tool_calls) > 0 ->
        updated_messages = messages ++ [message]

        tool_results_messages =
          Enum.map(tool_calls, fn call ->
            tool_name = call["function"]["name"]
            call_id = call["id"]

            Owl.IO.puts([
              Owl.Data.tag("Tool Call [#{tool_name}]: ", :yellow),
              inspect(call["function"]["arguments"])
            ])

            result_text = execute_tool_call(call, tool_name, tool_map)

            %{"role" => "tool", "tool_call_id" => call_id, "content" => result_text}
          end)

        run_loop(updated_messages ++ tool_results_messages, active_tools, state, current_iter + 1)

      {:ok, %{"content" => content} = message} when not is_nil(content) and content != "" ->
        Owl.IO.puts([Owl.Data.tag("Agent: ", :blue), content])
        {:ok, messages ++ [message], content}

      {:ok, message} ->
        content = message["content"] || "Done."
        Owl.IO.puts([Owl.Data.tag("Agent: ", :blue), content])
        {:ok, messages ++ [message], content}

      {:error, reason} ->
        Owl.IO.puts(Owl.Data.tag("Error calling LLM: #{inspect(reason)}", :red))
        {:error, reason}
    end
  end

  defp build_tool_map(tools) do
    Enum.into(tools, %{}, fn
      %{name: name} = mcp_tool -> {name, mcp_tool}
      tool_module when is_atom(tool_module) -> {tool_module.name(), tool_module}
    end)
  end

  defp execute_tool_call(call, tool_name, tool_map) do
    encoded = call["function"]["arguments"]

    case Tool.parse_args(encoded) do
      {:ok, tool_args} ->
        execute_tool(tool_name, tool_args, tool_map)

      {:error, reason} ->
        "ERROR: #{reason}"
    end
  end

  defp execute_tool(name, args, tool_map) do
    case Map.fetch(tool_map, name) do
      {:ok, %{type: :mcp, mcp_pid: pid, raw_name: raw_name}} ->
        try do
          case ToolAdapter.execute(pid, raw_name, args) do
            {:ok, output} -> output
            {:error, err} -> "ERROR: #{err}"
          end
        rescue
          e -> "ERROR executing MCP tool '#{name}': #{Exception.message(e)}"
        end

      {:ok, tool_module} when is_atom(tool_module) ->
        try do
          case tool_module.execute(args) do
            {:ok, output} -> output
            {:error, err} -> "ERROR: #{err}"
          end
        rescue
          e -> "ERROR executing tool '#{name}': #{Exception.message(e)}"
        end

      :error ->
        "ERROR: Tool '#{name}' is disabled or not registered."
    end
  end

  # Хелпер для відновлення збережених MCP при старті
  @doc false
  # У тестах MCP не піднімається: процеси реальні, повільні й залежать від
  # локального ~/.ella/mcp.json. Продакшн-шлях не змінюється.
  def restore_mcp?, do: Application.get_env(:ella, :restore_mcp, true)

  defp restore_saved_mcps(state) do
    if restore_mcp?() do
      do_restore_saved_mcps(state)
    else
      state
    end
  end

  defp do_restore_saved_mcps(state) do
    saved_servers = Storage.load_mcp_config()

    Enum.reduce(saved_servers, state, fn {name, %{"command" => exec, "args" => args}},
                                         acc_state ->
      case Ella.Mcp.Client.start_link(exec, args) do
        {:ok, mcp_pid} ->
          case Ella.Mcp.Client.list_tools(mcp_pid) do
            {:ok, %{"tools" => tools}} ->
              wrapped_tools = Enum.map(tools, &ToolAdapter.to_agent_tool(mcp_pid, &1))

              Owl.IO.puts(
                Owl.Data.tag(
                  "Auto-restored MCP [#{name}] with #{length(wrapped_tools)} tools",
                  :green
                )
              )

              %{
                acc_state
                | mcp_clients: [mcp_pid | acc_state.mcp_clients],
                  mcp_tools: acc_state.mcp_tools ++ wrapped_tools
              }

            _ ->
              acc_state
          end

        _ ->
          acc_state
      end
    end)
  end
end
