defmodule Ella.WebSearchTest do
  use ExUnit.Case, async: true

  alias Ella.Tools.WebSearch

  test "name/0 returns web_search" do
    assert WebSearch.name() == "web_search"
  end

  test "description/0 is non-empty" do
    assert is_binary(WebSearch.description())
    assert String.length(WebSearch.description()) > 0
  end

  test "parameters/0 schema" do
    params = WebSearch.parameters()

    assert params["type"] == "object"
    assert "query" in Map.keys(params["properties"])
    assert "limit" in Map.keys(params["properties"])
    assert params["required"] == ["query"]

    query_prop = params["properties"]["query"]
    assert query_prop["type"] == "string"

    limit_prop = params["properties"]["limit"]
    assert limit_prop["type"] == "integer"
    assert limit_prop["minimum"] == 1
    assert limit_prop["maximum"] == 10
  end

  test "execute/1 with invalid args returns error" do
    assert {:error, _} = WebSearch.execute(%{})
    assert {:error, _} = WebSearch.execute(%{"query" => 123})
  end
end
