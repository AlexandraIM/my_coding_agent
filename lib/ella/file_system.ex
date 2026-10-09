defmodule Ella.FileSystem do
  @moduledoc """
  Обхід дерева проєкту для інструментів пошуку.

  Надає єдине місце, де вирішується, що саме можна побачити: межа
  sandbox, приховані каталоги (`deps`, `_build`, `.git`) і правила
  `.gitignore`. Без цього `Grep` і `Glob` заганяли б у контекст моделі
  десятки тисяч рядків стороннього коду.
  """

  alias Ella.Sandbox

  # Те, що ніколи не цікавить агента: або згенеровано, або не наш код.
  @default_ignored ~w(
    .git _build deps cover doc node_modules
    .elixir_ls .ella .vscode .idea
  )

  @max_files 20_000
  @max_depth 24

  # Приховані файли всередині проєкту, які агента корисні,
  # на відміну від .git чи _build.
  @visible_dotfiles ~w(.formatter.exs .env.example .env.local .tool-versions)

  @doc "Каталоги, які завжди пропускаються при обході."
  def default_ignored, do: @default_ignored

  @doc """
  Повертає мауnd-map «абсолютний каталог -> true» з урахуванням
  `.gitignore` у корені проєкту.

  `.gitignore` розбирається спрощено: підтримуються коментарі й точні
  імена каталогів. Шаблони з `*` ігні��оруються — вимагати повної
  реалізації gitignore тут зайво, це лише оптимізація пошуку.
  """
  def ignored_dirs do
    gitignore_path = Path.join(Sandbox.root(), ".gitignore")

    from_gitignore =
      case File.read(gitignore_path) do
        {:ok, content} -> gitignore_patterns(content)
        {:error, _} -> []
      end

    (@default_ignored ++ from_gitignore)
    |> Enum.uniq()
    |> Map.new(&{Path.join(Sandbox.root(), &1), true})
  end

  @doc "Чи заборонено заходити в директорію."
  def ignored?(absolute_dir, ignored_map) do
    Map.has_key?(ignored_map, absolute_dir)
  end

  @doc """
  Рекурсивно збирає абсолютні шляхи до файлів під `absolute_dir`.

  Опції:
    * `:depth` — максимальна глибина відносно `absolute_dir`
    * `:include` — функція `abs_path -> boolean`
    * `:limit` — максимум файлів
    * `:ignored` — мауnd-map з `ignored_dirs/0`

  Повертає список абсолютних шляхів до файлів.
  """
  def walk_files(absolute_dir, opts \\ []) do
    depth = Keyword.get(opts, :depth, @max_depth)
    include = Keyword.get(opts, :include, fn _ -> true end)
    limit = Keyword.get(opts, :limit, @max_files)
    ignored_map = Keyword.get_lazy(opts, :ignored, &ignored_dirs/0)

    {files, _remaining} =
      collect(absolute_dir, depth, include, ignored_map, limit, [])

    Enum.reverse(files)
  end

  defp collect(_dir, depth, _include, _ignored, limit, acc) when depth < 0 or limit <= 0 do
    {acc, limit}
  end

  defp collect(dir, depth, include, ignored, limit, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        {acc, left} =
          Enum.reduce(entries, {acc, limit}, fn entry, {inner_acc, remaining} ->
            if remaining <= 0 do
              {inner_acc, remaining}
            else
              absolute = Path.join(dir, entry)

              cond do
                String.starts_with?(entry, ".") and entry not in @visible_dotfiles ->
                  {inner_acc, remaining}

                File.dir?(absolute) and not Sandbox.symlink?(absolute) ->
                  if ignored?(absolute, ignored) do
                    {inner_acc, remaining}
                  else
                    collect(absolute, depth - 1, include, ignored, remaining, inner_acc)
                  end

                include.(absolute) ->
                  {[absolute | inner_acc], remaining - 1}

                true ->
                  {inner_acc, remaining}
              end
            end
          end)

        {acc, left}

      {:error, _} ->
        {acc, limit}
    end
  end

  defp gitignore_patterns(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line ->
      line == "" or String.starts_with?(line, "#") or String.starts_with?(line, "!")
    end)
    |> Enum.map(fn line ->
      line
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> String.trim_trailing("/")
      |> String.trim_leading("/")
    end)
    |> Enum.reject(&(&1 == "" or String.contains?(&1, "*")))
  end
end
