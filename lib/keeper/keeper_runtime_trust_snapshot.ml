open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_runtime_trust_timeline

module Trust_core = Keeper_runtime_trust_snapshot_core

(** Short-lived cache for [snapshot_json]. The result is expensive to compute
    (tail-reads decision log, tool-call log, receipts, approval audit, and
    pending approvals) and is requested repeatedly by dashboard renders. The
    cache key includes runtime generation and last-turn timestamp so normal
    keeper progress invalidates it automatically. *)
module Snapshot_cache = struct
  type key =
    { base_path : string
    ; keeper_name : string
    ; generation : int
    ; last_turn_ts : float
    ; approval_queue_revision : int
    }

  (* [Hashtbl.Make] rather than the polymorphic table: [last_turn_ts] is a
     float, and the generic hash of a float is not the tool for a cache whose
     whole job is to notice that a keeper moved. Naming each field here is
     also what states that all five take part in the key -- with the generic
     table the compiler could see no field being read at all. *)
  module Key = struct
    type t = key

    let equal left right =
      String.equal left.base_path right.base_path
      && String.equal left.keeper_name right.keeper_name
      && Int.equal left.generation right.generation
      && Float.equal left.last_turn_ts right.last_turn_ts
      && Int.equal left.approval_queue_revision right.approval_queue_revision
    ;;

    (* [Float.equal] treats -0. and 0. as equal and NaN as equal to itself;
       [Hashtbl.hash] normalises both the same way, so equal keys hash alike. *)
    let hash key =
      Hashtbl.hash
        ( key.base_path
        , key.keeper_name
        , key.generation
        , key.last_turn_ts
        , key.approval_queue_revision )
    ;;
  end

  module Table = Hashtbl.Make (Key)

  type entry =
    { value : Yojson.Safe.t
    ; expires_at : float
    }

  let tbl : entry Table.t = Table.create 64
  let mu = Stdlib.Mutex.create ()
  let ttl_sec = 0.5
  let max_size = 256

  let clear_expired ~now =
    let expired =
      Table.fold (fun k e acc -> if e.expires_at <= now then k :: acc else acc) tbl []
    in
    List.iter (Table.remove tbl) expired

  let get ~now key =
    Stdlib.Mutex.protect mu (fun () ->
        match Table.find_opt tbl key with
        | Some entry when entry.expires_at > now -> Some entry.value
        | _ -> None)

  let set ~now key value =
    Stdlib.Mutex.protect mu (fun () ->
        clear_expired ~now;
        if Table.length tbl >= max_size
        then (
          (* Cap memory: drop expired entries, and if still full clear the
             whole table rather than keeping stale entries. *)
          clear_expired ~now;
          if Table.length tbl >= max_size then Table.clear tbl);
        Table.replace tbl key { value; expires_at = now +. ttl_sec })
end

module Completion_contract_result = Keeper_completion_contract_result_label

