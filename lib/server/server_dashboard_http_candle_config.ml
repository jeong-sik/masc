module Http = Http_server_eio
module Env = Server_dashboard_http_v2_envelope
module Registry = Keeper_runtime_setting_registry
module Sandbox_profile = Keeper_types_profile_sandbox

let error_result ?field ?extra code message =
  Error (Env.error_status code, Env.error_json ?field ?extra ~code message)
;;

(* ================================================================ *)
(* 4A. Fleet Candle Ledger (GET /api/v1/candle/ledger)              *)
(* ================================================================ *)

let candle_time_of_float now =
  match Ptime.of_float_s now with
  | Some pt -> Candle_time.of_ptime pt
  | None -> Candle_time.of_ptime Ptime.epoch
;;

let float_of_candle_time ct = Ptime.to_float_s (Candle_time.to_ptime ct)

let half_life_to_json = function
  | Candle_decay.Off ->
    `Assoc [ "mode", `String "off"; "half_life_hours", `Null; "half_life_sec", `Null ]
  | Candle_decay.Hours h ->
    `Assoc
      [ "mode", `String "decay"
      ; "half_life_hours", `Int h
      ; "half_life_sec", `Float (float_of_int (h * 3600))
      ]
;;

let equipment_to_json eq =
  `Assoc
    (List.map
       (fun slot ->
          let item_json =
            match Keeper_portrait_item.in_slot eq slot with
            | Some item -> `String (Keeper_portrait_item.id item)
            | None -> `Null
          in
          Keeper_portrait_item.slot_id slot, item_json)
       Keeper_portrait_item.slots)
;;

let unattributed_reason_label = function
  | Candle_event.No_candidates -> "no_candidates"
  | Candle_event.All_unrelated _ -> "all_unrelated"
  | Candle_event.No_related_keepers _ -> "no_related_keepers"
  | Candle_event.Window_released -> "window_released"
;;

let diagnostic_hint_for_unattributed ~linked_task_count = function
  | Candle_event.No_candidates ->
    if linked_task_count = 0
    then
      "0 tasks linked to this Goal in backlog; link tasks via goal_id to enable payout attribution."
    else
      Printf.sprintf
        "%d linked task(s) exist, but none were completed by an eligible Keeper inside the attribution window."
        linked_task_count
  | Candle_event.All_unrelated _ ->
    "Appraiser judged all candidate tasks unrelated to the Goal's success measure."
  | Candle_event.No_related_keepers _ ->
    "Related tasks had no eligible Keeper assignee."
  | Candle_event.Window_released ->
    "Held candidate window was released by operator while linked-task ambiguity remained."
;;

type goal_snapshot_info =
  { title : string
  ; linked_task_count : int
  }

type candidate_info =
  { fenced : bool
  ; candidate_task_count : int
  ; candidate_keeper_count : int
  }

let candle_ledger_json ?(now = Time_compat.now ()) ?(limit = 100) ?keeper ~base_path () =
  let limit = Server_utils.clamp ~min_v:1 ~max_v:500 limit in
  let cfg = Candle_config.load ~base_path in
  let config_state, disabled_reason, cfg_half_life, pricing_mode =
    match cfg with
    | Candle_config.Off -> "off", None, None, "off"
    | Candle_config.Disabled { reason } -> "disabled", Some reason, None, "disabled"
    | Candle_config.Enabled policy ->
      let pricing =
        match policy.pricing with
        | Candle_config.Fixed -> "fixed"
        | Candle_config.Supply_scaled _ -> "supply_scaled"
      in
      "enabled", None, Some policy.half_life, pricing
  in
  match Candle_ledger.read ~base_path with
  | Error read_err ->
    error_result Env.Store_unavailable (Candle_ledger.read_error_to_string read_err)
  | Ok view ->
    let events = Candle_ledger.events view in
    let ledger_state = if Candle_ledger.is_missing view then "missing" else "present" in
    let at = candle_time_of_float now in
    let balance_res = Candle_balance.of_events ~at events in
    let effective_half_life =
      match balance_res with
      | Ok bal ->
        (match Candle_balance.half_life bal with
         | Some hl -> Some hl
         | None -> cfg_half_life)
      | Error _ -> cfg_half_life
    in
    let policy_json =
      `Assoc
        [ "configuration", `String config_state
        ; "disabled_reason", Json_util.string_opt_to_json disabled_reason
        ; "pricing_mode", `String pricing_mode
        ; ( "half_life"
          , match effective_half_life with
            | Some hl -> half_life_to_json hl
            | None -> half_life_to_json Candle_decay.Off )
        ; ( "half_life_sec"
          , match effective_half_life with
            | Some (Candle_decay.Hours h) -> `Float (float_of_int (h * 3600))
            | Some Candle_decay.Off | None -> `Null )
        ]
    in
    let supply_json, balances_json, balance_error =
      match balance_res with
      | Error err ->
        ( `Assoc
            [ "issued_milli", `String "0"
            ; "burned_milli", `String "0"
            ; "circulating_milli", `String "0"
            ; "total_supply_milli", `String "0"
            ; "active_keepers", `Int 0
            ]
        , []
        , Some (Candle_balance.error_to_string err) )
      | Ok bal ->
        let supply = Candle_balance.supply bal in
        let summary = Candle_balance.supply_summary bal in
        let keepers_seen = Hashtbl.create 32 in
        List.iter
          (fun (k, _, _) -> Hashtbl.replace keepers_seen k ())
          (Candle_balance.decaying_balances bal);
        List.iter
          (fun (ev : Candle_event.t) ->
             match ev.body with
             | Candle_event.Paid p ->
               List.iter
                 (fun (a : Candle_payment.allocation) ->
                    Hashtbl.replace keepers_seen a.keeper ())
                 p.allocations
             | Candle_event.Purchased { keeper = k; _ }
             | Candle_event.Granted { keeper = k; _ }
             | Candle_event.Equipped { keeper = k; _ } ->
               Hashtbl.replace keepers_seen k ()
             | Candle_event.Gifted { from_keeper; to_keeper; _ }
             | Candle_event.Gifted_item { from_keeper; to_keeper; _ } ->
               Hashtbl.replace keepers_seen from_keeper ();
               Hashtbl.replace keepers_seen to_keeper ()
             | Candle_event.Half_life_set _
             | Candle_event.Snapshot _
             | Candle_event.Payout_owed _
             | Candle_event.Candidates _
             | Candle_event.Candidates_fenced _
             | Candle_event.Candidate_window_held _
             | Candle_event.Candidate_window_released _
             | Candle_event.Unattributed _
             | Candle_event.Payout_failed _ -> ())
          events;
        let rows =
          Hashtbl.fold (fun k () acc -> k :: acc) keepers_seen []
          |> List.filter (fun k ->
               match keeper with
               | None -> true
               | Some wanted -> String.equal k wanted)
          |> List.map (fun k ->
               let bal_m = Candle_balance.balance bal ~keeper:k in
               let dec_m = Candle_balance.decayed_milli bal ~keeper:k in
               let last_at =
                 Candle_balance.last_event_at bal ~keeper:k
                 |> Option.map float_of_candle_time
               in
               let owned =
                 Candle_balance.owned bal ~keeper:k
                 |> List.map (fun item -> `String (Keeper_portrait_item.id item))
               in
               let equipped =
                 equipment_to_json (Candle_balance.equipment bal ~keeper:k)
               in
               ( bal_m
               , k
               , `Assoc
                   [ "keeper", `String k
                   ; "balance_milli", `Int bal_m
                   ; "decayed_milli", `String (Z.to_string dec_m)
                   ; "last_event_unix", Json_util.float_opt_to_json last_at
                   ; "owned_items", `List owned
                   ; "equipped", equipped
                   ] ))
          |> List.sort (fun (ba, ka, _) (bb, kb, _) ->
               let c = Int.compare bb ba in
               if c <> 0 then c else String.compare ka kb)
          |> List.map (fun (_, _, j) -> j)
        in
        ( `Assoc
            [ "issued_milli", `String supply.issued_milli
            ; "burned_milli", `String supply.burned_milli
            ; "circulating_milli", `String supply.circulating_milli
            ; "total_supply_milli", `String (Z.to_string summary.total_supply_milli)
            ; "active_keepers", `Int summary.active_keepers
            ]
        , rows
        , None )
    in
    (* Correlate Snapshot, Candidates/Candidates_fenced, Held, Unattributed *)
    let snapshots_tbl : (string * string * string, goal_snapshot_info) Hashtbl.t =
      Hashtbl.create 16
    in
    let candidates_tbl : (string * string * string, candidate_info) Hashtbl.t =
      Hashtbl.create 16
    in
    let unattributed_count = ref 0 in
    let backlog_fenced_count = ref 0 in
    let zero_linked_goals = ref 0 in
    let held_windows_count = ref 0 in
    let diagnostic_items = ref [] in
    List.iter
      (fun (ev : Candle_event.t) ->
         match ev.body with
         | Candle_event.Snapshot s ->
           let linked_task_count = List.length s.linked_task_ids in
           if linked_task_count = 0 then incr zero_linked_goals;
           Hashtbl.replace
             snapshots_tbl
             (s.goal_id, s.request_id, s.verification_run_id)
             { title = s.title; linked_task_count }
         | Candle_event.Candidates c ->
           Hashtbl.replace
             candidates_tbl
             (c.goal_id, c.request_id, c.verification_run_id)
             { fenced = false
             ; candidate_task_count = List.length c.candidate_task_ids
             ; candidate_keeper_count = List.length c.candidate_keepers
             }
         | Candle_event.Candidates_fenced c ->
           incr backlog_fenced_count;
           Hashtbl.replace
             candidates_tbl
             (c.goal_id, c.request_id, c.verification_run_id)
             { fenced = true
             ; candidate_task_count = List.length c.candidate_task_ids
             ; candidate_keeper_count = List.length c.candidate_keepers
             }
         | Candle_event.Candidate_window_held h ->
           incr held_windows_count;
           let key = h.goal_id, h.request_id, h.verification_run_id in
           let title, linked_cnt =
             match Hashtbl.find_opt snapshots_tbl key with
             | Some s -> Some s.title, s.linked_task_count
             | None -> None, List.length h.tasks
           in
           diagnostic_items
           := `Assoc
                [ "goal_id", `String h.goal_id
                ; "title", Json_util.string_opt_to_json title
                ; "kind", `String "candidate_window_held"
                ; "observation", `String "held_for_operator_release"
                ; "linked_task_count", `Int linked_cnt
                ; "at_unix", `Float (float_of_candle_time ev.at)
                ; ( "diagnostic_hint"
                  , `String
                      "Linked task ordering or status was ambiguous; inspect goal candle detail or release hold." )
                ]
              :: !diagnostic_items
         | Candle_event.Unattributed u ->
           incr unattributed_count;
           let key = u.goal_id, u.request_id, u.verification_run_id in
           let title, linked_cnt =
             match Hashtbl.find_opt snapshots_tbl key with
             | Some s -> Some s.title, s.linked_task_count
             | None -> None, 0
           in
           let cand = Hashtbl.find_opt candidates_tbl key in
           let observation =
             match cand with
             | Some { fenced = true; _ } -> "backlog_fenced"
             | Some { fenced = false; _ } -> "candidates_observed"
             | None -> "no_candidates_record"
           in
           let cand_tasks =
             match cand with
             | Some c -> c.candidate_task_count
             | None -> 0
           in
           let cand_keepers =
             match cand with
             | Some c -> c.candidate_keeper_count
             | None -> 0
           in
           let hint =
             diagnostic_hint_for_unattributed ~linked_task_count:linked_cnt u.reason
           in
           diagnostic_items
           := `Assoc
                [ "goal_id", `String u.goal_id
                ; "title", Json_util.string_opt_to_json title
                ; "kind", `String "unattributed"
                ; "reason", `String (unattributed_reason_label u.reason)
                ; "observation", `String observation
                ; "linked_task_count", `Int linked_cnt
                ; "candidate_task_count", `Int cand_tasks
                ; "candidate_keeper_count", `Int cand_keepers
                ; "at_unix", `Float (float_of_candle_time ev.at)
                ; "diagnostic_hint", `String hint
                ]
              :: !diagnostic_items
         | Candle_event.Half_life_set _
         | Candle_event.Payout_owed _
         | Candle_event.Candidate_window_released _
         | Candle_event.Paid _
         | Candle_event.Purchased _
         | Candle_event.Granted _
         | Candle_event.Gifted _
         | Candle_event.Gifted_item _
         | Candle_event.Equipped _
         | Candle_event.Payout_failed _ -> ())
      events;
    let indexed_events =
      events
      |> List.mapi (fun idx ev -> idx + 1, ev)
      |> List.rev
      |> Server_utils.take limit
      |> List.map (fun (seq, (ev : Candle_event.t)) ->
           let base =
             [ "seq", `Int seq
             ; "at_unix", `Float (float_of_candle_time ev.at)
             ; "at_rfc3339", `String (Candle_time.to_rfc3339 ev.at)
             ; "kind", `String (Candle_event.kind ev.body)
             ]
           in
           let extra =
             match ev.body with
             | Candle_event.Candidates_fenced c ->
               [ "goal_id", `String c.goal_id
               ; "observation", `String "backlog_fenced"
               ; "candidate_task_count", `Int (List.length c.candidate_task_ids)
               ; "candidate_keeper_count", `Int (List.length c.candidate_keepers)
               ]
             | Candle_event.Candidates c ->
               [ "goal_id", `String c.goal_id
               ; "observation", `String "candidates"
               ; "candidate_task_count", `Int (List.length c.candidate_task_ids)
               ; "candidate_keeper_count", `Int (List.length c.candidate_keepers)
               ]
             | Candle_event.Unattributed u ->
               let key = u.goal_id, u.request_id, u.verification_run_id in
               let linked_cnt =
                 match Hashtbl.find_opt snapshots_tbl key with
                 | Some s -> s.linked_task_count
                 | None -> 0
               in
               let obs =
                 match Hashtbl.find_opt candidates_tbl key with
                 | Some { fenced = true; _ } -> "backlog_fenced"
                 | Some { fenced = false; _ } -> "candidates"
                 | None -> "unattributed"
               in
               [ "goal_id", `String u.goal_id
               ; "reason", `String (unattributed_reason_label u.reason)
               ; "observation", `String obs
               ; ( "diagnostic_hint"
                 , `String
                     (diagnostic_hint_for_unattributed
                        ~linked_task_count:linked_cnt
                        u.reason) )
               ]
             | Candle_event.Snapshot s ->
               [ "goal_id", `String s.goal_id
               ; "title", `String s.title
               ; "linked_task_count", `Int (List.length s.linked_task_ids)
               ]
             | Candle_event.Payout_owed p -> [ "goal_id", `String p.goal_id ]
             | Candle_event.Candidate_window_held h ->
               [ "goal_id", `String h.goal_id
               ; "task_count", `Int (List.length h.tasks)
               ]
             | Candle_event.Candidate_window_released r ->
               [ "goal_id", `String r.goal_id ]
             | Candle_event.Paid p ->
               [ "goal_id", `String p.identity.goal_id
               ; "total_milli", `Int p.total_milli
               ; ( "allocations"
                 , `List
                     (List.map
                        (fun (a : Candle_payment.allocation) ->
                           `Assoc
                             [ "keeper", `String a.keeper
                             ; "amount_milli", `Int a.amount_milli
                             ; "weight", `Int a.weight
                             ])
                        p.allocations) )
               ]
             | Candle_event.Purchased p ->
               [ "keeper", `String p.keeper
               ; "item", `String (Keeper_portrait_item.id p.item)
               ; "amount_milli", `Int p.amount_milli
               ]
             | Candle_event.Granted g ->
               [ "keeper", `String g.keeper
               ; "amount_milli", `Int g.amount_milli
               ; "reason", `String g.reason
               ]
             | Candle_event.Gifted g ->
               [ "from_keeper", `String g.from_keeper
               ; "to_keeper", `String g.to_keeper
               ; "amount_milli", `Int g.amount_milli
               ; "reason", `String g.reason
               ]
             | Candle_event.Gifted_item g ->
               [ "from_keeper", `String g.from_keeper
               ; "to_keeper", `String g.to_keeper
               ; "item", `String (Keeper_portrait_item.id g.item)
               ]
             | Candle_event.Equipped e ->
               [ "keeper", `String e.keeper
               ; "slot", `String (Keeper_portrait_item.slot_id e.slot)
               ; ( "choice"
                 , match e.choice with
                   | Candle_event.Default -> `String "default"
                   | Candle_event.Item item -> `String (Keeper_portrait_item.id item) )
               ]
             | Candle_event.Half_life_set hl -> [ "half_life", half_life_to_json hl ]
             | Candle_event.Payout_failed f ->
               [ "goal_id", `String f.goal_id; "due_date", `String f.due_date ]
           in
           `Assoc (base @ extra))
    in
    let data =
      `Assoc
        [ "ledger_state", `String ledger_state
        ; "total_events", `Int (List.length events)
        ; "balance_error", Json_util.string_opt_to_json balance_error
        ; "policy", policy_json
        ; "supply", supply_json
        ; "balances", `List balances_json
        ; ( "diagnostics"
          , `Assoc
              [ "unattributed_count", `Int !unattributed_count
              ; "backlog_fenced_count", `Int !backlog_fenced_count
              ; "zero_linked_tasks_goals", `Int !zero_linked_goals
              ; "held_windows_count", `Int !held_windows_count
              ; "items", `List !diagnostic_items
              ] )
        ; "recent_events", `List indexed_events
        ]
    in
    Ok (Env.ok ~now data)
;;

(* ================================================================ *)
(* 4B. Categorized TOML Schema & Atomic Patch API                   *)
(* ================================================================ *)

type config_target =
  | Target_runtime
  | Target_keeper of string
  | Target_keeper_create

type config_category =
  | Cat_runtime_providers
  | Cat_routing_failover
  | Cat_keepers_autonomy
  | Cat_sandbox_infra
  | Cat_memory_knowledge
  | Cat_economy_connectors
  | Cat_observability_ops

let all_config_categories =
  [ Cat_runtime_providers
  ; Cat_routing_failover
  ; Cat_keepers_autonomy
  ; Cat_sandbox_infra
  ; Cat_memory_knowledge
  ; Cat_economy_connectors
  ; Cat_observability_ops
  ]
;;

let config_category_to_string = function
  | Cat_runtime_providers -> "runtime_providers"
  | Cat_routing_failover -> "routing_failover"
  | Cat_keepers_autonomy -> "keepers_autonomy"
  | Cat_sandbox_infra -> "sandbox_infra"
  | Cat_memory_knowledge -> "memory_knowledge"
  | Cat_economy_connectors -> "economy_connectors"
  | Cat_observability_ops -> "observability_ops"
;;

let config_category_title = function
  | Cat_runtime_providers -> "Providers & Models"
  | Cat_routing_failover -> "Routing & Failover Lanes"
  | Cat_keepers_autonomy -> "Keepers & Autonomy"
  | Cat_sandbox_infra -> "Sandbox, microVM & SSH"
  | Cat_memory_knowledge -> "Board, Memory & Candle"
  | Cat_economy_connectors -> "Voice & Integrations"
  | Cat_observability_ops -> "General, UI & Observability"
;;

let category_of_registry_category : Registry.category -> config_category = function
  | Registry.Turn | Registry.Bootstrap | Registry.Lifecycle | Registry.Heartbeat ->
    Cat_keepers_autonomy
  | Registry.Sandbox | Registry.Transport -> Cat_sandbox_infra
  | Registry.Memory | Registry.Web_search -> Cat_memory_knowledge
  | Registry.Media -> Cat_economy_connectors
  | Registry.Diagnostics | Registry.Supervisor | Registry.Metrics | Registry.Otel ->
    Cat_observability_ops
;;

type provenance =
  | Prov_default
  | Prov_global
  | Prov_project
  | Prov_keeper
  | Prov_env_override

let provenance_to_string = function
  | Prov_default -> "default"
  | Prov_global -> "global"
  | Prov_project -> "project"
  | Prov_keeper -> "keeper"
  | Prov_env_override -> "env_override"
;;

type reload_scope =
  | Hot_reload
  | Next_turn
  | Restart_required

let reload_scope_to_string = function
  | Hot_reload -> "hot_reload"
  | Next_turn -> "next_turn"
  | Restart_required -> "restart_required"
;;

let max_reload_scope a b =
  match a, b with
  | Restart_required, _ | _, Restart_required -> Restart_required
  | Next_turn, _ | _, Next_turn -> Next_turn
  | Hot_reload, Hot_reload -> Hot_reload
;;

let reload_scope_of_registry = function
  | Registry.Next_turn -> Next_turn
  | Registry.Process_restart -> Restart_required
;;

let strip_toml_quotes (s : string) : string =
  let t = String.trim s in
  let len = String.length t in
  if len >= 2
     && ((t.[0] = '"' && t.[len - 1] = '"') || (t.[0] = '\'' && t.[len - 1] = '\''))
  then String.sub t 1 (len - 2)
  else t
;;

let split_dotted_key_segments (raw : string) : string list =
  let len = String.length raw in
  let buf = Buffer.create len in
  let acc = ref [] in
  let in_dq = ref false in
  let in_sq = ref false in
  let escaped = ref false in
  for i = 0 to len - 1 do
    let c = raw.[i] in
    if !escaped
    then (
      Buffer.add_char buf c;
      escaped := false)
    else if !in_dq
    then (
      Buffer.add_char buf c;
      if c = '\\' then escaped := true else if c = '"' then in_dq := false)
    else if !in_sq
    then (
      Buffer.add_char buf c;
      if c = '\'' then in_sq := false)
    else (
      match c with
      | '"' ->
        in_dq := true;
        Buffer.add_char buf c
      | '\'' ->
        in_sq := true;
        Buffer.add_char buf c
      | '.' ->
        acc := Buffer.contents buf :: !acc;
        Buffer.clear buf
      | _ -> Buffer.add_char buf c)
  done;
  acc := Buffer.contents buf :: !acc;
  List.rev !acc
;;

let split_identifier_words (s : string) : string list =
  String.split_on_char '-' s
  |> List.concat_map (String.split_on_char '_')
  |> List.filter (fun seg -> not (String.equal seg ""))
;;

let normalize_key_separators (s : string) : string =
  String.map (function '-' -> '_' | c -> c) s
;;

(* Non-secret configuration keys whose name happens to include the word [key]. *)
let safe_non_secret_key_names =
  [ "primary_key"
  ; "sort_key"
  ; "foreign_key"
  ; "partition_key"
  ; "cache_key"
  ; "routing_key"
  ; "group_key"
  ; "sharding_key"
  ; "idempotency_key"
  ; "dedup_key"
  ; "label_key"
  ; "tag_key"
  ; "metric_key"
  ; "full_key"
  ; "table_key"
  ; "key_name"
  ; "key_type"
  ; "key_id"
  ; "public_key"
  ]
;;

let is_secret_key raw_key =
  let segments = split_dotted_key_segments raw_key in
  let leaf =
    match List.rev segments with
    | last :: _ -> strip_toml_quotes last
    | [] -> strip_toml_quotes raw_key
  in
  let lc = String.lowercase_ascii (String.trim leaf) in
  if String.ends_with ~suffix:"_env" lc
     || String.ends_with ~suffix:"-env" lc
     || String.ends_with ~suffix:"_file" lc
     || String.ends_with ~suffix:"-file" lc
     || String.ends_with ~suffix:"_path" lc
     || String.ends_with ~suffix:"-path" lc
  then false
  else (
    let words = split_identifier_words lc in
    let norm = normalize_key_separators lc in
    let has_secret_key_word =
      (List.mem "key" words || List.mem "apikey" words || List.mem "passkey" words)
      && not (List.mem norm safe_non_secret_key_names)
    in
    let has_secret_session =
      String.equal lc "session"
      || String.starts_with ~prefix:"x-session" lc
      || String.starts_with ~prefix:"x_session" lc
      || String.ends_with ~suffix:"_session" lc
      || String.ends_with ~suffix:"-session" lc
      || List.mem norm
           [ "session_id"
           ; "session_key"
           ; "session_token"
           ; "session_secret"
           ; "session_cookie"
           ]
    in
    Secret_patterns.is_sensitive_key lc
    || String_util.contains_substring lc "api_key"
    || String_util.contains_substring lc "api-key"
    || String_util.contains_substring lc "secret"
    || String_util.contains_substring lc "password"
    || String_util.contains_substring lc "passwd"
    || String_util.contains_substring lc "token"
    || String_util.contains_substring lc "private_key"
    || String_util.contains_substring lc "private-key"
    || String_util.contains_substring lc "credential"
    || String_util.contains_substring lc "authorization"
    || String_util.contains_substring lc "cookie"
    || String_util.contains_substring lc "hmac"
    || List.mem "auth" words
    || List.mem "authn" words
    || List.mem "authz" words
    || List.mem "sig" words
    || List.mem "signature" words
    || has_secret_key_word
    || has_secret_session
    || String.equal lc "pat"
    || String.ends_with ~suffix:"_pat" lc
    || String.ends_with ~suffix:"-pat" lc
    || String.equal lc "bearer")
;;

(* Redact secret query-string parameters ([?key=...], [&token=...], [?api_key=...],
   etc.) while preserving the parameter name and URL structure. Compiled once at
   module init; [Re] is thread-safe across Eio fibers and domains. *)
let url_query_secret_re =
  let secret_param =
    Re.alt
      [ Re.str "api_key"
      ; Re.str "api-key"
      ; Re.str "apikey"
      ; Re.str "access_key"
      ; Re.str "access-key"
      ; Re.str "access_token"
      ; Re.str "access-token"
      ; Re.str "auth_token"
      ; Re.str "auth-token"
      ; Re.str "refresh_token"
      ; Re.str "refresh-token"
      ; Re.str "id_token"
      ; Re.str "id-token"
      ; Re.str "session_token"
      ; Re.str "session-token"
      ; Re.str "session_id"
      ; Re.str "session-id"
      ; Re.str "bearer_token"
      ; Re.str "bearer-token"
      ; Re.str "signature"
      ; Re.str "password"
      ; Re.str "passwd"
      ; Re.str "secret"
      ; Re.str "session"
      ; Re.str "token"
      ; Re.str "auth"
      ; Re.str "hmac"
      ; Re.str "sig"
      ; Re.str "key"
      ]
  in
  Re.compile
    (Re.seq
       [ Re.group (Re.seq [ Re.set "?&"; Re.no_case secret_param; Re.char '=' ])
       ; Re.rep1 (Re.compl [ Re.set "&# \t\r\n\"'" ])
       ])
;;

let redact_url_query_secrets (text : string) : string =
  if not (String.contains text '?') && not (String.contains text '&')
  then text
  else
    Re.replace
      url_query_secret_re
      ~f:(fun g -> Re.Group.get g 1 ^ "[REDACTED]")
      text
;;

let redact_value_secrets (text : string) : string =
  text |> Secret_patterns.redact_text |> redact_url_query_secrets
;;

let assignment_lhs_of_line (line : string) : (string * int) option =
  let len = String.length line in
  let i = ref 0 in
  while !i < len && (line.[!i] = ' ' || line.[!i] = '\t') do
    incr i
  done;
  if !i >= len || line.[!i] = '#' || line.[!i] = '['
  then None
  else (
    let start = !i in
    let in_dq = ref false in
    let in_sq = ref false in
    let escaped = ref false in
    let found_eq = ref None in
    while !i < len && Option.is_none !found_eq do
      let c = line.[!i] in
      if !escaped
      then escaped := false
      else if !in_dq
      then (if c = '\\' then escaped := true else if c = '"' then in_dq := false)
      else if !in_sq
      then (if c = '\'' then in_sq := false)
      else (
        match c with
        | '"' -> in_dq := true
        | '\'' -> in_sq := true
        | '#' -> i := len
        | '=' -> found_eq := Some !i
        | _ -> ());
      incr i
    done;
    match !found_eq with
    | None -> None
    | Some eq_idx ->
      let lhs = String.sub line start (eq_idx - start) |> String.trim in
      if String.equal lhs "" then None else Some (lhs, eq_idx))
;;

let leading_whitespace (line : string) : string =
  let len = String.length line in
  let i = ref 0 in
  while !i < len && (line.[!i] = ' ' || line.[!i] = '\t') do
    incr i
  done;
  String.sub line 0 !i
;;

(* Redact [secret_key = <value>] entries inside TOML inline tables [{ ... }]. *)
let rec redact_inline_table_secrets (line : string) : string =
  if not (String.contains line '{')
  then line
  else (
    let len = String.length line in
    let out = Buffer.create len in
    let skip_value pos =
      let p = ref pos in
      while !p < len && (line.[!p] = ' ' || line.[!p] = '\t') do
        incr p
      done;
      if !p >= len
      then !p
      else (
        match line.[!p] with
        | '"' ->
          incr p;
          let esc = ref false in
          while !p < len && (!esc || line.[!p] <> '"') do
            if !esc then esc := false else if line.[!p] = '\\' then esc := true;
            incr p
          done;
          if !p < len then incr p;
          !p
        | '\'' ->
          incr p;
          while !p < len && line.[!p] <> '\'' do
            incr p
          done;
          if !p < len then incr p;
          !p
        | '[' | '{' ->
          let close = if line.[!p] = '[' then ']' else '}' in
          let open_c = line.[!p] in
          let depth = ref 1 in
          let in_dq = ref false in
          let in_sq = ref false in
          let esc = ref false in
          incr p;
          while !p < len && !depth > 0 do
            let c = line.[!p] in
            if !esc then esc := false
            else if !in_dq then (if c = '\\' then esc := true else if c = '"' then in_dq := false)
            else if !in_sq then (if c = '\'' then in_sq := false)
            else if c = '"' then in_dq := true
            else if c = '\'' then in_sq := true
            else if c = open_c then incr depth
            else if c = close then decr depth;
            incr p
          done;
          !p
        | _ ->
          while !p < len && line.[!p] <> ',' && line.[!p] <> '}' && line.[!p] <> '#' do
            incr p
          done;
          !p)
    in
    let rec scan i depth in_dq in_sq esc =
      if i >= len
      then ()
      else (
        let c = line.[i] in
        if esc
        then (
          Buffer.add_char out c;
          scan (i + 1) depth in_dq in_sq false)
        else if in_dq
        then (
          Buffer.add_char out c;
          scan (i + 1) depth (c <> '"') false (c = '\\'))
        else if in_sq
        then (
          Buffer.add_char out c;
          scan (i + 1) depth false (c <> '\'') false)
        else if c = '#'
        then Buffer.add_substring out line i (len - i)
        else if c = '"' && depth = 0
        then (
          Buffer.add_char out c;
          scan (i + 1) depth true false false)
        else if c = '\'' && depth = 0
        then (
          Buffer.add_char out c;
          scan (i + 1) depth false true false)
        else if c = '{'
        then (
          Buffer.add_char out c;
          scan_inline_entry (i + 1) (depth + 1))
        else if c = '}' && depth > 0
        then (
          Buffer.add_char out c;
          scan (i + 1) (depth - 1) false false false)
        else (
          Buffer.add_char out c;
          scan (i + 1) depth false false false))
    and scan_inline_entry i depth =
      let p = ref i in
      while !p < len && (line.[!p] = ' ' || line.[!p] = '\t') do
        Buffer.add_char out line.[!p];
        incr p
      done;
      if !p >= len
      then ()
      else if line.[!p] = '}'
      then (
        Buffer.add_char out '}';
        scan (!p + 1) (depth - 1) false false false)
      else (
        (* Read key up to '=' or ',' or '}' *)
        let kstart = !p in
        let in_dq = ref false in
        let in_sq = ref false in
        let esc = ref false in
        while
          !p < len
          && (!in_dq || !in_sq || (line.[!p] <> '=' && line.[!p] <> ',' && line.[!p] <> '}'))
        do
          let c = line.[!p] in
          if !esc then esc := false
          else if !in_dq then (if c = '\\' then esc := true else if c = '"' then in_dq := false)
          else if !in_sq then (if c = '\'' then in_sq := false)
          else if c = '"' then in_dq := true
          else if c = '\'' then in_sq := true;
          incr p
        done;
        let key_raw = String.sub line kstart (!p - kstart) in
        Buffer.add_string out key_raw;
        if !p < len && line.[!p] = '='
        then (
          Buffer.add_char out '=';
          let after_eq = !p + 1 in
          if is_secret_key (String.trim key_raw)
          then (
            Buffer.add_string out " \"[REDACTED]\"";
            let next_i = skip_value after_eq in
            if next_i < len && line.[next_i] = ','
            then (
              Buffer.add_char out ',';
              scan_inline_entry (next_i + 1) depth)
            else if next_i < len && line.[next_i] = '}'
            then (
              Buffer.add_char out '}';
              scan (next_i + 1) (depth - 1) false false false)
            else scan next_i depth false false false)
          else (
            (* Non-secret value: recursively scan so nested inline tables are also checked *)
            let v_end = skip_value after_eq in
            let v_slice = String.sub line after_eq (v_end - after_eq) in
            Buffer.add_string out (redact_inline_table_secrets v_slice);
            if v_end < len && line.[v_end] = ','
            then (
              Buffer.add_char out ',';
              scan_inline_entry (v_end + 1) depth)
            else if v_end < len && line.[v_end] = '}'
            then (
              Buffer.add_char out '}';
              scan (v_end + 1) (depth - 1) false false false)
            else scan v_end depth false false false))
        else scan !p depth false false false)
    in
    scan 0 0 false false false;
    Buffer.contents out)
;;

let redact_toml_lines (lines : string list) : string array =
  let structural = Toml_line_editor.structural_lines lines in
  let in_secret_multiline = ref false in
  let redacted =
    List.map2
      (fun line is_struct ->
         if is_struct
         then (
           in_secret_multiline := false;
           match assignment_lhs_of_line line with
           | Some (lhs, eq_idx) when is_secret_key lhs ->
             in_secret_multiline := true;
             String.sub line 0 (eq_idx + 1) ^ " \"[REDACTED]\""
           | Some _ | None ->
             line |> redact_inline_table_secrets |> redact_value_secrets)
         else if !in_secret_multiline
         then leading_whitespace line ^ "\"[REDACTED]\""
         else line |> redact_inline_table_secrets |> redact_value_secrets)
      lines
      structural
  in
  Array.of_list redacted
;;

let redact_diff_line line =
  let prefix, body =
    if String.length line > 0 && (line.[0] = '+' || line.[0] = '-' || line.[0] = ' ')
    then String.sub line 0 1, String.sub line 1 (String.length line - 1)
    else "", line
  in
  let redacted_body =
    match assignment_lhs_of_line body with
    | Some (lhs, eq_idx) when is_secret_key lhs ->
      String.sub body 0 (eq_idx + 1) ^ " \"[REDACTED]\""
    | Some _ | None ->
      body |> redact_inline_table_secrets |> redact_value_secrets
  in
  prefix ^ redacted_body
;;

(* Deterministic LCS-based line-level unified diff with 3-line context and structural secret redaction *)
let compute_unified_diff ~before_label ~after_label ~before ~after =
  let a_lines = fst (Toml_line_editor.split_lines before) in
  let b_lines = fst (Toml_line_editor.split_lines after) in
  let a = Array.of_list a_lines in
  let b = Array.of_list b_lines in
  let a_red = redact_toml_lines a_lines in
  let b_red = redact_toml_lines b_lines in
  let m = Array.length a in
  let n = Array.length b in
  (* Trim common prefix and suffix to keep DP table tiny even on 4000-line runtime.toml *)
  let p = ref 0 in
  while !p < m && !p < n && String.equal a.(!p) b.(!p) do
    incr p
  done;
  let s = ref 0 in
  while
    !s < m - !p
    && !s < n - !p
    && String.equal a.(m - 1 - !s) b.(n - 1 - !s)
  do
    incr s
  done;
  let mm = m - !p - !s in
  let nn = n - !p - !s in
  let mid_ops =
    if mm = 0 && nn = 0
    then []
    else if mm * nn > 400_000
    then
      (* Fallback for huge unrelated rewrites: delete old mid, insert new mid *)
      List.init mm (fun k -> `Del (!p + k))
      @ List.init nn (fun k -> `Add (!p + k))
    else (
      let dp = Array.make_matrix (mm + 1) (nn + 1) 0 in
      for i = mm - 1 downto 0 do
        for j = nn - 1 downto 0 do
          if String.equal a.(!p + i) b.(!p + j)
          then dp.(i).(j) <- dp.(i + 1).(j + 1) + 1
          else dp.(i).(j) <- Int.max dp.(i + 1).(j) dp.(i).(j + 1)
        done
      done;
      let rec backtrack i j acc =
        if i = mm && j = nn
        then List.rev acc
        else if i < mm && j < nn && String.equal a.(!p + i) b.(!p + j)
        then backtrack (i + 1) (j + 1) (`Eq (!p + i) :: acc)
        else if i < mm && (j = nn || dp.(i + 1).(j) >= dp.(i).(j + 1))
        then backtrack (i + 1) j (`Del (!p + i) :: acc)
        else backtrack i (j + 1) (`Add (!p + j) :: acc)
      in
      backtrack 0 0 [])
  in
  let has_changes =
    List.exists
      (function
        | `Add _ | `Del _ -> true
        | `Eq _ -> false)
      mid_ops
  in
  if not has_changes
  then "", []
  else (
    let ctx = 3 in
    let ctx_before_start = Int.max 0 (!p - ctx) in
    let ctx_before =
      List.init (!p - ctx_before_start) (fun k -> `Eq (ctx_before_start + k))
    in
    let ctx_after_len = Int.min ctx !s in
    let ctx_after =
      List.init ctx_after_len (fun k -> `Eq (m - !s + k))
    in
    let hunk_ops = ctx_before @ mid_ops @ ctx_after in
    let old_start = ctx_before_start + 1 in
    let new_start = ctx_before_start + 1 in
    let old_count =
      List.fold_left
        (fun acc op ->
           match op with
           | `Eq _ | `Del _ -> acc + 1
           | `Add _ -> acc)
        0
        hunk_ops
    in
    let new_count =
      List.fold_left
        (fun acc op ->
           match op with
           | `Eq _ | `Add _ -> acc + 1
           | `Del _ -> acc)
        0
        hunk_ops
    in
    let rendered_lines =
      List.map
        (function
          | `Eq idx -> " " ^ a_red.(idx)
          | `Del idx -> "-" ^ a_red.(idx)
          | `Add idx -> "+" ^ b_red.(idx))
        hunk_ops
    in
    let header =
      Printf.sprintf "@@ -%d,%d +%d,%d @@" old_start old_count new_start new_count
    in
    let full_text =
      String.concat
        "\n"
        ([ "--- " ^ before_label; "+++ " ^ after_label; header ] @ rendered_lines)
    in
    let hunk_json =
      `Assoc
        [ "old_start", `Int old_start
        ; "old_count", `Int old_count
        ; "new_start", `Int new_start
        ; "new_count", `Int new_count
        ; "header", `String header
        ; "lines", `List (List.map (fun l -> `String l) rendered_lines)
        ]
    in
    full_text, [ hunk_json ])
;;

let parse_target ~target ~keeper =
  let trim_opt = function
    | None -> None
    | Some s ->
      let t = String.trim s in
      if String.equal t "" then None else Some t
  in
  match trim_opt target, trim_opt keeper with
  | None, _ -> Error ("target", "target query parameter is required (runtime | keeper:<name> | keeper_create)")
  | Some "runtime", None -> Ok Target_runtime
  | Some "runtime", Some _ -> Error ("keeper", "keeper parameter is not valid for target=runtime")
  | Some "keeper_create", None -> Ok Target_keeper_create
  | Some "keeper_create", Some _ ->
    Error ("keeper", "keeper parameter is not valid for target=keeper_create")
  | Some "keeper", Some k ->
    if Keeper_config.validate_name k
    then Ok (Target_keeper k)
    else Error ("keeper", Printf.sprintf "invalid keeper name %S" k)
  | Some "keeper", None -> Error ("keeper", "keeper parameter is required when target=keeper")
  | Some raw, None when String.starts_with ~prefix:"keeper:" raw ->
    let name =
      String.sub raw 7 (String.length raw - 7) |> String.trim
    in
    if Keeper_config.validate_name name
    then Ok (Target_keeper name)
    else Error ("target", Printf.sprintf "invalid keeper name %S" name)
  | Some raw, _ ->
    Error
      ( "target"
      , Printf.sprintf
          "unknown target %S; expected runtime, keeper:<name>, or keeper_create"
          raw )
;;

let split_table_key full_key =
  match List.rev (split_dotted_key_segments full_key) with
  | [] -> "", ""
  | [ leaf ] -> "", leaf
  | leaf :: rev_prefix -> String.concat "." (List.rev rev_prefix), leaf
;;

let toml_value_to_json ~secret = function
  | _ when secret ->
    `Assoc
      [ "kind", `String "secret_state"
      ; "configured", `Bool true
      ; "masked", `String "[REDACTED]"
      ; "source", `String "inline_redacted"
      ]
  | Keeper_toml_loader.Toml_string s -> `String (redact_value_secrets s)
  | Keeper_toml_loader.Toml_int i -> `Int i
  | Keeper_toml_loader.Toml_float f -> `Float f
  | Keeper_toml_loader.Toml_bool b -> `Bool b
  | Keeper_toml_loader.Toml_string_array xs ->
    `List (List.map (fun s -> `String (redact_value_secrets s)) xs)
  | Keeper_toml_loader.Toml_array _
  | Keeper_toml_loader.Toml_table _
  | Keeper_toml_loader.Toml_inline_table _
  | Keeper_toml_loader.Toml_table_array _
  | Keeper_toml_loader.Toml_offset_datetime _
  | Keeper_toml_loader.Toml_local_datetime _
  | Keeper_toml_loader.Toml_local_date _
  | Keeper_toml_loader.Toml_local_time _ -> `String "<structured>"
;;

let secret_state_json ~configured ~source =
  `Assoc
    [ "kind", `String "secret_state"
    ; "configured", `Bool configured
    ; "masked", `String (if configured then "[REDACTED]" else "")
    ; "source", `String source
    ]
;;

let is_unset_effective_display (s : string) : bool =
  let trimmed = String.trim s in
  String.equal trimmed ""
  || String.equal trimmed Registry.provider_default_display
  ||
  match String.lowercase_ascii trimmed with
  | "(none)" | "none" | "(unset)" | "unset" | "<none>" | "<unset>" -> true
  | lower ->
    String.starts_with ~prefix:"unset " lower
    || String.starts_with ~prefix:"unset(" lower
;;

let effective_value_to_json (row : Registry.setting) (raw_eff : string) : Yojson.Safe.t =
  let eff = redact_value_secrets raw_eff in
  let trimmed = String.trim eff in
  if is_unset_effective_display trimmed
  then `Null
  else (
    match row.value_kind with
    | Registry.Boolean ->
      (match String.lowercase_ascii trimmed with
       | "true" -> `Bool true
       | "false" -> `Bool false
       | _ -> `Null)
    | Registry.Integer ->
      (match int_of_string_opt trimmed with
       | Some i -> `Int i
       | None -> `Null)
    | Registry.Float ->
      (match float_of_string_opt trimmed with
       | Some f when Float.is_finite f -> `Float f
       | Some _ | None -> `Null)
    | Registry.String -> `String eff)
;;

let is_routing_failover_key (full_key : string) : bool =
  String.starts_with ~prefix:"runtime." full_key
  || String.starts_with ~prefix:"routing." full_key
  || String.starts_with ~prefix:"assignment." full_key
  || String.starts_with ~prefix:"assignments." full_key
  || String.starts_with ~prefix:"cascade." full_key
  || String.starts_with ~prefix:"cascades." full_key
  || String.starts_with ~prefix:"failover." full_key
  || String.starts_with ~prefix:"fusion." full_key
;;

(* Process-lifetime bind, port, listener, storage, and worker-pool sections
   cannot be hot-reloaded by [Server_runtime_config_broadcast]. Every dotted
   segment is normalized (`-` -> `_`, lowercased) so kebab-case sections like
   `[domain-pool]` and nested sections like `runtime.tls.*` or `runtime.pool.*`
   stay classified as [Restart_required]. *)
let is_restart_only_section_segment seg_norm =
  match seg_norm with
  | "server" | "http" | "grpc" | "listener" | "listeners" | "storage"
  | "pool" | "pools" | "domain_pool" | "executor_pool" | "worker_pool"
  | "tls" | "ssl" | "socket" | "sockets" | "bind" -> true
  | _ -> false
;;

let is_restart_only_runtime_key ~segs_norm ~leaf_norm =
  let any_seg_is_restart = List.exists is_restart_only_section_segment segs_norm in
  let leaf_is_restart =
    match leaf_norm with
    | "bind" | "bind_host" | "bind_addr" | "bind_address"
    | "listen" | "listen_addr" | "listen_address" | "listen_host" | "listen_port"
    | "port" | "grpc_port" | "http_port"
    | "storage_root" | "storage_dir" | "storage_path" | "storage_backend"
    | "data_root" | "data_dir" | "base_path" | "masc_root"
    | "socket" | "socket_path" | "unix_socket"
    | "pool_size" | "domain_pool_size" | "executor_pool_size"
    | "worker_pool_size" | "max_domains" -> true
    | _ ->
      String.ends_with ~suffix:"_port" leaf_norm
      || String.ends_with ~suffix:"_bind" leaf_norm
      || String.ends_with ~suffix:"_socket" leaf_norm
      || String.ends_with ~suffix:"_socket_path" leaf_norm
      || String.ends_with ~suffix:"_pool_size" leaf_norm
      || String.starts_with ~prefix:"tls_" leaf_norm
      || String.starts_with ~prefix:"ssl_" leaf_norm
  in
  any_seg_is_restart || leaf_is_restart
;;

let known_provider_mem (ids : (string, unit) Hashtbl.t) (top_lc : string) : bool =
  Hashtbl.mem ids top_lc
  || Hashtbl.fold
       (fun k () acc -> acc || String.equal (String.lowercase_ascii k) top_lc)
       ids
       false
;;

let classify_runtime_key_reload_scope ?known_provider_ids (full_key : string) : reload_scope =
  let segs = split_dotted_key_segments full_key |> List.map strip_toml_quotes in
  let segs_norm =
    List.map (fun s -> normalize_key_separators (String.lowercase_ascii (String.trim s))) segs
  in
  let leaf_norm =
    match List.rev segs_norm with
    | leaf :: _ -> leaf
    | [] -> ""
  in
  if is_restart_only_runtime_key ~segs_norm ~leaf_norm
  then Restart_required
  else (
    let top_raw =
      match segs with
      | top :: _ -> top
      | [] -> ""
    in
    let top_lc = String.lowercase_ascii (String.trim top_raw) in
    let is_known_provider_binding =
      match known_provider_ids with
      | Some ids -> known_provider_mem ids top_lc
      | None -> false
    in
    (* Only sections actually republished into [Runtime]'s materialized state
       by [Runtime.commit_config_text_locked] ([set_loaded]) qualify as
       [Hot_reload]; every other section defaults to [Restart_required]. *)
    let is_hot_reload_section =
      match segs_norm with
      | ("providers" | "models" | "runtime" | "media_readers"
        | "browser" | "machines" | "typesafeai") :: _ -> true
      | "lsp" :: "servers" :: _ -> true
      | _ -> is_known_provider_binding
    in
    if is_hot_reload_section
    then Hot_reload
    else Restart_required)
;;

let title_case_leaf (raw : string) : string =
  let clean = strip_toml_quotes raw in
  let parts =
    String.split_on_char '_' clean
    |> List.concat_map (String.split_on_char '-')
    |> List.filter (fun s -> not (String.equal s ""))
  in
  match parts with
  | [] -> clean
  | _ ->
    List.map
      (fun w ->
         let lw = String.lowercase_ascii w in
         match lw with
         | "api" | "url" | "ssh" | "tts" | "stt" | "ui" | "cli" | "id" | "tls" | "http"
         | "mcp" | "vm" | "gc" | "ms" | "s" | "sec" -> String.uppercase_ascii lw
         | _ ->
           String.capitalize_ascii lw)
      parts
    |> String.concat " "
;;

let human_leaf_label_en ~table ~key : string =
  let leaf = String.lowercase_ascii (strip_toml_quotes key) in
  let sub =
    match List.rev (split_dotted_key_segments table) with
    | last :: _ -> String.lowercase_ascii (strip_toml_quotes last)
    | [] -> ""
  in
  match sub, leaf with
  | "credentials", "type" -> "Auth Type"
  | "credentials", ("key" | "api-key" | "api_key" | "env") -> "API Key / Env"
  | "credentials", ("token-path" | "token_path") -> "Token Path"
  | "headers", _ -> "Header (" ^ strip_toml_quotes key ^ ")"
  | "healthcheck", "path" -> "Healthcheck Path"
  | "healthcheck", ("interval-s" | "interval_s") -> "Check Interval (s)"
  | "usage-read", "url" -> "Usage Poll URL"
  | "usage-read", ("kind" | "type") -> "Usage Format"
  | "capabilities", "tools" -> "Tool Calling"
  | "capabilities", "streaming" -> "Streaming"
  | "capabilities", "vision" -> "Vision"
  | "capabilities", ("prompt-caching" | "prompt_caching") -> "Prompt Caching"
  | _, ("tools-support" | "tools_support") -> "Tool Calling"
  | _, ("supports-image-input" | "supports_image_input") -> "Vision"
  | _, ("supports-prompt-caching" | "supports_prompt_caching") -> "Prompt Caching"
  | _, "streaming" -> "Streaming"
  | _, ("cache-retention" | "cache_retention") -> "Cache Retention"
  | _, ("explicit-context-cache-ttl-s" | "explicit_context_cache_ttl_s") ->
    "Explicit Cache TTL (s)"
  | _, "store" -> "Server Response Store"
  | _, "efforts" -> "Effort Variants"
  | _, ("display-name" | "display_name") -> "Display Name"
  | _, "protocol" -> "Protocol"
  | _, "endpoint" -> "Endpoint URL"
  | _, "command" -> "CLI Command"
  | _, "args" -> "CLI Args"
  | _, ("connect-timeout-s" | "connect_timeout_s") -> "Connect Timeout (s)"
  | _, ("exact-body-timeout-s" | "exact_body_timeout_s") -> "Body Timeout (s)"
  | _, ("timeout-s" | "timeout_s" | "request-timeout-s" | "request_timeout_s") ->
    "Request Timeout (s)"
  | _, ("max-retries" | "max_retries") -> "Max Retries"
  | _, "enabled" -> "Enabled"
  | _, ("api-name" | "api_name" | "model") -> "API Model ID"
  | _, ("max-context" | "max_context" | "context-window" | "context_window") ->
    "Max Context"
  | _, ("max-output-tokens" | "max_output_tokens") -> "Max Output Tokens"
  | _, "temperature" -> "Temperature"
  | _, ("reasoning-effort" | "reasoning_effort") -> "Reasoning Effort"
  | "runtime", "default" -> "Default Runtime"
  | "runtime", "media_failover" -> "Media Failover"
  | _, ("candidates" | "order" | "members") -> "Failover Order"
  | _, "host" -> "Host"
  | _, "port" -> "Port"
  | _, ("user" | "unix_user") -> "User"
  | _, ("max_sessions" | "max_concurrent") -> "Max Sessions"
  | _, "tts_provider" -> "TTS Provider"
  | _, "voice_id" -> "Voice ID"
  | _, "model_id" -> "Model ID"
  | _, "theme" -> "Theme"
  | _, "locale" -> "Locale"
  | _, "refresh_ms" -> "Refresh (ms)"
  | _ -> title_case_leaf key
;;

let collect_provider_catalog (doc : (string * Keeper_toml_loader.toml_value) list) =
  let ids : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let names : (string, string) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun (full_key, v) ->
       match split_dotted_key_segments full_key with
       | top :: pid :: rest
         when String.equal (String.lowercase_ascii (strip_toml_quotes top)) "providers" ->
         let pid = strip_toml_quotes pid in
         let pid_lc = String.lowercase_ascii pid in
         if not (String.equal pid_lc "")
         then (
           Hashtbl.replace ids pid_lc ();
           match rest, v with
           | [ leaf ], Keeper_toml_loader.Toml_string s ->
             let l = String.lowercase_ascii (strip_toml_quotes leaf) in
             let trimmed = String.trim s in
             if (String.equal l "display-name" || String.equal l "display_name")
                && not (String.equal trimmed "")
             then Hashtbl.replace names pid_lc trimmed
           | ( _
             , ( Keeper_toml_loader.Toml_string _
               | Keeper_toml_loader.Toml_int _
               | Keeper_toml_loader.Toml_float _
               | Keeper_toml_loader.Toml_bool _
               | Keeper_toml_loader.Toml_string_array _
               | Keeper_toml_loader.Toml_array _
               | Keeper_toml_loader.Toml_table _
               | Keeper_toml_loader.Toml_inline_table _
               | Keeper_toml_loader.Toml_table_array _
               | Keeper_toml_loader.Toml_offset_datetime _
               | Keeper_toml_loader.Toml_local_datetime _
               | Keeper_toml_loader.Toml_local_date _
               | Keeper_toml_loader.Toml_local_time _ ) ) -> ())
       | _ -> ())
    doc;
  ids, names
;;

let collect_provider_ids_union (texts : string list) : (string, unit) Hashtbl.t =
  let union : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.iter
    (fun text ->
       if not (String.equal (String.trim text) "")
       then (
         match Keeper_toml_loader.parse_toml text with
         | Ok doc ->
           let ids, _ = collect_provider_catalog doc in
           Hashtbl.iter
             (fun pid () -> Hashtbl.replace union (String.lowercase_ascii pid) ())
             ids
         | Error _ -> ()))
    texts;
  union
;;

let classify_entity_metadata ~known_provider_ids ~provider_display_names ~table ~key =
  let segs = split_dotted_key_segments table |> List.map strip_toml_quotes in
  let provider_title pid =
    match Hashtbl.find_opt provider_display_names (String.lowercase_ascii pid) with
    | Some title -> title
    | None -> title_case_leaf pid
  in
  let entity_group, entity_title, sub_group =
    match segs with
    | "providers" :: pid :: rest when not (String.equal pid "") ->
      let sub =
        match rest with
        | [] -> None
        | sub_name :: _ -> Some (String.lowercase_ascii sub_name)
      in
      "provider:" ^ pid, provider_title pid, sub
    | pid :: _ when known_provider_mem known_provider_ids (String.lowercase_ascii pid) ->
      "provider:" ^ pid, provider_title pid, Some "model_bindings"
    | "models" :: mid :: rest when not (String.equal mid "") ->
      let sub =
        match rest with
        | [] -> None
        | sub_name :: _ -> Some (String.lowercase_ascii sub_name)
      in
      "model:" ^ mid, mid, sub
    | "runtime" :: "lanes" :: lid :: _ when not (String.equal lid "") ->
      "lane:" ^ lid, lid, None
    | "runtime" :: "exact_output_lanes" :: lid :: _ when not (String.equal lid "") ->
      "exact_lane:" ^ lid, "Exact: " ^ lid, None
    | "runtime" :: "addon_exact_lanes" :: lid :: _ when not (String.equal lid "") ->
      "addon_lane:" ^ lid, "Addon: " ^ lid, None
    | "runtime" :: "assignments" :: _ ->
      "runtime:assignments", "Keeper Assignments", None
    | "runtime" :: _ -> "runtime:default", "Default Routing", None
    | "fusion" :: _ -> "fusion", "Fusion", None
    | "exec" :: "ssh" :: ("pools" | "endpoints") :: pool :: _
      when not (String.equal pool "") ->
      "ssh_pool:" ^ pool, "SSH: " ^ pool, None
    | "exec" :: "ssh" :: _ -> "ssh:global", "SSH Global", None
    | "sandbox" :: _ -> "sandbox", "microVM Sandbox", None
    | "voice" :: _ -> "voice", "Voice TTS/STT", None
    | "slack" :: _ -> "slack", "Slack", None
    | "discord" :: _ -> "discord", "Discord", None
    | "browser" :: _ -> "browser", "Browser", None
    | "candle" :: _ -> "candle", "Candle Economy", None
    | "board" :: _ -> "board", "Board", None
    | "memory" :: _ -> "memory", "Memory & Librarian", None
    | "typesafeai" :: _ -> "typesafeai", "TypeSafeAI", None
    | "web_search" :: _ -> "web_search", "Web Search", None
    | "skills" :: _ -> "skills", "Skills", None
    | "repositories" :: _ -> "repositories", "Repositories", None
    | "tui" :: _ -> "tui", "TUI & Display", None
    | "turn" :: _ -> "turn", "Keeper Turns", None
    | "wire_capture" :: _ -> "wire_capture", "Wire Capture", None
    | "otel" :: _ -> "otel", "OpenTelemetry", None
    | "metrics" :: _ -> "metrics", "Metrics", None
    | top :: _ ->
      if not (String.equal top "")
      then "section:" ^ top, title_case_leaf top, None
      else "section:general", "General", None
    | [] ->
      let prefix =
        match String.index_opt key '_' with
        | Some i when i > 0 -> String.sub key 0 i
        | Some _ | None -> "general"
      in
      "section:" ^ String.lowercase_ascii prefix, "General", None
  in
  let label = human_leaf_label_en ~table ~key in
  label, entity_group, entity_title, sub_group
;;

let runtime_schema_json ~now ~base_path =
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  let file_exists = Sys.file_exists runtime_path in
  let raw_res =
    if not file_exists
    then Ok ""
    else (
      match Fs_compat.load_file runtime_path with
      | content -> Ok content
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | exception Sys_error msg -> Error msg)
  in
  match raw_res with
  | Error msg -> error_result Env.Store_unavailable ("runtime.toml read failed: " ^ msg)
  | Ok raw_text ->
    let file_sha256 = Env.sha256_hex raw_text in
    let doc_res =
      if String.equal (String.trim raw_text) ""
      then Ok []
      else Keeper_toml_loader.parse_toml raw_text
    in
    (match doc_res with
     | Error detail ->
       error_result
         Env.Validation_failed
         ("runtime.toml parse failed: " ^ detail)
     | Ok doc ->
       let known_provider_ids, provider_display_names = collect_provider_catalog doc in
       let by_cat : (config_category, Yojson.Safe.t list) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun c -> Hashtbl.replace by_cat c []) all_config_categories;
    let push cat field_json =
      let prev =
        match Hashtbl.find_opt by_cat cat with
        | Some lst -> lst
        | None -> []
      in
      Hashtbl.replace by_cat cat (field_json :: prev)
    in
    let entity_meta_fields ~table ~key =
      let label, entity_group, entity_title, sub_group =
        classify_entity_metadata ~known_provider_ids ~provider_display_names ~table ~key
      in
      [ "label", `String label
      ; "entity_group", `String entity_group
      ; "entity_title", `String entity_title
      ; "sub_group", Json_util.string_opt_to_json sub_group
      ]
    in
    (* 1. Project runtime routing & failover fields in Cat_routing_failover *)
    let runtime_default_val = List.assoc_opt "runtime.default" doc in
    push
      Cat_routing_failover
      (`Assoc
        ([ "table", `String "runtime"
         ; "key", `String "default"
         ; "full_key", `String "runtime.default"
         ; "type", `String "string"
         ; ( "current_value"
           , match runtime_default_val with
             | Some v -> toml_value_to_json ~secret:false v
             | None -> `Null )
         ; "default_value", `Null
         ; ( "provenance"
           , `String
               (provenance_to_string
                  (if Option.is_some runtime_default_val then Prov_project else Prov_default)) )
         ; "reload_scope", `String (reload_scope_to_string Hot_reload)
         ; "secret", `Bool false
         ; "writable", `Bool true
         ; "description", `String "Default runtime or failover lane for unassigned Keepers"
         ]
         @ entity_meta_fields ~table:"runtime" ~key:"default"));
    let media_failover_val = List.assoc_opt "runtime.media_failover" doc in
    push
      Cat_routing_failover
      (`Assoc
        ([ "table", `String "runtime"
         ; "key", `String "media_failover"
         ; "full_key", `String "runtime.media_failover"
         ; "type", `String "string_list"
         ; ( "current_value"
           , match media_failover_val with
             | Some v -> toml_value_to_json ~secret:false v
             | None -> `List [] )
         ; "default_value", `List []
         ; ( "provenance"
           , `String
               (provenance_to_string
                  (if Option.is_some media_failover_val then Prov_project else Prov_default)) )
         ; "reload_scope", `String (reload_scope_to_string Hot_reload)
         ; "secret", `Bool false
         ; "writable", `Bool true
         ; "description", `String "Ordered vision/media failover runtime IDs"
         ]
         @ entity_meta_fields ~table:"runtime" ~key:"media_failover"));
    (* 2. Project every Keeper_runtime_setting_registry row exhaustively across categories *)
    List.iter
      (fun (row : Registry.setting) ->
         let cat = category_of_registry_category row.category in
         let toml_key_opt = Registry.toml_key_opt row in
         let full_key = Option.value toml_key_opt ~default:row.env_name in
         let table, key = split_table_key full_key in
         let is_cred =
           match row.effective with
           | Registry.Credential_presence -> true
           | Registry.Reader _ -> is_secret_key full_key || is_secret_key row.env_name
         in
         let configured_opt = Option.bind toml_key_opt (fun k -> List.assoc_opt k doc) in
         let env_set =
           Registry.reads_process_env row
           && Option.is_some (Env_config_core.raw_value_opt row.env_name)
         in
         let prov =
           if env_set
           then Prov_env_override
           else if Option.is_some configured_opt
           then Prov_project
           else Prov_default
         in
         let current_json =
           if is_cred
           then (
             let configured =
               Option.is_some configured_opt
               || Option.is_some (Env_config_core.raw_value_opt row.env_name)
             in
             let source =
               if env_set
               then "env:" ^ row.env_name
               else if Option.is_some configured_opt
               then "inline_redacted"
               else "unset"
             in
             secret_state_json ~configured ~source)
           else if env_set
           then (
             match Registry.effective_value row with
             | eff -> effective_value_to_json row eff
             | exception Env_config_core.Config_error _ -> `Null)
           else (
             match configured_opt with
             | Some v -> toml_value_to_json ~secret:false v
             | None ->
               (match Registry.effective_value row with
                | eff -> effective_value_to_json row eff
                | exception Env_config_core.Config_error _ -> `Null))
         in
         let type_str =
           if is_cred then "secret" else Registry.value_kind_label row.value_kind
         in
         let writable = Option.is_some toml_key_opt in
         let r_scope = reload_scope_of_registry row.reload_class in
         let range_json =
           match row.value_range with
           | Registry.Unbounded -> `Null
           | Registry.Integer_range { min_inclusive; max_inclusive } ->
             `Assoc
               [ "kind", `String "integer"
               ; "min_inclusive", Json_util.int_opt_to_json min_inclusive
               ; "max_inclusive", Json_util.int_opt_to_json max_inclusive
               ]
           | Registry.Float_range { min_inclusive; min_exclusive; max_inclusive } ->
             `Assoc
               [ "kind", `String "float"
               ; "min_inclusive", Json_util.float_opt_to_json min_inclusive
               ; "min_exclusive", Json_util.float_opt_to_json min_exclusive
               ; "max_inclusive", Json_util.float_opt_to_json max_inclusive
               ]
         in
         push
           cat
           (`Assoc
             ([ "table", `String table
              ; "key", `String key
              ; "full_key", `String full_key
              ; "env", `String row.env_name
              ; "type", `String type_str
              ; "range", range_json
              ; "current_value", current_json
              ; "default_value", (if is_cred then `Null else `String row.default_display)
              ; "provenance", `String (provenance_to_string prov)
              ; "reload_scope", `String (reload_scope_to_string r_scope)
              ; "secret", `Bool is_cred
              ; "writable", `Bool writable
              ; "description", `String row.description
              ]
              @ entity_meta_fields ~table ~key)))
      Registry.all;
    (* 3. Project any additional top-level/provider secret or custom keys in doc with redaction *)
    let known_keys = Hashtbl.create 128 in
    Hashtbl.replace known_keys "runtime.default" ();
    Hashtbl.replace known_keys "runtime.media_failover" ();
    List.iter
      (fun row ->
         Option.iter (fun k -> Hashtbl.replace known_keys k ()) (Registry.toml_key_opt row))
      Registry.all;
    let cache_retention_enums = [ "5m"; "1h"; "in_memory"; "24h" ] in
    List.iter
      (fun (full_key, toml_v) ->
         if not (Hashtbl.mem known_keys full_key)
         then (
           Hashtbl.replace known_keys full_key ();
           let table, key = split_table_key full_key in
           let sec = is_secret_key full_key in
           let cat =
             if is_routing_failover_key full_key
             then Cat_routing_failover
             else if String.starts_with ~prefix:"exec.ssh" full_key
                     || String.starts_with ~prefix:"sandbox" full_key
             then Cat_sandbox_infra
             else if String.starts_with ~prefix:"voice" full_key
                     || String.starts_with ~prefix:"slack." full_key
                     || String.starts_with ~prefix:"discord." full_key
                     || String.starts_with ~prefix:"browser." full_key
             then Cat_economy_connectors
             else if String.starts_with ~prefix:"memory" full_key
                     || String.starts_with ~prefix:"candle" full_key
                     || String.starts_with ~prefix:"board" full_key
                     || String.starts_with ~prefix:"typesafeai." full_key
                     || String.starts_with ~prefix:"web_search." full_key
                     || String.starts_with ~prefix:"skills." full_key
                     || String.starts_with ~prefix:"repositories." full_key
             then Cat_memory_knowledge
             else if String.starts_with ~prefix:"turn." full_key
             then Cat_keepers_autonomy
             else if String.starts_with ~prefix:"tui." full_key
                     || String.starts_with ~prefix:"wire_capture." full_key
                     || String.starts_with ~prefix:"otel" full_key
                     || String.starts_with ~prefix:"metrics" full_key
             then Cat_observability_ops
             else Cat_runtime_providers
           in
           let is_cache_retention =
             String.equal (String.lowercase_ascii (strip_toml_quotes key)) "cache-retention"
           in
           let type_str =
             if sec
             then "secret"
             else if is_cache_retention
             then "enum"
             else (
               match toml_v with
               | Keeper_toml_loader.Toml_bool _ -> "boolean"
               | Keeper_toml_loader.Toml_int _ -> "integer"
               | Keeper_toml_loader.Toml_float _ -> "float"
               | Keeper_toml_loader.Toml_string _ -> "string"
               | Keeper_toml_loader.Toml_string_array _ -> "string_list"
               | Keeper_toml_loader.Toml_array _
               | Keeper_toml_loader.Toml_table _
               | Keeper_toml_loader.Toml_inline_table _
               | Keeper_toml_loader.Toml_table_array _
               | Keeper_toml_loader.Toml_offset_datetime _
               | Keeper_toml_loader.Toml_local_datetime _
               | Keeper_toml_loader.Toml_local_date _
               | Keeper_toml_loader.Toml_local_time _ -> "structured")
           in
           let enum_member =
             if is_cache_retention
             then [ "enum_values", `List (List.map (fun s -> `String s) cache_retention_enums) ]
             else []
           in
           let r_scope =
             classify_runtime_key_reload_scope ~known_provider_ids full_key
           in
           push
             cat
             (`Assoc
               ([ "table", `String table
                ; "key", `String key
                ; "full_key", `String full_key
                ; "type", `String type_str
                ; "current_value", toml_value_to_json ~secret:sec toml_v
                ; "default_value", `Null
                ; "provenance", `String (provenance_to_string Prov_project)
                ; "reload_scope", `String (reload_scope_to_string r_scope)
                ; "secret", `Bool sec
                ; "writable", `Bool (not (String.equal type_str "structured"))
                ; "description", `String ("Declared runtime.toml key " ^ full_key)
                ]
                @ enum_member
                @ entity_meta_fields ~table ~key))))
      doc;
    (* 4. Expose optional runtime schema descriptors for declared providers, models, and bindings
       so Settings/TUI operators can discover and edit cache-retention, explicit-context-cache-ttl-s,
       store, and efforts even when omitted from runtime.toml (including empty binding tables). *)
    let seen_providers : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    let seen_models : (string, unit) Hashtbl.t = Hashtbl.create 16 in
    let seen_bindings : (string * string, unit) Hashtbl.t = Hashtbl.create 32 in
    let provider_order = ref [] in
    let model_order = ref [] in
    let binding_order = ref [] in
    let add_provider pid =
      if (not (String.equal pid "")) && not (Hashtbl.mem seen_providers pid)
      then (
        Hashtbl.replace seen_providers pid ();
        provider_order := pid :: !provider_order)
    in
    let add_model mid =
      if (not (String.equal mid "")) && not (Hashtbl.mem seen_models mid)
      then (
        Hashtbl.replace seen_models mid ();
        model_order := mid :: !model_order)
    in
    let add_binding pid mid =
      let pair = pid, mid in
      if (not (String.equal pid ""))
         && (not (String.equal mid ""))
         && not (Hashtbl.mem seen_bindings pair)
      then (
        Hashtbl.replace seen_bindings pair ();
        binding_order := pair :: !binding_order)
    in
    (match Runtime_toml.parse_string raw_text with
     | Ok cfg ->
       List.iter (fun (p : Runtime_schema.provider) -> add_provider p.id) cfg.providers;
       List.iter (fun (m : Runtime_schema.model_spec) -> add_model m.id) cfg.models;
       List.iter
         (fun (b : Runtime_schema.binding) -> add_binding b.provider_id b.model_id)
         cfg.bindings
     | Error _ -> ());
    List.iter
      (fun (full_key, _) ->
         let table, _ = split_table_key full_key in
         let segs = split_dotted_key_segments table |> List.map strip_toml_quotes in
         match segs with
         | "providers" :: pid :: _ -> add_provider pid
         | "models" :: mid :: _ -> add_model mid
         | [ pid; mid ]
           when known_provider_mem known_provider_ids (String.lowercase_ascii pid) ->
           add_binding pid mid
         | _ -> ())
      doc;
    let push_optional_descriptor ~table ~key ~type_str ?enum_values ?range_json ~description () =
      let full_key = table ^ "." ^ key in
      if not (Hashtbl.mem known_keys full_key)
      then (
        Hashtbl.replace known_keys full_key ();
        let enum_member =
          match enum_values with
          | Some vals -> [ "enum_values", `List (List.map (fun s -> `String s) vals) ]
          | None -> []
        in
        let range_member =
          match range_json with
          | Some r -> [ "range", r ]
          | None -> []
        in
        push
          Cat_runtime_providers
          (`Assoc
            ([ "table", `String table
             ; "key", `String key
             ; "full_key", `String full_key
             ; "type", `String type_str
             ; "current_value", `Null
             ; "default_value", `Null
             ; "provenance", `String (provenance_to_string Prov_default)
             ; "reload_scope", `String (reload_scope_to_string Hot_reload)
             ; "secret", `Bool false
             ; "writable", `Bool true
             ; "description", `String description
             ]
             @ enum_member
             @ range_member
             @ entity_meta_fields ~table ~key)))
    in
    let positive_int_range =
      `Assoc [ "kind", `String "integer"; "min_inclusive", `Int 1; "max_inclusive", `Null ]
    in
    List.iter
      (fun pid ->
         let table = "providers." ^ Toml_line_editor.render_key pid in
         push_optional_descriptor
           ~table
           ~key:Runtime_schema.store_key
           ~type_str:"boolean"
           ~description:"Enable server-side response storage (OpenAI Responses API)"
           ();
         push_optional_descriptor
           ~table
           ~key:Runtime_schema.explicit_context_cache_ttl_s_key
           ~type_str:"integer"
           ~range_json:positive_int_range
           ~description:"Provider-level explicit context cache TTL in seconds"
           ())
      (List.rev !provider_order);
    List.iter
      (fun mid ->
         let table = "models." ^ Toml_line_editor.render_key mid in
         push_optional_descriptor
           ~table
           ~key:Runtime_schema.explicit_context_cache_ttl_s_key
           ~type_str:"integer"
           ~range_json:positive_int_range
           ~description:"Model-level explicit context cache TTL in seconds"
           ();
         push_optional_descriptor
           ~table
           ~key:"efforts"
           ~type_str:"string_list"
           ~description:"Parameterized reasoning effort variants expanded into <id>@<effort> runtimes"
           ())
      (List.rev !model_order);
    List.iter
      (fun (pid, mid) ->
         let table =
           Toml_line_editor.render_key pid ^ "." ^ Toml_line_editor.render_key mid
         in
         push_optional_descriptor
           ~table
           ~key:"cache-retention"
           ~type_str:"enum"
           ~enum_values:cache_retention_enums
           ~description:"Prompt cache retention tier (5m | 1h | in_memory | 24h)"
           ();
         push_optional_descriptor
           ~table
           ~key:"efforts"
           ~type_str:"string_list"
           ~description:"Parameterized reasoning effort variants for this provider binding"
           ())
      (List.rev !binding_order);
    let categories_json =
      List.map
        (fun cat ->
           let fields =
             match Hashtbl.find_opt by_cat cat with
             | Some lst -> List.rev lst
             | None -> []
           in
           `Assoc
             [ "id", `String (config_category_to_string cat)
             ; "title", `String (config_category_title cat)
             ; "field_count", `Int (List.length fields)
             ; "fields", `List fields
             ])
        all_config_categories
    in
    let data =
      `Assoc
        [ "target", `String "runtime"
        ; "file_exists", `Bool file_exists
        ; "file_sha256", `String file_sha256
        ; "categories", `List categories_json
        ]
    in
    Ok (Env.ok ~now data))
;;

let read_keeper_runtime_assignment_context ~base_path ~keeper_name_opt =
  let runtime_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  if not (Sys.file_exists runtime_path)
  then None, []
  else (
    match Fs_compat.load_file runtime_path with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception Sys_error _ -> None, []
    | raw ->
      let assigned_runtime_opt =
        match keeper_name_opt, Keeper_toml_loader.parse_toml raw with
        | Some name, Ok doc ->
          (match List.assoc_opt ("runtime.assignments." ^ name) doc with
           | Some (Keeper_toml_loader.Toml_string s) ->
             let trimmed = String.trim s in
             if String.equal trimmed "" then None else Some trimmed
           | Some
               ( Keeper_toml_loader.Toml_int _
               | Keeper_toml_loader.Toml_float _
               | Keeper_toml_loader.Toml_bool _
               | Keeper_toml_loader.Toml_string_array _
               | Keeper_toml_loader.Toml_array _
               | Keeper_toml_loader.Toml_table _
               | Keeper_toml_loader.Toml_inline_table _
               | Keeper_toml_loader.Toml_table_array _
               | Keeper_toml_loader.Toml_offset_datetime _
               | Keeper_toml_loader.Toml_local_datetime _
               | Keeper_toml_loader.Toml_local_date _
               | Keeper_toml_loader.Toml_local_time _ )
           | None -> None)
        | None, _ | Some _, Error _ -> None
      in
      let runtime_choices =
        match Runtime_toml.parse_string raw with
        | Error _ -> []
        | Ok cfg ->
          let lane_ids =
            List.map (fun (l : Runtime_schema.lane_decl) -> l.id) cfg.lane_decls
          in
          let binding_ids =
            List.filter_map
              (fun (b : Runtime_schema.binding) ->
                 if b.enabled then Some (Runtime_schema.binding_key b) else None)
              cfg.bindings
          in
          let base = lane_ids @ binding_ids in
          let with_assigned =
            match assigned_runtime_opt with
            | Some cur when not (List.mem cur base) -> cur :: base
            | Some _ | None -> base
          in
          let seen = Hashtbl.create 32 in
          List.filter
            (fun id ->
               if Hashtbl.mem seen id
               then false
               else (
                 Hashtbl.replace seen id ();
                 true))
            with_assigned
      in
      assigned_runtime_opt, runtime_choices)
;;

let keeper_schema_fields ~doc ~is_create ~assigned_runtime_opt ~runtime_choices =
  let lookup full_key = List.assoc_opt full_key doc in
  let prov_of full_key =
    if is_create
    then Prov_default
    else if Option.is_some (lookup full_key)
    then Prov_keeper
    else Prov_default
  in
  let field ~cat ~table ~key ~type_str ?enum_values ?(writable = true) ~default_json ~reload ~secret ~description () =
    let full_key = table ^ "." ^ key in
    let current_json =
      match lookup full_key with
      | Some v -> toml_value_to_json ~secret v
      | None ->
        if secret
        then secret_state_json ~configured:false ~source:"unset"
        else default_json
    in
    let enum_member =
      match enum_values with
      | Some vals -> [ "enum_values", `List (List.map (fun s -> `String s) vals) ]
      | None -> []
    in
    ( cat
    , `Assoc
        ([ "table", `String table
         ; "key", `String key
         ; "full_key", `String full_key
         ; "type", `String type_str
         ; "current_value", current_json
         ; "default_value", (if secret then `Null else default_json)
         ; "provenance", `String (provenance_to_string (prov_of full_key))
         ; "reload_scope", `String (reload_scope_to_string reload)
         ; "secret", `Bool secret
         ; "writable", `Bool writable
         ; "description", `String description
         ]
         @ enum_member) )
  in
  let activation_enums =
    List.map Keeper_activation_mode.to_string Keeper_activation_mode.all
  in
  let sandbox_enums = Sandbox_profile.valid_sandbox_profile_strings in
  let network_enums = Sandbox_profile.valid_network_mode_strings in
  let microvm_enums = Keeper_microvm_backend.valid_strings in
  let runtime_assignment_field =
    let type_str, enum_member =
      if runtime_choices <> []
      then "enum", [ "enum_values", `List (List.map (fun s -> `String s) runtime_choices) ]
      else "string", []
    in
    let prov =
      if is_create || Option.is_none assigned_runtime_opt
      then Prov_default
      else Prov_project
    in
    ( Cat_runtime_providers
    , `Assoc
        ([ "table", `String "runtime.assignments"
         ; "key", `String "runtime"
         ; "full_key", `String "runtime.assignments.runtime"
         ; "type", `String type_str
         ; "current_value", Json_util.string_opt_to_json assigned_runtime_opt
         ; "default_value", `Null
         ; "provenance", `String (provenance_to_string prov)
         ; "reload_scope", `String (reload_scope_to_string Next_turn)
         ; "secret", `Bool false
         ; "writable", `Bool true
         ; ( "description"
           , `String
               "Assigned runtime or failover lane stored in runtime.toml [runtime.assignments]" )
         ]
         @ enum_member) )
  in
  [ field
      ~cat:Cat_keepers_autonomy
      ~table:"keeper"
      ~key:"name"
      ~type_str:"string"
      ~writable:is_create
      ~default_json:`Null
      ~reload:Restart_required
      ~secret:false
      ~description:"Canonical Keeper identifier matching filename <name>.toml"
      ()
  ; runtime_assignment_field
  ; field
      ~cat:Cat_keepers_autonomy
      ~table:"keeper"
      ~key:"group"
      ~type_str:"string"
      ~writable:true
      ~default_json:`Null
      ~reload:Next_turn
      ~secret:false
      ~description:"Optional deployment-neutral group label for dashboard grouping"
      ()
  ; field
      ~cat:Cat_keepers_autonomy
      ~table:"keeper"
      ~key:"activation_mode"
      ~type_str:"enum"
      ~enum_values:activation_enums
      ~default_json:(`String (Keeper_activation_mode.to_string Keeper_activation_mode.default))
      ~reload:Next_turn
      ~secret:false
      ~description:"Owner activation and initiative policy"
      ()
  ; field
      ~cat:Cat_keepers_autonomy
      ~table:"keeper"
      ~key:"instructions"
      ~type_str:"string"
      ~default_json:(`String "")
      ~reload:Next_turn
      ~secret:false
      ~description:"Per-Keeper system instructions appended to the shared Keeper prompt"
      ()
  ; field
      ~cat:Cat_keepers_autonomy
      ~table:"keeper"
      ~key:"mention_targets"
      ~type_str:"string_list"
      ~default_json:(`List [])
      ~reload:Next_turn
      ~secret:false
      ~description:"Aliases and @mention targets this Keeper responds to"
      ()
  ; field
      ~cat:Cat_keepers_autonomy
      ~table:"keeper"
      ~key:"board_interests"
      ~type_str:"string_list"
      ~default_json:(`List [])
      ~reload:Next_turn
      ~secret:false
      ~description:"Board topics/hearths this Keeper subscribes to"
      ()
  ; field
      ~cat:Cat_runtime_providers
      ~table:"keeper"
      ~key:"max_context_override"
      ~type_str:"integer"
      ~default_json:`Null
      ~reload:Next_turn
      ~secret:false
      ~description:"Optional context window token override for this Keeper"
      ()
  ; field
      ~cat:Cat_sandbox_infra
      ~table:"keeper"
      ~key:"sandbox_profile"
      ~type_str:"enum"
      ~enum_values:sandbox_enums
      ~default_json:(`String (Sandbox_profile.sandbox_profile_to_string Sandbox_profile.Docker))
      ~reload:Next_turn
      ~secret:false
      ~description:"Execution isolation backend (docker | microvm | remote_ssh)"
      ()
  ; field
      ~cat:Cat_sandbox_infra
      ~table:"keeper"
      ~key:"network_mode"
      ~type_str:"enum"
      ~enum_values:network_enums
      ~default_json:(`String (Sandbox_profile.network_mode_to_string Sandbox_profile.Network_none))
      ~reload:Next_turn
      ~secret:false
      ~description:"Sandbox outbound network boundary (none | inherit | policy)"
      ()
  ; field
      ~cat:Cat_sandbox_infra
      ~table:"keeper"
      ~key:"sandbox_image"
      ~type_str:"string"
      ~default_json:`Null
      ~reload:Next_turn
      ~secret:false
      ~description:"Container or microVM image reference"
      ()
  ; field
      ~cat:Cat_sandbox_infra
      ~table:"keeper"
      ~key:"microvm_backend"
      ~type_str:"enum"
      ~enum_values:microvm_enums
      ~default_json:`Null
      ~reload:Next_turn
      ~secret:false
      ~description:"Hypervisor runtime for microvm profile (apple_container | microsandbox | nerdctl_kata)"
      ()
  ; field
      ~cat:Cat_sandbox_infra
      ~table:"keeper"
      ~key:"remote_endpoint"
      ~type_str:"string"
      ~default_json:`Null
      ~reload:Next_turn
      ~secret:false
      ~description:"Named SSH endpoint from runtime.toml [exec.ssh.endpoints.<name>]"
      ()
  ; field
      ~cat:Cat_sandbox_infra
      ~table:"keeper"
      ~key:"masc_tools_enabled"
      ~type_str:"boolean"
      ~default_json:(`Bool true)
      ~reload:Next_turn
      ~secret:false
      ~description:"Expose MASC workspace tools to this Keeper"
      ()
  ; field
      ~cat:Cat_economy_connectors
      ~table:"keeper"
      ~key:"voice_always_allow"
      ~type_str:"boolean"
      ~default_json:(`Bool false)
      ~reload:Hot_reload
      ~secret:false
      ~description:"Allow voice bridge calls without per-turn confirmation"
      ()
  ; field
      ~cat:Cat_observability_ops
      ~table:"keeper"
      ~key:"telemetry_feedback_enabled"
      ~type_str:"boolean"
      ~default_json:(`Bool false)
      ~reload:Next_turn
      ~secret:false
      ~description:"Include recent tool/turn telemetry summary in Keeper context"
      ()
  ]
;;

let keeper_schema_json ~now ~base_path ~is_create ~keeper_name_opt =
  let path_opt =
    Option.map
      (Config_dir_resolver.keeper_toml_path_for_base_path ~base_path)
      keeper_name_opt
  in
  let loaded_res =
    match path_opt with
    | None -> Ok (false, "", [])
    | Some path ->
      if not (Sys.file_exists path)
      then
        error_result
          Env.Not_found
          (Printf.sprintf
             "keeper config %S not found"
             (Option.value ~default:"" keeper_name_opt))
      else (
        match Fs_compat.load_file path with
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception Sys_error msg ->
          error_result Env.Store_unavailable ("keeper config read failed: " ^ msg)
        | raw ->
          (match
             if String.equal (String.trim raw) ""
             then Ok []
             else Keeper_toml_loader.parse_toml raw
           with
           | Error detail ->
             error_result
               Env.Validation_failed
               (Printf.sprintf
                  "keeper config %s parse failed: %s"
                  (Filename.basename path)
                  detail)
           | Ok doc -> Ok (true, raw, doc)))
  in
  match loaded_res with
  | Error _ as err -> err
  | Ok (file_exists, raw_text, doc) ->
    let file_sha256 = Env.sha256_hex raw_text in
    let by_cat : (config_category, Yojson.Safe.t list) Hashtbl.t = Hashtbl.create 8 in
    List.iter (fun c -> Hashtbl.replace by_cat c []) all_config_categories;
    let assigned_runtime_opt, runtime_choices =
      read_keeper_runtime_assignment_context ~base_path ~keeper_name_opt
    in
    List.iter
      (fun (cat, fjson) ->
         let prev =
           match Hashtbl.find_opt by_cat cat with
           | Some lst -> lst
           | None -> []
         in
         Hashtbl.replace by_cat cat (fjson :: prev))
      (keeper_schema_fields ~doc ~is_create ~assigned_runtime_opt ~runtime_choices);
    let categories_json =
      List.map
        (fun cat ->
           let fields =
             match Hashtbl.find_opt by_cat cat with
             | Some lst -> List.rev lst
             | None -> []
           in
           `Assoc
             [ "id", `String (config_category_to_string cat)
             ; "title", `String (config_category_title cat)
             ; "field_count", `Int (List.length fields)
             ; "fields", `List fields
             ])
        all_config_categories
    in
    let target_label =
      match keeper_name_opt with
      | None -> "keeper_create"
      | Some name -> "keeper:" ^ name
    in
    let data =
      `Assoc
        [ "target", `String target_label
        ; "keeper", Json_util.string_opt_to_json keeper_name_opt
        ; "file_exists", `Bool file_exists
        ; "file_sha256", `String file_sha256
        ; "categories", `List categories_json
        ]
    in
    Ok (Env.ok ~now data)
;;

let config_schema_json ?(now = Time_compat.now ()) ~base_path ~target () =
  match target with
  | Target_runtime -> runtime_schema_json ~now ~base_path
  | Target_keeper name ->
    keeper_schema_json ~now ~base_path ~is_create:false ~keeper_name_opt:(Some name)
  | Target_keeper_create ->
    keeper_schema_json ~now ~base_path ~is_create:true ~keeper_name_opt:None
;;

(* Patch parsing and application *)
type patch_value =
  | Val_string of string
  | Val_int of int
  | Val_float of float
  | Val_bool of bool
  | Val_string_list of string list

type patch_op =
  | Op_set of
      { table : string
      ; key : string
      ; value : patch_value
      }
  | Op_remove of
      { table : string
      ; key : string
      }

let parse_patch_value ~op_kind json =
  match op_kind, json with
  | ("set_scalar" | "set_string"), `String s -> Ok (Val_string s)
  | ("set_scalar" | "set_string"), _ -> Error "expected a string value"
  | "set_int", `Int i -> Ok (Val_int i)
  | "set_int", _ -> Error "expected an integer value"
  | "set_float", `Float f ->
    if Float.is_finite f then Ok (Val_float f) else Error "float must be finite"
  | "set_float", `Int i -> Ok (Val_float (float_of_int i))
  | "set_float", _ -> Error "expected a numeric value"
  | "set_bool", `Bool b -> Ok (Val_bool b)
  | "set_bool", _ -> Error "expected a boolean value"
  | "set_string_array", `List items ->
    let rec loop acc = function
      | [] -> Ok (Val_string_list (List.rev acc))
      | `String s :: rest -> loop (s :: acc) rest
      | _ :: _ -> Error "string array elements must be strings"
    in
    loop [] items
  | "set_string_array", _ -> Error "expected a JSON array of strings"
  | "set", `String s -> Ok (Val_string s)
  | "set", `Int i -> Ok (Val_int i)
  | "set", `Float f ->
    if Float.is_finite f then Ok (Val_float f) else Error "float must be finite"
  | "set", `Bool b -> Ok (Val_bool b)
  | "set", `List items ->
    let rec loop acc = function
      | [] -> Ok (Val_string_list (List.rev acc))
      | `String s :: rest -> loop (s :: acc) rest
      | _ :: _ -> Error "array elements must be strings"
    in
    loop [] items
  | "set", _ -> Error "unsupported JSON value type for set"
  | other, _ -> Error (Printf.sprintf "unknown op %S" other)
;;

let is_valid_toml_bare_segment (s : string) : bool =
  let len = String.length s in
  if len = 0
  then false
  else (
    let ok = ref true in
    for i = 0 to len - 1 do
      match s.[i] with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> ()
      | _ -> ok := false
    done;
    !ok)
;;

let is_valid_toml_quoted_segment (s : string) : bool =
  let len = String.length s in
  if len < 3
  then false
  else (
    let q = s.[0] in
    if (q <> '"' && q <> '\'') || s.[len - 1] <> q
    then false
    else (
      let inner = String.sub s 1 (len - 2) in
      let ok = ref (String.length inner > 0) in
      let escaped = ref false in
      for i = 0 to String.length inner - 1 do
        let c = inner.[i] in
        if !escaped
        then escaped := false
        else if q = '"' && c = '\\'
        then escaped := true
        else if c = q || Char.code c < 0x20 || Char.code c = 0x7f
        then ok := false
      done;
      !ok && not !escaped))
;;

let is_valid_toml_table_segment (s : string) : bool =
  is_valid_toml_bare_segment s || is_valid_toml_quoted_segment s
;;

let is_valid_table_path (table : string) : bool =
  if String.equal table ""
  then true
  else (
    let segs = split_dotted_key_segments table in
    segs <> []
    && List.for_all is_valid_toml_table_segment segs
    &&
    match Otoml.Parser.from_string_result ("[" ^ table ^ "]") with
    | Ok _ -> true
    | Error _ -> false)
;;

let parse_patch_op idx = function
  | `Assoc fields ->
    let field_s name =
      match List.assoc_opt name fields with
      | Some (`String s) -> Some (String.trim s)
      | _ -> None
    in
    let op_kind =
      match field_s "op" with
      | Some s -> s
      | None -> "set"
    in
    let table_opt = field_s "table" in
    let key_opt = field_s "key" in
    let full_key_opt = field_s "full_key" in
    let table, key =
      match table_opt, key_opt, full_key_opt with
      | Some t, Some k, _ when not (String.equal k "") -> t, k
      | None, None, Some fk when not (String.equal fk "") -> split_table_key fk
      | None, Some k, _ when String.contains k '.' -> split_table_key k
      | Some t, Some k, _ -> t, k
      | None, Some k, _ -> "", k
      | _ -> "", ""
    in
    if String.equal key ""
    then Error (Printf.sprintf "changes[%d]" idx, "key is required")
    else if not (is_valid_table_path table)
    then
      Error
        ( Printf.sprintf "changes[%d].table" idx
        , Printf.sprintf
            "invalid TOML table path %S; expected dot-separated bare [A-Za-z0-9_-] or quoted TOML segments"
            table )
    else if not (is_valid_toml_bare_segment key)
    then
      Error
        ( Printf.sprintf "changes[%d].key" idx
        , Printf.sprintf
            "invalid TOML key %S; only [A-Za-z0-9_-] characters are allowed"
            key )
    else (
      match op_kind with
      | "remove" | "remove_key" -> Ok (Op_remove { table; key })
      | _ ->
        (match List.assoc_opt "value" fields with
         | None -> Error (Printf.sprintf "changes[%d].value" idx, "value is required")
         | Some `Null -> Ok (Op_remove { table; key })
         | Some vjson ->
           (match parse_patch_value ~op_kind vjson with
            | Ok value -> Ok (Op_set { table; key; value })
            | Error msg -> Error (Printf.sprintf "changes[%d].value" idx, msg))))
  | _ -> Error (Printf.sprintf "changes[%d]" idx, "each change must be a JSON object")
;;

let parse_target_json fields =
  match List.assoc_opt "target" fields with
  | Some (`String raw) ->
    (match parse_target ~target:(Some raw) ~keeper:None with
     | Ok Target_keeper_create ->
       (match List.assoc_opt "keeper_name" fields with
        | Some (`String name) when Keeper_config.validate_name (String.trim name) ->
          Ok (Target_keeper_create, Some (String.trim name))
        | _ ->
          Error
            ( "keeper_name"
            , "valid keeper_name is required when target is keeper_create" ))
     | Ok ((Target_runtime | Target_keeper _) as t) -> Ok (t, None)
     | Error err -> Error err)
  | Some (`Assoc tfields) ->
    (match List.assoc_opt "kind" tfields with
     | Some (`String "runtime_toml") | Some (`String "runtime") -> Ok (Target_runtime, None)
     | Some (`String "keeper_toml") | Some (`String "keeper") ->
       (match List.assoc_opt "keeper" tfields with
        | Some (`String k) when Keeper_config.validate_name (String.trim k) ->
          Ok (Target_keeper (String.trim k), None)
        | _ -> Error ("target.keeper", "valid keeper name is required"))
     | Some (`String "keeper_create") ->
       (match List.assoc_opt "keeper" tfields with
        | Some (`String k) when Keeper_config.validate_name (String.trim k) ->
          Ok (Target_keeper_create, Some (String.trim k))
        | _ -> Error ("target.keeper", "valid keeper name is required"))
     | _ -> Error ("target.kind", "unknown target kind"))
  | _ -> Error ("target", "target is required")
