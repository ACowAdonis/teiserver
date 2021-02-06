# Stated with this
# https://blog.oestrich.org/2017/07/using-ranch-with-elixir/
defmodule Teiserver.TcpServer do
  use GenServer
  require Logger
  alias Phoenix.PubSub

  alias Teiserver.Client
  alias Teiserver.Protocols.SpringProtocol

  @behaviour :ranch_protocol
  @default_protocol SpringProtocol

  def start_link(_opts) do
    :ranch.start_listener(make_ref(), :ranch_tcp, [{:port, 8200}], __MODULE__, [])
  end

  def start_link(ref, socket, transport, _opts) do
    pid = :proc_lib.spawn_link(__MODULE__, :init, [ref, socket, transport])
    {:ok, pid}
  end

  def init(ref, socket, transport) do
    Logger.debug("New TCP connection")
    :ok = :ranch.accept_ack(ref)
    :ok = transport.setopts(socket, [{:active, true}])

    @default_protocol.welcome(socket, transport)

    :ok = PubSub.subscribe(Teiserver.PubSub, "battle_updates")
    :ok = PubSub.subscribe(Teiserver.PubSub, "client_updates")
    :ok = PubSub.subscribe(Teiserver.PubSub, "user_updates")
    :gen_server.enter_loop(__MODULE__, [], %{
      client: nil,
      user: nil,
      socket: socket,
      transport: transport,
      protocol: @default_protocol
    })
  end

  def init(init_arg) do
    {:ok, init_arg}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_cast({:put, key, value}, _from, state) do
    new_state = Map.put(state, key, value)
    {:noreply, new_state}
  end

  def handle_info({:tcp, _socket, data}, state) do
    Logger.debug("<-- #{data}")
    new_state = state.protocol.handle(data, state)
    {:noreply, new_state}
  end
  
  # Client updates
  def handle_info({:logged_in_client, username}, state) do
    new_state = state.protocol.forward_logged_in_client(username, state)
    {:noreply, new_state}
  end

  def handle_info({:updated_client_status, username, status}, state) do
    new_state = state.protocol.forward_new_clientstatus({username, status}, state)
    {:noreply, new_state}
  end

  def handle_info({:updated_client, new_client}, state) when is_map(new_client) do
    new_state = if state.client.name == new_client.name do
      Map.put(state, :client, new_client)
    else
      state
    end
    {:noreply, new_state}
  end

  def handle_info({:new_battlestatus, username, battlestatus, team_colour}, state) do
    new_state = state.protocol.forward_new_battlestatus({username, battlestatus, team_colour}, state)
    {:noreply, new_state}
  end

  # User
  def handle_info({:updated_user, username, new_user, cause}, state) do
    new_state = if username == state.user.name do
      new_state = Map.put(state, :user, new_user)
      case cause do
        "accepted_friend" ->
          new_state.protocol.update_friend_list(new_state)
          new_state.protocol.update_friend_request_list(new_state)
          Logger.warn("Friend request accepted, no action")
        "request_accepted by " <> accepter ->
          new_state.protocol.update_friend_list(new_state)
          Logger.warn("Friend request to accepted by #{accepter}, no action")
        "declined_friend" ->
          new_state.protocol.do_friendlist_request(new_state)
          Logger.warn("Friend request declined, no action")
      end

      new_state
    else
      state
    end
    {:noreply, new_state}
  end

  # Chat
  def handle_info({:new_message, from, room_name, msg}, state) do
    new_state = state.protocol.forward_chat_message({from, room_name, msg}, state)
    {:noreply, new_state}
  end

  def handle_info({:add_user_to_room, username, room_name}, state) do
    new_state = state.protocol.forward_add_user_to_room({username, room_name}, state)
    {:noreply, new_state}
  end

  def handle_info({:remove_user_from_room, username, room_name}, state) do
    new_state = state.protocol.forward_remove_user_from_room({username, room_name}, state)
    {:noreply, new_state}
  end

  # Battles
  def handle_info({:add_user_to_battle, username, battle_id}, state) do
    new_state = state.protocol.forward_add_user_to_battle({username, battle_id}, state)
    {:noreply, new_state}
  end

  def handle_info({:remove_user_from_battle, username, battle_id}, state) do
    new_state = state.protocol.forward_remove_user_from_battle({username, battle_id}, state)
    {:noreply, new_state}
  end

  def handle_info({:battle_message, username, msg, battle_id}, state) do
    new_state = state.protocol.forward_battle_said({username, msg, battle_id}, state)
    {:noreply, new_state}
  end

  def handle_info({:tcp_closed, socket}, state = %{socket: socket, transport: transport}) do
    Logger.debug("Closing TCP connection")
    transport.close(socket)
    {:stop, :normal, state}
  end
  
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.debug("Closing TCP connection - no transport")
    {:stop, :normal, state}
  end

  # def handle_info(other, state) do
  #   Logger.error("No handler: #{other}")
  #   {:noreply, state}
  # end

  def terminate(reason, state) do
    Logger.warn("disconnect because #{Kernel.inspect reason}")
    Client.disconnect(state.client.name)
  end

end