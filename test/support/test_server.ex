defmodule WebSockex.TestServer do
  use Plug.Router

  @certfile Path.join([__DIR__, "priv", "websockex.cer"])
  @keyfile Path.join([__DIR__, "priv", "websockex.key"])
  @cacert Path.join([__DIR__, "priv", "websockexca.cer"]) |> File.read! |> :public_key.pem_decode

  plug :match
  plug :dispatch

  match _ do
    send_resp(conn, 200, "Hello from plug")
  end

  def start(pid) when is_pid(pid) do
    ref = make_ref()
    port = get_port()
    {:ok, agent_pid} = Agent.start_link(fn -> :ok end)
    url = "ws://localhost:#{port}/ws"

    opts = [dispatch: dispatch({pid, agent_pid}),
            port: port,
            ref: ref]

    case Plug.Adapters.Cowboy.http(__MODULE__, [], opts) do
      {:ok, _} ->
        {:ok, {ref, url}}
      {:error, :eaddrinuse} ->
        start(pid)
    end
  end

  def start_https(pid) do
    ref = make_ref()
    port = get_port()
    url = "wss://localhost:#{port}/ws"
    {:ok, agent_pid} = Agent.start_link(fn -> :ok end)

    opts = [dispatch: dispatch({pid, agent_pid}),
            certfile: @certfile,
            keyfile: @keyfile,
            port: port,
            ref: ref]

    case Plug.Adapters.Cowboy.https(__MODULE__, [], opts) do
      {:ok, _} ->
        {:ok, {ref, url}}
      {:error, :eaddrinuse} ->
        IO.puts "Address #{port} in use!"
        start_https(pid)
    end
  end

  def shutdown(ref) do
    Plug.Adapters.Cowboy.shutdown(ref)
  end

  def receive_socket_pid do
    receive do
      pid when is_pid(pid) -> pid
    after
      500 -> raise "No Server Socket pid"
    end
  end

  def cacerts do
    [{:Certificate, cert, _}] = @cacert
    [cert]
  end

  defp dispatch(tuple) do
    [{:_, [{"/ws", WebSockex.TestSocket, [tuple]}]}]
  end

  defp get_port do
    unless Process.whereis(__MODULE__), do: start_ports_agent()

    Agent.get_and_update(__MODULE__, fn(port) -> {port, port + 1} end)
  end

  defp start_ports_agent do
    Agent.start(fn -> Enum.random(50_000..63_000) end, name: __MODULE__)
  end
end

defmodule WebSockex.TestSocket do
  @behaviour :cowboy_websocket_handler

  def init(_, req, [{_, agent_pid}]) do
    case Agent.get(agent_pid, fn x -> x end) do
      :ok -> {:upgrade, :protocol, :cowboy_websocket}
      int when is_integer(int) ->
        :cowboy_req.reply(int, req)
        {:shutdown, req, :tests_are_fun}
    end
  end

  def terminate(_,_,_), do: :ok

  def websocket_init(_, req, [{pid, agent_pid}]) do
    send(pid, self())
    {:ok, req, %{pid: pid, agent_pid: agent_pid}}
  end

  def websocket_terminate({:remote, :closed}, _, state) do
    send(state.pid, :normal_remote_closed)
  end
  def websocket_terminate({:remote, close_code, reason}, _, state) do
    send(state.pid, {close_code, reason})
  end
  def websocket_terminate(_, _, _) do
    :ok
  end

  def websocket_handle({:binary, msg}, req, state) do
    send(state.pid, :erlang.binary_to_term(msg))
    {:ok, req, state}
  end
  def websocket_handle({:ping, _}, req, state), do: {:ok, req, state}
  def websocket_handle({:pong, ""}, req, state) do
    send(state.pid, :received_pong)
    {:ok, req, state}
  end
  def websocket_handle({:pong, payload}, req, %{ping_payload: ping_payload} = state) when payload == ping_payload do
    send(state.pid, :received_payload_pong)
    {:ok, req, state}
  end

  def websocket_info(:stall, _, _) do
    Process.sleep(:infinity)
  end
  def websocket_info(:send_ping, req, state), do: {:reply, :ping, req, state}
  def websocket_info(:send_payload_ping, req, state) do
    payload = "Llama and Lambs"
    {:reply, {:ping, payload}, req, Map.put(state, :ping_payload, payload)}
  end
  def websocket_info(:close, req, state), do: {:reply, :close, req, state}
  def websocket_info({:close, code, reason}, req, state) do
    {:reply, {:close, code, reason}, req, state}
  end
  def websocket_info({:send, frame}, req, state) do
    {:reply, frame, req, state}
  end
  def websocket_info({:set_code, code}, req, state) do
    Agent.update(state.agent_pid, fn _ -> code end)
    {:ok, req, state}
  end
  def websocket_info(:shutdown, req, state) do
    {:shutdown, req, state}
  end
  def websocket_info(_, req, state), do: {:ok, req, state}
end