let terminal_reason_from_decision json =
  match json_member "terminal_reason" json with
  | `Assoc _ as terminal_reason -> Keeper_turn_terminal.of_json terminal_reason
  | _ ->
      Option.map
        (fun code ->
          Keeper_turn_terminal.of_code ~source:"decision_log" code)
        (json_string_opt_member "terminal_reason_code" json)

let terminal_reason_from_receipt receipt =
  Option.map
    (Keeper_turn_terminal.of_code ~source:"execution_receipt")
    (json_string_opt_member "terminal_reason_code" receipt)

(* JSON-deserialization boundary: maps a runtime_blocker_class wire
   string into a typed [Keeper_turn_disposition.t]. The previous
   variant returned a [terminal_reason_code] wire string that the
   caller then passed back through [Keeper_turn_terminal.of_code]
   for a wire→typed roundtrip; emitting the typed value here removes
   that detour and lets the consumer use [of_disposition] directly.
   The provider-runtime classes preserve their originating blocker
   string in the typed payload instead of collapsing to a single
   "provider_error" literal. *)
let disposition_of_typed_runtime_blocker_class blocker_class =
  let raw_blocker_class =
    Keeper_meta_contract.blocker_class_to_string blocker_class
  in
  match blocker_class with
  | Keeper_meta_contract.Stale_turn_timeout ->
      Keeper_turn_disposition.Turn_wall_clock_timeout
  | Keeper_meta_contract.Agent_core_input_required ->
      Keeper_turn_disposition.Input_required
  | Keeper_meta_contract.Runtime_exhausted _ ->
      Keeper_turn_disposition.Provider_error
        (Keeper_turn_terminal_code.Provider_runtime_error raw_blocker_class)
  | Keeper_meta_contract.Capacity_backpressure ->
      Keeper_turn_disposition.Provider_error
        (Keeper_turn_terminal_code.Provider_runtime_error raw_blocker_class)
  | Keeper_meta_contract.Fiber_unresolved ->
      Keeper_turn_disposition.Provider_error
        Keeper_turn_terminal_code.Fiber_unresolved
  | Keeper_meta_contract.Agent_core_context_window_exceeded
  | Keeper_meta_contract.Agent_core_unrecognized_stop_reason
  | Keeper_meta_contract.Agent_core_guardrail_violation
  | Keeper_meta_contract.Agent_core_tripwire_violation
  | Keeper_meta_contract.Internal_unhandled_exception
  | Keeper_meta_contract.Internal_bridge_exception
  | Keeper_meta_contract.Internal_contract_rejected
  | Keeper_meta_contract.Incomplete_tool_transcript
  | Keeper_meta_contract.Terminal_effect_failed
  | Keeper_meta_contract.Provider_attempt_effect_fenced
  | Keeper_meta_contract.Tool_correction_lost
  | Keeper_meta_contract.Receipt_persistence_failed
  | Keeper_meta_contract.Gate_replay_repair_required ->
    Keeper_turn_disposition.Provider_error
      (Keeper_turn_terminal_code.of_core_error_wire raw_blocker_class)

let disposition_of_runtime_blocker_class raw_blocker_class =
  match Keeper_meta_contract.blocker_class_of_serialized_string raw_blocker_class with
  | Some blocker_class -> disposition_of_typed_runtime_blocker_class blocker_class
  | None -> Keeper_turn_disposition.Unknown { raw_error = "unknown_error" }

let terminal_reason_from_runtime_blocker_fields runtime_blocker_fields =
  match assoc_string_opt "runtime_blocker_class" runtime_blocker_fields with
  | None -> None
  | Some blocker_class ->
      let disposition = disposition_of_runtime_blocker_class blocker_class in
      let summary = assoc_string_opt "runtime_blocker_summary" runtime_blocker_fields in
      Some
        (Keeper_turn_terminal.of_disposition
           ~source:"runtime_blocker"
           ?summary
           disposition)

let receipt_ended_at_unix receipt =
  match json_string_opt_member "ended_at" receipt with
  | Some ended_at -> (
      match Masc_domain.parse_iso8601_opt ended_at with
      | Some ts when ts > 0.0 -> Some ts
      | Some _ | None -> None)
  | None -> None

(* Receipt timestamps are serialized as whole-second ISO strings, while runtime
   last-turn observations keep fractional seconds.  A same-second receipt must
   still be allowed to explain the blocker; otherwise the runtime blocker
   silently overrides its operator disposition. *)
let runtime_blocker_receipt_timestamp_epsilon_sec = 1.0

let runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
    latest_receipt =
  match assoc_string_opt "runtime_blocker_class" runtime_blocker_fields with
  | None -> false
  | Some _ -> (
    match latest_receipt with
    | None -> true
    | Some receipt -> (
        match receipt_ended_at_unix receipt with
        | Some receipt_ts ->
          meta.runtime.usage.last_turn_ts
          > receipt_ts +. runtime_blocker_receipt_timestamp_epsilon_sec
        | None -> meta.runtime.usage.last_turn_ts > 0.0))

let current_receipt_for_runtime_state ~meta ~runtime_blocker_fields
    latest_receipt =
  if runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
       latest_receipt
  then None
  else latest_receipt

let runtime_blocker_timeline_ts ~observed_at_unix ~meta
    ~runtime_blocker_fields latest_receipt =
  if
    runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
      latest_receipt
    && meta.runtime.usage.last_turn_ts > 0.0
  then meta.runtime.usage.last_turn_ts
  else observed_at_unix

let latest_terminal_reason_opt ~meta ~runtime_blocker_fields ~latest_decision
    ~latest_receipt =
  match Option.bind latest_decision terminal_reason_from_decision with
  | Some _ as value -> value
  | None ->
      if runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
           latest_receipt
      then terminal_reason_from_runtime_blocker_fields runtime_blocker_fields
      else Option.bind latest_receipt terminal_reason_from_receipt

let terminal_reason_timeline_event ~latest_decision ~latest_receipt =
  let source_json, ts_unix_opt, reason_opt =
    match latest_decision with
    | Some decision -> (
        match terminal_reason_from_decision decision with
        | Some reason ->
            ( Some decision,
              (match json_float_opt_member "ts_unix" decision with
               | Some _ as value -> value
               | None -> json_float_opt_member "wall_clock" decision),
              Some reason )
        | None -> (None, None, None))
    | None -> (None, None, None)
  in
  let source_json, ts_unix_opt, reason_opt =
    match reason_opt, latest_receipt with
    | Some _, _ -> (source_json, ts_unix_opt, reason_opt)
    | None, Some receipt -> (
        match terminal_reason_from_receipt receipt with
        | Some reason ->
            let ts_unix_opt =
              match json_string_opt_member "ended_at" receipt with
              | Some ended_at -> (
                  match Masc_domain.parse_iso8601_opt ended_at with
                  | Some ts when ts > 0.0 -> Some ts
                  | Some _ | None -> None)
              | None -> None
            in
            (Some receipt, ts_unix_opt, Some reason)
        | None -> (None, None, None))
    | None, None -> (None, None, None)
  in
  match source_json, ts_unix_opt, reason_opt with
  | Some source_json, Some ts_unix, Some reason ->
      Some
        (timeline_event_json
           ?trace_id:(json_string_opt_member "trace_id" source_json)
           ?keeper_turn_id:(keeper_turn_id_of_json source_json)
           ?task_id:
             (match json_string_opt_member "task_id" source_json with
              | Some _ as value -> value
              | None -> json_string_opt_member "current_task_id" source_json)
           ~goal_ids:(goal_ids_of_json source_json)
           ?next_human_action:reason.next_action
           ~ts_unix ~kind:"terminal_reason"
           ~title:"Terminal Reason"
           ~summary:reason.summary
           ~severity:(Keeper_turn_terminal.severity_to_string reason.severity)
           ())
  | _ -> None

type pending_approval_projection =
  {
    entries : Yojson.Safe.t list option;
    count : int option;
    state : Yojson.Safe.t;
    error : Keeper_approval_queue.storage_error option;
  }

let pending_approval_projection_with_reader
    ~(read_pending :
       base_path:string ->
       (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result)
    ~base_path ~keeper_name =
  match
    Keeper_runtime_trust_timeline.pending_approval_json_with_reader
      ~read_pending ~base_path ~keeper_name
  with
  | Ok entries ->
      {
        entries = Some entries;
        count = Some (List.length entries);
        state = Keeper_approval_queue.approval_queue_ready_state_json;
        error = None;
      }
  | Error error ->
      {
        entries = None;
        count = None;
        state =
          Keeper_approval_queue.approval_queue_unavailable_state_json error;
        error = Some error;
      }

let approval_queue_attention_of_projection
      ~base_path
      (projection : pending_approval_projection)
  =
  match projection.count, projection.error with
  | Some count, None -> Keeper_status_bridge.Approval_queue_ready count
  | _, Some error -> Keeper_status_bridge.Approval_queue_unavailable error
  | None, None ->
    Keeper_status_bridge.Approval_queue_unavailable
      { path = Keeper_gate_path.pending ~base_path
      ; reason = "approval queue projection has no current state"
      }

let receipt_operator_disposition receipt =
  match
    ( json_string_opt_member "operator_disposition" receipt,
      json_string_opt_member "operator_disposition_reason" receipt )
  with
  | Some disposition, Some reason -> Some (disposition, reason)
  | Some disposition, None -> Some (disposition, "")
  | None, _ -> None

let approval_queue_state_of_projection
    (projection : pending_approval_projection) =
  match projection.count, projection.error with
  | Some count, None -> Trust_core.Approval_queue_available count
  | _, Some _ | None, None -> Trust_core.Approval_queue_unavailable
;;

let trust_model_of_observations ~pending_approval_projection
    ~runtime_blocker_fields ~latest_receipt ~latest_next_action
    ~attention_fields =
  Trust_core.decide
    { approval_queue =
        approval_queue_state_of_projection pending_approval_projection
    ; runtime_blocker_class =
        assoc_string_opt "runtime_blocker_class" runtime_blocker_fields
    ; runtime_blocker_summary =
        assoc_string_opt "runtime_blocker_summary" runtime_blocker_fields
    ; receipt_operator_disposition =
        Option.bind latest_receipt receipt_operator_disposition
    ; attention_needs_attention =
        assoc_bool_default "needs_attention" ~default:false attention_fields
    ; attention_reason = assoc_string_opt "attention_reason" attention_fields
    ; attention_next_human_action =
        assoc_string_opt "next_human_action" attention_fields
    ; terminal_next_human_action = latest_next_action
    }
;;

let trust_model_json_fields (model : Trust_core.t) =
  [ "disposition", `String model.disposition
  ; "disposition_reason", `String model.disposition_reason
  ; "operator_disposition", `String model.operator_disposition
  ; "operator_disposition_reason", `String model.operator_disposition_reason
  ; "needs_attention", `Bool model.needs_attention
  ; "attention_reason", Json_util.string_opt_to_json model.attention_reason
  ; "next_human_action", Json_util.string_opt_to_json model.next_human_action
  ]
