defmodule Ella.Llm.Adapters.Poolside do
  @behaviour Ella.Llm.Adapter

  alias Ella.Llm.{Error, ToolCalls, Usage}
  alias Ella.Stream

  @impl true
  def chat_completion(messages, tools, config) do
    model = model(config)

    config
    |> build_req()
    |> Req.post(url: "/completions", json: payload(messages, tools, model, false))
    |> handle_response()
  end

  @impl true
  def chat_completion_stream(messages, tools, config, on_text) do
    model = model(config)

    {:ok, state} =
      Agent.start_link(fn ->
        %{buffer: "", text: "", tool_calls: [], usage: nil, halted: nil, completed: false}
      end)

    into =
      Stream.accumulator(
        fn event -> handle_event(event, on_text, state) end,
        fn _ -> Agent.update(state, &%{&1 | completed: true}) end
      )

    req =
      config
      |> build_req()
      |> Req.post(url: "/completions", json: payload(messages, tools, model, true), into: into)

    result =
      case req do
        {:ok, %Req.Response{status: 200}} ->
          final = Agent.get(state, & &1)

          cond do
            final.halted != nil ->
              {:error, halted_error(final.halted, final)}

            not final.completed ->
              {:error, truncated_error(final)}

            true ->
              {:ok, normalize_response(%{"text" => final.text, "tool_calls" => final.tool_calls}),
               final.usage}
          end

        {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
          {:error, classify(status, body, headers)}

        {:error, reason} ->
          {:error, network_error(reason, Agent.get(state, & &1))}
      end

    Agent.stop(state)
    result
  end

  # Див. OpenAI: обрив до першого фрагмента можна повторити, обрив після
  # надрукованого тексту — ні.
  defp truncated_error(%{text: text, tool_calls: calls}) do
    message =
      "Stream ended before the [DONE] marker " <>
        "(#{String.length(text)} chars, #{length(calls)} tool call(s))"

    if empty_output?(text, calls) do
      Error.transient(message <> " (before any output)")
    else
      Error.permanent(message <> " (partial output already shown)")
    end
  end

  defp empty_output?(text, calls), do: String.trim(text) == "" and calls == []

  defp halted_error(reason, %{text: text, tool_calls: calls}) do
    detail = "Stream halted: #{inspect(reason)}"

    if empty_output?(text, calls) do
      Error.transient(detail <> " (before any output)")
    else
      Error.permanent(detail <> " (partial output already shown)")
    end
  end

  defp network_error(reason, %{text: text, tool_calls: calls}) do
    message = "Network error: #{inspect(reason)}"

    if empty_output?(text, calls) do
      Error.transient(message)
    else
      Error.permanent(message <> " (stream interrupted after partial output)")
    end
  end

  defp handle_event(event, on_text, state) do
    case Stream.decode_data(event.data) do
      nil ->
        :ok

      %{"text" => text} when is_binary(text) and text != "" ->
        Agent.update(state, &%{&1 | text: &1.text <> text})

        case on_text.(text) do
          {:halt, reason} ->
            Agent.update(state, &%{&1 | halted: reason})
            {:halt, reason}

          _ ->
            :ok
        end

      %{"tool_calls" => [call | _]} when is_map(call) ->
        Agent.update(state, &%{&1 | tool_calls: ToolCalls.merge(&1.tool_calls, call)})
        :ok

      _ ->
        :ok
    end
  end

  defp payload(messages, tools, model, stream?) do
    %{
      "model" => model,
      "messages" => messages,
      "functions" => Enum.map(tools, &format_for_poolside/1),
      "stream" => stream?
    }
  end

  defp format_for_poolside(tool) when is_atom(tool) do
    %{
      "name" => tool.name(),
      "description" => tool.description(),
      "parameters" => tool.parameters()
    }
  end

  defp format_for_poolside(%{} = mcp_tool) do
    %{
      "name" => mcp_tool.name,
      "description" => mcp_tool.description,
      "parameters" => mcp_tool.parameters
    }
  end

  # Агент чекає узгоджену форму викликів: нормалізовані поля,
  # навіть якщо провайдер надсилав їх частинами або без id.
  defp normalize_response(body) do
    calls = body["tool_calls"] || []

    %{
      "content" => body["text"],
      "tool_calls" => if(calls == [], do: nil, else: ToolCalls.render(calls))
    }
  end

  defp build_req(config) do
    Req.new(
      base_url: Keyword.get(config, :base_url, "https://api.poolside.ai/v1"),
      headers: [{"x-api-key", Keyword.get(config, :api_key, System.get_env("POOLSIDE_API_KEY"))}],
      receive_timeout: Keyword.get(config, :request_timeout_ms) || 120_000
    )
  end

  defp model(config), do: Keyword.get(config, :model, "poolside-code-v1")

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    {:ok, normalize_response(body), usage(body)}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    {:error, classify(status, body, headers)}
  end

  defp handle_response({:error, reason}) do
    {:error, Error.transient("Network error: #{inspect(reason)}")}
  end

  defp usage(body), do: body |> Usage.from_response() |> Usage.with_cost()

  defp classify(429, body, headers) do
    Error.transient("Rate limited (429): #{inspect(body)}",
      status: 429,
      retry_after_ms: Ella.Llm.RetryAfter.from_headers(headers)
    )
  end

  defp classify(408, body, headers) do
    Error.transient("Request timeout (408): #{inspect(body)}",
      status: 408,
      retry_after_ms: Ella.Llm.RetryAfter.from_headers(headers)
    )
  end

  defp classify(status, body, headers) when status in 500..599 do
    Error.transient("Poolside server error #{status}: #{inspect(body)}",
      status: status,
      retry_after_ms: Ella.Llm.RetryAfter.from_headers(headers)
    )
  end

  defp classify(status, body, _headers) do
    Error.permanent("Poolside API error #{status}: #{inspect(body)}", status: status)
  end
end
