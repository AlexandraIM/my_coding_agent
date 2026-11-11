defmodule Ella.Approve do
  @moduledoc """
  Asks permission to modify a protected file.

  Two caveats without which the mechanism breaks:

  * **Non-interactive session.** In CI or a pipe there is no human to
    answer. Asking there means hanging forever, so permission is denied
    immediately in that case.

  * **Newline.** During streaming, fragments are printed via `IO.write`
    without a final newline, and the prompt would stick to the unbroken
    text.
  """

  alias Ella.Config

  @type answer :: :yes | :no | :unavailable

  @doc """
  Whether we can ask the user a question.
  """
  def interactive? do
    Application.get_env(:ella, :interactive, detect_interactive?())
  end

  defp detect_interactive? do
    ci = System.get_env("CI")

    if ci not in [nil, "", "false"] do
      false
    else
      case System.cmd("test", ["-t", "0"], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    end
  rescue
    _ -> false
  end

  @doc """
  Asks permission to change `path` with tool `tool`.

  Returns :yes, :no, or :unavailable (non-interactive session).
  """
  @spec ask(String.t(), String.t()) :: answer()
  def ask(tool_name, path) do
    if interactive?() do
      if Config.require_approval?() do
        case Ella.Output.sink() do
          {:tui, _pid} -> tui_prompt(tool_name, path)
          _ -> prompt(tool_name, path)
        end
      else
        warn_permissive(tool_name, path)
        :yes
      end
    else
      :unavailable
    end
  end

  defp tui_prompt(tool_name, path) do
    {:tui, pid} = Ella.Output.sink()
    send(pid, {:approval_request, tool_name, path, self()})

    receive do
      {:approval, :yes} -> :yes
      {:approval, :no} -> :no
    after
      60_000 -> :no
    end
  end

  defp prompt(tool_name, path) do
    Ella.Output.blank()

    Ella.Output.puts([
      Ella.Output.tag("PROTECTED FILE: ", :red),
      path,
      "\n",
      Ella.Output.tag("The agent wants to change it with ", :yellow),
      tool_name,
      "\n",
      Ella.Output.tag("Allow? [y/N] ", :yellow)
    ])

    answer =
      Owl.IO.input(label: "")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    case answer do
      answer when answer in ["y", "yes"] -> :yes
      _ -> :no
    end
  end

  defp warn_permissive(tool_name, path) do
    Ella.Output.puts(
      Ella.Output.tag(
        "[protected] #{path} changed by #{tool_name} without approval " <>
          "(require_approval is false)",
        :yellow
      )
    )
  end

  @doc """
  Message returned to the model after a refusal.

  The key is "do not retry": otherwise the agent would try the same
  write again and stop the session once more.
  """
  @spec refusal(String.t()) :: String.t()
  def refusal(path) do
    "Refused by the user: #{path} is a protected file. " <>
      "Do not retry this change. Ask the user how to proceed instead."
  end

  @doc """
  Message for a non-interactive session.
  """
  @spec unavailable(String.t()) :: String.t()
  def unavailable(path) do
    "Blocked: #{path} is a protected file and this session is non-interactive, " <>
      "so the user cannot be asked for approval. " <>
      "Do not retry; tell the user this file needs manual changes."
  end
end
