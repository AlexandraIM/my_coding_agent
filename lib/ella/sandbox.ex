defmodule Ella.Sandbox do
  @moduledoc """
  Межа файлової системи для інструментів агента.

  Модель передає шляхи як рядки, тому без перевірки вона може звернутися
  до `~/.ssh/id_rsa`, `/etc/passwd` або будь-якого файлу поза проєктом.
  Кожен інструмент, що торкається файлової системи, зобов'язаний
  пропускати свій шлях через `resolve/1`.
  """

  @doc """
  Root, відносно якого дозволено доступ. За замовчуванням — поточний
  робочий каталог. Може бути перевизначено для тестів.
  """
  def root do
    key = {__MODULE__, :root, Application.get_env(:ella, :sandbox_root)}

    case :persistent_term.get(key, nil) do
      nil ->
        configured = Application.get_env(:ella, :sandbox_root, File.cwd!())
        resolved = resolve_links(Path.expand(configured), 0)
        :persistent_term.put(key, resolved)
        resolved

      cached ->
        cached
    end
  end

  @doc """
  Чи є шлях допустимим для читання/запису.

  Повертає {:ok, absolute_path} або {:error, reason}.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(path) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, "Path is empty."}

      String.contains?(path, "\0") ->
        {:error, "Path contains a null byte."}

      Path.type(path) == :absolute ->
        {:error,
         "Absolute paths are not allowed: #{path}. Use a path relative to the project root " <>
           "(#{root()})."}

      true ->
        validate_traversal(path)
    end
  end

  def resolve(path) do
    {:error, "Path must be a string, got: #{inspect(path)}"}
  end

  @doc """
  Те саме, але зруйнує процес, якщо шлях недопустимий.

  Не використовуйте у коді, який має повертати помилку моделі.
  """
  @spec resolve!(String.t()) :: String.t()
  def resolve!(path) do
    case resolve(path) do
      {:ok, absolute} ->
        absolute

      {:error, reason} ->
        raise ArgumentError, "Ella.Sandbox rejected path: #{reason}"
    end
  end

  @doc """
  Чи залежить шлях (вже розрішений у абсолютний) від root.
  """
  def within_root?(absolute_path) do
    root = Path.expand(root())
    candidate = Path.expand(absolute_path)

    candidate == root or String.starts_with?(candidate, root <> "/")
  end

  @doc """
  Перетворює абсолютний шлях на відносний від root.

  Повертає {:ok, relative} або {:error, reason}, якщо шлях поза межами.
  """
  @spec relativize(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def relativize(absolute_path) do
    expanded = Path.expand(absolute_path)
    root = Path.expand(root())

    cond do
      expanded == root ->
        {:ok, "."}

      is_binary(root) and String.starts_with?(expanded, <<root::binary, "/">>) ->
        {:ok,
         binary_part(expanded, byte_size(root) + 1, byte_size(expanded) - byte_size(root) - 1)}

      true ->
        {:error, "Path is outside the project root: #{absolute_path}"}
    end
  end

  @doc """
  Чи існує шлях (вже перевірений через `resolve/1`).

  `File.exists?/1` повертає false для битих символічних лінків,
  тому перевіряємо й їх.
  """
  def exists?(absolute_path) do
    File.exists?(absolute_path) or symlink?(absolute_path)
  end

  @doc """
  Чи є шлях символічним лінком (-broken лінки теж).
  """
  def symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  @doc """
  Перевіряє шлях і одночасно читає файл.

  Корисно для інструментів читання: не дає TOCTOU-проміжку між
  перевіркою та відкриттям файлу.
  """
  @spec read(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def read(path) do
    with {:ok, absolute} <- resolve(path) do
      case File.read(absolute) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Перевіряє шлях і записує файл, створюючи проміжні директорії.
  """
  @spec write(String.t(), String.t()) :: :ok | {:error, String.t()}
  def write(path, content) do
    with {:ok, absolute} <- resolve(path) do
      case File.mkdir_p(Path.dirname(absolute)) do
        :ok -> File.write(absolute, content)
        {:error, reason} -> {:error, "Failed to create directory for #{path}: #{inspect(reason)}"}
      end
    end
  end

  # Reject ".." сегменти до будь-якого нормалізування: надійніше, ніж
  # покладатися лише на Path.expand, і дає зрозумілу помилку для моделі.
  defp validate_traversal(path) do
    segments = Path.split(path)

    if Enum.any?(segments, &(&1 == "..")) do
      {:error,
       "Path traversal via '..' is not allowed: #{path}. " <>
         "Paths must stay inside the project root (#{root()})."}
    else
      absolute = Path.expand(Path.join(root(), path))

      if within_root?(absolute) do
        check_symlinks(absolute, path)
      else
        {:error, "Path escapes the project root: #{path}"}
      end
    end
  end

  # Символічні лінки всередині проєкту можуть вести за його межі
  # (`lib/foo.ex -> ../../etc/passwd`). Розгортаємо їх і перевіряємо
  # кінцевий шлях.
  defp check_symlinks(absolute, original) do
    real = resolve_links(absolute, 0)

    if within_root?(real) do
      {:ok, absolute}
    else
      {:error, "Path resolves via symlink outside the project root: #{original}"}
    end
  end

  # Розгортає лінки по ланцюжку компонентів шляху. Захищений від циклів
  # і від виходу за межі ланцюжка (зупиняємось на корені ФС).
  defp resolve_links(path, depth) when depth > 32 do
    path
  end

  defp resolve_links("/", _depth), do: "/"

  defp resolve_links(path, depth) do
    expanded = Path.expand(path)
    parent = Path.dirname(expanded)
    base = Path.basename(expanded)

    resolved_parent = resolve_links(parent, depth + 1)
    joined = Path.join(resolved_parent, base)

    case File.read_link(expanded) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute do
            target
          else
            Path.join(Path.dirname(expanded), target)
          end

        resolve_links(Path.expand(target), depth + 1)

      {:error, _} ->
        joined
    end
  end
end