;;

let decision_log_persistence_surface = "keeper_runtime_trust_decision_log"

let report_decision_log_read_drop ~reason ~path ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
        ~labels:[("surface", decision_log_persistence_surface); ("reason", reason)]
        ())
    ~surface:decision_log_persistence_surface
    ~reason
    ~path
    ~detail

let latest_decision_json ~(config : Workspace.config) ~(keeper_name : string) :
    Yojson.Safe.t option =
  let path = Keeper_types_support.keeper_decision_log_path config keeper_name in
  if not (Fs_compat.file_exists path) then None
  else
    let lines, completion =
      match
        Keeper_memory.read_file_tail_lines_with_completion path
          ~max_bytes:40000 ~max_lines:20
      with
      | Ok (lines, completion) -> (lines, completion)
      | Error exn_class ->
          Keeper_memory.record_memory_recall_read_error
            ~site:"keeper_runtime_trust_decisions" path exn_class;
          ([], Keeper_memory.Complete)
    in
    lines
    |> List.rev
    (* [List.rev] puts the newest row first, so index 0 is the file's last
       line. The decision log is append-only and this read is not synchronised
       with the writer, so that one line can be mid-write. When the reader
       reports the tail as unterminated, its parse failure is an in-flight
       append rather than corruption: [find_map] falls through to the previous
       complete row and the next read sees it whole. Position alone is not
       enough — a genuinely malformed last line is newline-terminated and must
       keep [entry_load_error]. *)
    |> List.mapi (fun index line -> (index, line))
    |> List.find_map (fun (index, line) ->
           match Yojson.Safe.from_string line with
           | exception Yojson.Json_error detail ->
               let reason =
                 match (index, completion) with
                 | 0, Keeper_memory.Partial_last_line ->
                     Safe_ops.persistence_read_drop_reason_tail_partial_write
                 | 0, Keeper_memory.Complete
                 | _, Keeper_memory.Partial_last_line
                 | _, Keeper_memory.Complete ->
                     Safe_ops.persistence_read_drop_reason_entry_load_error
               in
               report_decision_log_read_drop ~reason ~path ~detail;
               None
           | (`Assoc _ as json) -> Some json
           | _ ->
               report_decision_log_read_drop
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~path
                 ~detail:"decision log row is not a JSON object";
               None)


let latest_turn_id ~(registry_entry : Keeper_registry.registry_entry option)
    ~(latest_decision : Yojson.Safe.t option)
    ~(latest_tool_call : Yojson.Safe.t option)
    ~(latest_receipt : Yojson.Safe.t option) =
  match Option.bind latest_decision (json_int_opt_member "turn_id") with
  | Some _ as turn_id -> turn_id
  | None ->
      (match Option.bind latest_tool_call (json_int_opt_member "keeper_turn_id") with
       | Some _ as turn_id -> turn_id
       | None ->
           (match Option.bind latest_receipt (json_int_opt_member "turn_count") with
            | Some _ as turn_id -> turn_id
            | None -> (
                match registry_entry with
                | Some { current_turn_observation = Some turn; _ } -> Some turn.turn_id
                | Some { last_completed_turn = Some turn; _ } -> Some turn.ct_turn_id
                | _ -> None)))

let latest_receipt_json ~(config : Workspace.config) ~(keeper_name : string) =
  Keeper_execution_receipt.latest_json config keeper_name

let selected_model_of_latest_decision latest_decision =
  Option.bind latest_decision (fun decision ->
      match
        decision |> json_member "telemetry"
        |> json_string_opt_member "selected_model"
      with
      | Some _ as value -> value
      | None -> json_string_opt_member "selected_model" decision)

let selected_model_of_latest_decision_or_receipt latest_decision latest_receipt
    =
  match selected_model_of_latest_decision latest_decision with
  | Some _ as value -> value
  | None ->
      Option.bind latest_receipt (fun receipt ->
          receipt |> json_member "runtime"
          |> json_string_opt_member "selected_model")

let pending_first_json pending_approvals =
  match pending_approvals with
  | first :: _ ->
      let tool_name = json_string_opt_member "tool_name" first in
      let approval_id = json_string_opt_member "id" first in
      let task_id = json_string_opt_member "task_id" first in
      let blocker_class = None in
      `Assoc
        [
          ("id", Json_util.string_opt_to_json approval_id);
          ("tool_name", Json_util.string_opt_to_json tool_name);
          ("task_id", Json_util.string_opt_to_json task_id);
          ("blocker_class", Json_util.string_opt_to_json blocker_class);
        ]
  | [] -> `Null

let approval_state_json ~pending_approval_projection
    ~latest_approval_audit =
  let latest_rule_match =
    Option.bind latest_approval_audit (fun json ->
        match json_member "rule_match" json with
        | `Assoc _ as rule_match -> Some rule_match
        | _ -> None)
  in
  let latest_event_kind =
    Option.bind latest_approval_audit (json_string_opt_member "event")
  in
  let decision_source =
    Option.bind latest_approval_audit (json_string_opt_member "decision_source")
  in
  let state =
    match pending_approval_projection.count with
    | None -> "unavailable"
    | Some pending_approval_count when pending_approval_count > 0 -> "pending"
    | Some _ -> (
        match latest_event_kind with
        | Some "resolved" -> "resolved"
        | Some "gate_allowed" -> "allowed"
        | Some _ -> "observed"
        | None -> "idle")
  in
  `Assoc
    [
      ("state", `String state);
      ( "queue_state",
        pending_approval_projection.state );
      ( "pending_count",
        match pending_approval_projection.count with
        | Some count -> `Int count
        | None -> `Null );
      ("decision_source", Json_util.string_opt_to_json decision_source);
      ("latest_event_kind", Json_util.string_opt_to_json latest_event_kind);
      ( "latest_event_at",
        match Option.bind latest_approval_audit (json_float_opt_member "ts") with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null );
      ( "rule_id",
        match latest_rule_match with
        | Some json -> json |> json_string_opt_member "rule_id" |> Json_util.string_opt_to_json
        | None -> `Null );
      ( "pending_first",
        match pending_approval_projection.entries with
        | Some entries -> pending_first_json entries
        | None -> `Null );
    ]

