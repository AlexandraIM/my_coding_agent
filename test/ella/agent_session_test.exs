defmodule Ella.AgentSessionTest do
  use ExUnit.Case, async: false

  alias Ella.Agent

  setup do
    root =
      Path.join(System.tmp_dir!(), "ella_agent_sess_#{System.unique_integer([:positive])}")

    storage_prev = Application.get_env(:ella, :storage_dir)
    mcp_prev = Application.get_env(:ella, :restore_mcp)
    Application.put_env(:ella, :storage_dir, root)
    Application.put_env(:ella, :restore_mcp, false)

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(storage_prev) do
        Application.delete_env(:ella, :storage_dir)
      else
        Application.put_env(:ella, :storage_dir, storage_prev)
      end

      if is_nil(mcp_prev) do
        Application.delete_env(:ella, :restore_mcp)
      else
        Application.put_env(:ella, :restore_mcp, mcp_prev)
      end
    end)

    :ok
  end

  test "save and load session restores messages and mode" do
    {:ok, pid} = Agent.start_link()
    Agent.set_mode(pid, :build)

    # Inject a couple of messages into history.
    :sys.replace_state(pid, fn state ->
      %{state | messages: state.messages ++ [%{"role" => "user", "content" => "hello"}]}
    end)

    assert {:ok, _path} = Agent.save_session(pid, "demo")

    # Fresh agent loads it.
    {:ok, pid2} = Agent.start_link()
    assert {:ok, "demo"} = Agent.load_session(pid2, "demo")

    state = :sys.get_state(pid2)
    assert state.mode == :build
    assert Enum.any?(state.messages, fn m -> m["content"] == "hello" end)

    GenServer.stop(pid)
    GenServer.stop(pid2)
  end

  test "load missing session returns error" do
    {:ok, pid} = Agent.start_link()
    assert {:error, :not_found} = Agent.load_session(pid, "nope")
    GenServer.stop(pid)
  end

  test "list_sessions delegates to storage" do
    {:ok, pid} = Agent.start_link()
    Agent.save_session(pid, "x")
    assert "x" in Agent.list_sessions()
    GenServer.stop(pid)
  end
end
