defmodule WebSockex.Client do
  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @moduledoc ~S"""
  A client handles negotiating the connection, then sending frames, receiving
  frames, closing, and reconnecting that connection.

  A simple client implementation would be:

  ```
  defmodule WsClient do
    use WebSockex.Client

    def start_link(url, state) do
      WebSockex.Client.start_link(url, __MODULE__, state)
    end

    def handle_frame({:text, msg}, state) do
      IO.puts "Received a message: #{msg}"
      {:ok, state}
    end
  end
  ```
  """

  @type frame :: {:ping | :ping, nil | message :: binary}
                 | {:text | :binary, message :: binary}

  @typedoc """
  The frame sent when the negotiating a connection closure.
  """
  @type close_frame :: {close_code, message :: binary}

  @typedoc """
  An integer between 1000 and 4999 that specifies the reason for closing the connection.
  """
  @type close_code :: integer

  @type options :: [option]

  @typedoc """
  Options values for `start_link`.

  - `:async` - Replies with `{:ok, pid}` before establishing the connection.
    This is useful for when attempting to connect indefinitely, this way the
    process doesn't block trying to establish a connection.

  Other possible option values include: `t:WebSockex.connection_option/0`
  """
  @type option :: WebSockex.Conn.connection_option
                  | {:async, boolean}

  @typedoc """
  The reason given and sent to the server when locally closing a connection.

  A `:normal` reason is the same as a `1000` reason.

  If the peer closes the connection abruptly without a close frame then the
  close reason is `{:remote, :closed}`.
  """
  @type close_reason :: {:remote | :local, :normal}
                        | {:remote | :local, :normal | close_code, close_frame}
                        | {:remote, :closed}
                        | {:error, term}

  @typedoc """
  A map that contains information about the failure to connect.

  This map contains the error, attempt number, and the `t:WebSockex.Conn.t/0`
  that was used to attempt the connection.
  """
  @type connect_failure_map :: %{error: %WebSockex.RequestError{} | %WebSockex.ConnError{},
                                 attempt_number: integer,
                                 conn: WebSockex.Conn.t}

  @doc """
  Invoked after connection is established.
  """
  @callback init(args :: any, WebSockex.Conn.t) :: {:ok, state :: term}

  @doc """
  Invoked on the reception of a frame on the socket.

  The control frames have possible payloads, when they don't have a payload
  then the frame will have `nil` as the payload. e.g. `{:ping, nil}`
  """
  @callback handle_frame(frame, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked to handle asynchronous `cast/2` messages.
  """
  @callback handle_cast(msg :: term, state ::term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked to handle all other non-WebSocket messages.
  """
  @callback handle_info(msg :: term, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked when the WebSocket disconnects from the server.

  This callback is only called when the `tcp` connection closes. In cases of
  crashes or other errors then the process will terminate immediately skipping
  this callback.

  See `t:close_reason/0` to see more information about what causes disconnects.
  """
  @callback handle_disconnect(close_reason, state :: term) ::
    {:ok, state}
    | {:reconnect, state} when state: term

  @doc """
  Invoked when the Websocket receives a ping frame
  """
  @callback handle_ping(:ping | {:ping, binary}, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked when the Websocket receives a pong frame.
  """
  @callback handle_pong(:pong | {:pong, binary}, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked when there is a failure trying to open the websocket.

  The failure map is the `t:connect_failure_map.t/0` type, and contains the
  error attempt number and `t:WebSockex.Conn.t/0` used to connect. You can
  modify the `Conn` struct to change various things about the way you're
  attmpting to connect.

  - `{:ok, state}` will continue the process termination or error.
  - `{:reconnect, state}` will attempt to reconnect instead of terminating.
  - `{:reconnect, conn, state}` will attempt to reconnect with the connection
    data in `conn`. `conn` is expected to be a `t:WebSockex.Conn.t/0`.
  """
  @callback handle_connect_failure(connect_failure_map, state :: term) ::
    {:ok, new_state}
    | {:reconnect, new_state}
    | {:reconnect, WebSockex.Conn.t, new_state} when new_state: term

  @doc """
  Invoked when the process is terminating.
  """
  @callback terminate(close_reason, state :: term) :: any

  @doc """
  Invoked when a new version the module is loaded during runtime.
  """
  @callback code_change(old_vsn :: term | {:down, term},
                        state :: term, extra :: term) ::
    {:ok, new_state :: term}
    | {:error, reason :: term}

  @optional_callbacks [handle_disconnect: 2, handle_ping: 2, handle_pong: 2, handle_connect_failure: 2,
                       terminate: 2, code_change: 3]

  defmacro __using__(_) do
    quote location: :keep do
      @behaviour WebSockex.Client

      @doc false
      def init(state, conn) do
        {:ok, state}
      end

      @doc false
      def handle_frame(frame, _state) do
        raise "No handle_frame/2 clause in #{__MODULE__} provided for #{inspect frame}"
      end

      @doc false
      def handle_cast(frame, _state) do
        raise "No handle_cast/2 clause in #{__MODULE__} provided for #{inspect frame}"
      end

      @doc false
      def handle_info(frame, state) do
        require Logger
        Logger.error "No handle_info/2 clause in #{__MODULE__} provided for #{inspect frame}"
        {:ok, state}
      end

      @doc false
      def handle_disconnect(_close_reason, state) do
        {:ok, state}
      end

      @doc false
      def handle_ping(:ping, state) do
        {:reply, :pong, state}
      end
      def handle_ping({:ping, msg}, state) do
        {:reply, {:pong, msg}, state}
      end

      @doc false
      def handle_pong(:pong, state), do: {:ok, state}
      def handle_pong({:pong, _}, state), do: {:ok, state}

      @doc false
      def handle_connect_failure(_failure_map, state), do: {:ok, state}

      @doc false
      def terminate(_close_reason, _state), do: :ok

      @doc false
      def code_change(_old_vsn, state, _extra), do: {:ok, state}

      defoverridable [init: 2, handle_frame: 2, handle_cast: 2, handle_info: 2, handle_ping: 2,
                      handle_pong: 2, handle_disconnect: 2, handle_connect_failure: 2,
                      terminate: 2, code_change: 3]
    end
  end

  @doc """
  Starts a `WebSockex.Client` process.

  For available option values see `t:option/0`.
  """
  @spec start(String.t, module, term, options) :: {:ok, pid} | {:error, term}
  def start(url, module, state, opts \\ []) do
    case parse_uri(url) do
      {:ok, uri} ->
        :proc_lib.start(__MODULE__, :init, [self(), uri, module, state, opts])
      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Starts a `WebSockex.Client` process linked to the current process.

  For available option values see `t:option/0`.
  """
  @spec start_link(String.t, module, term, options) :: {:ok, pid} | {:error, term}
  def start_link(url, module, state, opts \\ []) do
    case parse_uri(url) do
      {:ok, uri} ->
        :proc_lib.start_link(__MODULE__, :init, [self(), uri, module, state, opts])
      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Asynchronously sends a message to a client that is handled by `c:handle_cast/2`.
  """
  @spec cast(pid, term) :: :ok
  def cast(client, message) do
    send(client, {:"$websockex_cast", message})
    :ok
  end

  @doc """
  Queue a frame to be sent asynchronously.
  """
  @spec send_frame(pid, frame) :: :ok | {:error, WebSockex.FrameEncodeError.t}
  def send_frame(pid, frame) do
    with {:ok, binary_frame} <- WebSockex.Frame.encode_frame(frame),
    do: send(pid, {:"$websockex_send", binary_frame})
  end

  @doc false
  @spec init(pid, URI.t, module, term, options) :: {:ok, pid} | {:error, term}
  def init(parent, uri, module, module_state, opts) do
    # OTP stuffs
    debug = :sys.debug_options([])
    conn = WebSockex.Conn.new(uri, opts)

    reply_fun = case Keyword.get(opts, :async, false) do
                  true ->
                    :proc_lib.init_ack(parent, {:ok, self()})
                    &async_init_fun/1
                  false ->
                    &:proc_lib.init_ack(parent, &1)
                end

    state = %{conn: conn,
              module: module,
              module_state: module_state,
              reply_fun: reply_fun}

    init_connect(parent, debug, state, opts)
  end

  ## OTP Stuffs

  @doc false
  def system_continue(parent, debug, state) do
    websocket_loop(parent, debug, state)
  end

  @doc false
  def system_terminate(reason, parent, debug, state) do
    terminate(reason, parent, debug, state)
  end

  @doc false
  def system_get_state(state) do
    {:ok, state, state}
  end

  @doc false
  def system_replace_state(fun, state) do
    new_state = fun.(state)
    {:ok, new_state, new_state}
  end

  # Internals! Yay

  defp init_connect(parent, debug, state, opts, attempt \\ 1) do
    case open_connection(state.conn) do
      {:ok, new_conn} ->
        module_init(parent, debug, %{state | conn: new_conn}, opts)
      {:error, %{__struct__: struct} = reason}
      when struct in [WebSockex.ConnError, WebSockex.RequestError] ->
        case handle_connect_failure(reason, state, attempt) do
          {:ok, _} ->
            state.reply_fun.({:error, reason})
          {:reconnect, new_conn, new_module_state} ->
            state = %{state | conn: new_conn, module_state: new_module_state}
            init_connect(parent, debug, state, opts, attempt+1)
        end
      {:error, reason} ->
        error = Exception.normalize(:error, reason)
        state.reply_fun.({:error, error})
    end
  end

  defp reconnect(parent, debug, state, attempt \\ 1) do
    case open_connection(state.conn) do
      {:ok, conn} ->
        websocket_loop(parent, debug, %{state | conn: conn,
                                                buffer: <<>>})
      {:error, %{__struct__: struct} = reason}
      when struct in [WebSockex.ConnError, WebSockex.RequestError] ->
        case handle_connect_failure(reason, state, attempt) do
          {:ok, _} ->
            raise reason
          {:reconnect, new_conn, new_module_state} ->
            new_state = %{state | conn: new_conn,
                                  module_state: new_module_state}
            reconnect(parent, debug, new_state, attempt+1)
        end
      {:error, reason} ->
        error = Exception.normalize(:error, reason)
        raise error
    end
  end

  defp open_connection(conn) do
    with {:ok, conn} <- WebSockex.Conn.open_socket(conn),
         key <- :crypto.strong_rand_bytes(16) |> Base.encode64,
         {:ok, request} <- WebSockex.Conn.build_request(conn, key),
         :ok <- WebSockex.Conn.socket_send(conn, request),
         {:ok, headers} <- WebSockex.Conn.handle_response(conn),
         :ok <- validate_handshake(headers, key),
         :ok <- WebSockex.Conn.set_active(conn),
    do: {:ok, conn}
  end

  defp validate_handshake(headers, key) do
    challenge = :crypto.hash(:sha, key <> @handshake_guid) |> Base.encode64

    {_, res} = List.keyfind(headers, "Sec-Websocket-Accept", 0)

    if challenge == res do
      :ok
    else
      {:error, %WebSockex.HandshakeError{response: res, challenge: challenge}}
    end
  end

  defp websocket_loop(parent, debug, state) do
    case WebSockex.Frame.parse_frame(state.buffer) do
      {:ok, frame, buffer} ->
        handle_frame(frame, parent, debug, %{state | buffer: buffer})
      :incomplete ->
        transport = state.conn.transport
        socket = state.conn.socket
        receive do
          {:system, from, req} ->
            :sys.handle_system_msg(req, from, parent, __MODULE__, debug, state)
          {:"$websockex_cast", msg} ->
            common_handle({:handle_cast, msg}, parent, debug, state)
          {:"$websockex_send", binary_frame} ->
            handle_send(binary_frame, parent, debug, state)
          {^transport, ^socket, message} ->
            buffer = <<state.buffer::bitstring, message::bitstring>>
            websocket_loop(parent, debug, %{state | buffer: buffer})
          {:tcp_closed, ^socket} ->
            handle_close({:remote, :closed}, parent, debug, state)
          :"websockex_close_timeout" ->
            websocket_loop(parent, debug, state)
          msg ->
            common_handle({:handle_info, msg}, parent, debug, state)
        end
    end
  end

  defp handle_frame(:ping, parent, debug, state) do
    common_handle({:handle_ping, :ping}, parent, debug, state)
  end
  defp handle_frame({:ping, msg}, parent, debug, state) do
    common_handle({:handle_ping, {:ping, msg}}, parent, debug, state)
  end
  defp handle_frame(:pong, parent, debug, state) do
    common_handle({:handle_pong, :pong}, parent, debug, state)
  end
  defp handle_frame({:pong, msg}, parent, debug, state) do
    common_handle({:handle_pong, {:pong, msg}}, parent, debug, state)
  end
  defp handle_frame(:close, parent, debug, state) do
    handle_close({:remote, :normal}, parent, debug, state)
  end
  defp handle_frame({:close, code, reason}, parent, debug, state) do
    handle_close({:remote, code, reason}, parent, debug, state)
  end
  defp handle_frame({:fragment, _, _} = fragment, parent, debug, state) do
    handle_fragment(fragment, parent, debug, state)
  end
  defp handle_frame({:continuation, _} = fragment, parent, debug, state) do
    handle_fragment(fragment, parent, debug, state)
  end
  defp handle_frame({:finish, _} = fragment, parent, debug, state) do
    handle_fragment(fragment, parent, debug, state)
  end
  defp handle_frame(frame, parent, debug, state) do
    common_handle({:handle_frame, frame}, parent, debug, state)
  end

  defp common_handle({function, msg}, parent, debug, state) do
    case apply(state.module, function, [msg, state.module_state]) do
      {:ok, new_state} ->
        websocket_loop(parent, debug, %{state | module_state: new_state})
      {:reply, frame, new_state} ->
        with {:ok, binary_frame} <- WebSockex.Frame.encode_frame(frame),
             :ok <- WebSockex.Conn.socket_send(state.conn, binary_frame) do
          websocket_loop(parent, debug, %{state | module_state: new_state})
        else
          {:error, error} ->
            raise error
        end
      {:close, new_state} ->
        handle_close({:local, :normal}, parent, debug, %{state | module_state: new_state})
      {:close, {close_code, message}, new_state} ->
        handle_close({:local, close_code, message}, parent, debug, %{state | module_state: new_state})
      badreply ->
        raise %WebSockex.BadResponseError{module: state.module,
          function: function, args: [msg, state.module_state],
          response: badreply}
    end
  rescue
    exception ->
      terminate({exception, System.stacktrace}, parent, debug, state)
  end

  defp handle_close({:remote, :closed} = reason, parent, debug, state) do
    new_conn = %{state.conn | socket: nil}
    handle_disconnect(reason, parent, debug, %{state | conn: new_conn})
  end
  defp handle_close({:remote, _} = reason, parent, debug, state) do
    handle_remote_close(reason, parent, debug, state)
  end
  defp handle_close({:remote, _, _} = reason, parent, debug, state) do
    handle_remote_close(reason, parent, debug, state)
  end
  defp handle_close({:local, _} = reason, parent, debug, state) do
    handle_local_close(reason, parent, debug, state)
  end
  defp handle_close({:local, _, _} = reason, parent, debug, state) do
    handle_local_close(reason, parent, debug, state)
  end

  defp handle_disconnect(reason, parent, debug, state) do
    case apply(state.module, :handle_disconnect, [reason, state.module_state]) do
      {:ok, new_state} ->
        terminate(reason, parent, debug, %{state | module_state: new_state})
      {:reconnect, new_state} ->
        reconnect(parent, debug, %{state | module_state: new_state})
      badreply ->
        raise %WebSockex.BadResponseError{module: state.module,
          function: :handle_disconnect, args: [reason, state.module_state],
          response: badreply}
    end
  rescue
    exception ->
      terminate({exception, System.stacktrace}, parent, debug, state)
  end

  defp module_init(parent, debug, state, _opts) do
    case apply(state.module, :init, [state.module_state, state.conn]) do
      {:ok, new_module_state} ->
         state.reply_fun.({:ok, self()})
         state = Map.merge(state, %{buffer: <<>>,
                                    fragment: nil,
                                    module_state: new_module_state})
                 |> Map.delete(:reply_fun)

          websocket_loop(parent, debug, state)
      badreply ->
        raise %WebSockex.BadResponseError{module: state.module, function: :init,
          args: [state.module_state, state.conn], response: badreply}
    end
  end

  defp terminate(reason, _parent, _debug, %{module: mod, module_state: mod_state}) do
    mod.terminate(reason, mod_state)
    case reason do
      {_, :normal} ->
        exit(:normal)
      {_, 1000, _} ->
        exit(:normal)
      _ ->
        exit(reason)
    end
  end

  defp handle_connect_failure(reason, state, attempt) do
    failure_map = %{conn: state.conn,
                    error: reason,
                    attempt_number: attempt}

    case apply(state.module, :handle_connect_failure, [failure_map, state.module_state]) do
      {:ok, new_state} ->
        {:ok, new_state}
      {:reconnect, new_state} ->
        {:reconnect, state.conn, new_state}
      {:reconnect, new_conn, new_state} ->
        {:reconnect, new_conn, new_state}
      badreply ->
        raise %WebSockex.BadResponseError{module: state.module,
                                          function: :handle_connect_failure,
                                          args: [failure_map, state.module_state],
                                          response: badreply}
    end
  end

  defp handle_send(binary_frame, parent, debug, %{conn: conn} = state) do
    case WebSockex.Conn.socket_send(conn, binary_frame) do
      :ok ->
        websocket_loop(parent, debug, state)
      {:error, error} ->
        terminate(error, parent, debug, state)
    end
  end

  defp handle_fragment({:fragment, type, part}, parent, debug, %{fragment: nil} = state) do
    websocket_loop(parent, debug, %{state | fragment: {type, part}})
  end
  defp handle_fragment({:fragment, _, _}, parent, debug, state) do
    handle_close({:local, 1002, "Endpoint tried to start a fragment without finishing another"}, parent, debug, state)
  end
  defp handle_fragment({:continuation, _}, parent, debug, %{fragment: nil} = state) do
    handle_close({:local, 1002, "Endpoint sent a continuation frame without starting a fragment"}, parent, debug, state)
  end
  defp handle_fragment({:continuation, next}, parent, debug, %{fragment: {type, part}} = state) do
    websocket_loop(parent, debug, %{state | fragment: {type, <<part::binary, next::binary>>}})
  end
  defp handle_fragment({:finish, next}, parent, debug, %{fragment: {type, part}} = state) do
    handle_frame({type, <<part::binary, next::binary>>}, parent, debug, %{state | fragment: nil})
  end

  defp handle_remote_close(reason, parent, debug, state) do
    # If the socket is already closed then that's ok, but the spec says to send
    # the close frame back in response to receiving it.
    send_close_frame(reason, state.conn)

    Process.send_after(self(), :"$websockex_close_timeout", 5000)
    close_loop(reason, parent, debug, state)
  end

  defp handle_local_close(reason, parent, debug, state) do
    case send_close_frame(reason, state.conn) do
      :ok ->
        Process.send_after(self(), :"$websockex_close_timeout", 5000)
        close_loop(reason, parent, debug, state)
      {:error, %WebSockex.ConnError{original: :closed}} ->
        close_loop({:remote, :closed}, parent, debug, state)
    end
  end

  defp send_close_frame(reason, conn) do
    with {:ok, binary_frame} <- build_close_frame(reason),
    do: WebSockex.Conn.socket_send(conn, binary_frame)
  end

  defp build_close_frame({_, :normal}) do
    WebSockex.Frame.encode_frame(:close)
  end
  defp build_close_frame({_, code, msg}) do
    WebSockex.Frame.encode_frame({:close, code, msg})
  end

  defp async_init_fun({:ok, _}), do: :noop
  defp async_init_fun(exit_reason), do: exit(exit_reason)

  defp close_loop(reason, parent, debug, %{conn: conn} = state) do
    transport = state.conn.transport
    socket = state.conn.socket
    receive do
      {^transport, ^socket, _} ->
        close_loop(reason, parent, debug, state)
      {:tcp_closed, ^socket} ->
        new_conn = %{conn | socket: nil}
        handle_disconnect(reason, parent, debug, %{state | conn: new_conn})
      :"$websockex_close_timeout" ->
        new_conn = WebSockex.Conn.close_socket(conn)
        handle_disconnect(reason, parent, debug, %{state | conn: new_conn})
    end
  end

  defp parse_uri(url) do
    case URI.parse(url) do
      # This is confusing to look at. But it's just a match with multiple guards
      %URI{host: host, port: port, scheme: protocol}
      when is_nil(host)
      when is_nil(port)
      when not protocol in ["ws", "wss"] ->
        {:error, %WebSockex.URLError{url: url}}
      {:error, error} ->
        {:error, error}
      %URI{} = uri ->
        {:ok, uri}
    end
  end
end
