defmodule Ella.Llm.Adapters.OpenAI.StreamTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.Adapters.OpenAI

  defp sse(events) do
    body =
      Enum.map_join(events, fn event ->
        "data: " <> event <> "\n\n"
      end)

    "data: [DONE]\n\n" <> body
  end

  defp start_server(body, opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listener)

    parent = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)

      headers =
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: #{byte_size(body)}\r\n\r\n"

      :gen_tcp.send(socket, headers)

      # Репнемо дрібними шматочками, щоб перевірити буферизацію SSE.
      for chunk <- chunks(body), do: :gen_tcp.send(socket, chunk)

      send(parent, :sent)

      if Keyword.get(opts, :keep_open, false) do
        # Сервер, який не завершує відповідь: клієнт має закрити
        # з'єднання сам, інакше тест зависне.
        Process.sleep(5_000)
      else
        Process.sleep(200)
      end

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

  defp call(port, on_text) do
    config = [base_url: "http://localhost:#{port}/v1", api_key: "test", model: "gpt-4o"]

    OpenAI.chat_completion_stream([], [Ella.Tools.ReadFile], config, on_text)
  end

  describe "chat_completion_stream/4 — текст" do
    test "складає фрагменти в повний текст" do
      body =
        sse([
          ~s({"choices":[{"delta":{"content":"Hello"}}]}),
          ~s({"choices":[{"delta":{"content":", world"}}]}),
          ~s({"choices":[{"delta":{"content":"!"}}]})
        ])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      parent = self()
      on_text = fn fragment -> send(parent, {:fragment, fragment}) end

      assert {:ok, message, _usage} = call(port, on_text)

      assert message["content"] == "Hello, world!"
      assert message["tool_calls"] == nil

      assert_received {:fragment, "Hello"}
      assert_received {:fragment, ", world"}
      assert_received {:fragment, "!"}
    end

    test "повертає порожній текст, якщо контент не прийшов" do
      body = sse([~s({"choices":[{"delta":{}}]})])
      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, _usage} = call(port, fn _ -> :ok end)
      assert message["content"] == ""
    end
  end

  describe "chat_completion_stream/4 — виклики інструментів" do
    test "збирає аргументи з частин" do
      first =
        Jason.encode!(%{
          "choices" => [%{"delta" => %{"tool_calls" => [%{"index" => 0, "id" => "call_1"}]}}]
        })

      name =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"name" => "read_file"}}]
              }
            }
          ]
        })

      arg1 =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"path\""}}]
              }
            }
          ]
        })

      arg2 =
        Jason.encode!(%{
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => ":\"mix.exs\"}"}}]
              }
            }
          ]
        })

      body = sse([first, name, arg1, arg2])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, _usage} = call(port, fn _ -> :ok end)

      assert [call] = message["tool_calls"]
      assert call["id"] == "call_1"
      assert call["function"]["name"] == "read_file"
      assert Jason.decode!(call["function"]["arguments"]) == %{"path" => "mix.exs"}
    end

    test "збирає кілька паралельних викликів" do
      body =
        sse([
          ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"grep"}}]}}]}),
          ~s({"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"glob"}}]}}]})
        ])

      {listener, port} = start_server(body)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, message, _usage} = call(port, fn _ -> :ok end)

      assert length(message["tool_calls"]) == 2
      assert Enum.map(message["tool_calls"], & &1["function"]["name"]) == ["grep", "glob"]
    end
  end

  describe "chat_completion_stream/4 — зупинка" do
    test "on_text може перервати потік" do
      chunks =
        Enum.map(1..50, fn i ->
          Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "w#{i} "}}]})
        end)

      body = sse(chunks)
      {listener, port} = start_server(body, keep_open: true)
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

      assert {:error, error} = call(port, on_text)
      assert error.message =~ "halted"
      assert error.message =~ "user_cancelled"
      refute error.retryable?

      # Обрив зупинив читання: далі ніхто нічого не надсилає.
      refute_receive {:fragment, "w3 "}, 200
    end

    test "потік без зупинки повертає повний текст" do
      chunks =
        Enum.map(1..5, fn _i ->
          Jason.encode!(%{"choices" => [%{"delta" => %{"content" => "x"}}]})
        end)

      {listener, port} = start_server(sse(chunks))
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:ok, %{"content" => "xxxxx"}, _usage} = call(port, fn _ -> :ok end)
    end
  end

  describe "chat_completion_stream/4 — помилки" do
    test "повертає структуровану помилку для 401" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.send(socket, "HTTP/1.1 401 Unauthorized\r\n\r\n")
        :gen_tcp.close(socket)
      end)

      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call(port, fn _ -> :ok end)
      refute error.retryable?
      assert error.status == 401
    end

    test "повертає тимчасову помилку для 503" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.send(socket, "HTTP/1.1 503 Service Unavailable\r\n\r\n")
        :gen_tcp.close(socket)
      end)

      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call(port, fn _ -> :ok end)
      assert error.retryable?
      assert error.status == 503
    end

    test "читає Retry-After у секундах для 429" do
      {port, listener} = raw_server("HTTP/1.1 429 Too Many Requests\r\nretry-after: 3\r\n\r\n")
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call(port, fn _ -> :ok end)
      assert error.retryable?
      assert error.retry_after_ms == 3_000
    end

    test "читає Retry-After як HTTP-дату" do
      header = http_date(DateTime.add(DateTime.utc_now(), 30, :second))

      {port, listener} =
        raw_server("HTTP/1.1 429 Too Many Requests\r\nretry-after: #{header}\r\n\r\n")

      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call(port, fn _ -> :ok end)
      assert is_integer(error.retry_after_ms)
      assert error.retry_after_ms > 20_000
    end

    test "408 вважається тимчасовою помилкою" do
      {port, listener} = raw_server("HTTP/1.1 408 Request Timeout\r\n\r\n")
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call(port, fn _ -> :ok end)
      assert error.retryable?
      assert error.status == 408
    end

    test "обрив з'єднання до першого фрагмента можна повторити" do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 400\r\n\r\npartial")
        :gen_tcp.close(socket)
      end)

      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, error} = call(port, fn _ -> :ok end)
      assert error.retryable?
      assert error.message =~ "Network error"
    end

    test "обрив після видимого тексту не повторюється" do
      # Без [DONE]: з'єднання обривається, не дочекавшись завершення.
      body =
        Enum.map_join(
          [
            ~s({"choices":[{"delta":{"content":"Hello"}}]}),
            ~s({"choices":[{"delta":{"content":", world"}}]})
          ],
          fn event -> "data: " <> event <> "\n\n" end
        )

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n")
        :gen_tcp.send(socket, body)

        # Даємо клієнту прочитати чанки перед обривом: інакше гонка
        # і тест перевірятиме не логіку, а швидкість доставки.
        Process.sleep(100)
        # Обриваємо відповідь, не надіславши [DONE].
        :gen_tcp.close(socket)
      end)

      on_exit(fn -> :gen_tcp.close(listener) end)

      parent = self()
      on_text = fn fragment -> send(parent, {:fragment, fragment}) end

      assert {:error, error} = call(port, on_text)
      assert_received {:fragment, "Hello"}

      # Повтор продублював би "Hello" у терміналі, тож помилка
      # постійна.
      refute error.retryable?
      assert error.message =~ "partial output"
    end
  end

  defp http_date(datetime) do
    weekday = ~w(Mon Tue Wed Thu Fri Sat Sun) |> Enum.at(Date.day_of_week(datetime) - 1)
    month = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec) |> Enum.at(datetime.month - 1)

    "#{weekday}, #{pad(datetime.day)} #{month} #{datetime.year} " <>
      "#{pad(datetime.hour)}:#{pad(datetime.minute)}:#{pad(datetime.second)} GMT"
  end

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: to_string(n)

  defp raw_server(response) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
    end)

    {port, listener}
  end
end
