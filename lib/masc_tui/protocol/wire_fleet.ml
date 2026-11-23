open Masc_tui_core
open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let dashboard_shell_path = "/api/v1/dashboard/shell"
let dashboard_keepers_path = "/api/v1/gate/keepers?detailed=true&fresh=true"
let keepers_turns_path = "/api/v1/keepers/turns"
let fleet_stream_path = "/api/v1/stream/fleet"
let keeper_chat_stream_path = "/api/v1/keepers/chat/stream"
let keeper_turn_interrupt_path = "/api/v1/keepers/turn/interrupt"

let keeper_chat_history_path ~keeper ?limit ?before_seq () =
  let base =
    Printf.sprintf "/api/v1/keepers/%s/chat/history" (percent_encode keeper)
  in
  let params =
    (match limit with
    | None -> []
    | Some n -> [ Printf.sprintf "limit=%d" (max 1 n) ])
    @
    match before_seq with
    | None -> []
    | Some s -> [ Printf.sprintf "before_seq=%d" s ]
  in
  match params with
  | [] -> base
  | _ -> base ^ "?" ^ String.concat "&" params

let keeper_chat_history_page_path ~keeper ?limit ?cursor () =
  let base =
    Printf.sprintf "/api/v1/keepers/%s/chat/history/page"
      (percent_encode keeper)
  in
  let params =
    (match limit with
    | None -> []
    | Some n -> [ Printf.sprintf "limit=%d" (max 1 n) ])
    @
    match cursor with
    | None -> []
    | Some c -> [ "cursor=" ^ percent_encode c ]
  in
  match params with
  | [] -> base
  | _ -> base ^ "?" ^ String.concat "&" params

type activation_mode =
  | Activation_manual
  | Activation_on_demand
  | Activation_autonomous

type keeper_health =
  | Keeper_healthy
  | Keeper_working
  | Keeper_idle
  | Keeper_degraded
  | Keeper_recovering
  | Keeper_failing
  | Keeper_paused
  | Keeper_offline
  | Keeper_booting

type turn_lane =
  | Lane_chat
  | Lane_proactive
  | Lane_schedule
  | Lane_board
  | Lane_task
  | Lane_verification
  | Lane_maintenance
  | Lane_internal

type active_turn = {
  lane : turn_lane;
  started_at_unix : float;
  interrupt_token : string;
  phase : string option;
  tool_in_flight : string option;
  elapsed_ms : float option;
}

type keeper_turn_state =
  | Turn_idle
  | Turn_active of active_turn
  | Turn_unavailable of string

type keeper_turn_row = {
  keeper_name : string;
  chat_control_token : string option;
  state : keeper_turn_state;
}

type context_unavailable_reason =
  | Context_measurement_missing
  | Context_record_undecodable
  | Context_record_read_failed
  | Context_record_without_usage
  | Context_trace_mismatch
  | Context_cumulative_usage
  | Context_turn_total_usage
  | Context_usage_scope_unavailable
  | Context_tokens_exceed_window
  | Context_input_estimate
  | Context_input_provenance_unavailable

type context_reading =
  | Context_measured of {
      ratio : float option;
      tokens : int;
      window : int option;
      absolute_turn : int option;
      measured_at_unix : float option;
    }
  | Context_not_measured of {
      reason : context_unavailable_reason;
      estimated_ratio : float option;
    }

type keeper_summary = {
  name : string;
  group : string option;
  company : string;
  health : keeper_health;
  paused : bool;
  keepalive_running : bool;
  activation_mode : activation_mode;
  runtime_id : string;
  model_id : string option;
  current_task_id : string option;
  context : context_reading Observed.t;
  total_turns : int Observed.t;
  last_turn_at_unix : float option;
  active_turn : active_turn option;
  activity_sparkline_24h : float list;
}

type unreadable_keeper = {
  name : string;
  reason : string;
}

type keepers_roster = {
  keepers : keeper_summary list;
  unreadable : unreadable_keeper list;
}

type attention_bucket =
  | Bucket_asks
  | Bucket_approvals
  | Bucket_confirmations

type attention_item = {
  id : string;
  bucket : attention_bucket;
  kind : Health.attention_kind;
  title : string;
  summary : string;
  created_at_unix : float option;
  keeper : string option;
}

type keeper_sandbox_profile =
  | Profile_microvm
  | Profile_remote_ssh
  | Profile_docker
  | Profile_other of string

type candle_supply = {
  issued_milli : string;
  burned_milli : string;
  circulating_milli : string;
}

type candle_observation =
  | Candle_off
  | Candle_disabled of { reason : string }
  | Candle_ready of candle_supply

type turn_slot = {
  starts_at : int;
  ok : int;
  rested : int;
  failed : int;
  scheduled : int;
  reacted : int;
  chat : int;
  own : int;
  unknown : int;
}

type turn_pulse = { known_since : float; slots : turn_slot list }

let turn_slot_seconds = 1800

type keeper_roster_extras = {
  sandbox_profiles : (string * keeper_sandbox_profile) list;
  candle_balances_milli : (string * int) list;
  candle_summary : candle_observation option;
  turn_pulses : (string * turn_pulse) list;
}

type execution_keeper_enrichment = {
  keeper_name : string;
  sandbox_profile : keeper_sandbox_profile option;
  total_turns : int option;
}

type company_group = {
  company : string;
  keepers : keeper_summary list;
  running_count : int;
  working_count : int;
  failing_count : int;
  paused_count : int;
  attention_count : int;
  microvm_count : int;
  ssh_count : int;
  docker_count : int;
  turns_24h : int;
  cost_24h_usd : float;
  sparkline_24h : float list;
}

type daily_scorecard = {
  tasks_done_24h : int Observed.t;
  tasks_done_total : int Observed.t;
  tasks_in_progress : int Observed.t;
  tasks_claimed : int Observed.t;
  tasks_awaiting_verification : int Observed.t;
  tasks_todo : int Observed.t;
  tasks_cancelled : int Observed.t;
  goals_completed_24h : int Observed.t;
  verifications_passed_24h : int Observed.t;
  verifications_rejected_24h : int Observed.t;
  board_posts_24h : int Observed.t;
  turns_24h : int Observed.t;
  cost_24h_usd : float Observed.t;
}

type shell_counts = {
  agents : int;
  tasks : int;
  tasks_done_24h : int;
  keepers : int;
  persisted_keepers : int Observed.t;
  configured_keepers : int Observed.t;
  total_runtimes : int;
}

type shell_group = {
  group : string;
  keeper_count : int;
  keepers : string list;
}

type dashboard_shell = {
  generated_at_unix : float option;
  project : string option;
  version : string option;
  counts : shell_counts;
  scorecard_24h : daily_scorecard;
  groups : shell_group list;
}

let keeper_health_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "healthy" | "ok" | "active" | "running" -> Some Keeper_healthy
  | "working" | "in_turn" | "busy" -> Some Keeper_working
  | "idle" | "ready" | "standby" -> Some Keeper_idle
  | "degraded" | "warning" -> Some Keeper_degraded
  | "recovering" -> Some Keeper_recovering
  | "failing" | "failed" | "error" | "unhealthy" | "crashed" ->
      Some Keeper_failing
  | "paused" -> Some Keeper_paused
  | "offline" | "stopped" | "inactive" | "down" -> Some Keeper_offline
  | "booting" | "starting" -> Some Keeper_booting
  | _ -> None

let activation_mode_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "manual" -> Some Activation_manual
  | "on_demand" -> Some Activation_on_demand
  | "autonomous" -> Some Activation_autonomous
  | _ -> None

let turn_lane_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "chat" | "chat_operation" | "interactive" | "operator_chat" -> Some Lane_chat
  | "proactive" | "keepalive" | "autonomous" -> Some Lane_proactive
  | "schedule" | "scheduled" -> Some Lane_schedule
  | "board" | "board_attention" -> Some Lane_board
  | "task" -> Some Lane_task
  | "verification" | "verifier" -> Some Lane_verification
  | "maintenance" -> Some Lane_maintenance
  | "internal" | "librarian" -> Some Lane_internal
  | _ -> None

