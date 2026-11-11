defmodule Ella.AgentE2ETest do
  use ExUnit.Case, async: false

  defmodule FakeSequenceAdapter do
    @moduledoc "Replays a pre-programmed sequence of LLM responses."

    def chat_completion(messages, _tools, opts) do
      seq = Application.get_env(:ella, :fake_sequence, [])
      [next | rest] = seq
      Application.put_env(:ella, :fake_sequence, rest)

      if on_text = opts[:on_text], do: on_text.(next["content"] || "")

      {:ok, next, Ella.Llm.Usage.empty()}
    end
  end

  setup do
    previous_root = Application.get_env(:ella, :sandbox_root)
    root = Path.join(System.tmp_dir!(), "e2e_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    Application.put_env(:ella, :sandbox_root, root)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.delete_env(:ella, :fake_sequence)

      if is_nil(previous_root) do
        Application.delete_env(:ella, :sandbox_root)
      else
        Application.put_env(:ella, :sandbox_root, previous_root)
      end
    end)

    :ok
  end

  test "full loop: LLM calls tool, receives result, returns final answer" do
    Application.put_env(:ella, :fake_sequence, [
      %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "c1",
            "function" => %{
              "name" => "system_exec",
              "arguments" => ~s({"command":"echo hello"})
            }
          }
        ]
      },
      %{"role" => "assistant", "content" => "Done. Output was: hello"}
    ])

    {:ok, pid} =
      Ella.Agent.start_link(
        llm_opts: [adapter: FakeSequenceAdapter],
        mode: :build,
        tools: [Ella.Tools.SystemExec]
      )

    assert {:ok, reply} = Ella.Agent.ask(pid, "run echo")
    assert reply =~ "Done"

    GenServer.stop(pid)
  end

  test "mode transition: plan -> build exposes write_file" do
    Application.put_env(:ella, :fake_sequence, [%{"role" => "assistant", "content" => "ok"}])

    {:ok, pid} =
      Ella.Agent.start_link(
        llm_opts: [adapter: FakeSequenceAdapter],
        mode: :plan
      )

    assert Ella.Agent.active_tools(pid) |> Enum.member?("write_file") == false

    Ella.Agent.set_mode(pid, :build)

    assert Ella.Agent.active_tools(pid) |> Enum.member?("write_file")

    GenServer.stop(pid)
  end
end
