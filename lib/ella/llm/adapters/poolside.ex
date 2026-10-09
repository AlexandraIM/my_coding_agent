defmodule Ella.Llm.Adapters.Poolside do
  @behaviour Ella.Llm.Adapter

  @impl true
  def chat_completion(messages, tools, config) do
    base_url = Keyword.get(config, :base_url, "https://api.poolside.ai/v1")
    api_key = Keyword.get(config, :api_key, System.get_env("POOLSIDE_API_KEY"))
    model = Keyword.get(config, :model, "poolside-code-v1")

    # Форматуємо під специфічні вимоги Poolside API
    payload = %{
      "model" => model,
      "messages" => messages,
      "functions" => Enum.map(tools, &format_for_poolside/1)
    }

    req =
      Req.new(
        base_url: base_url,
        headers: [{"x-api-key", api_key}]
      )

    case Req.post(req, url: "/completions", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        # Трансформуємо відповідь Poolside у стандартний формат нашого агента
        {:ok, normalize_response(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Poolside API error (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end

  defp format_for_poolside(tool) do
    %{
      "name" => tool.name(),
      "description" => tool.description(),
      "parameters" => tool.parameters()
    }
  end

  defp normalize_response(body) do
    # Нормалізація відповіді у формат %{"content" => ..., "tool_calls" => ...}
    %{"content" => body["text"], "tool_calls" => body["tool_calls"]}
  end
end