let approval_queue_unavailable_timeline_event ~observed_at_unix
    pending_approval_projection =
  match pending_approval_projection.error with
  | None -> None
  | Some (error : Keeper_approval_queue.storage_error) ->
      let ts_unix = observed_at_unix in
      Some
        (`Assoc
          [
            ("ts", `String (Masc_domain.iso8601_of_unix_seconds ts_unix));
            ("ts_unix", `Float ts_unix);
            ("kind", `String "approval_queue_unavailable");
            ( "title",
              `String
                Keeper_approval_queue.approval_queue_unavailable_title );
            ( "summary",
              `String
                (Printf.sprintf "%s: %s" error.path error.reason) );
            ( "severity",
              `String
                Keeper_approval_queue.approval_queue_unavailable_severity );
            ("task_id", `Null);
            ("goal_ids", `List []);
            ("next_human_action", `String "runtime reset required");
            ("observation_only", `Bool false);
          ])

let execution_summary_json ~(meta : Keeper_meta_contract.keeper_meta) ~latest_receipt =
  let sandbox_kind =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "kind"
    | None -> Some (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile)
  in
  let network_mode =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "network_mode"
    | None -> Some (Keeper_types_profile_sandbox.network_mode_to_string meta.network_mode)
  in
  let sandbox_root =
    match latest_receipt with
    | Some receipt ->
        receipt |> json_member "sandbox"
        |> json_string_opt_member "sandbox_root"
    | None -> None
  in
  let completion_contract_result =
    Option.bind latest_receipt (json_string_opt_member "completion_contract_result")
  in
  let completion_contract_result_raw =
    match completion_contract_result with
    | Some value when value <> "" -> Some value
    | Some _ | None -> None
  in
  let typed_completion_contract_result =
    Option.bind completion_contract_result Completion_contract_result.of_string
  in
  let runtime_json =
    match latest_receipt with
    | Some receipt -> json_member "runtime" receipt
    | None -> `Null
  in
  let runtime_attempt_count =
    match runtime_json with
    | `Null -> None
    | json -> json_int_opt_member "attempt_count" json
  in
  let runtime_fallback_applied =
    match runtime_json with
    | `Null -> None
    | json -> json_bool_opt_member "fallback_applied" json
  in
  let runtime_outcome =
    match runtime_json with
    | `Null -> None
    | json -> json_string_opt_member "outcome" json
  in
  let runtime_selected_model =
    match runtime_json with
    | `Null -> None
    | json -> json_string_opt_member "selected_model" json
  in
  let completion_observation_summary =
    match typed_completion_contract_result with
    | Some result -> Completion_contract_result.to_string result
    | None ->
        (match completion_contract_result_raw with
         | Some raw -> "unknown_completion_contract_result:" ^ raw
         | None -> "not_observed")
  in
  `Assoc
    [
      ("completion_contract_result", Json_util.string_opt_to_json completion_contract_result);
      ( "provider_attempt_count",
        match runtime_attempt_count with
        | Some value -> `Int value
        | None -> `Null );
      ( "provider_fallback_applied",
        match runtime_fallback_applied with
        | Some value -> `Bool value
        | None -> `Null );
      ( "provider_selected_model",
        Json_util.string_opt_to_json runtime_selected_model );
      ( "runtime_outcome",
        Json_util.string_opt_to_json runtime_outcome );
      ( "sandbox_summary",
        match (sandbox_kind, network_mode) with
        | Some kind, Some mode -> `String (Printf.sprintf "%s / %s" kind mode)
        | Some kind, None -> `String kind
        | None, Some mode -> `String mode
        | None, None -> `Null );
      ("sandbox_root", Json_util.string_opt_to_json sandbox_root);
      ("completion_observation_summary", `String completion_observation_summary);
      ( "latest_receipt_at",
        Json_util.string_opt_to_json (Option.bind latest_receipt (json_string_opt_member "ended_at")) );
    ]