;;

let apply_patch_op text = function
  | Op_remove { table; key } ->
    if String.equal table ""
    then Error "removing a root-level key is not supported; specify table"
    else Ok (Toml_line_editor.edit_table_scalar text ~path:table ~key ~value:None)
  | Op_set { table; key; value } ->
    if String.equal table ""
    then (
      match value with
      | Val_bool b -> Ok (Toml_line_editor.edit_root_bool text ~key ~value:b)
      | Val_string _ | Val_int _ | Val_float _ | Val_string_list _ ->
        Error "table is required for non-boolean root keys")
    else (
      match value with
      | Val_string s ->
        Ok (Toml_line_editor.edit_table_scalar text ~path:table ~key ~value:(Some s))
      | Val_int i -> Ok (Toml_line_editor.edit_table_int text ~path:table ~key ~value:i)
      | Val_float f -> Ok (Toml_line_editor.edit_table_float text ~path:table ~key ~value:f)
      | Val_bool b -> Ok (Toml_line_editor.edit_table_bool text ~path:table ~key ~value:b)
      | Val_string_list xs ->
        Ok (Toml_line_editor.edit_table_multiline_array text ~path:table ~key ~values:xs))
;;

let reload_scope_for_ops ?known_provider_ids ~target ops =
  List.fold_left
    (fun acc op ->
       let table, key =
         match op with
         | Op_set { table; key; _ } | Op_remove { table; key } -> table, key
       in
       let full_key = if String.equal table "" then key else table ^ "." ^ key in
       let step =
         match target with
         | Target_runtime ->
           (match Registry.find_by_toml_key full_key with
            | Some row -> reload_scope_of_registry row.reload_class
            | None ->
              classify_runtime_key_reload_scope ?known_provider_ids full_key)
         | Target_keeper _ | Target_keeper_create ->
           (match key with
            | "voice_always_allow" -> Hot_reload
            | "name" -> Restart_required
            | _ -> Next_turn)
       in
       max_reload_scope acc step)
    Hot_reload
    ops
