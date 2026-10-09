defmodule Ella.Mcp.ToolAdapterTest do
  use ExUnit.Case, async: true

  alias Ella.Mcp.ToolAdapter

  defp wrap(tool) do
    ToolAdapter.to_agent_tool(self(), Map.put_new(tool, "name", "demo"))
  end

  describe "read_only?/1 — анотації MCP" do
    test "поважає annotations.readOnlyHint = true" do
      assert ToolAdapter.read_only?(%{
               "annotations" => %{"readOnlyHint" => true}
             })
    end

    test "поважає annotations.readOnlyHint = false" do
      refute ToolAdapter.read_only?(%{
               "annotations" => %{"readOnlyHint" => false}
             })
    end

    test "підтримує readOnlyHint без обгортки annotations" do
      assert ToolAdapter.read_only?(%{"readOnlyHint" => true})
    end

    test "анотація має пріоритет над евристикою за назвою" do
      refute ToolAdapter.read_only?(%{
               "name" => "search_docs",
               "annotations" => %{"readOnlyHint" => false}
             })
    end
  end

  describe "read_only?/1 — евристика за назвою" do
    test "вважає search/read/get/list/find/query/fetch безпечними" do
      for name <- [
            "search",
            "read_file",
            "get_weather",
            "list_dirs",
            "find_users",
            "query_db",
            "fetch_url"
          ] do
        assert ToolAdapter.read_only?(%{"name" => name}), "expected #{name} to be read-only"
      end
    end

    test "вважає write/delete/create безпечними" do
      for name <- ["write_file", "delete_repo", "create_issue", "update_doc", "send_email"] do
        refute ToolAdapter.read_only?(%{"name" => name}), "expected #{name} to be write-capable"
      end
    end

    test "невідомий інструмент без анотацій вважається таким, що пише" do
      refute ToolAdapter.read_only?(%{"name" => "do_something_unclear"})
    end

    test "відсутність імені вважається такою, що пише" do
      refute ToolAdapter.read_only?(%{})
    end
  end

  describe "to_agent_tool/2" do
    test "проставляє прапорець read_only у відповідності до анотації" do
      tool =
        wrap(%{
          "description" => "Searches docs",
          "inputSchema" => %{"type" => "object"},
          "annotations" => %{"readOnlyHint" => true}
        })

      assert tool.read_only == true
      assert tool.name == "mcp_demo"
      assert tool.raw_name == "demo"
      assert tool.type == :mcp
    end

    test "за замовчуванням read_only = false для інструментів без анотацій" do
      tool = wrap(%{"description" => "Writes stuff", "inputSchema" => %{"type" => "object"}})
      assert tool.read_only == false
    end

    test "підставляє опис, якщо сервер його не дав" do
      tool =
        wrap(%{
          "inputSchema" => %{"type" => "object"},
          "annotations" => %{"readOnlyHint" => true}
        })

      assert tool.description == "MCP Tool: demo"
    end
  end
end
