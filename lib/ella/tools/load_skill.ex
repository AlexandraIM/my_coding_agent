defmodule Ella.Tools.LoadSkill do
  @moduledoc """
  Читання повного тексту навички.

  У системному промпті навичка присутня лише назвою й описом — це
  дешево. Цей інструмент дозволяє моделі завантажити інструкції лише
  тоді, коли вони справді застосовні.
  """

  @behaviour Ella.Tool

  def name, do: "load_skill"

  def description do
    "Loads the full instructions for a project skill listed in PROJECT SKILLS. " <>
      "Call this before starting a task the skill applies to."
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "Exact skill name as shown in the PROJECT SKILLS list"
        }
      },
      "required" => ["name"]
    }
  end

  def execute(%{"name" => name}) when is_binary(name) do
    case Ella.Skills.find(Process.get(:ella_agent_skills, []), name) do
      {:ok, skill} ->
        {:ok, Ella.Skills.render(skill)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(args) do
    {:error, "Invalid arguments passed to load_skill: #{inspect(args)}"}
  end
end
