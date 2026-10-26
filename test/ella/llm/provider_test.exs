defmodule Ella.Llm.ProviderTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.Provider

  describe "providers/0" do
    test "returns all available providers" do
      providers = Provider.providers()

      assert is_list(providers)
      assert length(providers) >= 5

      provider_names = Enum.map(providers, & &1.name)
      assert "openai" in provider_names
      assert "poolside" in provider_names
      assert "mistral" in provider_names
      assert "ollama" in provider_names
      assert "opencode" in provider_names
    end

    test "returns providers sorted by name" do
      providers = Provider.providers()
      names = Enum.map(providers, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "provider_info/1" do
    test "returns info for known providers" do
      openai = Provider.provider_info("openai")
      assert openai.name == "openai"
      assert openai.display_name == "OpenAI"
      assert openai.base_url == "https://api.openai.com/v1"
      assert openai.requires_api_key? == true
      assert openai.default_model == "gpt-4o"
      assert openai.adapter == Ella.Llm.Adapters.OpenAI
    end

    test "returns nil for unknown providers" do
      assert Provider.provider_info("unknown") == nil
    end

    test "is case-insensitive" do
      upper = Provider.provider_info("OPENAI")
      lower = Provider.provider_info("openai")

      assert upper.name == lower.name
      assert upper.display_name == lower.display_name
    end
  end

  describe "default_models/1" do
    test "returns models for known providers" do
      openai_models = Provider.default_models("openai")
      assert is_list(openai_models)
      assert length(openai_models) == 4

      model_ids = Enum.map(openai_models, & &1["id"])
      assert "gpt-4o" in model_ids
      assert "gpt-4o-mini" in model_ids
      assert "gpt-4-turbo" in model_ids
      assert "gpt-3.5-turbo" in model_ids
    end

    test "returns empty list for unknown providers" do
      assert Provider.default_models("unknown") == []
    end
  end

  describe "adapter_for/1" do
    test "returns correct adapter for openai" do
      assert Provider.adapter_for("openai") == Ella.Llm.Adapters.OpenAI
    end

    test "returns correct adapter for poolside" do
      assert Provider.adapter_for("poolside") == Ella.Llm.Adapters.Poolside
    end

    test "returns OpenAI adapter for unknown providers" do
      assert Provider.adapter_for("unknown") == Ella.Llm.Adapters.OpenAI
    end
  end

  describe "display_name/1" do
    test "returns display name for known providers" do
      assert Provider.display_name("openai") == "OpenAI"
      assert Provider.display_name("poolside") == "Poolside"
      assert Provider.display_name("mistral") == "Mistral"
      assert Provider.display_name("ollama") == "Ollama"
      assert Provider.display_name("opencode") == "OpenCode"
    end

    test "returns original name for unknown providers" do
      assert Provider.display_name("unknown") == "unknown"
    end
  end

  describe "default_model/1" do
    test "returns default model for known providers" do
      assert Provider.default_model("openai") == "gpt-4o"
      assert Provider.default_model("poolside") == "poolside-code"
      assert Provider.default_model("mistral") == "codestral-latest"
      assert Provider.default_model("ollama") == "gemma4:31b-cloud"
      assert Provider.default_model("opencode") == "opencode-recommended"
    end

    test "returns original name for unknown providers" do
      assert Provider.default_model("unknown") == "unknown"
    end
  end

  describe "requires_api_key?/1" do
    test "returns true for providers that need API keys" do
      assert Provider.requires_api_key?("openai") == true
      assert Provider.requires_api_key?("poolside") == true
      assert Provider.requires_api_key?("mistral") == true
    end

    test "returns false for providers that don't need API keys" do
      assert Provider.requires_api_key?("ollama") == false
      assert Provider.requires_api_key?("opencode") == false
    end
  end

  describe "base_url/1" do
    test "returns base URL for known providers" do
      assert Provider.base_url("openai") == "https://api.openai.com/v1"
      assert Provider.base_url("poolside") == "https://api.poolside.ai/v1"
      assert Provider.base_url("mistral") == "https://api.mistral.ai/v1"
      assert Provider.base_url("ollama") == "http://localhost:11434/v1"
      assert Provider.base_url("opencode") == "http://localhost:4096/v1"
    end

    test "returns default OpenAI URL for unknown providers" do
      assert Provider.base_url("unknown") == "https://api.openai.com/v1"
    end
  end

  describe "valid_model?/2" do
    test "returns true for valid models" do
      assert Provider.valid_model?("openai", "gpt-4o") == true
      assert Provider.valid_model?("openai", "gpt-4o-mini") == true
      assert Provider.valid_model?("poolside", "poolside-code") == true
      assert Provider.valid_model?("mistral", "codestral-latest") == true
    end

    test "returns false for invalid models" do
      assert Provider.valid_model?("openai", "unknown-model") == false
      assert Provider.valid_model?("openai", "gpt-5") == false
    end

    test "returns false for unknown providers" do
      assert Provider.valid_model?("unknown", "anything") == false
    end
  end

  describe "api_key_env/1" do
    test "returns correct env var names for known providers" do
      assert Provider.api_key_env("openai") == "OPENAI_API_KEY"
      assert Provider.api_key_env("poolside") == "POOLSIDE_API_KEY"
      assert Provider.api_key_env("mistral") == "MISTRAL_API_KEY"
      assert Provider.api_key_env("opencode") == "OPENCODE_API_KEY"
    end

    test "returns OPENAI_API_KEY for unknown providers" do
      assert Provider.api_key_env("unknown") == "OPENAI_API_KEY"
    end
  end

  describe "format_providers_list/0" do
    test "returns formatted string" do
      result = Provider.format_providers_list()

      assert is_binary(result)
      assert String.contains?(result, "openai")
      assert String.contains?(result, "poolside")
      assert String.contains?(result, "mistral")
      assert String.contains?(result, "ollama")
      assert String.contains?(result, "opencode")
    end
  end
end