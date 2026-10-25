defmodule Ella.Tools.DelegateTask do
  @behaviour Ella.Tool

  def name, do: "delegate_task"
  def description, do: "Spawns a sub-agent for an isolated sub-task."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "Detailed task description for the sub-agent"
        }
      },
      "required" => ["task"]
    }
  end

  def execute(%{"task" => task}) do
    task_preview = String.slice(task, 0, 120) <> if String.length(task) > 120, do: "...", else: ""
    Owl.IO.puts(Owl.Data.tag("▶ Delegating sub-task: #{task_preview}", :magenta))

    case Ella.SubAgent.run_task(task, tools_for_mode(), llm_opts()) do
      {:ok, summary, usage} ->
        accumulate_usage(usage)
        usage_str = usage_summary(usage)
        {:ok, "Sub-agent result:#{usage_str}\n#{summary}"}

      {:ok, summary} ->
        {:ok, "Sub-agent result:\n#{summary}"}

      {:error, reason, usage} ->
        accumulate_usage(usage)
        usage_str = usage_summary(usage)
        {:error, "Sub-agent failed:#{usage_str} #{inspect(reason)}"}

      {:error, reason} ->
        {:error, "Sub-agent failed: #{inspect(reason)}"}
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to delegate_task: #{inspect(args)}"}
  end

  defp usage_summary(%Ella.Llm.Usage{} = u) do
    prompt = u.prompt_tokens || 0
    completion = u.completion_tokens || 0
    total = prompt + completion
    cost = if u.cost, do: " $#{:erlang.float_to_binary(u.cost, decimals: 4)}", else: ""
    if total > 0 do
      "\n  [usage: #{prompt} in / #{completion} out = #{total} tokens#{cost}]"
    else
      ""
    end
  end

  defp usage_summary(_), do: ""

  defp accumulate_usage(usage) do
    current = Process.get(:ella_subagent_usage, Ella.Llm.Usage.empty())
    Process.put(:ella_subagent_usage, Ella.Llm.Usage.add(current, usage))
  end

  # Сабагент успадковує режим головного агента. Агент записує його в
  # process dictionary під час ініціалізації та перемикання режимів.
  defp tools_for_mode do
    case Process.get(:ella_agent_mode) do
      :plan -> Ella.SubAgent.read_only_tools()
      _ -> Ella.SubAgent.all_tools()
    end
  end

  defp llm_opts, do: Process.get(:ella_agent_llm_opts, [])
end
