defmodule Ella.SubAgent do
  @doc """
  Universal sub-agent for executing isolated sub-tasks (research, code fixing, testing).
  """
  use GenServer

  alias Ella.LlmClient
  alias Ella.Tool

  # --- Client API ---

  def run_task(task_description, tools \\ all_tools(), llm_opts \\ []) do
    {:ok, pid} =
      GenServer.start_link(__MODULE__, task: task_description, tools: tools, llm_opts: llm_opts)

    GenServer.call(pid, :execute, :infinity)
  end

  # Повний набір інструментів за замовчуванням (включаючи редагування та запис)
  def all_tools do
    [
      Ella.Tools.ReadFile,
      Ella.Tools.WriteFile,
      Ella.Tools.ApplyPatch,
      Ella.Tools.SystemExec
    ]
  end

  @doc """
  Набір інструментів без права зміни стану.

  Використовується, коли головний агент у plan mode делегує завдання:
  інакше write_file/apply_patch всередині сабагента обійшли б read-only
  режим, оскільки DelegateTask доступний у plan mode.

  SystemExec свідомо відсутній: він дозволяє змінити стан через шелл
  (`> file`, `rm`), тому в plan mode недоступний ні головному агенту,
  ні сабагенту.
  """
  def read_only_tools do
    [
      Ella.Tools.ReadFile
    ]
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    task = Keyword.fetch!(opts, :task)
    tools = Keyword.get(opts, :tools, all_tools())

    system_prompt = """
    You are an autonomous sub-agent handling an isolated sub-task for the primary agent.
    Your goal is to execute the assigned task precisely, whether it involves reading files, analyzing problems, or modifying code and running tests.

    RULES:
    1. Focus strictly on the task provided. Do not modify unrelated files or perform out-of-scope actions.
    2. If you edit code, verify your changes using `system_exec` if applicable.
    3. Return a clear, concise summary of what was done, including modified files or findings.
    """

    state = %{
      messages: [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => task}
      ],
      tools: tools,
      tool_map: Enum.into(tools, %{}, fn t -> {t.name(), t} end),
      llm_opts: Keyword.get(opts, :llm_opts, []),
      # Сабагенти отримують вужчий контекст, тому ліміт ітерацій менший
      max_iterations: Keyword.get(opts, :max_iterations, 8)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:execute, _from, state) do
    Owl.IO.puts(Owl.Data.tag("[SubAgent] Executing sub-task...", :magenta))

    case run_loop(state.messages, state, 0) do
      {:ok, summary} ->
        Owl.IO.puts(Owl.Data.tag("[SubAgent] Finished sub-task.", :green))
        {:stop, :normal, {:ok, summary}, state}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  # --- Agentic Loop ---

  defp run_loop(_messages, state, current_iter) when current_iter >= state.max_iterations do
    {:ok,
     "Sub-agent reached the iteration limit (#{state.max_iterations}). Work summary attached."}
  end

  defp run_loop(messages, state, current_iter) do
    case LlmClient.chat_completion(messages, state.tools, state.llm_opts) do
      {:ok, %{"tool_calls" => tool_calls} = message}
      when is_list(tool_calls) and length(tool_calls) > 0 ->
        updated_messages = messages ++ [message]

        tool_results_messages =
          Enum.map(tool_calls, fn call ->
            tool_name = call["function"]["name"]
            call_id = call["id"]

            Owl.IO.puts([
              Owl.Data.tag("  [SubAgent Tool]: #{tool_name} ", :yellow),
              inspect(call["function"]["arguments"])
            ])

            result_text = execute_tool_call(call, tool_name, state.tool_map)
            %{"role" => "tool", "tool_call_id" => call_id, "content" => result_text}
          end)

        run_loop(updated_messages ++ tool_results_messages, state, current_iter + 1)

      {:ok, %{"content" => content}} ->
        {:ok, content || "Task completed."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tool_call(call, tool_name, tool_map) do
    case Tool.parse_args(call["function"]["arguments"]) do
      {:ok, tool_args} -> execute_tool(tool_name, tool_args, tool_map)
      {:error, reason} -> "ERROR: #{reason}"
    end
  end

  defp execute_tool(name, args, tool_map) do
    case Map.fetch(tool_map, name) do
      {:ok, tool_module} ->
        try do
          case tool_module.execute(args) do
            {:ok, output} -> output
            {:error, err} -> "ERROR: #{err}"
          end
        rescue
          e -> "ERROR executing tool '#{name}': #{Exception.message(e)}"
        end

      :error ->
        "ERROR: Tool '#{name}' is not available to this sub-agent."
    end
  end
end
