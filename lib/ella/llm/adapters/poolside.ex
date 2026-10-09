defmodule Ella.Llm.Adapters.Poolside do
  @behaviour Ella.Llm.Adapter

  alias Ella.Llm.{Error, Usage}

  @impl true
  def chat_completion(messages, tools, config) do
    base_url = Keyword.get(config, :base_url, "https://api.poolside.ai/v1")
    api_key = Keyword.get(config, :api_key, System.get_env("POOLSIDE_API_KEY"))
    model = Keyword.get(config, :model, "poolside-code-v1")

    payload = %{
      "model" => model,
      "messages" => messages,
      "functions" => Enum.map(tools, &format_for_poolside/1)
    }

    req =
      Req.new(
        base_url: base_url,
        headers: [{"x-api-key", api_key}],
        receive_timeout: 120_000
      )

    case Req.post(req, url: "/completions", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, normalize_response(body), usage(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, classify(status, body)}

      {:error, reason} ->
        {:error, Error.transient("Network error: #{inspect(reason)}")}
    end
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
