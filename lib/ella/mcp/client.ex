defmodule Ella.Mcp.Client do
  @doc """
  MCP-client to work with external MCP-servers via Stdio (Elixir Port) and JSON-RPC 2.0.
  """
  use GenServer

  # --- Client API ---

  def start_link(executable, args \\ []) when is_binary(executable) and is_list(args) do
    GenServer.start_link(__MODULE__, executable: executable, args: args)
  end

  def list_tools(pid) do
    GenServer.call(pid, :list_tools, :infinity)
  end

  def call_tool(pid, tool_name, arguments) do
    GenServer.call(pid, {:call_tool, tool_name, arguments}, :infinity)
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) when is_list(opts) do
    executable = Keyword.fetch!(opts, :executable)
    args = Keyword.get(opts, :args, [])

    exec_path = System.find_executable(executable) || executable

    port =
      Port.open({:spawn_executable, exec_path}, [
        :binary,
        :stream,
        :line,
        args: args
      ])

    state = %{
      port: port,
      request_id: 1,
      pending_requests: %{},
      buffer: ""
    }

    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    id = state.request_id

    init_request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2024-11-05",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "ElixirCodingAgent", "version" => "1.0.0"}
      }
    }

    send_json(state.port, init_request)

    {:noreply,
     %{
       state
       | request_id: id + 1,
         pending_requests: Map.put(state.pending_requests, id, :initialize)
     }}
  end

  @impl true
  def handle_call(:list_tools, from, state) do
    id = state.request_id
    request = %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list", "params" => %{}}

    send_json(state.port, request)

    {:noreply,
     %{state | request_id: id + 1, pending_requests: Map.put(state.pending_requests, id, from)}}
  end

  @impl true
  def handle_call({:call_tool, tool_name, arguments}, from, state) do
    id = state.request_id

    request = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => arguments}
    }

    send_json(state.port, request)

    {:noreply,
     %{state | request_id: id + 1, pending_requests: Map.put(state.pending_requests, id, from)}}
  end

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  @impl true
  def handle_info({port, {:data, {tag, line}}}, %{port: port} = state)
      when tag in [:line, :eol] do
    full_line = state.buffer <> line
    state = %{state | buffer: ""}

    case Jason.decode(String.trim(full_line)) do
      {:ok, %{"id" => id} = response} when is_map_key(state.pending_requests, id) ->
        {target, new_pending} = Map.pop(state.pending_requests, id)
        state = %{state | pending_requests: new_pending}

        case target do
          :initialize ->
            send_json(state.port, %{
              "jsonrpc" => "2.0",
              "method" => "notifications/initialized"
            })

            {:noreply, state}

          from ->
            result =
              case response do
                %{"result" => res} -> {:ok, res}
                %{"error" => err} -> {:error, err}
              end

            GenServer.reply(from, result)
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp send_json(port, map) do
    payload = Jason.encode!(map) <> "\n"
    Port.command(port, payload)
  end
end
