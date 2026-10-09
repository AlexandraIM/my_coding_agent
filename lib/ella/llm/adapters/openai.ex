defmodule Ella.Llm.Adapters.OpenAI do
  @behaviour Ella.Llm.Adapter

  alias Ella.Llm.{Error, Usage}

  @impl true
  def chat_completion(messages, tools, config) do
    base_url = Keyword.get(config, :base_url, "https://api.openai.com/v1")
    api_key = Keyword.get(config, :api_key, System.get_env("LLM_API_KEY") || "")
    model = Keyword.get(config, :model, "gpt-4o")

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
      {:ok, %Req.Response{status: 200, body: body, headers: headers}} ->
        finish(body, headers)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:error, classify(status, body, headers)}

      {:error, reason} ->
        {:error, Error.transient("Network error: #{inspect(reason)}")}
    end
  end

  defp finish(body, headers) do
    case Enum.at(body["choices"] || [], 0) do
      nil ->
        {:error,
         Error.permanent("API returned HTTP 200 but choices array is empty: #{inspect(body)}")}

      choice ->
        {:ok, choice["message"], usage(body)}
    end
    |> tap_usage(headers)
  end

  # OpenAI повертає usage у тілі; заголовки потрібні лише для retry_after.
  defp usage(body), do: body |> Usage.from_response() |> Usage.with_cost()

  defp tap_usage(result, _headers), do: result

  defp classify(429, body, headers) do
    Error.transient(
      "Rate limited (429): #{inspect(body)}",
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

  # Провайдери надсилають Retry-After у секундах або як HTTP-date.
  defp retry_after(headers) do
    case Req.Response.get_header(headers, "retry-after") do
      [value | _] ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1_000
          :error -> nil
        end

      [] ->
        nil
    end
  end
end
