defmodule Ella.Mcp.ClientTest do
  use ExUnit.Case, async: true
  alias Ella.Mcp.Client

  test "buffers incomplete lines (:noeol) without crashing" do
    port_ref = make_ref()
    state = %{port: port_ref, request_id: 1, pending_requests: %{1 => {self(), make_ref()}}, buffer: ""}

    # Simulate receiving {:noeol, chunk}
    {:noreply, updated_state} = Client.handle_info({port_ref, {:data, {:noeol, ~s[{"id":1,]}}}, state)
    assert updated_state.buffer == ~s[{"id":1,]

    # Simulate receiving second {:noeol, chunk}
    {:noreply, updated_state2} = Client.handle_info({port_ref, {:data, {:noeol, ~s["result":{}}]}}}, updated_state)
    assert updated_state2.buffer == ~s[{"id":1,"result":{}}]
  end
end
