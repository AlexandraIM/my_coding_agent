defmodule Ella.Tools.LoadSkillTest do
  use ExUnit.Case, async: false

  alias Ella.{Skills, Tools.LoadSkill}

  setup do
    skills = [
      %Skills{
        name: "Testing",
        description: "How to test",
        instructions: "Run mix test.",
        allowed_tools: ["system_exec", "read_file"]
      },
      %Skills{
        name: "Style",
        description: "Code style",
        instructions: "Follow the style guide.",
        allowed_tools: nil
      }
    ]

    Process.put(:ella_agent_skills, skills)
    on_exit(fn -> Process.delete(:ella_agent_skills) end)
    :ok
  end

  test "повертає повний текст навички" do
    assert {:ok, output} = LoadSkill.execute(%{"name" => "Testing"})
    assert output =~ "Run mix test."
    assert output =~ "Testing"
  end

  test "згадує обмеження інструментів" do
    assert {:ok, output} = LoadSkill.execute(%{"name" => "Testing"})
    assert output =~ "ONLY use"
    assert output =~ "system_exec"
  end

  test "не згадує обмеження для навички без tools" do
    assert {:ok, output} = LoadSkill.execute(%{"name" => "Style"})
    refute output =~ "ONLY use"
  end

  test "не чутливий до регістру" do
    assert {:ok, _} = LoadSkill.execute(%{"name" => "testing"})
  end

  test "повертає помилку для невідомої навички" do
    assert {:error, reason} = LoadSkill.execute(%{"name" => "Nope"})
    assert reason =~ "No skill named"
  end

  test "повертає помилку за відсутності навичок" do
    Process.put(:ella_agent_skills, [])
    assert {:error, _} = LoadSkill.execute(%{"name" => "Testing"})
  end

  test "відхиляє некоректні аргументи" do
    assert {:error, reason} = LoadSkill.execute(%{"skill" => "Testing"})
    assert reason =~ "Invalid arguments"
  end

  test "схема інструмента вимагає name" do
    params = LoadSkill.parameters()
    assert params["required"] == ["name"]
    assert Map.has_key?(params["properties"], "name")
  end
end
