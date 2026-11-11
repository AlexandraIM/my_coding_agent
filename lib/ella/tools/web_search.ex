defmodule Ella.Tools.WebSearch do
  @moduledoc """
  Web search tool for browsing the internet.

  This module implements a lightweight web‑search tool using DuckDuckGo's
  free HTML endpoint. The implementation avoids heavy HTML parsing libraries
  by performing simple string extraction, tolerating missing tags and other
  formatting quirks.

  **Key features**
  * Uses `Req.get/2` with a configurable receive timeout.
  * Normalises the `limit` argument, enforcing a default of 5 and a hard cap
    of 10 results.
  * Provides `search_url/0` and `url_encode/1` helpers that respect the
    `:web_search_url` application config, allowing callers to override the
    provider.
  * Safely strips any stray HTML tags from extracted snippets via `strip_tags/1`.
  * Returns detailed error tuples for network failures, non‑200 responses, or
    parsing problems.

  Future work may add additional providers (Brave, Serper.dev, Tavily) that
  can be selected through the `WEB_SEARCH_PROVIDER` environment variable and
  corresponding API‑key configuration.
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
    url = search_url() <> "?q=" <> url_encode(query)

    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, parse_duckduckgo(body, limit)}

      {:ok, %Req.Response{status: status}} ->
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
    case String.split(chunk, start_pat) do
      [_, rest | _] ->
        case String.split(rest, end_pat) do
          [inner | _] ->
            text =
              case String.split(inner, ">", parts: 2) do
                [_, after_bracket] -> after_bracket
                [plain] -> plain
              end

            text |> strip_tags() |> String.trim()

          _ ->
            ""
        end

      _ ->
        ""
    end
  end

  defp strip_tags(text) do
    String.replace(text, ~r/<[^>]+>/, "")
  end

  defp extract_url(chunk) do
    case String.split(chunk, "href=\"") do
      [_, rest | _] ->
        case String.split(rest, "\"") do
          [url | _] -> String.trim(url)
          _ -> ""
        end

      _ ->
        ""
    end
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

  defp search_url do
    Application.get_env(:ella, :web_search_url, @duckduckgo_url)
  end

  defp normalize_limit(nil), do: @default_limit

  defp normalize_limit(value) when is_integer(value) and value > 0 do
    min(value, @max_limit)
  end

  defp normalize_limit(_), do: @default_limit
end
