defmodule Ella.Tools.SystemExec do
  @behaviour Ella.Tool

  @default_timeout_ms 120_000
  @max_output_chars 30_000

  # Команди, які руйнують стан поза межами робочого проєкту або незворотні.
  # Агент сам їх не запускає — повертає помилку з поясненням.
  @denied_commands ~w(
    rm shutdown halt poweroff reboot mkfs dd
    sudo su doas launchctl systemctl killall
  )

  # Підкоманди, які ламають git-стан без можливості відкотитись.
  @denied_git_subcommands ~w(reset clean filter-branch push force)

  def name, do: "system_exec"

  def description,
    do:
      "Executes a terminal command through a shell (e.g., 'mix test', 'git status', " <>
        "'rg foo lib/ | head -20'). Supports pipes (&&, |, >) and runs in the project root."

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "The full shell command to execute (e.g., 'mix test')"
        }
      },
      "required" => ["command"]
    }
  end

  def execute(%{"command" => full_command}) when is_binary(full_command) do
    case check_allowed(full_command) do
      :ok ->
        run(full_command)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to system_exec: #{inspect(args)}"}
  end

  defp run(command) do
    timeout = Application.get_env(:ella, :exec_timeout_ms, @default_timeout_ms)
    opts = [stderr_to_stdout: true, cd: Ella.Sandbox.root()]

    task = Task.async(fn -> System.cmd(shell(), ["-c", command], opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, format_output("Success", 0, output)}

      {:ok, {output, exit_code}} ->
        {:error, format_output("Command failed", exit_code, output)}

      nil ->
        {:error,
         "Command timed out after #{timeout}ms and was killed. " <>
           "Consider running a narrower command."}
    end
  end

  defp shell do
    case :os.type() do
      {:win32, _} -> System.get_env("COMSPEC") || "cmd.exe"
      _ -> "/bin/sh"
    end
  end

  defp format_output(label, exit_code, output) do
    truncated = truncate(output)

    "#{label} (exit code #{exit_code}):\n#{truncated}"
  end

  defp truncate(output) do
    if String.length(output) > @max_output_chars do
      shown = String.slice(output, 0, @max_output_chars)

      shown <>
        "\n\n... [truncated #{String.length(output) - @max_output_chars} characters. " <>
        "The full output was too large for the context window.]"
    else
      output
    end
  end

  # Перевіряємо перший токен кожного сегмента ланцюга, щоб `ls && rm -rf`
  # не пройшов повз перевірку тільки першої команди.
  defp check_allowed(command) do
    command
    |> split_segments()
    |> Enum.reduce_while(:ok, fn segment, :ok ->
      case first_token(segment) do
        nil ->
          {:cont, :ok}

        cmd ->
          case check_command(cmd, segment) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp split_segments(command) do
    command
    |> String.split(~r/[;&|]+/)
    |> Enum.map(&String.trim/1)
  end

  defp first_token(segment) do
    segment |> String.split(~r/\s+/, trim: true) |> List.first()
  end

  defp check_command(cmd, segment) do
    base = Path.basename(cmd)

    cond do
      base in @denied_commands ->
        {:error,
         "Command '#{cmd}' is blocked by the agent's safety policy. " <>
           "Ask the user to run it manually."}

      base == "git" and destructive_git?(segment) ->
        {:error,
         "Destructive git command blocked: '#{segment}'. " <>
           "Use 'git status'/'git diff' to inspect state, and let the user handle resets."}

      true ->
        :ok
    end
  end

  defp destructive_git?(segment) do
    segment
    |> String.split(~r/\s+/)
    |> Enum.map(&Path.basename/1)
    |> Enum.any?(&(&1 in @denied_git_subcommands or String.starts_with?(&1, "--hard")))
  end
end
