defmodule Ella.Llm.Adapters.OpenAI do
  @behaviour Ella.Llm.Adapter

  alias Ella.Llm.{Error, Usage}
  alias Ella.Stream

  defstruct [:buffer, :text, :tool_calls, :usage, :halted]

  @type t :: %__MODULE__{
          buffer: String.t() | nil,
          text: String.t() | nil,
          tool_calls: [map()],
          usage: Usage.t() | nil,
          halted: term()
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

    into = Stream.accumulator(fn event -> handle_event(event, on_text, state) end)

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
          {:ok, state |> Agent.get(& &1) |> finalize(), Agent.get(state, & &1.usage)}

        {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
          {:error, classify(status, body, headers)}

        {:error, reason} ->
          {:error, Error.transient("Network error: #{inspect(reason)}")}
      end

    Agent.stop(state)
    result
  end

  defp new_stream_state do
    %__MODULE__{buffer: "", text: "", tool_calls: [], usage: nil, halted: nil}
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

    acc =
      case on_text.(content) do
        {:halt, reason} -> %{acc | halted: reason}
        _ -> acc
      end

    {acc, :ok}
  end

  defp apply_delta(acc, %{"tool_calls" => [call | _]}, _on_text) when is_map(call) do
    {%{acc | tool_calls: merge_tool_call(acc.tool_calls, call)}, :ok}
  end

  defp apply_delta(acc, _delta, _on_text), do: {acc, :ok}

  # Провайдери надсилають аргументи інструментів частинами: індекс у
  # масиві стабільний, тож накопичуємо за ним, а не просто append.
  defp merge_tool_call(existing, call) when is_list(existing) do
    index = Map.get(call, "index")

    case Enum.find_index(existing, &(&1["index"] == index)) do
      nil ->
        existing ++ [call]

      position ->
        List.replace_at(existing, position, merge_fields(Enum.at(existing, position), call))
    end
  end

  # Злиття має бути рекурсивним: аргументи приходять усередині
  # вкладеного об'єкта "function", і просте заміщення відкидало б
  # уже накопичену частину JSON.
  defp merge_fields(base, addition) do
    Enum.reduce(addition, base, fn
      {key, new}, acc when is_map(new) ->
        case Map.get(acc, key) do
          current when is_map(current) -> Map.put(acc, key, merge_fields(current, new))
          _ -> Map.put(acc, key, new)
        end

      {key, new}, acc when is_binary(new) ->
        case Map.get(acc, key) do
          current when is_binary(current) -> Map.put(acc, key, current <> new)
          _ -> Map.put(acc, key, new)
        end

      _key_value, acc ->
        acc
    end)
  end

  defp finalize(state) do
    case state.tool_calls do
      [] ->
        %{"role" => "assistant", "content" => state.text}

      calls ->
        rendered =
          calls
          |> Enum.with_index(1)
          |> Enum.map(fn {call, n} ->
            %{
              "id" => call["id"] || "call_#{n}",
              "type" => "function",
              "function" => %{
                "name" => get_in(call, ["function", "name"]),
                "arguments" => get_in(call, ["function", "arguments"]) || "{}"
              }
            }
          end)

        %{"role" => "assistant", "content" => state.text, "tool_calls" => rendered}
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
      receive_timeout: 120_000
    )
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

  # Провайдери надсилають Retry-After у секундах або як HTTP-date.
  # У stream-відповіді Req віддає заголовки звичайною мапою, а не
  # %Req.Response{}, тому читаємо обидва варіанти.
  defp retry_after(%Req.Response{} = response), do: retry_after(response.headers)

  defp retry_after(headers) when is_map(headers) do
    value =
      Enum.find_value(headers, fn
        {"retry-after", v} -> v
        _ -> nil
      end)

    parse_retry_after(value)
  end

  defp retry_after(_), do: nil

  defp parse_retry_after(nil), do: nil

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _} -> seconds * 1_000
      :error -> nil
    end
  end

  defp parse_retry_after(_), do: nil
end
