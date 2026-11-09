defmodule Ella.TuiTest do
  use ExUnit.Case, async: false

  alias TermUI.Test.DeterministicBackend

  setup do
    Application.put_env(:ella, :seed_default_skills, false)
    Ella.Storage.ensure_storage_created!()
    :ok
  end

  test "renders an initial frame" do
    {:ok, agent} = Ella.Agent.start_link([])
    {:ok, runtime} =
      TermUI.start_link(Ella.Tui,
        agent: agent,
        backend: {DeterministicBackend, owner: self(), size: {12, 60}}
      )

    assert_receive {:backend, :draw, %TermUI.Frame{} = _frame}, 1000
    # shutdown
    DeterministicBackend.send_event(runtime, TermUI.Event.key("c", modifiers: [:ctrl]))
    assert_receive {:backend, :shutdown, _}, 1000
  end

  test "typing and submit updates output" do
    {:ok, agent} = Ella.Agent.start_link([])
    {:ok, runtime} =
      TermUI.start_link(Ella.Tui,
        agent: agent,
        backend: {DeterministicBackend, owner: self(), size: {12, 60}}
      )

    assert_receive {:backend, :draw, _}, 1000

    # type "hi"
    DeterministicBackend.send_event(runtime, TermUI.Event.text("h"))
    DeterministicBackend.send_event(runtime, TermUI.Event.text("i"))
    DeterministicBackend.send_event(runtime, TermUI.Event.key(:enter))

    # should produce at least one more draw
    assert_receive {:backend, :draw, _}, 2000

    DeterministicBackend.send_event(runtime, TermUI.Event.key("c", modifiers: [:ctrl]))
    assert_receive {:backend, :shutdown, _}, 1000
  end
end
PYEOF