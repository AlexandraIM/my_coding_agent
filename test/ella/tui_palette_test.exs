defmodule Ella.TuiPaletteTest do
  use ExUnit.Case, async: false

  alias TermUI.Test.DeterministicBackend

  setup do
    Application.put_env(:ella, :seed_default_skills, false)
    Ella.Storage.ensure_storage_created!()
    :ok
  end

  test "typing / opens command palette in rendered frame" do
    {:ok, agent} = Ella.Agent.start_link([])

    {:ok, runtime} =
      TermUI.start_link(Ella.Tui,
        agent: agent,
        backend: {DeterministicBackend, owner: self(), size: {12, 60}}
      )

    assert_receive {:backend, :draw, _}, 1000

    DeterministicBackend.send_event(runtime, TermUI.Event.text("/"))
    assert_receive {:backend, :draw, frame}, 1000

    # The rendered frame should contain palette text
    rendered = frame_to_text(frame)
    assert rendered =~ "Command Palette"

    DeterministicBackend.send_event(runtime, TermUI.Event.key("c", modifiers: [:ctrl]))
    assert_receive {:backend, :shutdown, _}, 1000
  end

  test "submitting unknown command in palette does not fall back to /plan" do
    state = %{
      agent: nil,
      mode: :build,
      palette: true,
      input: "/unknown",
      output: []
    }

    new_state = Ella.Tui.update({:submit, "/unknown"}, state)
    assert new_state.mode == :build
    assert Enum.any?(new_state.output, &(&1 =~ "Unknown command: /unknown"))
  end

  defp frame_to_text(frame) do
    for r <- 1..frame.height, into: "" do
      row =
        for c <- 1..frame.width, into: "" do
          case Map.get(frame.cells, {r, c}) do
            %{char: ch} when is_binary(ch) -> ch
            _ -> " "
          end
        end

      row <> "\n"
    end
  end
end
