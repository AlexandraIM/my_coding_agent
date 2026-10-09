defmodule Ella.Llm.Adapters.Poolside do
  @behaviour Ella.Llm.Adapter

  alias Ella.Llm.{Error, Usage}
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
        %{buffer: "", text: "", tool_calls: [], usage: nil, halted: nil}
      end)

    into = Stream.accumulator(fn event -> handle_event(event, on_text, state) end)

    req =
      config
      |> build_req()
      |> Req.post(url: "/completions", json: payload(messages, tools, model, true), into: into)

    result =
      case req do
        {:ok, %Req.Response{status: 200}} ->
          final = Agent.get(state, & &1)

          case final.halted do
            nil ->
              {:ok, normalize_response(%{"text" => final.text, "tool_calls" => final.tool_calls}),
               final.usage}

            reason ->
              {:error, Error.permanent("Stream halted: #{inspect(reason)}")}
          end

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, classify(status, body)}

        {:error, reason} ->
          {:error, Error.transient("Network error: #{inspect(reason)}")}
      end

    Agent.stop(state)
    result
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
        Agent.update(state, &%{&1 | tool_calls: &1.tool_calls ++ [call]})
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

  defp normalize_response(body) do
    %{"content" => body["text"], "tool_calls" => body["tool_calls"]}
  end

  defp build_req(config) do
    Req.new(
      base_url: Keyword.get(config, :base_url, "https://api.poolside.ai/v1"),
      headers: [{"x-api-key", Keyword.get(config, :api_key, System.get_env("POOLSIDE_API_KEY"))}],
      receive_timeout: 120_000
    )
  end

  defp model(config), do: Keyword.get(config, :model, "poolside-code-v1")

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}) do
    {:ok, normalize_response(body), usage(body)}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, classify(status, body)}
  end

  defp handle_response({:error, reason}) do
    {:error, Error.transient("Network error: #{inspect(reason)}")}
  end

  defp usage(body), do: body |> Usage.from_response() |> Usage.with_cost()

  defp classify(429, body) do
    Error.transient("Rate limited (429): #{inspect(body)}", status: 429)
  end

  defp classify(status, body) when status in 500..599 do
    Error.transient("Poolside server error #{status}: #{inspect(body)}", status: status)
  end

  defp classify(status, body) do
    Error.permanent("Poolside API error #{status}: #{inspect(body)}", status: status)
  end
end
