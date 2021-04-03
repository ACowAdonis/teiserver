defmodule Teiserver.User do
  @moduledoc """
  Users here are a combination of Central.Account.User and the data within. They are merged like this into a map as their expected use case is very different.
  """
  alias Central.Communication
  alias Teiserver.Client
  alias Teiserver.EmailHelper
  alias Teiserver.Account
  alias Central.Helpers.StylingHelper
  alias Central.Helpers.TimexHelper

  @wordlist ~w(abacus rhombus square shape oblong rotund bag dice flatulence cats dogs mice eagle oranges apples pears neon lights electricity calculator harddrive cpu memory graphics monitor screen television radio microwave sulphur tree tangerine melon watermelon obstreperous chlorine argon mercury jupiter saturn neptune ceres firefly slug sloth madness happiness ferrous oblique advantageous inefficient starling clouds rivers sunglasses)

  @keys [:id, :name, :email, :inserted_at]
  @data_keys [
    :rank,
    :country,
    :country_override,
    :lobbyid,
    :ip,
    :moderator,
    :bot,
    :friends,
    :friend_requests,
    :ignored,
    :verification_code,
    :verified,
    :password_reset_code,
    :email_change_code,
    :password_hash,
    :ingame_minutes,
    :mmr,
    :banned,
    :muted,
    :banned_until,
    :muted_until
  ]

  @default_data %{
    rank: 1,
    country: "??",
    country_override: nil,
    lobbyid: "LuaLobby Chobby",
    ip: "default_ip",
    moderator: false,
    bot: false,
    friends: [],
    friend_requests: [],
    ignored: [],
    password_hash: nil,
    verification_code: nil,
    verified: false,
    password_reset_code: nil,
    email_change_code: nil,
    last_login: nil,
    ingame_minutes: 0,
    mmr: %{},
    banned: false,
    muted: false,
    banned_until: nil,
    muted_until: nil
  }

  @rank_levels [
    5, 15, 30, 100, 300, 1000, 3000
  ]

  require Logger
  alias Phoenix.PubSub
  import Central.Helpers.NumberHelper, only: [int_parse: 1]
  alias Teiserver.EmailHelper
  alias Teiserver.Account

  def generate_random_password() do
    @wordlist
    |> Enum.take_random(3)
    |> Enum.join(" ")
  end

  def clean_name(name) do
    ~r/([^a-zA-Z0-9_\-\[\]]|\s)/
    |> Regex.replace(name, "")
  end

  def bar_user_group_id() do
    ConCache.get(:application_metadata_cache, "bar_user_group")
  end

  def user_register_params(name, email, password_hash, extra_data \\ %{}) do
    name = clean_name(name)
    verification_code = :random.uniform(899_999) + 100_000
    web_password = generate_random_password()

    data =
      @default_data
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    %{
      name: name,
      email: email,
      password: web_password,
      colour: "#AA0000",
      icon: "fas fa-user",
      admin_group_id: bar_user_group_id(),
      permissions: ["teiserver", "teiserver.player", "teiserver.player.account"],
      data:
        data
        |> Map.merge(%{
          "password_hash" => password_hash,
          "verification_code" => verification_code,
          "verified" => false
        })
        |> Map.merge(extra_data)
    }
  end

  def register_user(name, email, password_hash, ip) do
    params =
      user_register_params(name, email, password_hash, %{
        "ip" => ip
      })

    case Account.create_user(params) do
      {:ok, user} ->

        Account.create_group_membership(%{
          user_id: user.id,
          group_id: bar_user_group_id()
        })

        # Now add them to the cache
        user
        |> convert_user
        |> add_user

        EmailHelper.new_user(user)
        user

      {:error, changeset} ->
        Logger.error(
          "Unable to create user with params #{Kernel.inspect(params)}\n#{
            Kernel.inspect(changeset)
          }"
        )
    end
  end

  def register_bot(bot_name, bot_host_id) do
    existing_bot = get_user_by_name(bot_name)

    cond do
      allow?(bot_host_id, :moderator) == false ->
        {:error, "no permission"}

      existing_bot != nil ->
        existing_bot

      true ->
        host = get_user_by_id(bot_host_id)

        params =
          user_register_params(bot_name, host.email, host.password_hash, %{
            "bot" => true,
            "verified" => true
          })
          |> Map.merge(%{
            email: String.replace(host.email, "@", ".bot#{bot_name}@")
          })

        case Account.create_user(params) do
          {:ok, user} ->
            Account.create_group_membership(%{
              user_id: user.id,
              group_id: bar_user_group_id()
            })

            # Now add them to the cache
            user
            |> convert_user
            |> add_user

          {:error, changeset} ->
            Logger.error(
              "Unable to create user with params #{Kernel.inspect(params)}\n#{
                Kernel.inspect(changeset)
              } in register_bot(#{bot_name}, #{bot_host_id})"
            )
        end
    end
  end

  def get_username(userid) do
    ConCache.get(:users_lookup_name_with_id, int_parse(userid))
  end

  def get_userid(username) do
    ConCache.get(:users_lookup_id_with_name, username)
  end

  def get_user_by_name(username) do
    id = ConCache.get(:users_lookup_id_with_name, username)
    ConCache.get(:users, id)
  end

  def get_user_by_email(email) do
    id = ConCache.get(:users_lookup_id_with_email, email)
    ConCache.get(:users, id)
  end

  def get_user_by_id(id) do
    ConCache.get(:users, int_parse(id))
  end

  def rename_user(user, new_name) do
    old_name = user.name
    new_name = clean_name(new_name)
    new_user = %{user | name: new_name}

    ConCache.delete(:users_lookup_id_with_name, old_name)
    ConCache.put(:users_lookup_name_with_id, user.id, new_name)
    ConCache.put(:users_lookup_id_with_name, new_name, user.id)
    ConCache.put(:users, user.id, new_user)
    new_user
  end

  def add_user(user) do
    update_user(user)
    ConCache.put(:users_lookup_name_with_id, user.id, user.name)
    ConCache.put(:users_lookup_id_with_name, user.name, user.id)
    ConCache.put(:users_lookup_id_with_email, user.email, user.id)

    ConCache.update(:lists, :users, fn value ->
      new_value =
        (value ++ [user.id])
        |> Enum.uniq()

      {:ok, new_value}
    end)

    user
  end

  # Persists the changes into the database so they will
  # be pulled out next time the user is accessed/recached
  # The special case here is to prevent the benchmark users causing issues
  defp persist_user(%{name: "TEST_" <> _}), do: nil

  defp persist_user(user) do
    db_user = Account.get_user!(user.id)

    data =
      @data_keys
      |> Map.new(fn k -> {to_string(k), Map.get(user, k, @default_data[k])} end)

    Account.update_user(db_user, %{"data" => data})
  end

  def update_user(user, persist \\ false) do
    ConCache.put(:users, user.id, user)
    if persist, do: persist_user(user)
    user
  end

  def request_password_reset(user) do
    code = :random.uniform(899_999) + 100_000
    update_user(%{user | password_reset_code: "#{code}"})
  end

  def generate_new_password() do
    new_plain_password = generate_random_password()
    new_encrypted_password = encrypt_password(new_plain_password)
    {new_plain_password, new_encrypted_password}
  end

  def reset_password(user, code) do
    case code == user.password_reset_code do
      true ->
        {plain_password, encrypted_password} = generate_new_password()
        EmailHelper.password_reset(user, plain_password)
        update_user(%{user | password_reset_code: nil, password_hash: encrypted_password})
        :ok

      false ->
        :error
    end
  end

  def request_email_change(nil, _), do: nil

  def request_email_change(user, new_email) do
    code = :random.uniform(899_999) + 100_000
    update_user(%{user | email_change_code: ["#{code}", new_email]})
  end

  def change_email(user, new_email) do
    ConCache.delete(:users_lookup_id_with_email, user.email)
    ConCache.put(:users_lookup_id_with_email, new_email, user.id)
    update_user(%{user | email: new_email, email_change_code: [nil, nil]})
  end

  def accept_friend_request(requester_id, accepter_id) do
    accepter = get_user_by_id(accepter_id)

    if requester_id in accepter.friend_requests do
      requester = get_user_by_id(requester_id)

      # Add to friends, remove from requests
      new_accepter =
        Map.merge(accepter, %{
          friends: accepter.friends ++ [requester_id],
          friend_requests: Enum.filter(accepter.friend_requests, fn f -> f != requester_id end)
        })

      new_requester =
        Map.merge(requester, %{
          friends: requester.friends ++ [accepter_id]
        })

      update_user(new_accepter, persist: true)
      update_user(new_requester, persist: true)

      Communication.notify(new_requester.id, %{
        title: "#{new_accepter.name} accepted your friend request",
        body: "#{new_accepter.name} accepted your friend request",
        icon: Teiserver.icon(:friend),
        colour: StylingHelper.get_fg(:success),
        redirect: "/teiserver/account/relationships#friends"
      }, 1, prevent_duplicates: true)

      # Now push out the updates
      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{requester_id}",
        {:this_user_updated, [:friends]}
      )

      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{accepter_id}",
        {:this_user_updated, [:friends, :friend_requests]}
      )

      new_accepter
    else
      accepter
    end
  end

  def decline_friend_request(requester_id, decliner_id) do
    decliner = get_user_by_id(decliner_id)

    if requester_id in decliner.friend_requests do
      # Remove from requests
      new_decliner =
        Map.merge(decliner, %{
          friend_requests: Enum.filter(decliner.friend_requests, fn f -> f != requester_id end)
        })

      update_user(new_decliner, persist: true)

      # Now push out the updates
      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{decliner_id}",
        {:this_user_updated, [:friend_requests]}
      )

      new_decliner
    else
      decliner
    end
  end

  def create_friend_request(requester_id, potential_id) do
    potential = get_user_by_id(potential_id)

    if requester_id not in potential.friend_requests and requester_id not in potential.friends do
      # Add to requests
      new_potential =
        Map.merge(potential, %{
          friend_requests: potential.friend_requests ++ [requester_id]
        })

      requester = get_user_by_id(requester_id)
      update_user(new_potential, persist: true)

      Communication.notify(new_potential.id, %{
        title: "New friend request from #{requester.name}",
        body: "New friend request from #{requester.name}",
        icon: Teiserver.icon(:friend),
        colour: StylingHelper.get_fg(:info),
        redirect: "/teiserver/account/relationships#requests"
      }, 1, prevent_duplicates: true)

      # Now push out the updates
      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{potential_id}",
        {:this_user_updated, [:friend_requests]}
      )

      new_potential
    else
      potential
    end
  end

  def ignore_user(ignorer_id, ignored_id) do
    ignorer = get_user_by_id(ignorer_id)

    if ignored_id not in ignorer.ignored do
      # Add to requests
      new_ignorer =
        Map.merge(ignorer, %{
          ignored: ignorer.ignored ++ [ignored_id]
        })

      update_user(new_ignorer, persist: true)

      # Now push out the updates
      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{ignorer_id}",
        {:this_user_updated, [:ignored]}
      )

      new_ignorer
    else
      ignorer
    end
  end

  def unignore_user(unignorer_id, unignored_id) do
    unignorer = get_user_by_id(unignorer_id)

    if unignored_id in unignorer.ignored do
      # Add to requests
      new_unignorer =
        Map.merge(unignorer, %{
          ignored: Enum.filter(unignorer.ignored, fn f -> f != unignored_id end)
        })

      update_user(new_unignorer, persist: true)

      # Now push out the updates
      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{unignorer_id}",
        {:this_user_updated, [:ignored]}
      )

      new_unignorer
    else
      unignorer
    end
  end

  def remove_friend(remover_id, removed_id) do
    remover = get_user_by_id(remover_id)

    if removed_id in remover.friends do
      # Add to requests
      new_remover =
        Map.merge(remover, %{
          friends: Enum.filter(remover.friends, fn f -> f != removed_id end)
        })

      removed = get_user_by_id(removed_id)

      new_removed =
        Map.merge(removed, %{
          friends: Enum.filter(removed.friends, fn f -> f != remover_id end)
        })

      update_user(new_remover, persist: true)
      update_user(new_removed, persist: true)

      # Now push out the updates
      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{remover_id}",
        {:this_user_updated, [:friends]}
      )

      PubSub.broadcast(
        Central.PubSub,
        "user_updates:#{removed_id}",
        {:this_user_updated, [:friends]}
      )

      new_remover
    else
      remover
    end
  end

  def send_direct_message(from_id, to_id, msg) do
    PubSub.broadcast(
      Central.PubSub,
      "user_updates:#{to_id}",
      {:direct_message, from_id, msg}
    )
  end

   @spec list_users :: list
   def list_users() do
    ConCache.get(:lists, :users)
    |> Enum.map(fn userid -> ConCache.get(:users, userid) end)
  end

  @spec list_users(list) :: list
  def list_users(id_list) do
    id_list
    |> Enum.map(fn userid ->
      ConCache.get(:users, userid)
    end)
  end

  def ring(ringee_id, ringer_id) do
    PubSub.broadcast(Central.PubSub, "user_updates:#{ringee_id}", {:action, {:ring, ringer_id}})
  end

  def encrypt_password(password) do
    :crypto.hash(:md5, password) |> Base.encode64()
  end

  @spec test_password(String.t(), String.t() | map) :: boolean
  def test_password(password, user) when is_map(user) do
    test_password(password, user.password_hash)
  end

  def test_password(password, existing_password) do
    password == existing_password
  end

  def verify_user(user) do
    %{user | verification_code: nil, verified: true}
    |> update_user(persist: true)
  end

  def try_login(username, password, state, ip, lobby) do
    case get_user_by_name(username) do
      nil ->
        {:error, "No user found for '#{username}'"}

      user ->
        banned_until_dt = TimexHelper.parse_ymd_hms(user.banned_until)

        cond do
          user.banned ->
            {:error, "Banned"}

          test_password(password, user) == false ->
            {:error, "Invalid password"}

          banned_until_dt != nil and Timex.compare(Timex.now(), banned_until_dt) != 1 ->
            {:error, "Temporarily banned"}

          Client.get_client_by_id(user.id) != nil ->
            {:error, "Already logged in"}

          user.verified == false ->
            {:error, "Unverified", user.id}

          true ->
            do_login(user, state, ip, lobby)
        end
    end
  end

  defp do_login(user, state, ip, lobbyid) do
    # If they don't want a flag shown, don't show it, otherwise check for an override before trying geoip
    country = cond do
      Central.Config.get_user_config_cache(user.id, "teiserver.Show flag") == false ->
        "??"
      user.country_override != nil ->
        user.country_override
      true ->
        Teiserver.Geoip.get_flag(ip)
    end

    last_login = round(:erlang.system_time(:seconds)/60)

    ingame_hours = user.ingame_minutes / 60
    rank = @rank_levels
    |> Enum.filter(fn r -> r < ingame_hours end)
    |> Enum.count

    user = %{user | ip: ip, lobbyid: lobbyid, country: country, last_login: last_login, rank: rank}
    update_user(user, persist: true)

    proto = state.protocol_out

    proto.reply(:login_accepted, user.name, nil, state)
    proto.reply(:motd, nil, nil, state)

    {:ok, user}
  end

  def logout(nil), do: nil

  def logout(user_id) do
    user = get_user_by_id(user_id)
    # TODO In some tests it's possible for last_login to be nil, this is a temporary workaround
    system_minutes = round(:erlang.system_time(:seconds)/60)
    new_ingame_minutes =
      user.ingame_minutes +
        (system_minutes - (user.last_login || system_minutes))

    user = %{user | ingame_minutes: new_ingame_minutes}
    update_user(user, persist: true)
  end

  def convert_user(user) do
    data =
      @data_keys
      |> Map.new(fn k -> {k, Map.get(user.data || %{}, to_string(k), @default_data[k])} end)

    user
    |> Map.take(@keys)
    |> Map.merge(@default_data)
    |> Map.merge(data)
  end

  @spec new_report(Integer.t()) :: :ok
  def new_report(report_id) do
    report = Account.get_report!(report_id)
    user = get_user_by_id(report.target_id)

    changes = case {report.response_action, report.expires} do
      {"Mute", nil} ->
        %{muted: true}

      {"Mute", expires} ->
        %{muted_until: expires}

      {"Ban", nil} ->
        %{banned: true}

      {"Ban", expires} ->
        %{banned_until: expires}

      {"Ignore report", nil} ->
        %{}

      {action, _} ->
        throw "No handler for action type '#{action}' in #{__MODULE__}"
    end

    Map.merge(user, changes)
    |> update_user(persist: true)

    :ok
  end

  def recache_user(id) do
    if get_user_by_id(id) do
      Account.get_user!(id)
      |> convert_user
      |> update_user
    else
      Account.get_user!(id)
      |> convert_user
      |> add_user
    end
  end

  def delete_user(userid) do
    user = get_user_by_id(userid)

    if user do
      Client.disconnect(userid)
      :timer.sleep(100)

      ConCache.delete(:users, userid)
      ConCache.delete(:users_lookup_name_with_id, user.id)
      ConCache.delete(:users_lookup_id_with_name, user.name)
      ConCache.delete(:users_lookup_id_with_email, user.email)

      ConCache.update(:lists, :users, fn value ->
        new_value =
          value
          |> Enum.filter(fn v -> v != userid end)

        {:ok, new_value}
      end)
    end
  end

  def allow?(userid, permission) do
    user = get_user_by_id(userid)

    case permission do
      :moderator ->
        user.moderator
      _ ->
        false
    end
  end

  def pre_cache_users() do
    group_id = bar_user_group_id()
    ConCache.insert_new(:lists, :users, [])

    user_count =
      Account.list_users(
        search: [
          # Get from the bar group or the admins, admins are group 3
          admin_group: [group_id, 3]
        ],
        limit: :infinity
      )
      |> Parallel.map(fn user ->
        user
        |> convert_user
        |> add_user
      end)
      |> Enum.count()

    # This is mostly so I can see exactly when the restart happened and get logs from this point on
    Logger.info("----------------------------------------")
    Logger.info("pre_cache_users, got #{user_count} users")
    Logger.info("----------------------------------------")
  end
end
