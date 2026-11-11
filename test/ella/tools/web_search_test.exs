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

  test "execute/1 parses search results from 200 response" do
    html = """
    <div class="result">
      <a class="result__a" href="https://elixir-lang.org">Elixir Language</a>
      <a class="result__snippet">Dynamic, functional language for building scalable applications.</a>
    </div>
    """

    response =
      "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: #{byte_size(html)}\r\n\r\n" <>
        html

    {port, listener} = raw_server(response)
    on_exit(fn -> :gen_tcp.close(listener) end)

    Application.put_env(:ella, :web_search_url, "http://127.0.0.1:#{port}/")
    on_exit(fn -> Application.delete_env(:ella, :web_search_url) end)

    assert {:ok, result} = WebSearch.execute(%{"query" => "elixir"})
    assert result =~ "Elixir Language"
    assert result =~ "https://elixir-lang.org"
  end

  test "execute/1 handles malformed HTML without crashing" do
    html = """
    <div class="result">
      <span>Malformed result with no anchor or snippet</span>
    </div>
    """

    response =
      "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: #{byte_size(html)}\r\n\r\n" <>
        html

    {port, listener} = raw_server(response)
    on_exit(fn -> :gen_tcp.close(listener) end)

    Application.put_env(:ella, :web_search_url, "http://127.0.0.1:#{port}/")
    on_exit(fn -> Application.delete_env(:ella, :web_search_url) end)

    assert {:ok, result} = WebSearch.execute(%{"query" => "elixir"})
    assert result =~ "No web results found"
  end

  defp raw_server(response) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)

        _ ->
          :ok
      end
    end)

    {port, listener}
  end
end