;;

let validate_patched_toml ~target ~expected_keeper_name ~after_text ~target_path =
  (* Step 1: Parse TOML 1.0 syntax strictly with Otoml *)
  match Otoml.Parser.from_string after_text with
  | exception Otoml.Parse_error (_, msg) ->
    Error ("patched TOML failed to parse: " ^ msg)
  | _ ->
    (match target with
     | Target_runtime ->
       (match Keeper_runtime_config.validate_source_text after_text with
        | Error msg -> Error ("runtime config validation failed: " ^ msg)
        | Ok report ->
          if not (Keeper_runtime_config.validation_report_is_valid report)
          then (
            let first_err =
              match
                List.find_opt
                  (fun (issue : Keeper_runtime_config.validation_issue) ->
                     issue.severity = Keeper_runtime_config.Error)
                  report.issues
              with
              | Some i -> Printf.sprintf "%s: %s" i.key i.detail
              | None -> "runtime setting validation failed"
            in
            Error first_err)
          else (
            match
              Runtime.validate_config_text ~runtime_config_path:target_path after_text
            with
            | Ok () -> Ok []
            | Error msg -> Error ("runtime validation failed: " ^ msg)))
     | Target_keeper _ | Target_keeper_create ->
       (match Keeper_toml_loader.parse_toml after_text with
        | Error msg -> Error ("keeper TOML parse failed: " ^ msg)
        | Ok doc ->
          let unknown = Keeper_types_profile.detect_unknown_keeper_toml_keys doc in
          if unknown <> []
          then
            Error
              ("unknown keeper TOML keys: " ^ String.concat ", " unknown)
          else (
            (* Verify keeper.name matches target filename and passes validate_name *)
            let name_check =
              match List.assoc_opt "keeper.name" doc, expected_keeper_name with
              | Some (Keeper_toml_loader.Toml_string actual_name), Some expected ->
                let trimmed = String.trim actual_name in
                if not (Keeper_config.validate_name trimmed)
                then Error (Printf.sprintf "invalid keeper.name %S" actual_name)
                else if not (String.equal trimmed expected)
                then
                  Error
                    (Printf.sprintf
                       "keeper.name %S must match target keeper %S"
                       trimmed
                       expected)
                else Ok ()
              | Some (Keeper_toml_loader.Toml_string actual_name), None ->
                if Keeper_config.validate_name (String.trim actual_name)
                then Ok ()
                else Error (Printf.sprintf "invalid keeper.name %S" actual_name)
              | ( Some
                    ( Keeper_toml_loader.Toml_int _
                    | Keeper_toml_loader.Toml_float _
                    | Keeper_toml_loader.Toml_bool _
                    | Keeper_toml_loader.Toml_string_array _
                    | Keeper_toml_loader.Toml_array _
                    | Keeper_toml_loader.Toml_table _
                    | Keeper_toml_loader.Toml_inline_table _
                    | Keeper_toml_loader.Toml_table_array _
                    | Keeper_toml_loader.Toml_offset_datetime _
                    | Keeper_toml_loader.Toml_local_datetime _
                    | Keeper_toml_loader.Toml_local_date _
                    | Keeper_toml_loader.Toml_local_time _ )
                , _ ) -> Error "keeper.name must be a string"
              | None, Some expected ->
                Error
                  (Printf.sprintf
                     "keeper.name is required and must equal %S"
                     expected)
              | None, None -> Error "keeper.name is required"
            in
            match name_check with
            | Error msg -> Error msg
            | Ok () ->
              (match Keeper_types_profile.profile_defaults_of_toml doc with
               | Error msg -> Error ("keeper profile validation failed: " ^ msg)
               | Ok defaults ->
                 let unknown_deny =
                   Keeper_types_profile.unknown_deny_tools defaults.tool_deny
                 in
                 if unknown_deny <> []
                 then
                   Error
                     ("unknown keeper.tools.deny tools: "
                      ^ String.concat ", " unknown_deny)
                 else Ok []))))