let latest_causal_event_summary ~observed_at_unix ~meta ~latest_decision
    ~latest_receipt ~latest_tool_call ~latest_approval_audit
    ~runtime_blocker_fields ~next_human_action =
  let blocker_ts_unix =
    runtime_blocker_timeline_ts ~observed_at_unix ~meta
      ~runtime_blocker_fields latest_receipt
  in
  let blocker_observation_only =
    not
      (runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
         latest_receipt)
  in
  let task_id = Keeper_runtime_contract.current_task_id_opt meta in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  [
    terminal_reason_timeline_event ~latest_decision ~latest_receipt;
    Option.bind latest_decision decision_timeline_event;
    Option.bind latest_receipt receipt_timeline_event;
    Option.bind latest_tool_call tool_call_timeline_event;
    Option.bind latest_approval_audit approval_event_timeline_event;
    blocker_timeline_event ~ts_unix:blocker_ts_unix
      ~observed_at_unix:blocker_ts_unix
      ~runtime_blocker_fields ?task_id
      ~trace_id ~next_human_action
      ~observation_only:blocker_observation_only ();
  ]
  |> List.filter_map Fun.id
  |> sort_timeline_events
  |> fun events -> latest_causal_from_timeline (`List events)

let approval_audit_rows_or_fail = function
  | Ok rows -> rows
  | Error error ->
    failwith
      ("approval audit unavailable: "
       ^ Keeper_approval.Audit.read_error_to_string error)
;;

type raw_observations =
  { latest_decision : Yojson.Safe.t option
  ; latest_tool_call : Yojson.Safe.t option
  ; latest_receipt : Yojson.Safe.t option
  ; latest_approval_audit : Yojson.Safe.t option
  ; pending_approval_projection : pending_approval_projection
  ; runtime_blocker_fields : (string * Yojson.Safe.t) list
  ; attention_fields : (string * Yojson.Safe.t) list
  ; observed_at_unix : float
  }

type raw_snapshot =
  { observations : raw_observations
  ; registry_entry : Keeper_registry.registry_entry option
  ; runtime_contract : Yojson.Safe.t
  ; recent_tool_call_rows : Yojson.Safe.t list
  ; recent_approval_audit_rows : Yojson.Safe.t list
  ; recent_transition_rows : Yojson.Safe.t list
  }

let collect_raw_observations_with_pending_reader
    ~(read_pending :
       base_path:string ->
       (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result)
    ~approval_audit_limit ~(config : Workspace.config) ~(meta : keeper_meta) =
  let latest_decision = latest_decision_json ~config ~keeper_name:meta.name in
  let latest_tool_call = latest_tool_call_json ~keeper_name:meta.name in
  let latest_receipt = latest_receipt_json ~config ~keeper_name:meta.name in
  let recent_approval_audit_rows =
    Keeper_approval.Audit.read_recent ~base_path:config.base_path
      ~keeper_name:meta.name ~n:approval_audit_limit ()
    |> approval_audit_rows_or_fail
  in
  let latest_approval_audit =
    match recent_approval_audit_rows with
    | json :: _ -> Some json
    | [] -> None
  in
  let pending_approval_projection =
    pending_approval_projection_with_reader ~read_pending
      ~base_path:config.base_path ~keeper_name:meta.name
  in
  let runtime_blocker_fields =
    Keeper_status_bridge.runtime_blocker_fields_json config meta
  in
  let attention_fields =
    Keeper_status_bridge.attention_fields_json_with_approval_queue
      config
      meta
      (approval_queue_attention_of_projection
         ~base_path:config.base_path
         pending_approval_projection)
  in
  let observed_at_unix = Time_compat.now () in
  ( { latest_decision
    ; latest_tool_call
    ; latest_receipt
    ; latest_approval_audit
    ; pending_approval_projection
    ; runtime_blocker_fields
    ; attention_fields
    ; observed_at_unix
    }
  , recent_approval_audit_rows )
;;

let collect_summary_raw ~(config : Workspace.config) ~(meta : keeper_meta) =
  collect_raw_observations_with_pending_reader
    ~read_pending:
      Keeper_approval_queue.list_pending_dashboard_json_for_workspace
    ~approval_audit_limit:1 ~config ~meta
  |> fst
;;

let summary_json_of_raw ~(meta : keeper_meta) (raw : raw_observations) =
  let latest_receipt_for_runtime_state =
    current_receipt_for_runtime_state ~meta
      ~runtime_blocker_fields:raw.runtime_blocker_fields raw.latest_receipt
  in
  let latest_terminal_reason =
    latest_terminal_reason_opt ~meta
      ~runtime_blocker_fields:raw.runtime_blocker_fields
      ~latest_decision:raw.latest_decision ~latest_receipt:raw.latest_receipt
  in
  let latest_terminal_reason_json =
    latest_terminal_reason
    |> Option.map Keeper_turn_terminal.to_json
    |> Option.value ~default:`Null
  in
  let latest_next_action =
    Option.bind latest_terminal_reason (fun reason -> reason.next_action)
  in
  let trust_model =
    trust_model_of_observations
      ~pending_approval_projection:raw.pending_approval_projection
      ~runtime_blocker_fields:raw.runtime_blocker_fields
      ~latest_receipt:latest_receipt_for_runtime_state
      ~latest_next_action ~attention_fields:raw.attention_fields
  in
  let execution_summary =
    execution_summary_json ~meta ~latest_receipt:raw.latest_receipt
  in
  let approval_state =
    approval_state_json
      ~pending_approval_projection:raw.pending_approval_projection
      ~latest_approval_audit:raw.latest_approval_audit
  in
  let latest_causal_event =
    match
      approval_queue_unavailable_timeline_event
        ~observed_at_unix:raw.observed_at_unix
        raw.pending_approval_projection
    with
    | Some event -> event
    | None ->
        latest_causal_event_summary ~observed_at_unix:raw.observed_at_unix
          ~meta ~latest_decision:raw.latest_decision
          ~latest_receipt:raw.latest_receipt
          ~latest_tool_call:raw.latest_tool_call
          ~latest_approval_audit:raw.latest_approval_audit
          ~runtime_blocker_fields:raw.runtime_blocker_fields
          ~next_human_action:trust_model.next_human_action
  in
  `Assoc
    (trust_model_json_fields trust_model
     @ [ ("approval_queue_state", raw.pending_approval_projection.state)
       ; ("approval", approval_state)
       ; ("execution", execution_summary)
       ; ("latest_terminal_reason", latest_terminal_reason_json)
       ; ("latest_next_action", Json_util.string_opt_to_json latest_next_action)
       ; ("latest_causal_event", latest_causal_event)
       ])

let summary_json ~(config : Workspace.config) ~(meta : keeper_meta) =
  collect_summary_raw ~config ~meta |> summary_json_of_raw ~meta
;;

let causal_timeline_json ~observed_at_unix ~recent_tool_call_rows
    ~recent_approval_audit_rows ~recent_transition_rows ~meta
    ~latest_decision ~latest_receipt ~latest_tool_call
    ~latest_approval_audit ~runtime_blocker_fields ~next_human_action
    ~pending_approval_projection =
  let tool_events =
    List.filter_map tool_call_timeline_event recent_tool_call_rows
  in
  let approval_events =
    List.filter_map approval_event_timeline_event recent_approval_audit_rows
  in
  let transition_events =
    List.filter_map transition_timeline_event recent_transition_rows
  in
  let decision_events =
    (match latest_decision with
     | Some json -> [ decision_timeline_event json ]
     | None -> [])
    |> List.filter_map Fun.id
  in
  let receipt_events =
    (match latest_receipt with
     | Some receipt -> [ receipt_timeline_event receipt ]
     | None -> [])
    |> List.filter_map Fun.id
  in
  let terminal_reason_events =
    [ terminal_reason_timeline_event ~latest_decision ~latest_receipt ]
    |> List.filter_map Fun.id
  in
  let blocker_events =
    let task_id = Keeper_runtime_contract.current_task_id_opt meta in
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let blocker_ts_unix =
      runtime_blocker_timeline_ts ~observed_at_unix ~meta
        ~runtime_blocker_fields latest_receipt
    in
    let blocker_observation_only =
      not
        (runtime_blocker_supersedes_receipt ~meta ~runtime_blocker_fields
           latest_receipt)
    in
    [
      blocker_timeline_event ~ts_unix:blocker_ts_unix
        ~observed_at_unix:blocker_ts_unix
        ~runtime_blocker_fields ?task_id
        ~trace_id ~next_human_action
        ~observation_only:blocker_observation_only ()
    ]
    |> List.filter_map Fun.id
  in
  let latest_tool_call_event =
    match latest_tool_call with
    | Some json -> tool_call_timeline_event json
    | None -> None
  in
  let latest_approval_event =
    match latest_approval_audit with
    | Some json -> approval_event_timeline_event json
    | None -> None
  in
  let dedupe_key json =
    let kind = json_string_opt_member "kind" json |> Option.value ~default:"" in
    let ts = json_string_opt_member "ts" json |> Option.value ~default:"" in
    let title = json_string_opt_member "title" json |> Option.value ~default:"" in
    kind ^ "|" ^ ts ^ "|" ^ title
  in
  let dedupe acc item =
    let key = dedupe_key item in
    if List.exists (fun existing -> String.equal key (dedupe_key existing)) acc
    then acc
    else item :: acc
  in
  let live_pending_events =
    match pending_approval_projection.entries with
    | Some entries ->
        List.filter_map live_pending_approval_timeline_event entries
    | None -> []
  in
  let approval_queue_state_events =
    List.filter_map Fun.id
      [
        approval_queue_unavailable_timeline_event ~observed_at_unix
          pending_approval_projection;
      ]
  in
  tool_events @ approval_events @ transition_events @ terminal_reason_events
  @ decision_events @ receipt_events @ blocker_events @ live_pending_events
  @ approval_queue_state_events
  @ (List.filter_map Fun.id [ latest_tool_call_event; latest_approval_event ])
  |> List.fold_left dedupe []
  |> sort_timeline_events
  |> take 12
  |> fun items -> `List items

let collect_raw_snapshot_with_pending_reader
    ~(read_pending :
       base_path:string ->
       (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result)
    ~(config : Workspace.config) ~(meta : keeper_meta) =
  let registry_entry =
    Keeper_registry.get ~base_path:config.base_path meta.name
  in
  let runtime_contract =
    Keeper_runtime_contract.runtime_observability_contract_json ~config meta
  in
  let recent_tool_call_rows =
    Keeper_tool_call_log.read_recent ~keeper_name:meta.name ~n:6 ()
  in
  let recent_transition_rows =
    match
      Keeper_transition_audit.recent_transitions_json
        ~keeper_name:meta.name ~limit:6
    with
    | `List items -> items
    | _ -> []
  in
  let observations, recent_approval_audit_rows =
    collect_raw_observations_with_pending_reader ~read_pending
      ~approval_audit_limit:8 ~config ~meta
  in
  { observations
  ; registry_entry
  ; runtime_contract
  ; recent_tool_call_rows
  ; recent_approval_audit_rows
  ; recent_transition_rows
  }
;;

let snapshot_json_of_raw ~(meta : keeper_meta) (raw : raw_snapshot) =
  let observations = raw.observations in
  let latest_receipt_for_runtime_state =
    current_receipt_for_runtime_state ~meta
      ~runtime_blocker_fields:observations.runtime_blocker_fields
      observations.latest_receipt
  in
  let latest_terminal_reason =
    latest_terminal_reason_opt ~meta
      ~runtime_blocker_fields:observations.runtime_blocker_fields
      ~latest_decision:observations.latest_decision
      ~latest_receipt:observations.latest_receipt
  in
  let latest_terminal_reason_json =
    latest_terminal_reason
    |> Option.map Keeper_turn_terminal.to_json
    |> Option.value ~default:`Null
  in
  let latest_next_action =
    Option.bind latest_terminal_reason (fun reason -> reason.next_action)
  in
  let selected_model =
    selected_model_of_latest_decision_or_receipt observations.latest_decision
      observations.latest_receipt
  in
  let runtime_phase =
    match raw.registry_entry with
    | Some entry -> `String (Keeper_state_machine.phase_to_string entry.phase)
    | None -> `Null
  in
  let trust_model =
    trust_model_of_observations
      ~pending_approval_projection:observations.pending_approval_projection
      ~runtime_blocker_fields:observations.runtime_blocker_fields
      ~latest_receipt:latest_receipt_for_runtime_state ~latest_next_action
      ~attention_fields:observations.attention_fields
  in
  let approval_state =
    approval_state_json
      ~pending_approval_projection:observations.pending_approval_projection
      ~latest_approval_audit:observations.latest_approval_audit
  in
  let execution_summary =
    execution_summary_json ~meta ~latest_receipt:observations.latest_receipt
  in
  let causal_timeline =
    causal_timeline_json
      ~observed_at_unix:observations.observed_at_unix
      ~recent_tool_call_rows:raw.recent_tool_call_rows
      ~recent_approval_audit_rows:raw.recent_approval_audit_rows
      ~recent_transition_rows:raw.recent_transition_rows ~meta
      ~latest_decision:observations.latest_decision
      ~latest_receipt:observations.latest_receipt
      ~latest_tool_call:observations.latest_tool_call
      ~latest_approval_audit:observations.latest_approval_audit
      ~runtime_blocker_fields:observations.runtime_blocker_fields
      ~next_human_action:trust_model.next_human_action
      ~pending_approval_projection:observations.pending_approval_projection
  in
  let latest_causal_event =
    latest_causal_from_timeline causal_timeline
  in
  `Assoc
    ([ ("trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
     ; ("generation", `Int meta.runtime.nonce)
     ; ( "turn_id"
       , match
           latest_turn_id ~registry_entry:raw.registry_entry
             ~latest_decision:observations.latest_decision
             ~latest_tool_call:observations.latest_tool_call
             ~latest_receipt:observations.latest_receipt
         with
         | Some turn_id -> `Int turn_id
         | None -> `Null )
     ; ("phase", runtime_phase)
     ; ("raw_phase", runtime_phase)
     ; ( "current_task_id"
       , Json_util.string_opt_to_json
           (Keeper_runtime_contract.current_task_id_opt meta) )
     ; ("active_model", Json_util.string_opt_to_json selected_model)
     ; ("selected_model", Json_util.string_opt_to_json selected_model)
     ; ("runtime_contract", raw.runtime_contract)
     ; ("runtime_blockers", `Assoc observations.runtime_blocker_fields)
     ]
     @ trust_model_json_fields trust_model
     @ [ ("approval_queue_state", observations.pending_approval_projection.state)
       ; ("approval", approval_state)
       ; ("execution", execution_summary)
       ; ("latest_terminal_reason", latest_terminal_reason_json)
       ; ("latest_next_action", Json_util.string_opt_to_json latest_next_action)
       ; ( "pending_approval_count"
         , match observations.pending_approval_projection.count with
           | Some count -> `Int count
           | None -> `Null )
       ; ( "pending_approvals"
         , match observations.pending_approval_projection.entries with
           | Some entries -> `List entries
           | None -> `Null )
       ; ( "latest_decision"
         , Option.value ~default:`Null observations.latest_decision )
       ; ( "latest_tool_call"
         , Option.value ~default:`Null observations.latest_tool_call )
       ; ( "latest_receipt"
         , Option.value ~default:`Null observations.latest_receipt )
       ; ("latest_causal_event", latest_causal_event)
       ; ("causal_timeline", causal_timeline)
       ; ( "last_event_bus_correlation"
         , match raw.registry_entry with
           | Some entry ->
               Json_util.string_opt_to_json entry.last_event_bus_correlation
           | None -> `Null )
       ])
;;

let snapshot_json_inner_with_pending_reader
    ~(read_pending :
       base_path:string ->
       (Yojson.Safe.t list, Keeper_approval_queue.storage_error) result)
    ~(config : Workspace.config) ~(meta : keeper_meta) =
  collect_raw_snapshot_with_pending_reader ~read_pending ~config ~meta
  |> snapshot_json_of_raw ~meta
;;

let snapshot_json_inner ~(config : Workspace.config) ~(meta : keeper_meta) =
  snapshot_json_inner_with_pending_reader
    ~read_pending:
      Keeper_approval_queue.list_pending_dashboard_json_for_workspace
    ~config ~meta

let snapshot_json ~(config : Workspace.config) ~(meta : keeper_meta) =
  let cache_key =
    { Snapshot_cache.base_path = config.base_path
    ; keeper_name = meta.name
    ; generation = meta.runtime.nonce
    ; last_turn_ts = meta.runtime.usage.last_turn_ts
    ; approval_queue_revision =
        Keeper_approval_queue.store_revision_for_workspace
          ~base_path:config.base_path
    }
  in
  let now = Time_compat.now () in
  match Snapshot_cache.get ~now cache_key with
  | Some value -> value
  | None ->
      let value = snapshot_json_inner ~config ~meta in
      Snapshot_cache.set ~now cache_key value;
      value

module For_testing = struct
  let snapshot_json_inner_with_pending_reader =
    snapshot_json_inner_with_pending_reader
end
