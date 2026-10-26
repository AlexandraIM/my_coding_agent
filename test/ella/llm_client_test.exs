defmodule Ella.LlmClientTest do
  use ExUnit.Case, async: true

  alias Ella.Llm.{Error, Usage}
  alias Ella.LlmClient

  defmodule FlakyAdapter do
    @behaviour Ella.Llm.Adapter

    # Послідовність результатів живе в process dictionary тестового
    # процесу: config передається за значенням і не накопичує стан.
    def chat_completion(_messages, _tools, _config) do
      agent = Process.get(:ella_test_pid)

      results = Process.get({__MODULE__, :results}, [])
      index = Process.get({__MODULE__, :index}, 0)

      result =
        case Enum.at(results, index) do
          # Не передбачено наступного результату — це сам LlmClient
          # вирішує, чи повторювати, тож повертаємо тимчасову помилку.
          nil -> {:error, Error.transient("sequence exhausted")}
          value -> value
        end

      Process.put({__MODULE__, :index}, index + 1)
      send(agent, {:attempt, index})

      result
    end

    def setup(results) do
      Process.put({__MODULE__, :results}, results)
      Process.put({__MODULE__, :index}, 0)
      Process.put(:ella_test_pid, self())
    end
  end

  defp no_sleep(_ms), do: :ok

  defp run(_adapter, results, opts \\ []) do
    FlakyAdapter.setup(results)

    LlmClient.chat_completion([], [],
      adapter: FlakyAdapter,
      config: [],
      max_attempts: Keyword.get(opts, :max_attempts, 4),
      sleep_fn: &no_sleep/1,
      retry_delay_fn: fn _ -> 1 end,
      on_retry: fn _, _, _ -> :ok end
    )
  end

  describe "успішна відповідь" do
    test "повертає повідомлення та usage" do
      usage = %Usage{prompt_tokens: 10, completion_tokens: 5, model: "gpt-4o"}

      assert {:ok, %{"content" => "hi"}, ^usage} =
               run(FlakyAdapter, [{:ok, %{"content" => "hi"}, usage}])
    end

    test "оцінює usage, коли адаптер його не повернув" do
      assert {:ok, _message, usage} = run(FlakyAdapter, [{:ok, %{"content" => "hi"}}])
      assert is_integer(usage.prompt_tokens)
    end
  end

  describe "повтори при тимчасових помилках" do
    test "повторює 429 і врешті повертає успіх" do
      results = [
        {:error, Error.transient("Rate limited (429)")},
        {:error, Error.transient("Rate limited (429)")},
        {:ok, %{"content" => "finally"}, nil}
      ]

      assert {:ok, %{"content" => "finally"}, _usage} = run(FlakyAdapter, results)
      assert_received {:attempt, 2}
      assert_received {:attempt, 1}
    end

    test "повторює 503" do
      results = [
        {:error, Error.transient("Server error 503")},
        {:ok, %{"content" => "ok"}, nil}
      ]

      assert {:ok, _, _} = run(FlakyAdapter, results)
    end

    test "не повторює помилку авторизації" do
      results = [{:error, Error.permanent("API error 401", status: 401)}]

      assert {:error, %Error{retryable?: false}} = run(FlakyAdapter, results)

      # Рівно один виклик адаптера — повтору не було.
      assert_received {:attempt, 0}
      refute_received {:attempt, _}
    end

    test "зупиняється після max_attempts" do
      results =
        for _ <- 1..10, do: {:error, Error.transient("429")}

      assert {:error, error} = run(FlakyAdapter, results, max_attempts: 3)
      assert Error.retryable?(error)
      # max_attempts спроб: початкова + 2 повтори
      assert_received {:attempt, 2}
    end

    test "використовує retry_after_ms замість власного backoff" do
      results = [
        {:error, Error.transient("429", retry_after_ms: 5_000)},
        {:ok, %{"content" => "ok"}, nil}
      ]

      FlakyAdapter.setup(results)

      LlmClient.chat_completion([], [],
        adapter: FlakyAdapter,
        config: [],
        sleep_fn: fn ms -> send(self(), {:slept, ms}) end,
        retry_delay_fn: fn _ -> 1 end,
        on_retry: fn _, _, _ -> :ok end
      )

      assert_received {:slept, 5_000}
    end

    test "нормалізує помилки-рядки" do
      assert {:error, %Error{retryable?: true}} =
               run(FlakyAdapter, [{:error, "Network error: timeout"}])
    end
  end

  describe "сумісність з адаптерами без streaming" do
    defmodule LegacyAdapter do
      @behaviour Ella.Llm.Adapter

      @impl true
      def chat_completion(_messages, _tools, config) do
        agent = Process.get(:ella_test_pid)
        send(agent, {:legacy_called, true})
        Keyword.fetch!(config, :result)
      end
    end

    test "використовує звичайний виклик, якщо chat_completion_stream/4 відсутня" do
      Process.put(:ella_test_pid, self())
      message = %{"content" => "legacy response"}

      assert {:ok, ^message, _usage} =
               LlmClient.chat_completion([], [],
                 adapter: LegacyAdapter,
                 config: [result: {:ok, message, nil}],
                 sleep_fn: &no_sleep/1
               )

      assert_received {:legacy_called, true}
    end

    test "кастомний адаптер отримує конфіг без падіння" do
      Process.put(:ella_test_pid, self())

      assert {:error, %Error{}} =
               LlmClient.chat_completion([], [],
                 adapter: LegacyAdapter,
                 config: [result: {:error, "boom"}],
                 sleep_fn: &no_sleep/1
               )
    end
  end

  describe "backoff" do
    test "зростає експоненційно" do
      first = LlmClient.backoff(1)
      third = LlmClient.backoff(3)

      assert third > first
      assert first >= 500
    end

    test "не перевищує максимум" do
      assert LlmClient.backoff(50) <= 30_000
    end
  end

  describe "адаптери та провайдери" do
    test "adapter_for/1 повертає правильний адаптер для openai" do
      assert LlmClient.adapter_for("openai") == Ella.Llm.Adapters.OpenAI
    end

    test "adapter_for/1 повертає правильний адаптер для poolside" do
      assert LlmClient.adapter_for("poolside") == Ella.Llm.Adapters.Poolside
    end

    test "available_models/1 повертає моделі для відомих провайдерів" do
      openai_models = LlmClient.available_models("openai")
      assert is_list(openai_models)
      assert length(openai_models) >= 4

      model_ids = Enum.map(openai_models, & &1["id"])
      assert "gpt-4o" in model_ids
    end

    test "available_models/1 повертає порожній список для невідомих провайдерів" do
      assert LlmClient.available_models("unknown") == []
    end

    test "config_for/1 повертає базову конфігурацію для openai" do
      config = LlmClient.config_for("openai")
      assert Keyword.has_key?(config, :base_url)
      assert Keyword.has_key?(config, :api_key)
      assert Keyword.has_key?(config, :model)
    end

    test "config_for/1 використовує LLM_MODEL з середовища" do
      original = System.get_env("LLM_MODEL")
      System.put_env("LLM_MODEL", "gpt-4o-mini")

      config = LlmClient.config_for("openai")
      assert Keyword.get(config, :model) == "gpt-4o-mini"

      if original do
        System.put_env("LLM_MODEL", original)
      else
        System.delete_env("LLM_MODEL")
      end
    end

    test "provider_opts/1 повертає комплектні опції" do
      opts = LlmClient.provider_opts("openai")
      assert Keyword.has_key?(opts, :adapter)
      assert Keyword.has_key?(opts, :config)
      assert Keyword.has_key?(opts, :max_attempts)
    end
  end
end