;;

let snapshots_dir_for_base_path ~base_path =
  let res = Config_dir_resolver.resolve_for_base_path ~base_path in
  Filename.concat res.config_root.path "snapshots"
;;

let config_patch_json ?(now = Time_compat.now ()) ~config ~actor ~body_str () =
  let base_path = config.Workspace.base_path in
  match Yojson.Safe.from_string body_str with
  | exception Yojson.Json_error msg ->
    error_result Env.Invalid_param ("invalid JSON: " ^ msg)
  | `Assoc fields ->
    let parsed =
      let open Result.Syntax in
      let* target, create_name_opt = parse_target_json fields in
      let* expected_sha256 =
        match List.assoc_opt "expected_sha256" fields with
        | None | Some `Null -> Ok None
        | Some (`String s) ->
          let trimmed = String.lowercase_ascii (String.trim s) in
          if String_util.is_lowercase_sha256_hex trimmed
          then Ok (Some trimmed)
          else Error ("expected_sha256", "expected_sha256 must be 64 lowercase hex characters")
        | Some _ -> Error ("expected_sha256", "expected_sha256 must be a string")
      in
      let* dry_run =
        match List.assoc_opt "dry_run" fields with
        | None -> Ok true
        | Some (`Bool b) -> Ok b
        | Some _ -> Error ("dry_run", "dry_run must be a boolean")
      in
      let* raw_ops =
        match List.assoc_opt "changes" fields, List.assoc_opt "ops" fields with
        | Some (`List xs), None | None, Some (`List xs) -> Ok xs
        | Some _, Some _ -> Error ("changes", "provide either changes or ops, not both")
        | None, None -> Error ("changes", "changes array is required")
        | Some _, None | None, Some _ -> Error ("changes", "changes must be a JSON array")
      in
      let* () =
        if raw_ops = [] && target <> Target_keeper_create
        then Error ("changes", "changes must not be empty")
        else Ok ()
      in
      let* ops =
        let rec loop idx acc = function
          | [] -> Ok (List.rev acc)
          | item :: rest ->
            let* op = parse_patch_op idx item in
            loop (idx + 1) (op :: acc) rest
        in
        loop 0 [] raw_ops
      in
      let* () =
        match target with
        | Target_keeper _ ->
          let mutates_name =
            List.exists
              (function
                | Op_set { table = "keeper"; key = "name"; _ }
                | Op_remove { table = "keeper"; key = "name" } -> true
                | Op_set _ | Op_remove _ -> false)
              ops
          in
          if mutates_name
          then Error ("changes", "keeper.name is immutable for existing keepers")
          else Ok ()
        | Target_runtime | Target_keeper_create -> Ok ()
      in
      Ok (target, create_name_opt, expected_sha256, dry_run, ops)
    in
    (match parsed with
     | Error (field, msg) -> error_result ~field Env.Validation_failed msg
     | Ok (target, create_name_opt, expected_sha256, dry_run, ops) ->
       let target_path, target_label, expected_keeper_name =
         match target with
         | Target_runtime ->
           Config_dir_resolver.runtime_toml_path_for_base_path ~base_path, "runtime.toml", None
         | Target_keeper name ->
           ( Config_dir_resolver.keeper_toml_path_for_base_path ~base_path name
           , Printf.sprintf "keepers/%s.toml" name
           , Some name )
         | Target_keeper_create ->
           let name = Option.value ~default:"new-keeper" create_name_opt in
           ( Config_dir_resolver.keeper_toml_path_for_base_path ~base_path name
           , Printf.sprintf "keepers/%s.toml" name
           , Some name )
       in
       let run_patch () =
         let exists = Sys.file_exists target_path in
         if target = Target_keeper_create && exists
         then
           error_result
             Env.Conflict_cas
             (Printf.sprintf "keeper config %s already exists" target_label)
         else (
           (* Separate real on-disk pre-image (hashed for CAS & saved as snapshot)
              from the edit template synthesized for Target_keeper_create. *)
           let preimage_res =
             match target, exists with
             | Target_keeper_create, false ->
               let name = Option.value ~default:"new-keeper" create_name_opt in
               let template =
                 Printf.sprintf "[keeper]\nname = \"%s\"\n" (Toml_line_editor.escape_string name)
               in
               Ok ("", template)
             | Target_keeper _, false ->
               error_result Env.Not_found (Printf.sprintf "%s does not exist" target_label)
             | Target_runtime, false -> Ok ("", "")
             | _, true ->
               (match Fs_compat.load_file target_path with
                | content -> Ok (content, content)
                | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                | exception Sys_error msg ->
                  error_result Env.Store_unavailable ("config read failed: " ^ msg))
           in
           match preimage_res with
           | Error _ as err -> err
           | Ok (disk_preimage, edit_base_text) ->
             let before_sha256 = Env.sha256_hex disk_preimage in
             let cas_check =
               match expected_sha256 with
               | Some exp ->
                 if String.equal exp before_sha256
                 then Ok ()
                 else
                   error_result
                     Env.Conflict_cas
                     ~extra:[ "current_sha256", `String before_sha256 ]
                     "configuration changed on disk since last read; reload before patching"
               | None ->
                 if (not dry_run) && exists
                 then
                   error_result
                     Env.Conflict_cas
                     ~extra:[ "current_sha256", `String before_sha256 ]
                     "expected_sha256 is required when committing changes to an existing config"
                 else Ok ()
             in
             match cas_check with
             | Error _ as err -> err
             | Ok () ->
               let is_keeper_assignment_op ~keeper_name = function
                 | Op_set { table = "runtime.assignments"; key; _ }
                 | Op_remove { table = "runtime.assignments"; key } ->
                   String.equal key "runtime" || String.equal key keeper_name
                 | Op_set { table = "keeper"; key = "runtime"; _ }
                 | Op_remove { table = "keeper"; key = "runtime" } -> true
                 | Op_set _ | Op_remove _ -> false
               in
               let assignment_ops, file_ops =
                 match target, expected_keeper_name with
                 | (Target_keeper _ | Target_keeper_create), Some keeper_name ->
                   List.partition (is_keeper_assignment_op ~keeper_name) ops
                 | Target_runtime, _ | (Target_keeper _ | Target_keeper_create), None ->
                   [], ops
               in
               let assignment_target_res =
                 match assignment_ops with
                 | [] -> Ok None
                 | _ ->
                   List.fold_left
                     (fun acc op ->
                        match acc with
                        | Error _ as err -> err
                        | Ok _ ->
                          (match op with
                           | Op_remove _ -> Ok (Some None)
                           | Op_set { value = Val_string s; _ } ->
                             let trimmed = String.trim s in
                             if String.equal trimmed ""
                             then Ok (Some None)
                             else Ok (Some (Some trimmed))
                           | Op_set
                               { value =
                                   Val_int _
                                   | Val_float _
                                   | Val_bool _
                                   | Val_string_list _
                               ; _
                               } ->
                             Error
                               "keeper runtime assignment must be a string runtime/lane ID"))
                     (Ok None)
                     assignment_ops
               in
               let prepared_res =
                 let open Result.Syntax in
                 let* desired_assignment_opt = assignment_target_res in
                 let* after_text =
                   List.fold_left
                     (fun acc op ->
                        let* txt = acc in
                        apply_patch_op txt op)
                     (Ok edit_base_text)
                     file_ops
                 in
                 let* runtime_assign_preview =
                   match desired_assignment_opt, expected_keeper_name with
                   | None, _ | _, None -> Ok None
                   | Some assign_val, Some keeper_name ->
                     let runtime_path =
                       Config_dir_resolver.runtime_toml_path_for_base_path ~base_path
                     in
                     if not (Sys.file_exists runtime_path)
                     then
                       Error "runtime.toml does not exist; cannot assign keeper runtime"
                     else (
                       match Fs_compat.load_file runtime_path with
                       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                       | exception Sys_error msg ->
                         Error ("runtime.toml read failed: " ^ msg)
                       | rt_before ->
                         let rt_before_sha = Env.sha256_hex rt_before in
                         let rt_after =
                           Toml_line_editor.edit_table_scalar
                             rt_before
                             ~path:"runtime.assignments"
                             ~key:keeper_name
                             ~value:assign_val
                         in
                         let* () =
                           Runtime.validate_config_text
                             ~runtime_config_path:runtime_path
                             rt_after
                           |> Result.map_error (fun msg ->
                             "runtime assignment validation failed: " ^ msg)
                         in
                         let rt_diff, rt_hunks =
                           compute_unified_diff
                             ~before_label:"a/runtime.toml"
                             ~after_label:"b/runtime.toml"
                             ~before:rt_before
                             ~after:rt_after
                         in
                         let rt_changed = not (String.equal rt_before rt_after) in
                         Ok
                           (Some
                              ( runtime_path
                              , keeper_name
                              , assign_val
                              , rt_before_sha
                              , rt_changed
                              , rt_diff
                              , rt_hunks )))
                 in
                 let* warnings =
                   if file_ops = []
                      && target <> Target_keeper_create
                      && Option.is_some runtime_assign_preview
                   then Ok []
                   else
                     validate_patched_toml
                       ~target
                       ~expected_keeper_name
                       ~after_text
                       ~target_path
                 in
                 Ok (after_text, warnings, runtime_assign_preview)
               in
               (match prepared_res with
                | Error msg -> error_result Env.Validation_failed msg
                | Ok (after_text, warnings, runtime_assign_preview) ->
                  (let after_sha256 = Env.sha256_hex after_text in
                   let file_changed =
                     target = Target_keeper_create
                     || not (String.equal disk_preimage after_text)
                   in
                   let rt_changed, rt_diff, rt_hunks =
                     match runtime_assign_preview with
                     | None -> false, "", []
                     | Some (_, _, _, _, c, d, h) -> c, d, h
                   in
                   let changed = file_changed || rt_changed in
                   let file_diff, file_hunks =
                     if file_changed
                     then
                       compute_unified_diff
                         ~before_label:("a/" ^ target_label)
                         ~after_label:("b/" ^ target_label)
                         ~before:disk_preimage
                         ~after:after_text
                     else "", []
                   in
                   let diff_text =
                     match String.equal file_diff "", String.equal rt_diff "" with
                     | true, true -> ""
                     | false, true -> file_diff
                     | true, false -> rt_diff
                     | false, false -> file_diff ^ "\n" ^ rt_diff
                   in
                   let diff_hunks = file_hunks @ rt_hunks in
                   let known_provider_ids =
                     match target with
                     | Target_runtime ->
                       Some (collect_provider_ids_union [ disk_preimage; after_text ])
                     | Target_keeper _ | Target_keeper_create -> None
                   in
                   let r_scope =
                     reload_scope_for_ops ?known_provider_ids ~target ops
                   in
                     if dry_run
                     then
                       Ok
                         (Env.ok
                            ~now
                            (`Assoc
                              [ "applied", `Bool false
                              ; "dry_run", `Bool true
                              ; "target", `String target_label
                              ; "changed", `Bool changed
                              ; "before_sha256", `String before_sha256
                              ; "new_sha256", `String after_sha256
                              ; "snapshot_id", `Null
                              ; "reload_scope", `String (reload_scope_to_string r_scope)
                              ; "unified_diff", `String diff_text
                              ; "diff_hunks", `List diff_hunks
                              ; ( "validation_warnings"
                                , `List (List.map (fun w -> `String w) warnings) )
                              ]))
                     else (
                       (* Commit path: snapshot backup of true disk_preimage + atomic commit *)
                       let parent_dir = Filename.dirname target_path in
                       let snaps_dir = snapshots_dir_for_base_path ~base_path in
                       let snapshot_id =
                         Printf.sprintf
                           "snap-%d-%s"
                           (int_of_float now)
                           (String.sub before_sha256 0 12)
                       in
                       let snap_path =
                         Filename.concat snaps_dir (snapshot_id ^ ".toml")
                       in
                       match
                         Fs_compat.mkdir_p parent_dir;
                         Fs_compat.mkdir_p snaps_dir
                       with
                       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                       | exception exn ->
                         error_result
                           Env.Store_unavailable
                           ("config directory preparation failed: " ^ Printexc.to_string exn)
                       | () ->
                         (match Fs_compat.save_file_atomic snap_path disk_preimage with
                          | Error msg ->
                            error_result
                              Env.Store_unavailable
                              ("snapshot backup write failed: " ^ msg)
                          | Ok () ->
                            let write_res =
                              match target with
                              | Target_runtime ->
                                (* Already holding [Runtime.with_config_lock]: validate,
                                   atomically replace, republish live Runtime registry, and
                                   bump [config_text_revision] for [Server_runtime_config_broadcast]. *)
                                (match
                                   Runtime.commit_config_text_locked
                                     ~runtime_config_path:target_path
                                     after_text
                                 with
                                 | Ok _receipt ->
                                   Workspace_dataset_event.announce
                                     ~base_path
                                     Workspace_dataset_event.Runtime_config;
                                   Ok ()
                                 | Error (Runtime.Config_commit_refused detail) ->
                                   error_result Env.Validation_failed detail
                                 | Error (Runtime.Config_commit_write_failed failure) ->
                                   error_result
                                     Env.Store_unavailable
                                     ("runtime config commit failed: "
                                      ^ Fs_compat.atomic_replace_failure_to_string failure))
                              | Target_keeper _ | Target_keeper_create ->
                                let should_write_keeper =
                                  file_ops <> [] || target = Target_keeper_create
                                in
                                let write_keeper () =
                                  if not should_write_keeper
                                  then Ok ()
                                  else (
                                    match Fs_compat.save_file_atomic target_path after_text with
                                    | Error msg ->
                                      error_result
                                        Env.Store_unavailable
                                        ("atomic config write failed: " ^ msg)
                                    | Ok () ->
                                      Keeper_types_profile.invalidate_keeper_profile_snapshots ();
                                      Ok ())
                                in
                                let rollback_keeper () =
                                  if should_write_keeper
                                  then (
                                    (if target = Target_keeper_create && not exists
                                     then (
                                       try Unix.unlink target_path with
                                       | Unix.Unix_error _ -> ())
                                     else ignore (Fs_compat.save_file_atomic target_path disk_preimage));
                                    Keeper_types_profile.invalidate_keeper_profile_snapshots ())
                                in
                                (match runtime_assign_preview with
                                 | None -> write_keeper ()
                                 | Some (runtime_path, keeper_name, assign_val, rt_before_sha, _, _, _) ->
                                   (match
                                      Runtime.with_config_lock
                                        ~runtime_config_path:runtime_path
                                        (fun () ->
                                           let res =
                                             match Fs_compat.load_file runtime_path with
                                             | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
                                             | exception Sys_error msg ->
                                               error_result
                                                 Env.Store_unavailable
                                                 ("runtime.toml read failed: " ^ msg)
                                             | cur_rt ->
                                               let cur_rt_sha = Env.sha256_hex cur_rt in
                                               if not (String.equal cur_rt_sha rt_before_sha)
                                               then
                                                 Error
                                                   ( `Conflict
                                                   , `Assoc
                                                       [ ( "error"
                                                         , `Assoc
                                                             [ "code", `String "conflict_cas"
                                                             ; ( "message"
                                                               , `String
                                                                   "runtime.toml changed concurrently during keeper assignment patch; reload and retry" )
                                                             ] )
                                                       ; "current_runtime_sha256", `String cur_rt_sha
                                                       ] )
                                               else (
                                                 let rt_after =
                                                   Toml_line_editor.edit_table_scalar
                                                     cur_rt
                                                     ~path:"runtime.assignments"
                                                     ~key:keeper_name
                                                     ~value:assign_val
                                                 in
                                                 match write_keeper () with
                                                 | Error _ as err -> err
                                                 | Ok () ->
                                                   (match
                                                      Runtime.commit_config_text_locked
                                                        ~runtime_config_path:runtime_path
                                                        rt_after
                                                    with
                                                    | Ok _ ->
                                                      Workspace_dataset_event.announce
                                                        ~base_path
                                                        Workspace_dataset_event.Runtime_config;
                                                      Ok ()
                                                    | Error (Runtime.Config_commit_refused detail) ->
                                                      rollback_keeper ();
                                                      error_result Env.Validation_failed detail
                                                    | Error (Runtime.Config_commit_write_failed failure) ->
                                                      rollback_keeper ();
                                                      error_result
                                                        Env.Store_unavailable
                                                        ("runtime config commit failed: "
                                                         ^ Fs_compat.atomic_replace_failure_to_string failure)))
                                           in
                                           Ok res)
                                    with
                                    | Ok res -> res
                                    | Error detail ->
                                      error_result
                                        Env.Store_unavailable
                                        ("runtime config lock error: " ^ detail)))
                            in
                            (match write_res with
                             | Error _ as err -> err
                             | Ok () ->
                               Audit_log.log_action
                                 config
                                 ~agent_id:
                                   (let a = String.trim actor in
                                    if String.equal a "" then "operator" else a)
                                 ~action:Audit_log.RuntimeConfigWrite
                                 ~details:
                                   (`Assoc
                                     [ "target", `String target_label
                                     ; "snapshot_id", `String snapshot_id
                                     ; "before_sha256", `String before_sha256
                                     ; "after_sha256", `String after_sha256
                                     ; "op_count", `Int (List.length ops)
                                     ; "reload_scope", `String (reload_scope_to_string r_scope)
                                     ])
                                 ~outcome:Audit_log.Success
                                 ();
                               Ok
                                 (Env.ok
                                    ~now
                                    (`Assoc
                                      [ "applied", `Bool true
                                      ; "dry_run", `Bool false
                                      ; "target", `String target_label
                                      ; "changed", `Bool changed
                                      ; "before_sha256", `String before_sha256
                                      ; "new_sha256", `String after_sha256
                                      ; "snapshot_id", `String snapshot_id
                                      ; "snapshot_path", `String snap_path
                                      ; "reload_scope", `String (reload_scope_to_string r_scope)
                                      ; "unified_diff", `String diff_text
                                      ; "diff_hunks", `List diff_hunks
                                      ; ( "validation_warnings"
                                        , `List (List.map (fun w -> `String w) warnings) )
                                      ]))))))))
       in
       if dry_run
       then run_patch ()
       else (
         match target with
         | Target_runtime ->
           (* Share Runtime's authoritative config write lock with [/api/v1/runtime/config]
              and CLI writers. *)
           let parent_dir = Filename.dirname target_path in
           (match Fs_compat.mkdir_p parent_dir with
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
              error_result
                Env.Store_unavailable
                ("config directory error: " ^ Printexc.to_string exn)
            | () ->
              (match
                 Runtime.with_config_lock ~runtime_config_path:target_path (fun () ->
                   Ok (run_patch ()))
               with
               | Ok res -> res
               | Error detail ->
                 error_result
                   Env.Store_unavailable
                   ("runtime config lock failed: " ^ detail)))
         | Target_keeper _ | Target_keeper_create ->
           let lock_dir = Config_dir_resolver.locks_dir ~base_path in
           (match Fs_compat.mkdir_p lock_dir with
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
              error_result
                Env.Store_unavailable
                ("lock directory error: " ^ Printexc.to_string exn)
            | () ->
              let lock_path = Filename.concat lock_dir "config-patch.lock" in
              (match File_lock_eio.with_durable_lock ~lock_path run_patch with
               | Ok res -> res
               | Error err ->
                 error_result
                   Env.Store_unavailable
                   ("config patch lock failed: "
                    ^ File_lock_eio.durable_lock_error_to_string err)))))
  | _ -> error_result Env.Invalid_param "request body must be a JSON object"
