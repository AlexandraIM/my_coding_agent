defmodule Ella.Tools.SystemExec do
  @behaviour Ella.Tool

  def name, do: "system_exec"

  def description,
    do: "Executes a terminal command (e.g., 'mix test', 'git status', 'npm run build')."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "The full terminal command to execute (e.g., 'mix test')"
        }
      },
      "required" => ["command"]
    }
  end

  def execute(%{"command" => full_command}) do
    case String.split(full_command, " ", trim: true) do
      [cmd | args] ->
        case System.cmd(cmd, args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, "Success:\n#{output}"}

          {output, exit_code} ->
            {:error, "Command failed (exit code #{exit_code}):\n#{output}"}
        end

      [] ->
        {:error, "Empty command provided."}
    end
  end
end
