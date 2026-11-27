type t =
  | Off
  | Disabled of string
  | Ready of { policy : Candle_config.policy; balance : Candle_balance.t; events : Candle_event.t list }

let read ~now ~base_path =
  match Candle_status.observed_view ~now ~base_path with
  | Ok view -> Ready {policy=view.policy;balance=view.balance;events=view.events}
  | Error Candle_status.Off -> Off
  | Error (Candle_status.Disabled reason) -> Disabled reason
  | Error ((Candle_status.Invalid_time _ | Candle_status.Invalid_ledger _
      | Candle_status.Ledger_unavailable _) as error) ->
      Disabled (Candle_status.error_to_string error)

let summary = function
  | Off -> Candle_observation.Off
  | Disabled reason -> Candle_observation.Disabled {reason}
  | Ready { balance; _ } -> Candle_observation.Ready (Candle_balance.supply balance)

(* Folded on demand from the same events: only the gate roster carries it,
   and other readers do not pay for a second fold. *)
let decay_basis = function
  | Off | Disabled _ -> None
  | Ready { events; _ } ->
      Some (Result.map_error Candle_balance.error_to_string (Candle_decay_basis.of_events events))

let balance observation ~keeper = match observation with
  | Off | Disabled _ -> None
  | Ready { balance; _ } -> Some (string_of_int (Candle_balance.balance balance ~keeper))

let equipment observation ~keeper = match observation with
  | Off -> Ok (Keeper_portrait_look.equipment_of_name keeper)
  | Disabled reason -> Error ("Candle is disabled: " ^ reason)
  | Ready { balance; _ } -> Ok (Candle_balance.equipment balance ~keeper)

let disabled_account_revision reason =
  Agent_core_sha256.(digest_string ("disabled\000" ^ reason) |> to_hex)

let event_may_affect_account_revision (event : Candle_event.t) =
  match event.body with
  | Candle_event.Half_life_set _
  | Candle_event.Paid _
  | Candle_event.Purchased _
  | Candle_event.Granted _
  | Candle_event.Gifted _
  | Candle_event.Gifted_item _
  | Candle_event.Equipped _ -> true
  | Candle_event.Snapshot _
  | Candle_event.Payout_owed _
  | Candle_event.Candidates _ | Candle_event.Candidates_fenced _
  | Candle_event.Candidate_window_held _ | Candle_event.Candidate_window_released _
  | Candle_event.Unattributed _
  | Candle_event.Payout_failed _ -> false

type touched =
  | Every_keeper
  | Keepers of string list

(* The same Keepers [event_is_relevant_to_keeper] answers true for, listed. *)
let event_touches (event : Candle_event.t) =
  match event.body with
  | Candle_event.Half_life_set _ -> Every_keeper
  | Candle_event.Paid payment ->
    Keepers (List.map (fun (allocation : Candle_payment.allocation) -> allocation.keeper)
               payment.allocations)
  | Candle_event.Purchased purchase -> Keepers [ purchase.keeper ]
  | Candle_event.Granted granted -> Keepers [ granted.keeper ]
  | Candle_event.Gifted gift -> Keepers [ gift.from_keeper; gift.to_keeper ]
  | Candle_event.Gifted_item gift -> Keepers [ gift.from_keeper; gift.to_keeper ]
  | Candle_event.Equipped choice -> Keepers [ choice.keeper ]
  | Candle_event.Snapshot _
  | Candle_event.Payout_owed _
  | Candle_event.Candidates _ | Candle_event.Candidates_fenced _
  | Candle_event.Candidate_window_held _ | Candle_event.Candidate_window_released _
  | Candle_event.Unattributed _
  | Candle_event.Payout_failed _ -> Keepers []

let keepers_touched events =
  List.fold_left
    (fun touched event ->
       match touched, event_touches event with
       | Every_keeper, (Every_keeper | Keepers _) | Keepers _, Every_keeper -> Every_keeper
       | Keepers held, Keepers more -> Keepers (more @ held))
    (Keepers []) events
  |> function
  | Every_keeper -> Every_keeper
  | Keepers keepers -> Keepers (List.sort_uniq String.compare keepers)

type cached_revision_table = {
  rev_events : Candle_event.t list;
  rev_policy : Candle_config.policy;
  rev_balance : Candle_balance.t;
  rev_total_supply_milli : Z.t;
  rev_active_keepers : int;
  rev_mu : Stdlib.Mutex.t;
  rev_by_keeper : (string, string) Hashtbl.t;
  rev_compute : keeper:string -> string;
}

let revision_table_cache_mu = Stdlib.Mutex.create ()
let revision_table_cache : cached_revision_table list ref = ref []
let revision_table_cache_max = 8
let revision_per_keeper_cache_max = 512

let lookup_memoized_revision (table : cached_revision_table) ~keeper =
  match
    Stdlib.Mutex.protect table.rev_mu (fun () ->
      Hashtbl.find_opt table.rev_by_keeper keeper)
  with
  | Some digest -> digest
  | None ->
    let digest = table.rev_compute ~keeper in
    Stdlib.Mutex.protect table.rev_mu (fun () ->
      if Hashtbl.length table.rev_by_keeper >= revision_per_keeper_cache_max
         && not (Hashtbl.mem table.rev_by_keeper keeper)
      then Hashtbl.clear table.rev_by_keeper;
      Hashtbl.replace table.rev_by_keeper keeper digest);
    digest

