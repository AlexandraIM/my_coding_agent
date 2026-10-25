defmodule Ella.ReviewModeTest do
  use ExUnit.Case, async: false

  alias Ella.Agent

  setup do
    root =
      Path.join(System.tmp_dir!(), "ella_review_#{System.unique_integer([:positive])}")

    skills_dir = Path.join(root, ".ella/skills")
    File.mkdir_p!(skills_dir)
    File.mkdir_p!(Path.join(root, "global_skills"))

    previous = Application.get_env(:ella, :sandbox_root)
    previous_global = Application.get_env(:ella, :global_skills_dir)
    Application.put_env(:ella, :sandbox_root, root)
    Application.put_env(:ella, :global_skills_dir, Path.join(root, "global_skills"))

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(previous) do
        Application.delete_env(:ella, :sandbox_root)
      else
        Application.put_env(:ella, :sandbox_root, previous)
      end

      if is_nil(previous_global) do
        Application.delete_env(:ella, :global_skills_dir)
      else
        Application.put_env(:ella, :global_skills_dir, previous_global)
      end
    end)

    :ok
  end

  test "set_mode to :review switches mode and updates system prompt" do
    {:ok, pid} = Agent.start_link()
    Agent.set_mode(pid, :review)

    state = :sys.get_state(pid)
    assert state.mode == :review

    [system | _] = state.messages
    assert system["content"] =~ "REVIEW MODE"
    assert system["content"] =~ "DO NOT write or modify"

    GenServer.stop(pid)
  end

  test "review mode exposes read-only tools + system_exec + delegate_task" do
    {:ok, pid} = Agent.start_link()
    Agent.set_mode(pid, :review)

    tool_names = Agent.active_tools(pid)

    assert "read_file" in tool_names
    assert "grep" in tool_names
    assert "glob" in tool_names
    assert "list_dir" in tool_names
    assert "system_exec" in tool_names
    assert "delegate_task" in tool_names
    assert "load_skill" in tool_names

    # Write tools must NOT be present
    refute "write_file" in tool_names
    refute "apply_patch" in tool_names

    GenServer.stop(pid)
  end

  test "switching from review to build restores write tools" do
    {:ok, pid} = Agent.start_link()
    Agent.set_mode(pid, :review)
    Agent.set_mode(pid, :build)

    tool_names = Agent.active_tools(pid)

    assert "write_file" in tool_names
    assert "apply_patch" in tool_names

    GenServer.stop(pid)
  end
end