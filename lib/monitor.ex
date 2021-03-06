# Matthew Brookes (mb5715) and Abhinav Mishra (am8315)

defmodule MonitorState do
  @enforce_keys [:paxos, :config]
  defstruct(
    paxos:        nil,
    config:       Map.new,
    clock:        0,
    updates:      Map.new,
    requests:     Map.new,
    transactions: Map.new,
    dbs:          Map.new,
    clients:      Map.new,
    keep_alive:   []
  )
end # MonitorState

defmodule Monitor do

  def start config, paxos do
    Process.send_after self(), :print, config.print_after
    state = %MonitorState{
      paxos: paxos,
      config: config
    }
    next state
  end # start

  defp next state do
    receive do
      { :keep_alive, pid } ->
        next %{ state | keep_alive: [pid | state.keep_alive] }
      { :client_sleep, client_num, sent } ->
        if !state.config.silent, do:
          IO.puts "\nClient #{client_num} going to sleep, sent = #{sent}"

        clients = Map.put state.clients, client_num, sent
        next %{ state | clients: clients }

      { :db_update, db, db_num, seqnum, transaction } ->
        { :move, amount, from, to } = transaction

        done = Map.get state.updates, db_num, 0

        if seqnum != done + 1  do
          IO.puts "  ** error db #{db_num}: seq #{seqnum} expecting #{done+1}"
          System.halt
        end

        transactions =
          case Map.get state.transactions, seqnum do
            nil ->
              Map.put state.transactions, seqnum, %{ amount: amount, from: from, to: to }

            t -> # already logged - check transaction
              if amount != t.amount or from != t.from or to != t.to do
                IO.puts " ** error db #{db_num}.#{done} [#{amount},#{from},#{to}] " <>
                  "= log #{done}/#{Map.size state.transactions} [#{t.amount},#{t.from},#{t.to}]"
                System.halt
              end
              state.transactions
          end # case

          updates = Map.put state.updates, db_num, seqnum
          dbs = Map.put state.dbs, db_num, db
          next %{ state | updates: updates, transactions: transactions,
                  dbs: dbs }

      { :client_request, server_num } ->  # requests by replica
        seen = Map.get state.requests, server_num, 0
        requests = Map.put state.requests, server_num, seen + 1
        next %{ state | requests: requests }

      :print ->
        clock = state.clock + state.config.print_after

        if !state.config.silent do
          print_stats clock, state.updates, state.requests
        end

        if Map.size(state.clients) === state.config.n_clients do
          total_messages = Enum.sum(for { _, sent } <- state.clients, do: sent)

          halt = Enum.all?(
            (for { _, num_updates } <- state.updates, do:
              num_updates === total_messages),
            fn(x) -> x end
          )

          if halt do
            print_stats clock, state.updates, state.requests
            print_db state.dbs
            send state.paxos, :success
            if state.config.setup === :'docker' do
              for pid <- state.keep_alive, do:
                send pid, :kill
            end
          end
        end

        Process.send_after self(), :print, state.config.print_after
        next %{ state | clock: clock }

      _ ->
        IO.puts "monitor: unexpected message"
        System.halt
    end # receive
  end # next

  defp print_stats clock, updates, requests do
    sorted = updates |> Map.to_list |> List.keysort(0)
    IO.puts "\ntime = #{clock}  updates done = #{inspect sorted}"
    sorted = requests |> Map.to_list |> List.keysort(0)
    IO.puts "time = #{clock} requests seen = #{inspect sorted}"
  end

  defp print_db dbs do
    sorted_dbs = dbs |> Map.to_list |> List.keysort(0)
    for { num, balances } <- sorted_dbs do
      IO.puts "-------------------------------"
      IO.puts "Database Number #{num}"
      IO.puts "-------------------------------"

      sorted_balances = balances |> Map.to_list |> List.keysort(0)
      for { account, balance } <- sorted_balances, do:
        IO.puts "Account ##{account}:\t#{balance}"

    end
    IO.puts "-------------------------------"
  end

end # Monitor