;;

let respond_result ~req reqd = function
  | Ok json -> Http.Response.json_value ~compress:true ~request:req json reqd
  | Error (status, json) ->
    Http.Response.json_value ~status ~compress:true ~request:req json reqd
;;

let add_routes router =
  router
  |> Server_route.get
       (Server_route.Permission Masc_domain.CanReadState)
       "/api/v1/candle/ledger"
       (fun state req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let limit = Server_utils.int_query_param req "limit" ~default:100 in
          let keeper =
            Server_utils.query_param req "keeper"
            |> Option.map String.trim
            |> Fun.flip Option.bind (fun s -> if String.equal s "" then None else Some s)
          in
          let result =
            Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
              candle_ledger_json ~limit ?keeper ~base_path ())
          in
          respond_result ~req reqd result)
  |> Server_route.get
       (Server_route.Token_permission Masc_domain.CanAdmin)
       "/api/v1/config/schema"
       (fun state _actor req reqd ->
          let base_path = (Mcp_server.workspace_config state).base_path in
          let result =
            match
              parse_target
                ~target:(Server_utils.query_param req "target")
                ~keeper:(Server_utils.query_param req "keeper")
            with
            | Error (field, msg) -> error_result ~field Env.Invalid_param msg
            | Ok target ->
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                config_schema_json ~base_path ~target ())
          in
          respond_result ~req reqd result)
  |> Server_route.post
       (Server_route.Token_permission Masc_domain.CanAdmin)
       "/api/v1/config/patch"
       (fun state actor req reqd ->
          Http.Request.read_body_async reqd (fun body_str ->
            let config = Mcp_server.workspace_config state in
            let result =
              Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
                config_patch_json ~config ~actor ~body_str ())
            in
            respond_result ~req reqd result))
;;
