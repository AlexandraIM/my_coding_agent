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
    case Ella.SubAgent.run_task(task, tools_for_mode(), llm_opts()) do
      {:ok, summary} ->
        {:ok, "Sub-agent result:\n#{summary}"}

      {:error, reason} ->
        {:error, "Sub-agent failed: #{inspect(reason)}"}
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to delegate_task: #{inspect(args)}"}
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
