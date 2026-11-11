defmodule Ella.Tools.DelegateTaskTest do
  use ExUnit.Case, async: false

  alias Ella.Tools.DelegateTask

  defmodule DummyAdapter do
    @behaviour Ella.Llm.Adapter
    def chat_completion(_messages, _tools, _config) do
      {:ok, %{"role" => "assistant", "content" => "Sub-agent finished"}, Ella.Llm.Usage.empty()}
    end

    def chat_completion_stream(_messages, _tools, _config, _on_text) do
      {:ok, %{"role" => "assistant", "content" => "Sub-agent finished"}, Ella.Llm.Usage.empty()}
    end
  end

  test "parameters and metadata" do
    assert DelegateTask.name() == "delegate_task"
    assert is_binary(DelegateTask.description())
    assert DelegateTask.parameters()["required"] == ["task"]
  end

  test "execute with invalid args" do
    assert {:error, _} = DelegateTask.execute(%{})
    assert {:error, _} = DelegateTask.execute("invalid")
  end

  test "execute prints banner via Ella.Output" do
    Ella.Output.set_sink({:tui, self()})
    on_exit(fn -> Ella.Output.reset_sink() end)

    Process.put(:ella_agent_llm_opts, adapter: DummyAdapter)
    _ = DelegateTask.execute(%{"task" => "test task description"})

    assert_receive {:output, banner}, 1000
    assert banner =~ "Delegating sub-task: test task description"
  end
end