let prefix_before_dash name =
  match String.index_opt name '-' with
  | Some idx when idx > 0 -> Some (String.sub name 0 idx)
  | Some _ | None -> None

let classify_company_single ~group _name =
  match group with
  | Some g when not (String.equal (String.trim g) "") -> Some (String.trim g)
  | Some _ | None -> None

let company_sort_rank = function
  | "Other" -> 1
  | _ -> 0

let aggregate_company_sparkline (members : keeper_summary list) =
  let non_empty =
    List.filter_map
      (fun (k : keeper_summary) ->
        if k.activity_sparkline_24h = [] then None
        else Some (Array.of_list k.activity_sparkline_24h))
      members
  in
  match non_empty with
  | [] -> []
  | arrs ->
      let max_len =
        List.fold_left (fun acc a -> max acc (Array.length a)) 0 arrs
      in
      let out = Array.make max_len 0.0 in
      List.iter
        (fun a ->
          let len = Array.length a in
          let offset = max_len - len in
          for i = 0 to len - 1 do
            out.(offset + i) <- out.(offset + i) +. a.(i)
          done)
        arrs;
      Array.to_list out

let group_by_company ?(attention = []) ?(sandbox_profiles = [])
    ?(keeper_costs_24h = []) keepers =
  let prefix_counts = Hashtbl.create 16 in
  List.iter
    (fun (k : keeper_summary) ->
      match classify_company_single ~group:k.group k.name with
      | Some _ -> ()
      | None -> (
          match prefix_before_dash k.name with
          | Some p ->
              let prev =
                match Hashtbl.find_opt prefix_counts p with
                | Some c -> c
                | None -> 0
              in
              Hashtbl.replace prefix_counts p (prev + 1)
          | None -> ()))
    keepers;
  let resolve_company (k : keeper_summary) =
    match classify_company_single ~group:k.group k.name with
    | Some c -> c
    | None -> (
        match prefix_before_dash k.name with
        | Some p -> (
            match Hashtbl.find_opt prefix_counts p with
            | Some c when c >= 2 -> p
            | Some _ | None -> "Other")
        | None -> "Other")
  in
  let profile_tbl = Hashtbl.create (max 8 (List.length sandbox_profiles)) in
  List.iter (fun (n, p) -> Hashtbl.replace profile_tbl n p) sandbox_profiles;
  let cost_tbl = Hashtbl.create (max 8 (List.length keeper_costs_24h)) in
  List.iter (fun (n, c) -> Hashtbl.replace cost_tbl n c) keeper_costs_24h;
  let buckets : (string, keeper_summary list) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (k : keeper_summary) ->
      let comp = resolve_company k in
      let k' = { k with company = comp } in
      let prev =
        match Hashtbl.find_opt buckets comp with Some l -> l | None -> []
      in
      Hashtbl.replace buckets comp (k' :: prev))
    keepers;
  let attn_for_keeper name =
    List.fold_left
      (fun acc (item : attention_item) ->
        match item.keeper with
        | Some kn when String.equal kn name -> acc + 1
        | Some _ | None -> acc)
      0 attention
  in
  let groups =
    Hashtbl.fold
      (fun company rev_members acc ->
        let members =
          List.sort
            (fun (a : keeper_summary) (b : keeper_summary) ->
              String.compare a.name b.name)
            rev_members
        in
        let running_count = ref 0 in
        let working_count = ref 0 in
        let failing_count = ref 0 in
        let paused_count = ref 0 in
        let attention_count = ref 0 in
        let microvm_count = ref 0 in
        let ssh_count = ref 0 in
        let docker_count = ref 0 in
        let turns_24h = ref 0 in
        let cost_24h_usd = ref 0.0 in
        List.iter
          (fun (k : keeper_summary) ->
            (match k.health with
            | Keeper_failing -> incr failing_count
            | Keeper_offline -> ()
            | Keeper_paused -> incr paused_count
            | Keeper_healthy | Keeper_working | Keeper_booting | Keeper_idle
            | Keeper_degraded | Keeper_recovering
              when k.paused ->
                incr paused_count
            | Keeper_working | Keeper_booting ->
                incr running_count;
                incr working_count
            | Keeper_healthy | Keeper_degraded | Keeper_recovering ->
                incr running_count
            | Keeper_idle ->
                if k.keepalive_running then incr running_count);
            attention_count := !attention_count + attn_for_keeper k.name;
            (match Hashtbl.find_opt profile_tbl k.name with
            | Some Profile_microvm -> incr microvm_count
            | Some Profile_remote_ssh -> incr ssh_count
            | Some Profile_docker -> incr docker_count
            | Some (Profile_other _) | None -> ());
            let k_turns =
              List.fold_left ( +. ) 0.0 k.activity_sparkline_24h
              |> Float.round |> Int.of_float
            in
            turns_24h := !turns_24h + k_turns;
            let k_cost =
              match Hashtbl.find_opt cost_tbl k.name with
              | Some c -> c
              | None -> 0.0
            in
            cost_24h_usd := !cost_24h_usd +. k_cost)
          members;
        let sparkline_24h = aggregate_company_sparkline members in
        {
          company;
          keepers = members;
          running_count = !running_count;
          working_count = !working_count;
          failing_count = !failing_count;
          paused_count = !paused_count;
          attention_count = !attention_count;
          microvm_count = !microvm_count;
          ssh_count = !ssh_count;
          docker_count = !docker_count;
          turns_24h = !turns_24h;
          cost_24h_usd = !cost_24h_usd;
          sparkline_24h;
        }
        :: acc)
      buckets []
  in
  List.sort
    (fun (a : company_group) (b : company_group) ->
      let ra = company_sort_rank a.company in
      let rb = company_sort_rank b.company in
      if ra <> rb then Int.compare ra rb
      else String.compare a.company b.company)
    groups

let decode_active_turn json =
  let* lane = decode_enum ~field:"lane" turn_lane_of_string json in
  let* started_at_unix = required_finite_float json "started_at_unix" in
  let* interrupt_token = required_string_field json "interrupt_token" in
  let* phase = optional_nonblank_string json "phase" in
  let* tool_in_flight = optional_nonblank_string json "tool_in_flight" in
  let* elapsed_ms = optional_finite_float json "elapsed_ms" in
  Ok
    {
      lane;
      started_at_unix;
      interrupt_token;
      phase;
      tool_in_flight;
      elapsed_ms;
    }

let decode_keeper_turn_row json =
  let* keeper_name = required_nonblank_string json "keeper_name" in
  let* chat_control_token =
    optional_nonblank_string json "chat_control_token"
  in
  let* status = required_nonblank_string json "status" in
  match status with
  | "unavailable" ->
      let* detail = required_string_field json "detail" in
      Ok
        { keeper_name; chat_control_token; state = Turn_unavailable detail }
  | "ok" -> (
      let* turn_val = required_member json "turn" in
      match turn_val with
      | `Null -> Ok { keeper_name; chat_control_token; state = Turn_idle }
      | `Assoc _ as turn_json ->
          let* active = decode_active_turn turn_json in
          Ok { keeper_name; chat_control_token; state = Turn_active active }
      | bad -> field_type_error "turn" "an object or null" bad)
  | other -> Error (Printf.sprintf "unknown keeper turn status %S" other)

let decode_keeper_turns json =
  let* _, body = unwrap_v2_or_raw json in
  let* rows =
    if has_field body "keepers" then required_list_field body "keepers"
    else if has_field body "turns" then required_list_field body "turns"
    else required_list_field body "rows"
  in
  decode_list "keepers" decode_keeper_turn_row rows

let decode_float_list json key =
  let* items = optional_list_field json key in
  decode_list key
    (function
      | `Float f when Float.is_finite f -> Ok f
      | `Int i -> Ok (Float.of_int i)
      | bad -> field_type_error key "a finite number" bad)
    items

let decode_turn_slot slot =
  let* starts_at = required_int_field slot "starts_at" in
  let count = required_nonnegative_int_field slot in
  let* ok = count "ok" in
  let* rested = count "rested" in
  let* failed = count "failed" in
  let* scheduled = count "scheduled" in
  let* reacted = count "reacted" in
  let* chat = count "chat" in
  let* own = count "own" in
  let* unknown = count "unknown" in
  Ok { starts_at; ok; rested; failed; scheduled; reacted; chat; own; unknown }

let decode_turn_pulse json =
  match optional_object_field json "recent_turns" with
  | Error _ as err -> err
  | Ok None -> Ok None
  | Ok (Some rt) ->
      let* known_since = required_nonnegative_float rt "known_since" in
      let* raw_slots = optional_list_field rt "slots" in
      let* slots = decode_list "recent_turns.slots" decode_turn_slot raw_slots in
      let oldest_first =
        List.sort (fun (a : turn_slot) b -> Int.compare a.starts_at b.starts_at) slots
      in
      Ok (Some { known_since; slots = oldest_first })

(* Turns that ran ([ok] and [failed], as the server's fleet total counts them)
   per slot from the oldest stored slot to the newest. The server stores only
   slots that hold a turn, so a slot between two stored ones held none and is
   drawn as zero instead of being closed up. *)
let sparkline_of_pulse { slots; known_since = _ } =
  match slots with
  | [] -> []
  | first :: _ ->
      let by_start = Hashtbl.create (List.length slots) in
      List.iter (fun (s : turn_slot) -> Hashtbl.replace by_start s.starts_at s) slots;
      let last = (List.nth slots (List.length slots - 1)).starts_at in
      let n = ((last - first.starts_at) / turn_slot_seconds) + 1 in
      List.init n (fun i ->
          match Hashtbl.find_opt by_start (first.starts_at + (i * turn_slot_seconds)) with
          | Some s -> Float.of_int (s.ok + s.failed)
          | None -> 0.0)

let decode_lane_turn_count ~observed_at json =
  match optional_object_field json "runtime_lane_observation" with
  | Error _ | Ok None -> Observed.unreported
  | Ok (Some obs) -> (
      match optional_object_field obs "turn" with
      | Error _ | Ok None -> Observed.unreported
      | Ok (Some turn_obj) -> (
          match optional_int_field turn_obj "turn_count" with
          | Ok (Some n) when n >= 0 -> Observed.value ~observed_at n
          | Ok (Some _) | Ok None | Error _ -> Observed.unreported))

let context_unavailable_reason_of_string = function
  | "context_measurement_missing" -> Some Context_measurement_missing
  | "turn_record_undecodable" -> Some Context_record_undecodable
  | "turn_record_read_failed" -> Some Context_record_read_failed
  | "turn_record_without_usage" -> Some Context_record_without_usage
  | "turn_record_trace_mismatch" -> Some Context_trace_mismatch
  | "conversation_cumulative_usage" -> Some Context_cumulative_usage
  | "turn_total_usage" -> Some Context_turn_total_usage
  | "usage_scope_unavailable" -> Some Context_usage_scope_unavailable
  | "context_tokens_exceed_window" -> Some Context_tokens_exceed_window
  | "context_input_estimate" -> Some Context_input_estimate
  | "input_provenance_unavailable" -> Some Context_input_provenance_unavailable
  | _ -> None

(* The row carries Keeper_context_observation_projection's fields.
   [context_provenance] says whether [context_ratio] measured a dispatched
   request; any other provenance names the reason in
   [context_metrics_unavailable_reason] and may carry an estimate. A row
   without [context_provenance] is a server that reported no context. *)
let decode_context_reading ~observed_at json =
  if not (has_field json "context_provenance") then Ok Observed.unreported
  else
    let* provenance = required_nonblank_string json "context_provenance" in
    match provenance with
    | "measured" ->
        let* tokens = required_int_field json "context_tokens" in
        let* window = required_nullable_int_field json "context_max" in
        let* ratio = optional_finite_float json "context_ratio" in
        let* context = optional_object_field json "context" in
        let* measured_at_unix, absolute_turn =
          match context with
          | None -> Ok (None, None)
          | Some ctx ->
              let* at = decode_optional_timestamp_unix ctx "observed_at" in
              let* turn = optional_int_field ctx "absolute_turn" in
              Ok (at, turn)
        in
        Ok
          (Observed.value ~observed_at
             (Context_measured
                { ratio; tokens; window; absolute_turn; measured_at_unix }))
    | "estimated" | "unavailable" ->
        let* reason =
          decode_enum ~field:"context_metrics_unavailable_reason"
            context_unavailable_reason_of_string json
        in
        let* estimated_ratio =
          optional_finite_float json "estimated_context_ratio"
        in
        Ok
          (Observed.value ~observed_at
             (Context_not_measured { reason; estimated_ratio }))
    | other ->
        Error (Printf.sprintf "unknown context_provenance value %S" other)

let decode_keeper_summary ~observed_at json =
  let* name = required_nonblank_string json "name" in
  let* group = optional_nonblank_string json "group" in
  let* health = decode_enum ~field:"health" keeper_health_of_string json in
  let* paused = required_bool_field json "paused" in
  let* keepalive_running = required_bool_field json "keepalive_running" in
  let* activation_mode =
    decode_enum ~field:"activation_mode" activation_mode_of_string json
  in
  let* runtime_id = required_string_field json "runtime_id" in
  let* model_id = optional_nonblank_string json "model_id" in
  let* current_task_id = optional_nonblank_string json "current_task_id" in
  let* context = decode_context_reading ~observed_at json in
  let* total_turns_raw = observed_int ~observed_at json "total_turns" in
  let total_turns =
    match total_turns_raw with
    | Observed.Value _ -> total_turns_raw
    | Observed.Absent | Observed.Unreported | Observed.Loading _ | Observed.Failed _ -> (
        match decode_lane_turn_count ~observed_at json with
        | Observed.Value _ as v -> v
        | Observed.Absent | Observed.Unreported | Observed.Loading _ | Observed.Failed _ ->
            total_turns_raw)
  in
  let* last_turn_at_unix =
    decode_optional_timestamp_unix json "last_turn_at_unix"
  in
  let* active_turn =
    let* turn_obj = optional_object_field json "active_turn" in
    match turn_obj with
    | None -> Ok None
    | Some obj ->
        let* t = decode_active_turn obj in
        Ok (Some t)
  in
  let* explicit_sparkline = decode_float_list json "activity_sparkline_24h" in
  let* activity_sparkline_24h =
    if explicit_sparkline <> [] then Ok explicit_sparkline
    else
      let* pulse = decode_turn_pulse json in
      Ok (Option.fold ~none:[] ~some:sparkline_of_pulse pulse)
  in
  let company =
    match classify_company_single ~group name with
    | Some c -> c
    | None -> "Other"
  in
  Ok
    {
      name;
      group;
      company;
      health;
      paused;
      keepalive_running;
      activation_mode;
      runtime_id;
      model_id;
      current_task_id;
      context;
      total_turns;
      last_turn_at_unix;
      active_turn;
      activity_sparkline_24h;
    }

(* The gate roster lists a keeper whose effective meta did not read as a row
   with [name] and an [effective_meta_error] object but no health, runtime or
   activation fields (Keeper_tool_surface_ops.keeper_list_error_row_json).
   Such a row decodes apart from the summaries, so one broken keeper TOML
   does not fail the whole roster. *)
type roster_row =
  | Roster_keeper of keeper_summary
  | Roster_unreadable of unreadable_keeper

let decode_roster_row ~observed_at json =
  let* meta_error = optional_object_field json "effective_meta_error" in
  match meta_error with
  | Some err ->
      let* name = required_nonblank_string json "name" in
      let* reason = required_string_field err "message" in
      Ok (Roster_unreadable { name; reason })
  | None ->
      let* summary = decode_keeper_summary ~observed_at json in
      Ok (Roster_keeper summary)

let decode_keepers_roster ~observed_at json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "keepers" in
  let* rows = decode_list "keepers" (decode_roster_row ~observed_at) items in
  let keepers =
    List.filter_map
      (function
        | Roster_keeper k -> Some k
        | Roster_unreadable _ -> None)
      rows
  in
  let unreadable =
    List.filter_map
      (function
        | Roster_unreadable u -> Some u
        | Roster_keeper _ -> None)
      rows
  in
  Ok ({ keepers; unreadable } : keepers_roster)

let sandbox_profile_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "microvm" -> Profile_microvm
  | "remote_ssh" | "ssh" -> Profile_remote_ssh
  | "docker" -> Profile_docker
  | other -> Profile_other other

let decode_milli_string json key =
  match member key json with
  | `String s when not (String.equal (String.trim s) "") -> Ok (String.trim s)
  | `Int i when i >= 0 -> Ok (Int.to_string i)
  | bad -> field_type_error key "a non-negative milli string or integer" bad

(* [candle] is Candle_observation.to_json: [status] names the ledger state and
   only a ready ledger carries the supply amounts. *)
let decode_candle_observation_opt body =
  let* candle = optional_object_field body "candle" in
  match candle with
  | None -> Ok None
  | Some cobj -> (
      let* status = required_nonblank_string cobj "status" in
      match status with
      | "off" -> Ok (Some Candle_off)
      | "disabled" ->
          let* reason = required_string_field cobj "reason" in
          Ok (Some (Candle_disabled { reason }))
      | "ready" ->
          let* issued_milli = decode_milli_string cobj "issued_milli" in
          let* burned_milli = decode_milli_string cobj "burned_milli" in
          let* circulating_milli =
            decode_milli_string cobj "circulating_milli"
          in
          Ok
            (Some
               (Candle_ready { issued_milli; burned_milli; circulating_milli }))
      | other -> Error (Printf.sprintf "unknown candle status value %S" other))

let extract_sandbox_profile_opt obj =
  let direct =
    match optional_nonblank_string obj "sandbox_profile" with
    | Ok (Some s) -> Some (sandbox_profile_of_string s)
    | Ok None | Error _ -> None
  in
  match direct with
  | Some _ -> direct
  | None -> (
      match optional_object_field obj "meta" with
      | Ok (Some meta) -> (
          match optional_nonblank_string meta "sandbox_profile" with
          | Ok (Some s) -> Some (sandbox_profile_of_string s)
          | Ok None | Error _ -> None)
      | Ok None | Error _ -> None)

let extract_candle_balance_opt obj =
  let parse_milli = function
    | `Int i -> Some i
    | `String s -> int_of_string_opt (String.trim s)
    | `Float f when Float.is_finite f -> Some (Int.of_float f)
    | `Null | `Bool _ | `Intlit _ | `Float _ | `Assoc _ | `List _ -> None
  in
  match parse_milli (member "candle_balance_milli" obj) with
  | Some v -> Some v
  | None -> (
      match optional_object_field obj "candle" with
      | Ok (Some c) -> parse_milli (member "balance_milli" c)
      | Ok None | Error _ -> None)

let decode_keepers_roster_extras json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "keepers" in
  let* candle_summary = decode_candle_observation_opt body in
  let profiles = ref [] in
  let balances = ref [] in
  let pulses = ref [] in
  List.iter
    (fun item ->
      match optional_nonblank_string item "name" with
      | Ok (Some name) ->
          (match extract_sandbox_profile_opt item with
          | Some p -> profiles := (name, p) :: !profiles
          | None -> ());
          (match extract_candle_balance_opt item with
          | Some b -> balances := (name, b) :: !balances
          | None -> ());
          (* A malformed pulse already fails the roster decode
             ([decode_keeper_summary]), so it never reaches here. *)
          (match decode_turn_pulse item with
          | Ok (Some pulse) -> pulses := (name, pulse) :: !pulses
          | Ok None | Error _ -> ())
      | Ok None | Error _ -> ())
    items;
  Ok
    {
      sandbox_profiles = List.rev !profiles;
      candle_balances_milli = List.rev !balances;
      candle_summary;
      turn_pulses = List.rev !pulses;
    }

let decode_execution_keeper_enrichments json =
  let* _, body = unwrap_v2_or_raw json in
  let* candle_summary = decode_candle_observation_opt body in
  let* items = optional_list_field body "keepers" in
  let enrichments =
    List.filter_map
      (fun item ->
        match optional_nonblank_string item "name" with
        | Ok (Some keeper_name) ->
            let sandbox_profile = extract_sandbox_profile_opt item in
            let total_turns =
              match optional_int_field item "total_turns" with
              | Ok (Some n) when n >= 0 -> Some n
              | Ok (Some _) | Ok None | Error _ -> (
                  match optional_int_field item "turn_count" with
                  | Ok (Some n) when n >= 0 -> Some n
                  | Ok (Some _) | Ok None | Error _ -> None)
            in
            Some { keeper_name; sandbox_profile; total_turns }
        | Ok None | Error _ -> None)
      items
  in
  Ok (enrichments, candle_summary)

type turn_usage_scope =
  | Usage_per_request
  | Usage_turn_total
  | Usage_conversation_cumulative
  | Usage_scope_unavailable

type turn_input_provenance =
  | Input_measured_request
  | Input_context_estimate

type turn_record_row = {
  absolute_turn : int;
  input_tokens : int option;
  usage_scope : turn_usage_scope;
  input_provenance : turn_input_provenance option;
  context_window : int option;
  provider_context_window : int option;
}

type keeper_turn_records = {
  keeper : string;
  skipped_rows : int;
  rows : turn_record_row list;
}

(* The server clamps [limit] to this (Server_dashboard_http_keeper_read_limits
   .trajectory_max_limit). *)
let keeper_turn_records_max_limit = 500

let keeper_turn_records_path ~keeper ~limit =
  Printf.sprintf "/api/v1/keepers/%s/turn-records?limit=%d"
    (percent_encode keeper)
    (max 1 (min keeper_turn_records_max_limit limit))

let turn_usage_scope_of_string = function
  | "per_request" -> Some Usage_per_request
  | "turn_total" -> Some Usage_turn_total
  | "conversation_cumulative" -> Some Usage_conversation_cumulative
  | "unavailable" -> Some Usage_scope_unavailable
  | _ -> None

let turn_input_provenance_of_string = function
  | "measured_request" -> Some Input_measured_request
  | "context_estimate" -> Some Input_context_estimate
  | _ -> None

(* One [entries] item is [{record: Turn_record.to_json, diff_vs_prev}]. Only
   the fields the context-fill rule reads are decoded. *)
let decode_turn_record_row json =
  let* record = required_object_field json "record" in
  let* absolute_turn = required_int_field record "absolute_turn" in
  let* input_tokens = optional_int_field record "input_tokens" in
  let* usage_scope =
    decode_enum ~field:"usage_scope" turn_usage_scope_of_string record
  in
  let* input_provenance =
    decode_optional_enum ~field:"input_provenance"
      turn_input_provenance_of_string record
  in
  let* context_window = optional_int_field record "context_window" in
  let* provider_context_window =
    optional_int_field record "provider_context_window"
  in
  Ok
    {
      absolute_turn;
      input_tokens;
      usage_scope;
      input_provenance;
      context_window;
      provider_context_window;
    }

let decode_keeper_turn_records json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* skipped_rows = required_nonnegative_int_field body "skipped_rows" in
  let* entries = required_list_field body "entries" in
  let* rows = decode_list "entries" decode_turn_record_row entries in
  Ok { keeper; skipped_rows; rows }

(* The same rule Keeper_context_observation_projection applies to the newest
   record: a fill is measured only for per-request usage whose input counts a
   dispatched request, against the provider window (else the configured one),
   and never above that window. *)
let turn_record_context_fill (r : turn_record_row) =
  let measured_tokens =
    match r.usage_scope, r.input_provenance with
    | Usage_per_request, Some Input_measured_request -> r.input_tokens
    | Usage_per_request, (Some Input_context_estimate | None)
    | ( ( Usage_turn_total | Usage_conversation_cumulative
        | Usage_scope_unavailable )
      , (Some (Input_measured_request | Input_context_estimate) | None) ) ->
        None
  in
  let window =
    match r.provider_context_window with
    | Some _ as reported -> reported
    | None -> r.context_window
  in
  match measured_tokens, window with
  | Some tokens, Some maximum
    when maximum > 0 && tokens >= 0 && tokens <= maximum ->
      Some (Float.of_int tokens /. Float.of_int maximum)
  | Some _, (Some _ | None) | None, (Some _ | None) -> None

let decode_attention_item json =
  let* kind_word = required_nonblank_string json "kind" in
  let* id = required_nonblank_string json "id" in
  let* title = required_nonblank_string json "title" in
  let* summary =
    match optional_string_field json "summary" with
    | Ok (Some s) -> Ok s
    | Ok None -> Ok ""
    | Error _ as err -> err
  in
  let* created_at_unix = decode_optional_timestamp_unix json "created_at_unix" in
  let* bucket, kind, keeper =
    match kind_word with
    | "pending_ask" ->
        let* ask_id =
          match optional_nonblank_string json "ask_id" with
          | Ok (Some v) -> Ok v
          | Ok None -> Ok id
          | Error _ as err -> err
        in
        let* keeper = required_nonblank_string json "keeper" in
        Ok
          ( Bucket_asks
          , Health.Pending_ask { ask_id; keeper }
          , Some keeper )
    | "held_tool_approval" ->
        let* request_id =
          match optional_nonblank_string json "request_id" with
          | Ok (Some v) -> Ok v
          | Ok None -> Ok id
          | Error _ as err -> err
        in
        let* keeper = required_nonblank_string json "keeper" in
        let* tool = required_nonblank_string json "tool" in
        Ok
          ( Bucket_approvals
          , Health.Held_tool_approval { request_id; keeper; tool }
          , Some keeper )
    | "goal_confirmation" ->
        let* goal_id =
          match optional_nonblank_string json "goal_id" with
          | Ok (Some v) -> Ok v
          | Ok None -> Ok id
          | Error _ as err -> err
        in
        let* keeper = optional_nonblank_string json "keeper" in
        Ok
          ( Bucket_confirmations
          , Health.Goal_confirmation { goal_id }
          , keeper )
    | other -> Error (Printf.sprintf "unknown attention kind %S" other)
  in
  Ok { id; bucket; kind; title; summary; created_at_unix; keeper }

let empty_scorecard =
  {
    tasks_done_24h = Observed.unreported;
    tasks_done_total = Observed.unreported;
    tasks_in_progress = Observed.unreported;
    tasks_claimed = Observed.unreported;
    tasks_awaiting_verification = Observed.unreported;
    tasks_todo = Observed.unreported;
    tasks_cancelled = Observed.unreported;
    goals_completed_24h = Observed.unreported;
    verifications_passed_24h = Observed.unreported;
    verifications_rejected_24h = Observed.unreported;
    board_posts_24h = Observed.unreported;
    turns_24h = Observed.unreported;
    cost_24h_usd = Observed.unreported;
  }

let decode_daily_scorecard ~observed_at json =
  let* tasks_done_24h = observed_int ~observed_at json "tasks_done_24h" in
  let* tasks_done_total = observed_int ~observed_at json "tasks_done_total" in
  let* tasks_in_progress = observed_int ~observed_at json "tasks_in_progress" in
  let* tasks_claimed = observed_int ~observed_at json "tasks_claimed" in
  let* tasks_awaiting_verification =
    observed_int ~observed_at json "tasks_awaiting_verification"
  in
  let* tasks_todo = observed_int ~observed_at json "tasks_todo" in
  let* tasks_cancelled = observed_int ~observed_at json "tasks_cancelled" in
  let* goals_completed_24h =
    observed_int ~observed_at json "goals_completed_24h"
  in
  let* verifications_passed_24h =
    observed_int ~observed_at json "verifications_passed_24h"
  in
  let* verifications_rejected_24h =
    observed_int ~observed_at json "verifications_rejected_24h"
  in
  let* board_posts_24h = observed_int ~observed_at json "board_posts_24h" in
  let* turns_24h = observed_int ~observed_at json "turns_24h" in
  let* cost_24h_usd = observed_float ~observed_at json "cost_24h_usd" in
  Ok
    {
      tasks_done_24h;
      tasks_done_total;
      tasks_in_progress;
      tasks_claimed;
      tasks_awaiting_verification;
      tasks_todo;
      tasks_cancelled;
      goals_completed_24h;
      verifications_passed_24h;
      verifications_rejected_24h;
      board_posts_24h;
      turns_24h;
      cost_24h_usd;
    }

let decode_shell_group json =
  let* group = required_nonblank_string json "group" in
  let* keeper_count = required_nonnegative_int_field json "keeper_count" in
  let* keepers = required_string_list json "keepers" in
  Ok { group; keeper_count; keepers }

let decode_dashboard_shell ~observed_at json =
  let* meta, body = unwrap_v2_or_raw json in
  let* generated_at_unix =
    match meta with
    | Some (m : envelope_meta) -> Ok (Some m.generated_at_unix)
    | None -> (
        match decode_optional_timestamp_unix body "generated_at" with
        | Ok (Some _ as ts) -> Ok ts
        | Ok None -> decode_optional_timestamp_unix body "generated_at_unix"
        | Error _ as err -> err)
  in
  let* status_obj = optional_object_field body "status" in
  let* project =
    match status_obj with
    | Some st -> optional_nonblank_string st "project"
    | None -> Ok None
  in
  let* version =
    match status_obj with
    | Some st -> optional_nonblank_string st "version"
    | None -> Ok None
  in
  let* counts_obj = required_object_field body "counts" in
  let* agents = required_nonnegative_int_field counts_obj "agents" in
  let* tasks = required_nonnegative_int_field counts_obj "tasks" in
  let* tasks_done_24h_obs =
    observed_int ~observed_at counts_obj "tasks_done_24h"
  in
  let* tasks_done_24h =
    match tasks_done_24h_obs with
    | Observed.Value { data; _ } when data < 0 ->
        Error
          (Printf.sprintf "field \"tasks_done_24h\" must be >= 0, got %d" data)
    | Observed.Value { data; _ } -> Ok data
    | Observed.Absent | Observed.Unreported | Observed.Loading _ | Observed.Failed _ ->
        Ok 0
  in
  let* keepers = required_nonnegative_int_field counts_obj "keepers" in
  let* persisted_keepers =
    observed_int ~observed_at counts_obj "persisted_keepers"
  in
  let* configured_keepers =
    observed_int ~observed_at body "configured_keepers"
  in
  let* total_runtimes =
    required_nonnegative_int_field counts_obj "total_runtimes"
  in
  let* scorecard_24h =
    match optional_object_field body "scorecard_24h" with
    | Ok (Some sc_json) -> decode_daily_scorecard ~observed_at sc_json
    | Ok None -> Ok empty_scorecard
    | Error _ as err -> err
  in
  let* group_items = optional_list_field body "groups" in
  let* groups = decode_list "groups" decode_shell_group group_items in
  Ok
    {
      generated_at_unix;
      project;
      version;
      counts =
        {
          agents;
          tasks;
          tasks_done_24h;
          keepers;
          persisted_keepers;
          configured_keepers;
          total_runtimes;
        };
      scorecard_24h;
      groups;
    }

type fleet_stream_reading = {
  status : string;
  operator_action_required : bool;
  bootable_count : int;
  running_count : int;
  executable_count : int;
  failing_count : int;
  recovering_count : int;
  paused_count : int;
  proactive_interval_sec : int option;
}

type fleet_degradation = {
  since_unix : float;
  reason : string;
}

type fleet_stream_event =
  | Fleet_snapshot of {
      schema : int;
      revision : int;
      measured_at_unix : float;
      reading : fleet_stream_reading;
      degraded : fleet_degradation option;
    }
  | Fleet_changed of {
      revision : int;
      measured_at_unix : float;
      reading : fleet_stream_reading;
    }
  | Fleet_unavailable_snapshot of {
      schema : int;
      revision : int;
      degradation : fleet_degradation;
    }
  | Fleet_degraded of {
      revision : int;
      degradation : fleet_degradation;
    }

let decode_fleet_reading json =
  let* status = required_nonblank_string json "status" in
  let* operator_action_required =
    required_bool_field json "operator_action_required"
  in
  let* bootable_count = required_nonnegative_int_field json "bootable_count" in
  let* running_count = required_nonnegative_int_field json "running_count" in
  let* executable_count =
    required_nonnegative_int_field json "executable_count"
  in
  let* failing_count = required_nonnegative_int_field json "failing_count" in
  let* recovering_count =
    required_nonnegative_int_field json "recovering_count"
  in
  let* paused_count = required_nonnegative_int_field json "paused_count" in
  let* proactive_interval_sec =
    optional_int_field json "proactive_interval_sec"
  in
  Ok
    {
      status;
      operator_action_required;
      bootable_count;
      running_count;
      executable_count;
      failing_count;
      recovering_count;
      paused_count;
      proactive_interval_sec;
    }

let decode_degradation_fields json =
  let* since_unix = required_finite_float json "since" in
  let* reason = required_nonblank_string json "reason" in
  Ok { since_unix; reason }

let decode_fleet_stream_event json =
  (* Matches [Fleet_stream.encode] in [lib/fleet_stream/fleet_stream.ml]. *)
  let* event_name = required_nonblank_string json "event" in
  let* revision = required_int_field json "revision" in
  let* () =
    if revision < 1 then Error "fleet stream revision must be >= 1" else Ok ()
  in
  match event_name with
  | "snapshot" ->
      let* schema = required_int_field json "schema" in
      let* measured_at_unix = required_finite_float json "measured_at" in
      let* fleet_json = required_object_field json "fleet" in
      let* reading = decode_fleet_reading fleet_json in
      let* degraded =
        match optional_object_field json "degraded" with
        | Ok None -> Ok None
        | Ok (Some deg) ->
            let* d = decode_degradation_fields deg in
            Ok (Some d)
        | Error _ as err -> err
      in
      Ok (Fleet_snapshot { schema; revision; measured_at_unix; reading; degraded })
  | "changed" ->
      let* measured_at_unix = required_finite_float json "measured_at" in
      let* fleet_json = required_object_field json "fleet" in
      let* reading = decode_fleet_reading fleet_json in
      Ok (Fleet_changed { revision; measured_at_unix; reading })
  | "unavailable_snapshot" ->
      let* schema = required_int_field json "schema" in
      let* degradation = decode_degradation_fields json in
      Ok (Fleet_unavailable_snapshot { schema; revision; degradation })
  | "degraded" ->
      let* degradation = decode_degradation_fields json in
      Ok (Fleet_degraded { revision; degradation })
  | other -> Error (Printf.sprintf "unknown fleet stream event %S" other)

type chat_surface =
  | Surface_dashboard
  | Surface_agent
  | Surface_broadcast
  | Surface_discord
  | Surface_slack
  | Surface_webhook
  | Surface_gate of string

type chat_peer =
  | Peer_keeper of string
  | Peer_external of string
  | Peer_unresolved of string option

type chat_role =
  | Role_user
  | Role_peer of {
      peer : chat_peer;
      surface : chat_surface option;
    }
  | Role_assistant
  | Role_system
  | Role_tool
  | Role_request_failure

type chat_origin =
  | Origin_bare
  | Origin_connector of string

type submit_mode =
  | Follow_up
  | Steer of {
      control_token : string;
      operation_id : string;
    }

type chat_attachment = {
  attachment_id : string;
  name : string;
  mime_type : string;
  size : int;
  data_base64 : string;
}

type chat_submit_request = {
  request_id : string;
  keeper_name : string;
  message : string;
  origin : chat_origin;
  mode : submit_mode;
  turn_instructions : string option;
  since_seq : int option;
  attachments : chat_attachment list;
}

type chat_message = {
  id : string;
  role : chat_role;
  content : string;
  ts_unix : float;
  turn_ref : string option;
  model_used : string option;
  tool_call_id : string option;
  tool_call_name : string option;
  execution_id : string option;
  operation_id : string option;
  transcript_slot : string option;
  failure_kind : string option;
}

type chat_history_page = {
  messages : chat_message list;
  has_more : bool;
  next_cursor : string option;
}

type accepted_state =
  | Accepted_queued
  | Accepted_running
  | Accepted_succeeded
  | Accepted_failed
  | Accepted_cancelled

type interactive_outcome =
  | Interactive_applied
  | Interactive_stale_control
  | Interactive_paused
  | Interactive_replayed

type turn_interrupt_response = {
  signalled : bool;
  paused : bool;
  chat_control_token : string option;
  reason : string option;
}

type chat_stream_chunk =
  | Chunk_accepted of {
      operation_id : string;
      queued_count : int;
      state : accepted_state;
      interactive_outcome : interactive_outcome option;
      control_token : string option;
    }
  | Chunk_run_started of { operation_id : string option }
  | Chunk_text_delta of { operation_id : string option; delta : string }
  | Chunk_thinking_delta of { operation_id : string option; delta : string }
  | Chunk_thinking_snapshot of {
      operation_id : string option;
      snapshot : string;
    }
  | Chunk_tool_start of {
      operation_id : string option;
      tool_use_id : string;
      tool_name : string;
      args_preview : string option;
    }
  | Chunk_tool_args of {
      operation_id : string option;
      tool_use_id : string;
      delta : string option;
      snapshot : string option;
    }
  | Chunk_tool_end of {
      operation_id : string option;
      tool_use_id : string;
      tool_name : string option;
      ok : bool option;
      output_preview : string option;
    }
  | Chunk_reply_details of {
      operation_id : string option;
      reply : string;
      turn_outcome : string option;
      turn_ref : string option;
    }
  | Chunk_turn_done of {
      operation_id : string option;
      turn_ref : string option;
      reply : string option;
    }
  | Chunk_error of {
      operation_id : string option;
      code : string option;
      message : string;
    }
  | Chunk_ignored

let encode_chat_submit_request req =
  (* Strict allowlist in [server_routes_http_keeper_stream.ml:366-434]:
     [request_id; name; message; turn_instructions; channel; attachments;
     since_seq; admission_intent]. *)
  let channel_field =
    match req.origin with
    | Origin_bare -> []
    | Origin_connector ch -> [ ("channel", `String ch) ]
  in
  let admission_field =
    match req.mode with
    | Follow_up -> []
    | Steer { control_token; operation_id } ->
        [
          ( "admission_intent"
          , `Assoc
              [
                ("kind", `String "interactive");
                ("control_token", `String control_token);
                ("interrupt_token", `Null);
                ("operation_id", `String operation_id);
              ] );
        ]
  in
  let instructions_field =
    match req.turn_instructions with
    | None -> []
    | Some instr -> [ ("turn_instructions", `String instr) ]
  in
  let since_seq_field =
    match req.since_seq with
    | None -> []
    | Some s -> [ ("since_seq", `Int s) ]
  in
  let attachments_field =
    match req.attachments with
    | [] -> []
    | items ->
        [
          ( "attachments"
          , `List
              (List.map
                 (fun (a : chat_attachment) ->
                   `Assoc
                     [
                       ("attachment_id", `String a.attachment_id);
                       ("name", `String a.name);
                       ("mime_type", `String a.mime_type);
                       ("size", `Int a.size);
                       ("data", `String a.data_base64);
                     ])
                 items) );
        ]
  in
  `Assoc
    ([
       ("request_id", `String req.request_id);
       ("name", `String req.keeper_name);
       ("message", `String req.message);
     ]
    @ channel_field @ instructions_field @ since_seq_field @ admission_field
    @ attachments_field)

