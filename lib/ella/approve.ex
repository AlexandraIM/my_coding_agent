defmodule Ella.Approve do
  @moduledoc """
  Запит дозволу на зміну захищеного файлу.

  Два застереження, без яких механізм зламається:

  * **Неінтерактивний сеанс.** У CI або пайпі немає людини, яка
    відповість. Запитати там — значить намертво зависнути, тому в
    такому разі дозвіл одразу відхиляється.

  * **Перенос рядка.** Під час стріму фрагменти друкуються через
    `IO.write` без фінального переносу, і запит прилип би до
    нерозривного тексту.
  """

  alias Ella.Config

  @type answer :: :yes | :no | :unavailable

  @doc """
  Чи можна ставити питання користувачеві.
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
  Питає дозвіл на зміну `path` інструментом `tool`.

  Повертає :yes, :no або :unavailable (неінтерактивний сеанс).
  """
  @spec ask(String.t(), String.t()) :: answer()
  def ask(tool_name, path) do
    if interactive?() do
      if Config.require_approval?() do
        prompt(tool_name, path)
      else
        warn_permissive(tool_name, path)
        :yes
      end
    else
      :unavailable
    end
  end

  defp prompt(tool_name, path) do
    IO.puts("")

    Owl.IO.puts([
      Owl.Data.tag("PROTECTED FILE: ", :red),
      path,
      "\n",
      Owl.Data.tag("The agent wants to change it with ", :yellow),
      tool_name,
      "\n",
      Owl.Data.tag("Allow? [y/N] ", :yellow)
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
    Owl.IO.puts(
      Owl.Data.tag(
        "[protected] #{path} changed by #{tool_name} without approval " <>
          "(require_approval is false)",
        :yellow
      )
    )
  end

  @doc """
  Повідомлення, яке повертається моделі після відмови.

  Ключове — «do not retry»: інакше агент спробує той самий запис ще
  раз і знову зупинить сесію.
  """
  @spec refusal(String.t()) :: String.t()
  def refusal(path) do
    "Refused by the user: #{path} is a protected file. " <>
      "Do not retry this change. Ask the user how to proceed instead."
  end

  @doc """
  Повідомлення для неінтерактивного сеансу.
  """
  @spec unavailable(String.t()) :: String.t()
  def unavailable(path) do
    "Blocked: #{path} is a protected file and this session is non-interactive, " <>
      "so the user cannot be asked for approval. " <>
      "Do not retry; tell the user this file needs manual changes."
  end
end
