defmodule Ella.Storage do
  @doc """
  Module to rule the configuration in hiden folder .ella
  """
  # Визначення шляху до прихованої папки
  def base_dir do
    # Пріоритет: локальна папка .ella у проєкті, якщо існує, інакше глобальна у ~/.ella
    local_dir = Path.join(File.cwd!(), ".ella")

    if File.dir?(local_dir) do
      local_dir
    else
      Path.join(System.user_home!(), ".ella")
    end
  end

  @doc "Ініціалізація папки та необхідних підпапок при старті"
  def ensure_storage_created! do
    dir = base_dir()
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "skills"))

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

  @doc "Завантаження всіх скілів із папки skills/"
  def load_skills do
    ensure_storage_created!()
    skills_dir = Path.join(base_dir(), "skills")

    skills_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(fn file ->
      path = Path.join(skills_dir, file)
      {:ok, content} = File.read(path)
      Jason.decode!(content)
    end)
  end
end
