defmodule Ella.Config do
  @moduledoc """
  Конфігурація проєкту: `.ella/config.json`.

  Захищені шляхи — властивість конкретного репозиторію, а не агента.
  Ella працює з довільними мовами, тому список визначає проєкт, а не
  код агента.

      {
        "protected_paths": ["mix.exs", "mix.lock", ".github/"],
        "require_approval": true
      }

  Файл опціональний: без нього захист не ввімкнено.
  """

  alias Ella.Sandbox

  @filename ".ella/config.json"

  # Зразок для проєкту: показати користувачу, як увімкнути, але
  # нічого не захищати без явного рішення.
  @default %{
    "protected_paths" => [],
    "require_approval" => true
  }

  @doc """
  Чи читаємо конфіг зараз (у тестах — вимикається).
  """
  def enabled?, do: Application.get_env(:ella, :load_project_config, true)

  @doc """
  Повертає розпізнаний конфіг, накладаючи його на дефолти.
  """
  @spec load() :: map()
  def load do
    if enabled?() do
      path = Path.join(Sandbox.root(), @filename)

      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} when is_map(decoded) -> merge(decoded)
            _ -> @default
          end

        {:error, _} ->
          @default
      end
    else
      @default
    end
  end

  @doc """
  Список захищених шляхів або префіксів директорій.
  """
  def protected_paths(config \\ load()) do
    config
    |> Map.get("protected_paths", [])
    |> List.wrap()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Чи питати дозволу перед зміною захищеного файлу.

  Якщо `require_approval` вимкнено, запит не показується — зміна
  проходить, але в консолю пишеться попередження.
  """
  def require_approval?(config \\ load()) do
    Map.get(config, "require_approval", true) != false
  end

  @doc """
  Чи захищений шлях.

  Елемент списку захищає і сам файл, і все всередині, якщо це
  директорія (закінчується на `/` або збігається як префікс).
  """
  @spec protected?(String.t(), map()) :: boolean()
  def protected?(path, config \\ load()) when is_binary(path) do
    normalized = normalize(path)

    Enum.any?(protected_paths(config), fn rule ->
      rule = normalize(rule)

      normalized == rule or String.starts_with?(normalized, rule <> "/")
    end)
  end

  # ".github/" і ".github" мають означати те саме, "./mix.exs" — те саме,
  # що "mix.exs".
  defp normalize(path) do
    path
    |> String.trim()
    |> String.trim_trailing("/")
    |> Path.expand(".")
    |> Path.relative_to_cwd()
    |> String.trim_leading("./")
  end

  defp merge(parsed) do
    Map.merge(@default, parsed, fn _key, default, given ->
      if is_nil(given), do: default, else: given
    end)
  end
end
