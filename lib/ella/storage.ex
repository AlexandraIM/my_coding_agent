defmodule Ella.Storage do
  @doc """
  Module to rule the configuration in hiden folder .ella
  """
  # Визначення шляху до прихованої папки
  def base_dir do
    # У тестах можна перевизначити через :storage_dir, щоб не чіпати реальну ФС.
    case Application.get_env(:ella, :storage_dir) do
      nil ->
        local_dir = Path.join(File.cwd!(), ".ella")

        if File.dir?(local_dir) do
          local_dir
        else
          Path.join(System.user_home!(), ".ella")
        end

      dir when is_binary(dir) ->
        dir
    end
  end

  @doc "Ініціалізація папки та необхідних підпапок при старті"
  def ensure_storage_created! do
    dir = base_dir()
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "skills"))
    File.mkdir_p!(Path.join(dir, "sessions"))

    mcp_file = Path.join(dir, "mcp.json")

    unless File.exists?(mcp_file) do
      File.write!(mcp_file, Jason.encode!(%{"mcpServers" => %{}}, pretty: true))
    end

    dir
  end

  @doc "Зчитування конфігурації MCP"
  def load_mcp_config do
    ensure_storage_created!()
    mcp_file = Path.join(base_dir(), "mcp.json")

    with {:ok, content} <- File.read(mcp_file),
         {:ok, %{"mcpServers" => servers}} <- Jason.decode(content) do
      servers
    else
      _ -> %{}
    end
  end

  @doc "Збереження нового MCP-сервера"
  def save_mcp_server(name, command, args) do
    ensure_storage_created!()
    mcp_file = Path.join(base_dir(), "mcp.json")
    servers = load_mcp_config()

    updated_servers = Map.put(servers, name, %{"command" => command, "args" => args})
    new_config = %{"mcpServers" => updated_servers}

    File.write!(mcp_file, Jason.encode!(new_config, pretty: true))
  end

  # --- Session persistence ---

  @doc "Шлях до каталогу збережених сесій."
  def sessions_dir(dir \\ base_dir()) do
    Path.join(dir, "sessions")
  end

  @doc "Шлях до файлу конкретної сесії."
  def session_path(name, dir \\ base_dir()) do
    Path.join(sessions_dir(dir), "#{sanitize_name(name)}.json")
  end

  defp sanitize_name(name) do
    name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
  end

  @doc "Зберігає сесію (повідомлення, режим, облік) у JSON."
  def save_session(name, data, dir \\ base_dir()) do
    ensure_storage_created!()
    File.mkdir_p!(sessions_dir(dir))

    payload = %{
      "name" => to_string(name),
      "mode" => to_string(Map.get(data, :mode, "plan")),
      "messages" => Map.get(data, :messages, []),
      "usage" => usage_to_map(Map.get(data, :usage)),
      "saved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    path = session_path(name, dir)
    File.write!(path, Jason.encode!(payload, pretty: true))
    {:ok, path}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Зчитує збережену сесію."
  def load_session(name, dir \\ base_dir()) do
    path = session_path(name, dir)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"messages" => messages} = payload} when is_list(messages) ->
            {:ok,
             %{
               messages: messages,
               mode: parse_mode(Map.get(payload, "mode")),
               usage: map_to_usage(Map.get(payload, "usage")),
               saved_at: Map.get(payload, "saved_at")
             }}

          _ ->
            {:error, :invalid_session}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Список збережених сесій (імена)."
  def list_sessions(dir \\ base_dir()) do
    dir = sessions_dir(dir)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.trim_trailing(&1, ".json"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "Видаляє збережену сесію."
  def delete_session(name, dir \\ base_dir()) do
    path = session_path(name, dir)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Provider persistence ---

  def provider_path(dir \\ base_dir()) do
    Path.join(dir, "provider.json")
  end

  def save_provider(provider, config \\ %{}, dir \\ base_dir()) do
    ensure_storage_created!()

    payload = %{
      "provider" => to_string(provider),
      "config" => config || %{}
    }

    path = provider_path(dir)
    File.write!(path, Jason.encode!(payload, pretty: true))
    {:ok, path}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def load_provider(dir \\ base_dir()) do
    path = provider_path(dir)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"provider" => provider} = payload} when is_binary(provider) ->
            {:ok, %{provider: provider, config: Map.get(payload, "config", %{})}}

          _ ->
            {:error, :invalid_provider}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_mode("build"), do: :build
  defp parse_mode(_), do: :plan

  defp usage_to_map(nil), do: nil

  defp usage_to_map(%Ella.Llm.Usage{} = u) do
    %{
      "prompt_tokens" => u.prompt_tokens,
      "completion_tokens" => u.completion_tokens,
      "model" => u.model,
      "cost" => u.cost
    }
  end

  defp usage_to_map(other), do: other

  defp map_to_usage(nil), do: Ella.Llm.Usage.empty()

  defp map_to_usage(%{} = m) do
    %Ella.Llm.Usage{
      prompt_tokens: Map.get(m, "prompt_tokens"),
      completion_tokens: Map.get(m, "completion_tokens"),
      model: Map.get(m, "model"),
      cost: Map.get(m, "cost")
    }
  end

  defp map_to_usage(_), do: Ella.Llm.Usage.empty()
end
