defmodule Ella.Llm.Adapters.OpenAI do
  @behaviour Ella.Llm.Adapter

  alias Ella.Llm.{Error, ToolCalls, Usage}
  alias Ella.Stream

  defstruct [:buffer, :text, :tool_calls, :usage, :halted, completed: false]

  @type t :: %__MODULE__{
          buffer: String.t() | nil,
          text: String.t() | nil,
          tool_calls: [map()],
          usage: Usage.t() | nil,
          halted: term(),
          completed: boolean()
        }

  @impl true
  def chat_completion(messages, tools, config) do
    model = model(config)

    config
    |> build_req()
    |> Req.post(url: "/chat/completions", json: payload(messages, tools, model, false))
    |> handle_response()
  end

  @impl true
  def chat_completion_stream(messages, tools, config, on_text) do
    model = model(config)
    {:ok, state} = Agent.start_link(fn -> new_stream_state() end)

    into =
      Stream.accumulator(
        fn event -> handle_event(event, on_text, state) end,
        fn _ -> Agent.update(state, &%{&1 | completed: true}) end
      )

    req =
      config
      |> build_req()
      |> Req.post(
        url: "/chat/completions",
        json: payload(messages, tools, model, true),
        into: into
      )

    result =
      case req do
        {:ok, %Req.Response{status: 200}} ->
          final = Agent.get(state, & &1)

          # Потік міг обірватися: відповідь неповна, і виглядати як
          # успішна вона не повинна — інакше агент збереже обрізаний
          # текст і піде далі.
          cond do
            final.halted != nil ->
              {:error, halted_error(final.halted, final)}

            not complete?(final) ->
              {:error, truncated_error(final)}

            true ->
              {:ok, finalize(final), final.usage}
          end

        {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
          {:error, classify(status, body, headers)}

        {:error, reason} ->
          {:error, network_error(reason, Agent.get(state, & &1))}
      end

    Agent.stop(state)
    result
  end

  defp new_stream_state do
    %__MODULE__{buffer: "", text: "", tool_calls: [], usage: nil, halted: nil, completed: false}
  end

  # Потік без маркера [DONE] обірваний: сервер не доповів відповідь
  # до кінця, і лише виглядає, що все добре.
  defp complete?(%__MODULE__{halted: nil, completed: true}), do: true
  defp complete?(%__MODULE__{halted: _reason}), do: false
  defp complete?(_state), do: false

  # Обрив потоку до того, як користувач побачив хоч щось, безпечно
  # повторюється: повтор не дублює видимого виводу. Якщо ж текст уже
  # надруковано, повтор призвів би до двох копій відповіді в терміналі,
  # тому такий випадок — помилка постійна.
  defp halted_error(reason, %{text: text, tool_calls: calls}) do
    detail = "Stream halted: #{inspect(reason)}"

    if empty_output?(text, calls) do
      Error.transient(detail <> " (before any output)")
    else
      Error.permanent(detail <> " (partial output already shown)")
    end
  end

  defp empty_output?(text, calls), do: String.trim(text) == "" and calls == []

  defp truncated_error(%__MODULE__{} = final) do
    message =
      "Stream ended before the [DONE] marker " <>
        "(#{String.length(final.text)} chars, #{length(final.tool_calls)} tool call(s))"

    if empty_output?(final.text, final.tool_calls) do
      Error.transient(message <> " (before any output)")
    else
      Error.permanent(message <> " (partial output already shown)")
    end
  end

  # Обрив з'єднання — типова тимчасова помилка, але повтор безпечний
  # лише тоді, коли користувач ще нічого не бачив.
  defp network_error(reason, state) do
    message = "Network error: #{inspect(reason)}"

    if empty_output?(state.text, state.tool_calls) do
      Error.transient(message)
    else
      Error.permanent(message <> " (stream interrupted after partial output)")
    end
  end

  # Чанк може нести або текст, або частину виклику інструмента.
  defp handle_event(event, on_text, state) do
    case Stream.decode_data(event.data) do
      nil ->
        :ok

      %{"choices" => [%{"delta" => delta} | _]} ->
        Agent.get_and_update(state, fn acc ->
          {next, emit} = apply_delta(acc, delta, on_text)
          {emit, next}
        end)

      %{"usage" => usage} ->
        Agent.update(state, &%{&1 | usage: usage_of(usage)})

      _ ->
        :ok
    end
  end

  defp apply_delta(acc, %{"content" => content}, on_text)
       when is_binary(content) and content != "" do
    acc = %{acc | text: acc.text <> content}

    case on_text.(content) do
      {:halt, reason} -> {%{acc | halted: reason}, {:halt, reason}}
      _ -> {acc, :ok}
    end
  end

  defp apply_delta(acc, %{"tool_calls" => [call | _]}, _on_text) when is_map(call) do
    {%{acc | tool_calls: ToolCalls.merge(acc.tool_calls, call)}, :ok}
  end

  defp apply_delta(acc, _delta, _on_text), do: {acc, :ok}

  defp finalize(state) do
    case state.tool_calls do
      [] ->
        %{"role" => "assistant", "content" => state.text}

      calls ->
        %{
          "role" => "assistant",
          "content" => state.text,
          "tool_calls" => ToolCalls.render(calls)
        }
    end
  end

  defp payload(messages, tools, model, stream?) do
    %{
      "model" => model,
      "messages" => messages,
      "tools" => Ella.Agent.build_tool_schemas(tools),
      "stream" => stream?
    }
    |> maybe_put_usage(stream?)
  end

  # Без stream_options фінальний чанк не містить usage.
  defp maybe_put_usage(payload, true),
    do: Map.put(payload, "stream_options", %{"include_usage" => true})

  defp maybe_put_usage(payload, false), do: payload

  defp build_req(config) do
    Req.new(
      base_url: Keyword.get(config, :base_url, "https://api.openai.com/v1"),
      headers: [
        {"authorization",
         "Bearer #{Keyword.get(config, :api_key, System.get_env("LLM_API_KEY") || "")}"},
        {"content-type", "application/json"}
      ],
      receive_timeout: timeout(config)
    )
  end

  # Таймаут приходить у конфіг запиту: LlmClient додає його з
  # конфігурації проєкту, тож адаптер не читає файли сам.
  defp timeout(config) do
    Keyword.get(config, :request_timeout_ms) || 120_000
  end

  defp model(config), do: Keyword.get(config, :model, "gpt-4o")

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    case Enum.at(body["choices"] || [], 0) do
      nil ->
        {:error,
         Error.permanent("API returned HTTP 200 but choices array is empty: #{inspect(body)}")}

      choice ->
        {:ok, choice["message"], usage(body)}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    {:error, classify(status, body, headers)}
  end

  defp handle_response({:error, reason}) do
    {:error, Error.transient("Network error: #{inspect(reason)}")}
  end

  defp usage(body), do: body |> Usage.from_response() |> Usage.with_cost()

  defp usage_of(%{} = usage) do
    %{"usage" => usage} |> Usage.from_response() |> Usage.with_cost()
  end

  defp classify(429, body, headers) do
    Error.transient("Rate limited (429): #{inspect(body)}", retry_after_ms: retry_after(headers))
  end

  defp classify(408, body, headers) do
    # 408 — сервер сам зізнався, що не дочекався запиту: це саме
    # випадок для повтору, а не для паніки.
    Error.transient(
      "Request timeout (408): #{inspect(body)}",
      status: 408,
      retry_after_ms: retry_after(headers)
    )
  end

  defp classify(status, body, headers) when status in 500..599 do
    Error.transient(
      "Server error #{status}: #{inspect(body)}",
      status: status,
      retry_after_ms: retry_after(headers)
    )
  end

  defp classify(status, body, _headers) do
    Error.permanent("API error #{status}: #{inspect(body)}", status: status)
  end

  # Retry-After уміє бути і кількістю секунд, і HTTP-датою —
  # розбираємо обидва варіанти в одному місці.
  defp retry_after(response), do: Ella.Llm.RetryAfter.from_headers(response)
end
