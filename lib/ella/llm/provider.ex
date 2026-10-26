defmodule Ella.Llm.Provider do
  @moduledoc """
  Module for working with LLM providers and their models.

  Provides metadata about available providers, their models, and configuration.
  """

  # Provider definitions with their metadata
  @providers %{
    "openai" => %{
      name: "openai",
      display_name: "OpenAI",
      base_url: "https://api.openai.com/v1",
      requires_api_key?: true,
      default_model: "gpt-4o",
      adapter: Ella.Llm.Adapters.OpenAI,
      models: [
        %{"id" => "gpt-4o", "description" => "GPT-4o — flagship model, realtime vision"},
        %{"id" => "gpt-4o-mini", "description" => "GPT-4o Mini — fast and efficient"},
        %{"id" => "gpt-4-turbo", "description" => "GPT-4 Turbo — powerful reasoning"},
        %{"id" => "gpt-3.5-turbo", "description" => "GPT-3.5 Turbo — legacy, fast"}
      ]
    },
    "poolside" => %{
      name: "poolside",
      display_name: "Poolside",
      base_url: "https://api.poolside.ai/v1",
      requires_api_key?: true,
      default_model: "poolside-code",
      adapter: Ella.Llm.Adapters.Poolside,
      models: [
        %{"id" => "poolside-code", "description" => "Poolside Code — coding assistant"},
        %{"id" => "poolside-chat", "description" => "Poolside Chat — general conversation"}
      ]
    },
    "mistral" => %{
      name: "mistral",
      display_name: "Mistral",
      base_url: "https://api.mistral.ai/v1",
      requires_api_key?: true,
      default_model: "codestral-latest",
      adapter: Ella.Llm.Adapters.OpenAI,
      models: [
        %{"id" => "codestral-latest", "description" => "Codestral — code-oriented"},
        %{"id" => "mistral-large-latest", "description" => "Mistral Large — flagship"},
        %{"id" => "mistral-medium-latest", "description" => "Mistral Medium — balanced"},
        %{"id" => "mistral-small-latest", "description" => "Mistral Small — fast"}
      ]
    },
    "ollama" => %{
      name: "ollama",
      display_name: "Ollama",
      base_url: "http://localhost:11434/v1",
      requires_api_key?: false,
      default_model: "gemma4:31b-cloud",
      adapter: Ella.Llm.Adapters.OpenAI,
      models: [
        %{"id" => "gemma4:31b-cloud", "description" => "Gemma 4 31B"},
        %{"id" => "llama3.1:8b", "description" => "Llama 3.1 8B"},
        %{"id" => "llama3.1:70b", "description" => "Llama 3.1 70B"},
        %{"id" => "codellama:13b", "description" => "Code Llama 13B"}
      ]
    },
    "opencode" => %{
      name: "opencode",
      display_name: "OpenCode",
      base_url: "http://localhost:4096/v1",
      requires_api_key?: false,
      default_model: "opencode-recommended",
      adapter: Ella.Llm.Adapters.OpenAI,
      models: [
        %{"id" => "opencode-recommended", "description" => "OpenCode recommended model"}
      ]
    }
  }

  @doc """
  Returns the list of all available providers.

  Each provider is returned as a map with:
  - `name`: the provider identifier
  - `display_name`: human-readable name
  - `base_url`: the API endpoint
  - `requires_api_key?`: boolean indicating if an API key is needed
  - `default_model`: the default model for this provider
  - `models`: list of available models with their descriptions
  """
  @spec providers() :: [map()]
  def providers do
    @providers
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Returns the default models known for a provider.
  These are static definitions; actual available models may vary based on the provider's API.

  ## Examples

      iex> Ella.Llm.Provider.default_models("openai")
      [%{"id" => "gpt-4o", "description" => "GPT-4o — flagship model, realtime vision"}, ...]

      iex> Ella.Llm.Provider.default_models("unknown")
      []
  """
  @spec default_models(String.t()) :: [map()]
  def default_models(provider) when is_binary(provider) do
    provider
    |> String.downcase()
    |> then(&Map.get(@providers, &1, %{}))
    |> Map.get(:models, [])
  end

  @doc """
  Gets detailed information about a specific provider.

  Returns a map with provider metadata, or `nil` if the provider is unknown.
  """
  @spec provider_info(String.t()) :: map() | nil
  def provider_info(provider) when is_binary(provider) do
    @providers
    |> Map.get(String.downcase(provider))
  end

  @doc """
  Returns the adapter module for the given provider.

  ## Examples

      iex> Ella.Llm.Provider.adapter_for("openai")
      Ella.Llm.Adapters.OpenAI

      iex> Ella.Llm.Provider.adapter_for("poolside")
      Ella.Llm.Adapters.Poolside
  """
  @spec adapter_for(String.t()) :: module()
  def adapter_for(provider) when is_binary(provider) do
    provider_key = String.downcase(provider)

    @providers
    |> Map.get(provider_key, %{})
    |> Map.get(:adapter, Ella.Llm.Adapters.OpenAI)
  end

  @doc """
  Returns the display name for a provider (e.g., "OpenAI" instead of "openai").

  ## Examples

      iex> Ella.Llm.Provider.display_name("openai")
      "OpenAI"

      iex> Ella.Llm.Provider.display_name("unknown")
      "unknown"
  """
  @spec display_name(String.t()) :: String.t()
  def display_name(provider) when is_binary(provider) do
    @providers
    |> Map.get(String.downcase(provider), %{name: provider})
    |> Map.get(:display_name, provider)
  end

  @doc """
  Returns the default model for a provider.

  ## Examples

      iex> Ella.Llm.Provider.default_model("openai")
      "gpt-4o"

      iex> Ella.Llm.Provider.default_model("unknown")
      "unknown"
  """
  @spec default_model(String.t()) :: String.t()
  def default_model(provider) when is_binary(provider) do
    @providers
    |> Map.get(String.downcase(provider), %{})
    |> Map.get(:default_model, provider)
  end

  @doc """
  Checks if a provider requires an API key.

  ## Examples

      iex> Ella.Llm.Provider.requires_api_key?("openai")
      true

      iex> Ella.Llm.Provider.requires_api_key?("ollama")
      false
  """
  @spec requires_api_key?(String.t()) :: boolean()
  def requires_api_key?(provider) when is_binary(provider) do
    @providers
    |> Map.get(String.downcase(provider), %{})
    |> Map.get(:requires_api_key?, true)
  end

  @doc """
  Returns the base URL for a provider.

  ## Examples

      iex> Ella.Llm.Provider.base_url("openai")
      "https://api.openai.com/v1"

      iex> Ella.Llm.Provider.base_url("ollama")
      "http://localhost:11434/v1"
  """
  @spec base_url(String.t()) :: String.t()
  def base_url(provider) when is_binary(provider) do
    @providers
    |> Map.get(String.downcase(provider), %{})
    |> Map.get(:base_url, "https://api.openai.com/v1")
  end

  @doc """
  Checks if a given model ID is valid for the provider.

  ## Examples

      iex> Ella.Llm.Provider.valid_model?("openai", "gpt-4o")
      true

      iex> Ella.Llm.Provider.valid_model?("openai", "unknown-model")
      false
  """
  @spec valid_model?(String.t(), String.t()) :: boolean()
  def valid_model?(provider, model) when is_binary(provider) and is_binary(model) do
    model_id = String.downcase(model)

    @providers
    |> Map.get(String.downcase(provider), %{})
    |> Map.get(:models, [])
    |> Enum.any?(fn m -> Map.get(m, "id") == model_id end)
  end

  @doc """
  Returns the environment variable name for the API key of a provider.

  ## Examples

      iex> Ella.Llm.Provider.api_key_env("openai")
      "OPENAI_API_KEY"

      iex> Ella.Llm.Provider.api_key_env("poolside")
      "POOLSIDE_API_KEY"
  """
  @spec api_key_env(String.t()) :: String.t()
  def api_key_env(provider) when is_binary(provider) do
    case String.downcase(provider) do
      "openai" -> "OPENAI_API_KEY"
      "poolside" -> "POOLSIDE_API_KEY"
      "mistral" -> "MISTRAL_API_KEY"
      "opencode" -> "OPENCODE_API_KEY"
      "ollama" -> "OLLAMA_API_KEY"
      _ -> "OPENAI_API_KEY"
    end
  end

  @doc """
  Returns a formatted string showing all providers with their default models.
  Useful for CLI output.
  """
  @spec format_providers_list() :: String.t()
  def format_providers_list do
    providers()
    |> Enum.map(fn p ->
      model = p.default_model
      # All default models should be valid by definition
      marker = if Enum.any?(p.models, &(&1["id"] == model)), do: "✓", else: " "

      "  #{p.name} (#{p.display_name}) - default: #{model} #{marker}"
    end)
    |> Enum.join("\n")
  end
end