defmodule Ella.StreamTest do
  use ExUnit.Case, async: true

  alias Ella.Stream

  defp feed(chunk), do: Stream.feed(chunk, %{})

  defp feed(chunk, state), do: Stream.feed(chunk, state)

  defp feed_all(chunks, state) do
    Enum.reduce(chunks, {[], state}, fn chunk, {acc, st} ->
      {:ok, events, new_state} = Stream.feed(chunk, st)
      {acc ++ events, new_state}
    end)
  end

  describe "feed/2 — цілі події" do
    test "розбирає одну подію" do
      {:ok, [event], _state} = feed(~s(data: {"a":1}\n\n))

      assert event.data == ~s({"a":1})
      assert event.event == nil
      assert event.id == nil
    end

    test "розбирає кілька подій з одного шматка" do
      {:ok, events, _state} = feed("data: one\n\ndata: two\n\n")

      assert length(events) == 2
      assert Enum.map(events, & &1.data) == ["one", "two"]
    end

    test "читає поле event та id" do
      {:ok, [event], _state} = feed("event: message\nid: 42\ndata: body\n\n")

      assert event.event == "message"
      assert event.id == "42"
      assert event.data == "body"
    end
  end

  describe "feed/2 — розбиті шматки" do
    test "буферизує неповну подію" do
      {:ok, events, state} = feed("data: hel")
      assert events == []

      {:ok, events2, _} = feed("lo\n\n", state)
      assert Enum.map(events2, & &1.data) == ["hello"]
    end

    test "буферизує половину роздільника подій" do
      {:ok, first, state} = feed("data: a\n")
      assert first == []

      {:ok, second, _} = feed("\ndata: b\n\n", state)
      assert Enum.map(second, & &1.data) == ["a", "b"]
    end

    test "склеює подію розірвану на багато шматків" do
      {events, _state} =
        feed_all(["da", "ta: he", "llo", "\n", "\n", ""], %{})

      assert Enum.map(events, & &1.data) == ["hello"]
    end

    test "повертає події перед неповною в кінці шматка" do
      {:ok, events, state} = feed("data: complete\n\ndata: partial")

      assert Enum.map(events, & &1.data) == ["complete"]
      assert state.buffer == "data: partial"
    end
  end

  describe "feed/2 — ігнорування" do
    test "ігнорує коментарі keep-alive" do
      {:ok, events, _state} = feed(": keep-alive\n\ndata: real\n\n")

      assert Enum.map(events, & &1.data) == ["real"]
    end

    test "ігнорує [DONE]" do
      {:ok, events, _state} = feed("data: real\n\ndata: [DONE]\n\n")

      assert Enum.map(events, & &1.data) == ["real"]
    end

    test "ігнорує подію без data" do
      {:ok, events, _state} = feed("event: ping\n\n")
      assert events == []
    end

    test "не плутає CRLF із роздільником" do
      {:ok, events, _state} = feed("data: a\r\n\r\ndata: b\r\n\r\n")

      assert Enum.map(events, & &1.data) == ["a", "b"]
    end
  end

  describe "done?/1" do
    test "розпізнає маркер завершення" do
      assert Stream.done?("[DONE]")
      assert Stream.done?(" [DONE] ")
      refute Stream.done?("{\"a\":1}")
    end
  end

  describe "decode_data/1" do
    test "розбирає JSON" do
      assert %{"text" => "hi"} = Stream.decode_data(~s({"text":"hi"}))
    end

    test "повертає nil на невалідний JSON" do
      assert Stream.decode_data("not json") == nil
    end
  end

  describe "accumulator/1" do
    test "передає події в callback і повертає {:cont, state}" do
      parent = self()

      acc =
        Stream.accumulator(fn event ->
          send(parent, {:event, event.data})
        end)

      state = %{}
      assert {:cont, new_state} = acc.({:data, "data: a\n\n"}, state)

      assert_received {:event, "a"}
      assert is_map(new_state)
    end

    test "зупиняється на {:done}" do
      acc = Stream.accumulator(fn _ -> :ok end)

      assert {:done, %{}} = acc.({:done, %{}}, nil)
    end

    test "накопичує буфер між викликами" do
      parent = self()

      acc =
        Stream.accumulator(fn event ->
          send(parent, {:event, event.data})
        end)

      {:cont, state} = acc.({:data, "data: par"}, %{})
      {:cont, _state} = acc.({:data, "tial\n\n"}, state)

      assert_received {:event, "partial"}
    end
  end
end