let ready_account_revision_reader ~events ~policy ~balance =
  let min_active_balance_milli =
    Candle_config.min_active_balance_milli policy.Candle_config.pricing
  in
  let summary =
    Candle_balance.supply_summary ~min_active_balance_milli balance
  in
  let matches (entry : cached_revision_table) =
    entry.rev_events == events
    && Candle_balance.same_owned entry.rev_balance balance
    && Z.equal entry.rev_total_supply_milli summary.total_supply_milli
    && Int.equal entry.rev_active_keepers summary.active_keepers
    && (entry.rev_policy == policy || entry.rev_policy = policy)
  in
  let cached =
    Stdlib.Mutex.protect revision_table_cache_mu (fun () ->
      List.find_opt matches !revision_table_cache)
  in
  match cached with
  | Some table -> lookup_memoized_revision table
  | None ->
    let global_events_rev = ref [] in
    let per_keeper_rev : (string, (int * Yojson.Safe.t) list) Hashtbl.t = Hashtbl.create 32 in
    let idx = ref 0 in
    List.iter
      (fun event ->
         if event_may_affect_account_revision event then begin
           let i = !idx in
           idx := i + 1;
           let json = Candle_event.to_yojson event in
           match event_touches event with
           | Every_keeper -> global_events_rev := (i, json) :: !global_events_rev
           | Keepers keepers ->
             let rec add_unique seen = function
               | [] -> ()
               | keeper :: rest ->
                 if List.mem keeper seen then add_unique seen rest
                 else begin
                   let prev = Option.value ~default:[] (Hashtbl.find_opt per_keeper_rev keeper) in
                   Hashtbl.replace per_keeper_rev keeper ((i, json) :: prev);
                   add_unique (keeper :: seen) rest
                 end
             in
             add_unique [] keepers
         end)
      events;
    let global_events = List.rev !global_events_rev in
    let merge_indexed_rev a b =
      let rec loop acc xs ys =
        match xs, ys with
        | [], rest | rest, [] -> List.rev_append acc (List.map snd rest)
        | (ia, ja) :: xs', (ib, jb) :: ys' ->
          if ia <= ib then loop (ja :: acc) xs' ys else loop (jb :: acc) xs ys'
      in
      loop [] a b
    in
    let half_life = match policy.Candle_config.half_life with
      | Candle_decay.Off -> `String "off"
      | Candle_decay.Hours hours -> `Int hours in
    let pricing_tail = match policy.Candle_config.pricing with
      | Candle_config.Fixed -> []
      | Candle_config.Supply_scaled p ->
        [ `Assoc
            [ "mode", `String "supply_scaled"
            ; "target_per_keeper_milli", `Int p.target_per_keeper_milli
            ; "min_permille", `Int p.min_permille
            ; "max_permille", `Int p.max_permille
            ; ( "rounding"
              , `String
                  (match p.rounding with
                   | Candle_math.Floor -> "down"
                   | Candle_math.Ceil -> "up") )
            ] ] in
    let catalog = Keeper_portrait_item.all |> List.map (fun item ->
      let price =
        match
          Candle_config.effective_price
            policy
            ~total_supply_milli:summary.total_supply_milli
            ~active_keepers:summary.active_keepers
            item
        with
        | Candle_config.Unpriced -> `Null
        | Candle_config.Priced amount -> `String (string_of_int amount)
      in
      `List [`String (Keeper_portrait_item.id item); price]) in
    let rev_compute ~keeper =
      let keeper_events =
        match Hashtbl.find_opt per_keeper_rev keeper with
        | None -> []
        | Some rev -> List.rev rev
      in
      let facts =
        match global_events, keeper_events with
        | [], ks -> List.map snd ks
        | gs, [] -> List.map snd gs
        | gs, ks -> merge_indexed_rev gs ks
      in
      let owned =
        Candle_balance.owned balance ~keeper
        |> List.map (fun item -> `String (Keeper_portrait_item.id item))
      in
      let account =
        `List ([ half_life; `List facts; `List owned; `List catalog ] @ pricing_tail)
      in
      Agent_core_sha256.(digest_string ("ready\000" ^ Yojson.Safe.to_string account) |> to_hex)
    in
    let table =
      { rev_events = events
      ; rev_policy = policy
      ; rev_balance = balance
      ; rev_total_supply_milli = summary.total_supply_milli
      ; rev_active_keepers = summary.active_keepers
      ; rev_mu = Stdlib.Mutex.create ()
      ; rev_by_keeper = Hashtbl.create 32
      ; rev_compute
      }
    in
    Stdlib.Mutex.protect revision_table_cache_mu (fun () ->
      let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | entry :: rest ->
          if matches entry then take n acc rest
          else take (n - 1) (entry :: acc) rest
      in
      revision_table_cache := table :: take (revision_table_cache_max - 1) [] !revision_table_cache);
    lookup_memoized_revision table

let ready_account_revision ~events ~policy ~balance ~keeper =
  ready_account_revision_reader ~events ~policy ~balance ~keeper

let account_revision_reader = function
  | Off -> (fun ~keeper:_ -> None)
  | Disabled reason ->
      let rev = Some (disabled_account_revision reason) in
      (fun ~keeper:_ -> rev)
  | Ready { policy; balance; events } ->
      let reader = ready_account_revision_reader ~events ~policy ~balance in
      (fun ~keeper -> Some (reader ~keeper))

let account_revision observation ~keeper =
  account_revision_reader observation ~keeper
