defmodule Ella.ProjectRules do
  @doc """
  Шукає локальні файли інструкцій у корені проєкту та повертає їхній вміст.
  """

  # Список файлів у порядку пріоритету
  @rule_files ["AGENTS.md", "AGENT.md", ".cursorrules", ".agentrules", "CLAUDE.md"]

  @ignored_dirs [".git", "_build", "deps", "node_modules", ".elixir_ls", ".poolside"]

  def project_tree(root_dir \\ File.cwd!(), depth \\ 2) do
    lines = build_tree(root_dir, "", depth, 0)
    "PROJECT TREE (top #{depth} levels):\n" <> Enum.join(lines, "\n")
  end

  defp build_tree(_root, _prefix, depth, level) when level >= depth, do: []

  defp build_tree(root, prefix, depth, level) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(String.starts_with?(&1, ".") and &1 not in [".ella"]))
        |> Enum.reject(&(&1 in @ignored_dirs))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          path = Path.join(root, name)
          indent = String.duplicate("  ", level)

          if File.dir?(path) do
            [indent <> name <> "/"] ++ build_tree(path, prefix, depth, level + 1)
          else
            [indent <> name]
          end
        end)

      {:error, _} ->
        []
    end
  end

  def load_rules(root_dir \\ File.cwd!()) do
    @rule_files
    |> Enum.map(&Path.join(root_dir, &1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        ""

      file_path ->
        filename = Path.basename(file_path)
        Owl.IO.puts(Owl.Data.tag("Loaded project rules from #{filename}", :magenta))

        case File.read(file_path) do
          {:ok, content} ->
            """

            PROJECT SPECIFIC INSTRUCTIONS & RULES (from #{filename}):
            ---
            #{content}
            ---
            """

          {:error, _} ->
            ""
        end
    end
  end
end
