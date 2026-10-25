defmodule Ella.Tools.WebSearch do
  @moduledoc """
  Web search tool for browsing the internet.

  Default provider: DuckDuckGo HTML (free, no API key required).

  TODO: Add Brave Search / Serper.dev / Tavily support as optional providers
  behind WEB_SEARCH_PROVIDER env var and API key config.
  """

  @behaviour Ella.Tool

  @default_limit 5
  @max_limit 10
  @duckduckgo_url "https://html.duckduckgo.com/html/"

  def name, do: "web_search"

  def description do
    "Searches the web for information and returns a list of results with " <>
      "titles, URLs, and snippets. Uses DuckDuckGo by default (free, no API key)."
  end

  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Search query (e.g., 'Elixir OTP GenServer best practices')"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of results (default 5, max 10)",
          "minimum" => 1,
          "maximum" => 10
        }
      },
      "required" => ["query"]
    }
  end

  def execute(%{"query" => query}) when is_binary(query) do
    limit = normalize_limit(nil)
    do_search(query, limit)
  end

  def execute(%{"query" => query, "limit" => limit}) when is_binary(query) do
    do_search(query, limit)
  end

  def execute(args) do
    {:error, "Invalid arguments passed to web_search: #{inspect(args)}"}
  end

  # --- Search ---

  defp do_search(query, limit) do
    limit = normalize_limit(limit)

    case search_duckduckgo(query, limit) do
      {:ok, results} ->
        {:ok, format_results(results, query)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_duckduckgo(query, limit) do
    url = @duckduckgo_url <> "?q=" <> url_encode(query)

    case Req.get(url, timeout: 15_000) do
      %Req.Response{status: 200, body: body} ->
        {:ok, parse_duckduckgo(body, limit)}

      %Req.Response{status: status} ->
        {:error, "Web search returned status #{status}"}

      {:error, reason} ->
        {:error, "Web search request failed: #{inspect(reason)}"}
    end
  rescue
    e ->
      {:error, "Web search error: #{Exception.message(e)}"}
  end

  # --- Parsing (DuckDuckGo HTML) ---

  # DuckDuckGo HTML wraps each result in <div class="result">...</div>.
  # We parse with lightweight string splitting to avoid adding an HTML
  # parser dependency. If the markup changes, results may be empty —
  # that's acceptable for a free, no-key provider.
  defp parse_duckduckgo(html, limit) do
    chunks = String.split(html, "<div class=\"result\"")

    chunks
    |> Enum.drop(1)
    |> Enum.map(fn chunk ->
      %{
        "title" => extract_between(chunk, "<a class=\"result__a\"", "</a>"),
        "url" => extract_url(chunk),
        "snippet" => extract_between(chunk, "<a class=\"result__snippet\"", "</a>")
      }
    end)
    |> Enum.filter(fn r -> r["title"] != "" and r["url"] != "" end)
    |> Enum.take(limit)
  end

  defp extract_between(chunk, start_pat, end_pat) do
    chunk
    |> String.split(start_pat)
    |> Enum.drop(1)
    |> hd()
    |> String.split(end_pat)
    |> hd()
    |> String.trim()
  end

  defp extract_url(chunk) do
    chunk
    |> String.split("href=\"")
    |> Enum.drop(1)
    |> hd()
    |> String.split("\"")
    |> hd()
    |> String.trim()
  end

  # --- Formatting ---

  defp format_results(results, query) do
    if results == [] do
      "No web results found for #{inspect(query)}."
    else
      header =
        "Web results for #{inspect(query)} (#{length(results)}):"

      body =
        results
        |> Enum.with_index(1)
        |> Enum.map(fn {r, i} ->
          "#{i}. #{r["title"]}\n   #{r["url"]}\n   #{r["snippet"]}"
        end)
        |> Enum.join("\n\n")

      header <> "\n\n" <> body
    end
  end

  # --- Helpers ---

  defp url_encode(text) do
    URI.encode(text, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 in ~w(- _ . ~)))
  end

  defp normalize_limit(nil), do: @default_limit

  defp normalize_limit(value) when is_integer(value) and value > 0 do
    min(value, @max_limit)
  end

  defp normalize_limit(_), do: @default_limit
end
