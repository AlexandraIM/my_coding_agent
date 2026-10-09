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
    case Ella.SubAgent.run_task(task) do
      {:ok, summary} ->
        {:ok, "Sub-agent result:\n#{summary}"}

      {:error, reason} ->
        {:error, "Sub-agent failed: #{inspect(reason)}"}
    end
  end
end
