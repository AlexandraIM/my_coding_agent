defmodule Ella.Mcp.ToolAdapter do
  @doc """
  Wraps MCP Tool into a format that LlmClient can use.
  """

  def to_agent_tool(mcp_pid, %{
        "name" => name,
        "description" => description,
        "inputSchema" => schema
      }) do
    %{
      type: :mcp,
      mcp_pid: mcp_pid,
      raw_name: name,
      name: "mcp_" <> name,
      description: description || "MCP Tool: #{name}",
      parameters: schema
    }
  end

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
