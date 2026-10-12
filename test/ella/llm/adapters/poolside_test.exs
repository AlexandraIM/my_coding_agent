defmodule Ella.Llm.Adapters.PoolsideTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.Adapters.Poolside

  defp sse(events) do
    body = Enum.map_join(events, fn event -> "data: " <> event <> "\n\n" end)

    "data: [DONE]\n\n" <> body
  end

  defp events_body(events) do
    Enum.map_join(events, fn event -> "data: " <> event <> "\n\n" end)
  end

  defp start_server(body, opts \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{byte_size(body)}\r\n\r\n"
      )

      for chunk <- chunks(body), do: :gen_tcp.send(socket, chunk)

      Process.sleep(if Keyword.get(opts, :keep_open, false), do: 2_000, else: 100)
      :gen_tcp.close(socket)
    end)

    {listener, port}
  end

  defp chunks(body) do
    body
    |> :binary.bin_to_list()
    |> Enum.chunk_every(7)
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  defp stream_config(port) do
    [base_url: "http://localhost:#{port}/v1", api_key: "test", model: "poolside-code-v1"]
  end

  defp call_stream(port, on_text \\ fn _ -> :ok end) do
    Poolside.chat_completion_stream([], [Ella.Tools.ReadFile], stream_config(port), on_text)
  end

  describe "chat_completion_stream/4 — текст" do
    test "складає фрагменти в повний текст" do
      body =
        sse([
          ~s({"text":"Hello"}),
          ~s({"text":", world"}),
          ~s({"text":"!"})
        ])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, _usage} = call_stream(port)
      assert message["content"] == "Hello, world!"
    end

    test "передає фрагменти в on_text, щоб текст друкувався наживо" do
      body = sse([~s({"text":"abc"})])
      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      parent = self()
      on_text = fn fragment -> send(parent, {:fragment, fragment}) end

      assert {:ok, _message, _usage} = call_stream(port, on_text)
      assert_received {:fragment, "abc"}
    end
  end

  describe "chat_completion_stream/4 — виклики інструментів" do
    test "збирає аргументи з частин в один виклик" do
      body =
        sse([
          ~s({"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file"}}]}),
          ~s({"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\""}}]}),
          ~s({"tool_calls":[{"index":0,"function":{"arguments":":\\"mix.exs\\"}"}}]})
        ])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, _usage} = call_stream(port)

      assert [call] = message["tool_calls"]
      assert call["id"] == "call_1"
      assert call["function"]["name"] == "read_file"
      assert Jason.decode!(call["function"]["arguments"]) == %{"path" => "mix.exs"}
    end

    test "підтримує паралельні виклики" do
      body =
        sse([
          ~s({"tool_calls":[{"index":0,"function":{"name":"grep"}}]}),
          ~s({"tool_calls":[{"index":1,"function":{"name":"glob"}}]})
        ])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, _usage} = call_stream(port)

      assert length(message["tool_calls"]) == 2
      assert Enum.map(message["tool_calls"], & &1["function"]["name"]) == ["grep", "glob"]
    end

    test "нормалізує плоску форму виклику" do
      body = sse([~s({"tool_calls":[{"index":0,"name":"list_dir","arguments":"{}"}]})])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, _usage} = call_stream(port)

      assert [call] = message["tool_calls"]
      assert call["function"]["name"] == "list_dir"
      assert call["type"] == "function"
    end
  end

  describe "chat_completion_stream/4 — обрив і помилки" do
    test "потік без [DONE] вважається обірваним" do
      body = events_body([~s({"text":"Hello"})])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call_stream(port)

      assert error.message =~ "[DONE]"

      # Текст уже надруковано, тому повтор продублював би його.
      refute error.retryable?
    end

    test "зупинка on_text зупиняє потік" do
      chunks =
        Enum.map(1..50, fn i -> ~s({"text":"w#{i} "}) end)

      {listener, port} = start_server(sse(chunks), keep_open: true)
      on_exit(fn -> :gen_tcp.close(listener) end)

      parent = self()

      on_text = fn fragment ->
        send(parent, {:fragment, fragment})

        if String.contains?(fragment, "w2") do
          {:halt, :user_cancelled}
        else
          :ok
        end
      end

      assert {:error, error} = call_stream(port, on_text)
      assert error.message =~ "user_cancelled"

      refute_receive {:fragment, "w3 "}, 200
    end

    test "401 не повторюється" do
      {port, listener} = raw_server("HTTP/1.1 401 Unauthorized\r\n\r\n")
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call_stream(port)
      refute error.retryable?
      assert error.status == 401
    end

    test "503 повторюється і читає Retry-After" do
      {port, listener} =
        raw_server("HTTP/1.1 503 Service Unavailable\r\nretry-after: 2\r\n\r\n")

      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call_stream(port)
      assert error.retryable?
      assert error.retry_after_ms == 2_000
    end
  end

  describe "chat_completion/3 — без стріму" do
    test "повертає текст і usage" do
      body =
        Jason.encode!(%{
          "text" => "hello",
          "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 3},
          "model" => "poolside-code-v1"
        })

      {port, listener} = json_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, usage} = Poolside.chat_completion([], [], stream_config(port))

      assert message["content"] == "hello"
      assert usage.prompt_tokens == 12
    end

    test "повертає постійну помилку для 400" do
      {port, listener} = json_server(~s({"error":"bad request"}), status: "400 Bad Request")
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = Poolside.chat_completion([], [], stream_config(port))
      refute error.retryable?
      assert error.status == 400
    end
  end

  defp json_server(body, opts \\ []) do
    status = Keyword.get(opts, :status, "200 OK")

    raw_server(
      "HTTP/1.1 #{status}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"
    )
  end

  defp raw_server(response) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :gen_tcp.send(socket, response)
      Process.sleep(50)
      :gen_tcp.close(socket)
    end)

    {port, listener}
  end
end
