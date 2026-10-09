defmodule Ella.Mcp.ToolAdapter do
  @doc """
  Wraps MCP Tool into a format that LlmClient can use.
  """

  # description та inputSchema необов'язкові у MCP-специфікації,
  # тому звертаємося через Map.fetch з fallback.
  def to_agent_tool(mcp_pid, %{"name" => name} = tool) do
    %{
      type: :mcp,
      mcp_pid: mcp_pid,
      raw_name: name,
      name: "mcp_" <> name,
      description: Map.get(tool, "description") || "MCP Tool: #{name}",
      parameters: Map.get(tool, "inputSchema") || %{"type" => "object"},
      read_only: read_only?(tool)
    }
  end

  @doc """
  Визначає, чи інструмент здатний лише читати дані.

  MCP-сервер може оголосити підказку через `annotations.readOnlyHint`
  (специфікація 2025). Коли сервер її не надає, вважаємо інструмент
  таким, що може змінювати стан: безпечніше заборонити його в plan mode,
  ніж дозволити потенційну запис.
  """
  def read_only?(%{"annotations" => %{"readOnlyHint" => hint}}) when is_boolean(hint) do
    hint
  end

  def read_only?(%{"readOnlyHint" => hint}) when is_boolean(hint) do
    hint
  end

  # Назва як евристика для серверів без анотацій.
  def read_only?(%{"name" => name}) when is_binary(name) do
    name
    |> String.downcase()
    |> String.starts_with?(~w(read get search list find query fetch))
  end

  def read_only?(_), do: false

  def execute(mcp_pid, raw_name, args) do
    case Ella.Mcp.Client.call_tool(mcp_pid, raw_name, args) do
      {:ok, %{"content" => content_list}} ->
        text = Enum.map_join(content_list, "\n", fn item -> item["text"] || "" end)
        {:ok, text}

      {:error, err} ->
        {:error, "MCP call failed: #{inspect(err)}"}
    end
  end
end