(* The server's closed [Surface_ref.t] vocabulary; it rejects an unknown kind
   the same way. *)
let decode_chat_surface json =
  let* kind = required_nonblank_string json "kind" in
  match kind with
  | "dashboard" -> Ok Surface_dashboard
  | "agent" -> Ok Surface_agent
  | "broadcast" -> Ok Surface_broadcast
  | "discord" -> Ok Surface_discord
  | "slack" -> Ok Surface_slack
  | "webhook" -> Ok Surface_webhook
  | "gate" ->
      let* label = required_nonblank_string json "label" in
      Ok (Surface_gate label)
  | other -> Error (Printf.sprintf "unknown surface kind value %S" other)

type speaker_authority =
  | Authority_owner
  | Authority_keeper
  | Authority_external

(* The server writes [Keeper_chat_store.speaker_authority] as these three
   labels. *)
let speaker_authority_of_string = function
  | "owner" -> Some Authority_owner
  | "keeper" -> Some Authority_keeper
  | "external" -> Some Authority_external
  | _ -> None

(* Every Keeper input is a [user] row: the operator's, another Keeper's
   message or broadcast, a connector author's. Only [speaker_authority] says
   which, so a row without it is unresolved rather than the operator's. *)
let decode_user_role json =
  let* authority =
    decode_optional_enum ~field:"speaker_authority" speaker_authority_of_string
      json
  in
  let* speaker_id = optional_nonblank_string json "speaker_id" in
  let* speaker_name = optional_nonblank_string json "speaker_name" in
  let name = match speaker_name with Some _ -> speaker_name | None -> speaker_id in
  let peer_role peer =
    let* surface_json = optional_object_field json "surface" in
    let* surface =
      match surface_json with
      | None -> Ok None
      | Some s -> Result.map Option.some (decode_chat_surface s)
    in
    Ok (Role_peer { peer; surface })
  in
  match authority, name with
  | Some Authority_owner, (Some _ | None) -> Ok Role_user
  | Some Authority_keeper, Some n -> peer_role (Peer_keeper n)
  | Some Authority_external, Some n -> peer_role (Peer_external n)
  | (Some (Authority_keeper | Authority_external) | None), (Some _ | None) ->
      peer_role (Peer_unresolved speaker_id)

let decode_chat_role json =
  let* raw = required_string_field json "role" in
  match raw with
  | "operator" -> Ok Role_user
  | "user" -> decode_user_role json
  | "assistant" | "keeper" -> Ok Role_assistant
  | "system" -> Ok Role_system
  | "tool" -> Ok Role_tool
  | "request_failure" -> Ok Role_request_failure
  | other -> Error (Printf.sprintf "unknown role value %S" other)

let decode_chat_message json =
  let* id = required_nonblank_string json "id" in
  let* role = decode_chat_role json in
  let* content = required_string_field json "content" in
  let* ts_unix = required_finite_float json "ts" in
  let* turn_ref = optional_nonblank_string json "turn_ref" in
  let* model_used = optional_nonblank_string json "model_used" in
  let* tool_call_id = optional_nonblank_string json "tool_call_id" in
  let* tool_call_name = optional_nonblank_string json "tool_call_name" in
  let* execution_id = optional_nonblank_string json "execution_id" in
  let* delivery_key_opt = optional_object_field json "delivery_key" in
  let* dk_op_id =
    match delivery_key_opt with
    | Some dk -> optional_nonblank_string dk "operation_id"
    | None -> Ok None
  in
  let* top_op_id = optional_nonblank_string json "operation_id" in
  let operation_id = match dk_op_id with Some _ as x -> x | None -> top_op_id in
  let* slot_opt = optional_object_field json "transcript_slot" in
  let* transcript_slot =
    match slot_opt with
    | Some sl -> optional_nonblank_string sl "kind"
    | None -> Ok None
  in
  let* failure_kind = optional_nonblank_string json "failure_kind" in
  Ok
    {
      id;
      role;
      content;
      ts_unix;
      turn_ref;
      model_used;
      tool_call_id;
      tool_call_name;
      execution_id;
      operation_id;
      transcript_slot;
      failure_kind;
    }

let decode_chat_history = function
  | `List items -> decode_list "chat_history" decode_chat_message items
  | bad -> field_type_error "chat_history" "a JSON array" bad

let decode_chat_history_page json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = required_list_field body "messages" in
  let* messages = decode_list "messages" decode_chat_message items in
  let* has_more = required_bool_field body "has_more" in
  let* next_cursor = optional_nonblank_string body "next_cursor" in
  Ok { messages; has_more; next_cursor }

let accepted_state_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "queued" -> Some Accepted_queued
  | "running" | "accepted" -> Some Accepted_running
  | "succeeded" -> Some Accepted_succeeded
  | "failed" -> Some Accepted_failed
  | "cancelled" -> Some Accepted_cancelled
  | _ -> None

let interactive_outcome_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "applied" -> Some Interactive_applied
  | "stale_control" -> Some Interactive_stale_control
  | "paused" -> Some Interactive_paused
  | "replayed" -> Some Interactive_replayed
  | _ -> None

let operation_run_prefix = "keeper-operation-run-"

let operation_id_of_run_id raw =
  let trimmed = String.trim raw in
  if String.starts_with ~prefix:operation_run_prefix trimmed then
    let plen = String.length operation_run_prefix in
    let rest =
      String.trim (String.sub trimmed plen (String.length trimmed - plen))
    in
    if String.equal rest "" then None else Some rest
  else None

let chunk_operation_id json =
  let* direct = optional_nonblank_string json "operation_id" in
  match direct with
  | Some _ as x -> Ok x
  | None ->
      let* run_id = optional_nonblank_string json "runId" in
      Ok (Option.bind run_id operation_id_of_run_id)

let resolve_tool_use_id json =
  let* tc_id = optional_nonblank_string json "toolCallId" in
  match tc_id with
  | Some id -> Ok id
  | None -> (
      let* legacy_id = optional_nonblank_string json "tool_use_id" in
      match legacy_id with
      | Some id -> Ok id
      | None -> (
          let* scope = optional_int_field json "toolStreamScope" in
          let* block = optional_int_field json "toolCallBlockIndex" in
          match scope, block with
          | Some s, Some b -> Ok (Printf.sprintf "scope-%d-block-%d" s b)
          | None, Some b -> Ok (Printf.sprintf "block-%d" b)
          | Some s, None -> Ok (Printf.sprintf "scope-%d" s)
          | None, None ->
              Error
                "missing tool call identifier (toolCallId, tool_use_id, or toolStreamScope/toolCallBlockIndex)"))

let decode_native_completion_ok completion =
  let* kind = optional_nonblank_string completion "kind" in
  match kind with
  | Some ("error_reported" | "decline_reported") -> Ok (Some false)
  | Some "completion_reported" -> Ok (Some true)
  | Some "result_received" -> (
      let* is_err = optional_bool_field completion "is_error" in
      match is_err with
      | Some true -> Ok (Some false)
      | Some false -> Ok (Some true)
      | None -> Ok None)
  | Some ("end_observed" | "completion_unrecorded" | "unrecognized_status") | None ->
      Ok None
  | Some _ -> Ok None

let decode_custom_chat_chunk json =
  let* name = required_nonblank_string json "name" in
  let* outer_op_id = chunk_operation_id json in
  match name with
  | "KEEPER_CHAT_OPERATION_ACCEPTED" ->
      let* value = required_object_field json "value" in
      let* operation_id = required_nonblank_string value "operation_id" in
      let* queued_count = required_nonnegative_int_field value "queued_count" in
      let* state = decode_enum ~field:"state" accepted_state_of_string value in
      let* interactive_opt = optional_object_field value "interactive" in
      let* interactive_outcome, control_token =
        match interactive_opt with
        | None -> Ok (None, None)
        | Some inter ->
            let* outcome =
              decode_optional_enum ~field:"outcome"
                interactive_outcome_of_string inter
            in
            let* token =
              optional_nonblank_string inter "chat_control_token"
            in
            Ok (outcome, token)
      in
      Ok
        (Chunk_accepted
           {
             operation_id;
             queued_count;
             state;
             interactive_outcome;
             control_token;
           })
  | "KEEPER_THINKING_DELTA" ->
      let* value = required_object_field json "value" in
      let* delta = required_string_field value "delta" in
      Ok (Chunk_thinking_delta { operation_id = outer_op_id; delta })
  | "KEEPER_THINKING_SNAPSHOT" ->
      let* value = required_object_field json "value" in
      let* snapshot = required_string_field value "snapshot" in
      Ok (Chunk_thinking_snapshot { operation_id = outer_op_id; snapshot })
  | "KEEPER_REPLY_DETAILS" ->
      let* value = required_object_field json "value" in
      let* reply = required_string_field value "reply" in
      let* turn_outcome = optional_nonblank_string value "turn_outcome" in
      let* turn_ref = optional_nonblank_string value "turn_ref" in
      Ok
        (Chunk_reply_details
           { operation_id = outer_op_id; reply; turn_outcome; turn_ref })
  | "KEEPER_TOOL_RESULT_READY" ->
      let* value = required_object_field json "value" in
      let* tool_use_id = resolve_tool_use_id value in
      Ok
        (Chunk_tool_end
           {
             operation_id = outer_op_id;
             tool_use_id;
             tool_name = None;
             ok = None;
             output_preview = None;
           })
  | "KEEPER_NATIVE_TOOL_START" ->
      let* value = required_object_field json "value" in
      let* tool_use_id = resolve_tool_use_id value in
      let* name_opt = optional_nonblank_string value "toolCallName" in
      let tool_name = Option.value name_opt ~default:"native_tool" in
      Ok
        (Chunk_tool_start
           {
             operation_id = outer_op_id;
             tool_use_id;
             tool_name;
             args_preview = None;
           })
  | "KEEPER_NATIVE_TOOL_END" ->
      let* value = required_object_field json "value" in
      let* tool_use_id = resolve_tool_use_id value in
      let* tool_name = optional_nonblank_string value "toolCallName" in
      let* comp_opt = optional_object_field value "completion" in
      let* ok =
        match comp_opt with
        | Some comp -> decode_native_completion_ok comp
        | None -> Ok None
      in
      Ok
        (Chunk_tool_end
           {
             operation_id = outer_op_id;
             tool_use_id;
             tool_name;
             ok;
             output_preview = None;
           })
  | "KEEPER_CONNECTED"
  | "KEEPER_RUNTIME_ATTEMPT_STARTED"
  | "KEEPER_PROVIDER_RETRY"
  | "KEEPER_STREAM_MESSAGE_START"
  | "KEEPER_STREAM_MESSAGE_DELTA"
  | "KEEPER_STREAM_MESSAGE_STOP"
  | "KEEPER_STREAM_PING"
  | "KEEPER_CONTENT_BLOCK_START"
  | "KEEPER_CONTENT_BLOCK_STOP"
  | "KEEPER_MODEL_CONTENT_ACTIVITY"
  | "KEEPER_THINKING_SIGNATURE_DELTA"
  | "KEEPER_MEDIA_DELTA"
  | "KEEPER_STREAM_PROTOCOL_ERROR"
  | "KEEPER_CHAT_BATCH_BOUND"
  | "KEEPER_CONTINUATION_CHECKPOINT"
  | "KEEPER_EXTERNAL_EFFECT_COMPLETED"
  | "KEEPER_TOOL_APPROVAL_REQUESTED"
  | "KEEPER_TOOL_APPROVAL_SETTLED"
  | "KEEPER_TOOL_CALL_ADMITTED"
  | "KEEPER_TOOL_TRANSCRIPT_COMMITTED"
  | "KEEPER_NATIVE_TOOL_PROGRESS" ->
      Ok Chunk_ignored
  | other -> Error (Printf.sprintf "unknown CUSTOM chat stream event %S" other)

let decode_chat_stream_chunk json =
  let* kind = required_nonblank_string json "type" in
  match kind with
  | "CUSTOM" -> decode_custom_chat_chunk json
  | "accepted" ->
      let* operation_id = required_nonblank_string json "operation_id" in
      let* queued_count = required_nonnegative_int_field json "queued_count" in
      let* state = decode_enum ~field:"state" accepted_state_of_string json in
      Ok
        (Chunk_accepted
           {
             operation_id;
             queued_count;
             state;
             interactive_outcome = None;
             control_token = None;
           })
  | "RUN_STARTED" ->
      let* operation_id = chunk_operation_id json in
      Ok (Chunk_run_started { operation_id })
  | "TEXT_MESSAGE_START" | "TEXT_MESSAGE_END" -> Ok Chunk_ignored
  | "text_delta" | "TEXT_MESSAGE_CONTENT" ->
      let* operation_id = chunk_operation_id json in
      let* delta = required_string_field json "delta" in
      Ok (Chunk_text_delta { operation_id; delta })
  | "thinking_delta" ->
      let* operation_id = chunk_operation_id json in
      let* delta = required_string_field json "delta" in
      Ok (Chunk_thinking_delta { operation_id; delta })
  | "tool_start" | "TOOL_CALL_START" ->
      let* operation_id = chunk_operation_id json in
      let* tool_use_id = resolve_tool_use_id json in
      let* name_camel = optional_nonblank_string json "toolCallName" in
      let* tool_name =
        match name_camel with
        | Some n -> Ok n
        | None -> required_nonblank_string json "tool_name"
      in
      let* args_preview = optional_string_field json "args_preview" in
      Ok
        (Chunk_tool_start { operation_id; tool_use_id; tool_name; args_preview })
  | "TOOL_CALL_ARGS" ->
      let* operation_id = chunk_operation_id json in
      let* tool_use_id = resolve_tool_use_id json in
      let* delta = optional_string_field json "delta" in
      let snapshot =
        match member "snapshot" json with
        | `Null -> None
        | `String s -> Some s
        | other -> Some (Yojson.Safe.to_string other)
      in
      Ok (Chunk_tool_args { operation_id; tool_use_id; delta; snapshot })
  | "tool_end" | "TOOL_CALL_END" ->
      let* operation_id = chunk_operation_id json in
      let* tool_use_id = resolve_tool_use_id json in
      let* name_camel = optional_nonblank_string json "toolCallName" in
      let* name_snake = optional_nonblank_string json "tool_name" in
      let tool_name =
        match name_camel with Some _ as x -> x | None -> name_snake
      in
      let* ok = optional_bool_field json "ok" in
      let* output_preview = optional_string_field json "output_preview" in
      Ok
        (Chunk_tool_end
           { operation_id; tool_use_id; tool_name; ok; output_preview })
  | "turn_done" | "RUN_FINISHED" ->
      let* operation_id = chunk_operation_id json in
      let* turn_ref = optional_nonblank_string json "turn_ref" in
      let* reply = optional_string_field json "reply" in
      Ok (Chunk_turn_done { operation_id; turn_ref; reply })
  | "error" | "RUN_ERROR" ->
      let* operation_id = chunk_operation_id json in
      let* code = optional_nonblank_string json "code" in
      let* message = required_nonblank_string json "message" in
      Ok (Chunk_error { operation_id; code; message })
  | other -> Error (Printf.sprintf "unknown chat stream chunk type %S" other)

let decode_turn_interrupt_response json =
  let* _, body = unwrap_v2_or_raw json in
  let* signalled = decode_bool_field_or body "signalled" ~default:false in
  let* paused = decode_bool_field_or body "paused" ~default:false in
  let* chat_control_token = optional_nonblank_string body "chat_control_token" in
  let* reason = optional_nonblank_string body "reason" in
  Ok { signalled; paused; chat_control_token; reason }
