defmodule Ella.Llm.Adapters.OpenAI do
  @behaviour Ella.Llm.Adapter

  @impl true
  def chat_completion(messages, tools, config) do
    base_url = Keyword.get(config, :base_url, "https://api.openai.com/v1")
    api_key = Keyword.get(config, :api_key, System.get_env("LLM_API_KEY") || "")
    model = Keyword.get(config, :model, "gpt-4o")

    # Конвертуємо інструменти в схему
    tool_schemas = Ella.Agent.build_tool_schemas(tools)

    payload = %{
      "model" => model,
      "messages" => messages,
      "tools" => tool_schemas
    }

    req =
      Req.new(
        base_url: base_url,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 120_000
      )

    case Req.post(req, url: "/chat/completions", json: payload) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Enum.at(body["choices"] || [], 0) do
          nil ->
            {:error, "API returned HTTP 200 but choices array is empty: #{inspect(body)}"}

          choice ->
            {:ok, choice["message"]}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "API error Status #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Network error: #{inspect(reason)}"}
    end
  end
end
