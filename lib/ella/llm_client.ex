defmodule Ella.LlmClient do
  @doc """
  Entry point for LLM client, handles chat completion requests.
  """

  def chat_completion(messages, tools, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, default_adapter())
    config = Keyword.get(opts, :config, default_config_for(adapter))

    Owl.IO.puts(Owl.Data.tag("--- [LLM REQUEST START] ---", :magenta))
    Owl.IO.puts([Owl.Data.tag("Adapter: ", :cyan), inspect(adapter)])
    Owl.IO.puts([Owl.Data.tag("Config: ", :cyan), inspect(config)])

    case adapter.chat_completion(messages, tools, config) do
      {:ok, response} = result ->
        Owl.IO.puts(Owl.Data.tag("--- [LLM RESPONSE SUCCESS] ---", :green))
        Owl.IO.puts(inspect(response, pretty: true, limit: :infinity))
        result

      {:error, reason} = result ->
        Owl.IO.puts(Owl.Data.tag("--- [LLM RESPONSE ERROR] ---", :red))
        Owl.IO.puts(inspect(reason, pretty: true, limit: :infinity))
        result
    end
  end

  defp default_adapter do
    case System.get_env("LLM_PROVIDER") do
      "poolside" -> Ella.Llm.Adapters.Poolside
      "mistral" -> Ella.Llm.Adapters.OpenAI
      "opencode" -> Ella.Llm.Adapters.OpenAI
      "ollama" -> Ella.Llm.Adapters.OpenAI
      _ -> Ella.Llm.Adapters.OpenAI
    end
  end

  defp default_config_for(Ella.Llm.Adapters.OpenAI) do
    provider = System.get_env("LLM_PROVIDER") || "openai"

    case provider do
      "mistral" ->
        [
          base_url: "https://api.mistral.ai/v1",
          api_key: System.get_env("MISTRAL_API_KEY"),
          model: System.get_env("LLM_MODEL") || "codestral-latest"
        ]

      "opencode" ->
        [
          base_url: System.get_env("OPENCODE_BASE_URL") || "http://localhost:4096/v1",
          api_key: System.get_env("OPENCODE_API_KEY") || "free",
          model: System.get_env("LLM_MODEL") || "opencode-recommended"
        ]

      "ollama" ->
        [
          base_url: System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434/v1",
          api_key: "ollama",
          model: System.get_env("LLM_MODEL") || "gemma4:31b-cloud"
        ]

      _ ->
        [
          base_url: System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1",
          api_key: System.get_env("OPENAI_API_KEY"),
          model: System.get_env("LLM_MODEL") || "gpt-4o"
        ]
    end
  end

  defp default_config_for(Ella.Llm.Adapters.Poolside) do
    [
      base_url: System.get_env("POOLSIDE_BASE_URL") || "https://api.poolside.ai/v1",
      api_key: System.get_env("POOLSIDE_API_KEY"),
      model: System.get_env("LLM_MODEL") || "poolside-code"
    ]
  end
end
