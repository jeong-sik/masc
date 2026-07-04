open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_context_runtime
module StringSet = Set_util.StringSet


(* Issue #8484: Variant SSOT for memory search scope. Adding a new
   constructor forces compilation in [memory_search_source_to_string]
   AND extends [valid_memory_search_source_strings]; the schema in
   [tool_shard.ml] mirrors the SSOT (cycle: Tool_shard ->
   Keeper_tool_memory_runtime -> ... -> Tool_shard prevented via local mirror,
   sync test catches drift). The previous code used a string match
   with a wildcard `_ -> memory` branch which silently routed any
   unknown source to memory. Now unknown values are rejected at the
   tool boundary. *)
type memory_search_source =
  | Memory
  | History
  | All

let memory_search_source_to_string = function
  | Memory -> "memory"
  | History -> "history"
  | All -> "all"
;;

let memory_search_source_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "memory" -> Some Memory
  | "history" -> Some History
  | "all" -> Some All
  | _ -> None
;;

let all_memory_search_sources = [ Memory; History; All ]

let valid_memory_search_source_strings =
  List.map memory_search_source_to_string all_memory_search_sources
;;

type memory_match =
  { kind : string
  ; horizon : string
  ; source : string option
  ; text : string
  ; priority : int
  ; generation : int
  ; turn : int
  ; ts : string
  ; score : float
  }

let memory_bank_persistence_surface = "keeper_tool_memory_bank"

let report_memory_bank_read_drop ~path ~reason ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Otel_metric_store.inc_counter
        Otel_metric_store.metric_persistence_read_drops
        ~labels:[ "surface", memory_bank_persistence_surface; "reason", reason ]
        ())
    ~surface:memory_bank_persistence_surface
    ~reason
    ~path
    ~detail
;;

let search_memory_bank
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(query : string)
      ~(kind_filter : string)
      ~(limit : int)
  : memory_match list * int
  =
  let path = Keeper_types_support.keeper_memory_bank_path config meta.name in
  let lines =
    match
      Keeper_memory_recall.read_file_tail_lines_result path
        ~max_bytes:(256 * 1024) ~max_lines:500
    with
    | Ok lines -> lines
    | Error exn_class ->
        Keeper_memory_recall.record_memory_recall_read_error
          ~site:"keeper_memory_search" path exn_class;
        []
  in
  let now_ts = Time_compat.now () in
  let parsed =
    lines
    |> List.filter_map (fun line ->
      match Yojson.Safe.from_string line with
      | exception Yojson.Json_error detail ->
        report_memory_bank_read_drop
          ~path
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~detail;
        None
      | `Assoc _ as j ->
        (try
           let schema_version = Safe_ops.json_int ~default:0 "schema_version" j in
           let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
           let horizon = Keeper_memory_policy.memory_horizon_of_json_opt j in
           let expected_horizon =
             Keeper_memory_policy.memory_horizon_of_kind_opt kind
           in
           let source = Safe_ops.json_string ~default:"" "source" j |> String.trim in
           let trace_id = Safe_ops.json_string ~default:"" "trace_id" j |> String.trim in
           let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
           let priority = Safe_ops.json_int ~default:0 "priority" j in
           let generation = Safe_ops.json_int ~default:0 "generation" j in
           let turn = Safe_ops.json_int ~default:0 "turn" j in
           let ts = Safe_ops.json_string ~default:"" "ts" j in
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           if schema_version <> Keeper_memory_policy.keeper_memory_schema_version
           then (
             report_memory_bank_read_drop
               ~path
               ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
               ~detail:"memory bank row has unsupported schema_version";
             None)
           else if kind = "" || text = "" || source = "" || trace_id = ""
           then (
             report_memory_bank_read_drop
               ~path
               ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
               ~detail:
                 "memory bank row is missing required kind, text, source, or trace_id";
             None)
           else (
             match expected_horizon, horizon with
             | None, _ | _, None ->
               report_memory_bank_read_drop
                 ~path
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~detail:"memory bank row has unknown kind or missing horizon";
               None
             | Some eh, Some h when not (String.equal eh h) ->
               report_memory_bank_read_drop
                 ~path
                 ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
                 ~detail:"memory bank row kind/horizon mismatch";
               None
             | Some _, Some h ->
               Some
                 { kind
                 ; horizon = h
                 ; source = Some source
                 ; text
                 ; priority
                 ; generation
                 ; turn
                 ; ts
                 ; score = ts_unix
                 })
         with
         | Yojson.Safe.Util.Type_error (detail, _) ->
           report_memory_bank_read_drop
             ~path
             ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
             ~detail;
           None)
      | _ ->
        report_memory_bank_read_drop
          ~path
          ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
          ~detail:"memory bank row is not a JSON object";
        None)
  in
  let total_candidates = List.length parsed in
  (* Structured filter: kind (deterministic) *)
  let filtered =
    if kind_filter = ""
    then parsed
    else List.filter (fun m -> String_util.equals_ci m.kind kind_filter) parsed
  in
  (* Text match: query against text field (non-deterministic data).
     Partial-token match (count > 0), not strict token-AND — a natural-language
     query like "notable event lesson learned" previously matched 0 notes even
     when 2 of 4 tokens overlapped a stored note. Exact-AND semantics survive
     via the matched_token_ratio weight in scoring (full match = ratio 1.0). *)
  let matched =
    if query = ""
    then filtered
    else List.filter (fun m -> String_util.count_matched_tokens_ci m.text query > 0) filtered
  in
  (* Scoring: priority * recency_weight.
     recency_weight normalizes age relative to the oldest note in the result set.
     No hardcoded decay constant — uses min/max normalization. *)
  let ts_values = List.map (fun m -> m.score) matched in
  let min_ts =
    match ts_values with
    | [] -> now_ts
    | ts :: rest -> List.fold_left min ts rest
  in
  let max_age = max 1.0 (now_ts -. min_ts) in
  let scored =
    matched
    |> List.map (fun m ->
      let age = max 0.0 (now_ts -. m.score) in
      let recency_weight = max 0.0 (min 1.0 (1.0 -. (0.3 *. (age /. max_age)))) in
      let horizon_weight =
        match m.horizon with
        | h when h = Keeper_memory_policy.long_term_horizon -> 1.10
        | h when h = Keeper_memory_policy.short_term_horizon ->
          if m.generation >= meta.runtime.generation then 1.05 else 0.65
        | _ -> 1.0
      in
      let source_bonus =
        match m.source with
        | Some "cross_trace_recurrence" -> 0.04
        | Some "progress_consolidation" -> 0.02
        | _ -> 0.0
      in
      let synthetic_penalty =
        if Keeper_synthetic_marker.contains_marker m.text then -0.1 else 0.0
      in
      let token_match_weight =
        if query = "" then 1.0
        else String_util.matched_token_ratio_ci m.text query
      in
      let score =
        (float_of_int m.priority /. 100.0
           *. recency_weight
           *. horizon_weight
           *. token_match_weight)
        +. synthetic_penalty
        +. source_bonus
      in
      let rounded = Float.round (score *. 1000.0) /. 1000.0 in
      { m with score = rounded })
  in
  let sorted =
    scored |> List.sort (fun a b -> Float.compare b.score a.score) |> take limit
  in
  sorted, total_candidates
;;

let memory_match_to_json (m : memory_match) : Yojson.Safe.t =
  `Assoc
    [ "kind", `String m.kind
    ; "horizon", `String m.horizon
    ; ( "source", Json_util.string_opt_to_json m.source )
    ; "text", `String m.text
    ; "priority", `Int m.priority
    ; "generation", `Int m.generation
    ; "turn", `Int m.turn
    ; "ts", `String m.ts
    ; "score", `Float m.score
    ]
;;

(* --- History search (checkpoint + trace history) --- *)

let search_history
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(query : string)
      ~(limit : int)
  : string list
  =
  (* RFC-0149 §3.1 — aggregation site.  Multiple history files are
     concatenated for search; a per-path Read failure is dropped to
     [[]] so a single corrupt history does not suppress matches from
     the others.  The decision to elide is made *here* rather than
     hidden inside a silent facade — failures still surface via the
     [metric_keeper_memory_recall_read_errors] counter emitted by
     [Keeper_memory_recall.load_history_user_messages_result]. *)
  let current_history =
    match
      Keeper_memory_recall.load_history_user_messages_result
        ~path:
          (Keeper_types_support.keeper_history_path
             config
             (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
        ~max_n:50
    with
    | Ok msgs -> msgs
    | Error _ -> []
  in
  let prev_history =
    meta.runtime.trace_history
    |> List.concat_map (fun old_trace_id ->
      match
        Keeper_memory_recall.load_history_user_messages_result
          ~path:(Keeper_types_support.keeper_history_path config old_trace_id)
          ~max_n:20
      with
      | Ok msgs -> msgs
      | Error _ -> [])
  in
  let checkpoint_user_msgs =
    Keeper_memory_recall.recent_user_messages (messages_of_context ctx_work) ~max_n:100
  in
  let key_of s =
    let len = min 100 (String.length s) in
    String.sub s 0 len
  in
  let seen0 =
    List.fold_left
      (fun acc s -> StringSet.add (key_of s) acc)
      StringSet.empty
      checkpoint_user_msgs
  in
  let dedup seen lst =
    List.fold_left
      (fun (acc, seen) s ->
         let k = key_of s in
         if StringSet.mem k seen then acc, seen else s :: acc, StringSet.add k seen)
      ([], seen)
      lst
    |> fun (acc, seen) -> List.rev acc, seen
  in
  let all_candidates =
    checkpoint_user_msgs
    @ fst (dedup seen0 current_history)
    @ fst (dedup (snd (dedup seen0 current_history)) prev_history)
  in
  all_candidates
  |> List.filter (fun msg -> query <> "" && String_util.contains_all_tokens_ci msg query)
  |> List.rev
  |> take limit
;;

(* --- Unified keeper_memory_search dispatch --- *)

let keeper_memory_search_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(args : Yojson.Safe.t)
  =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let limit = max 1 (min 10 (Safe_ops.json_int ~default:5 "limit" args)) in
  let source_raw = Safe_ops.json_string ~default:"memory" "source" args in
  match memory_search_source_of_string_opt source_raw with
  | None ->
    error_json
      ~fields:
        [ "error_kind", `String "invalid_memory_search_source"
        ; "provided_source", `String source_raw
        ; ( "supported_sources"
          , `List (List.map (fun s -> `String s) valid_memory_search_source_strings) )
        ]
      "invalid keeper_memory_search source"
  | Some source ->
    let source_label = memory_search_source_to_string source in
    let kind_filter = Safe_ops.json_string ~default:"" "kind" args |> String.trim in
    let result =
    match source with
    | History ->
      let matches = search_history ~config ~meta ~ctx_work ~query ~limit in
      let no_match = matches = [] in
      let match_jsons = List.map (fun msg -> `String msg) matches in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "match_count", `Int (List.length matches)
         ; "matches", `List match_jsons
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
    | All ->
      let bank_matches, bank_total =
        search_memory_bank ~config ~meta ~query ~kind_filter ~limit
      in
      let history_limit = max 0 (limit - List.length bank_matches) in
      let history_matches =
        if history_limit > 0
        then search_history ~config ~meta ~ctx_work ~query ~limit:history_limit
        else []
      in
      let total_matches = List.length bank_matches + List.length history_matches in
      let no_match = total_matches = 0 in
      let bank_jsons = List.map memory_match_to_json bank_matches in
      let history_jsons =
        List.map
          (fun msg ->
             `Assoc
               [ "source", `String (memory_search_source_to_string History)
               ; "text", `String msg
               ])
          history_matches
      in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int bank_total
         ; "match_count", `Int total_matches
         ; "matches", `List (bank_jsons @ history_jsons)
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
    | Memory ->
      let matches, total_candidates =
        search_memory_bank ~config ~meta ~query ~kind_filter ~limit
      in
      let no_match = matches = [] in
      let match_jsons = List.map memory_match_to_json matches in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int total_candidates
         ; "match_count", `Int (List.length matches)
         ; "matches", `List match_jsons
         ]
         @ (if no_match then [ "no_match", `Bool true ] else [])
         @ if kind_filter <> "" then [ "kind_filter", `String kind_filter ] else [])
  in
  (* Day-1 search logging: append search event to decisions log.
     Extract match_count and top_score from the already-computed result. *)
  let log_match_count =
    match result with
    | `Assoc fields ->
      (match List.assoc_opt "match_count" fields with
       | Some (`Int n) -> n
       | _ -> 0)
    | _ -> 0
  in
  let log_top_score =
    match result with
    | `Assoc fields ->
      (match List.assoc_opt "matches" fields with
       | Some (`List (first :: _)) ->
         (match first with
          | `Assoc mfields ->
            (match List.assoc_opt "score" mfields with
             | Some (`Float s) -> Some s
             | _ -> None)
          | _ -> None)
       | _ -> None)
    | _ -> None
  in
  (try
     let log_entry =
       `Assoc
         ([ "ts_unix", `Float (Time_compat.now ())
          ; "event", `String "memory_search"
          ; "query", `String query
          ; "source", `String source_label
          ; "kind_filter", `String kind_filter
          ; "match_count", `Int log_match_count
          ]
          @
          match log_top_score with
          | Some s -> [ "top_score", `Float s ]
          | None -> [])
     in
     Keeper_types_support.append_jsonl_line
       (Keeper_types_support.keeper_decision_log_path config meta.name)
       log_entry
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string DecisionAuditFlushFailures)
       ~labels:[ "keeper", meta.name ]
       ();
     Log.Keeper.warn ~keeper_name:meta.name
       "memory_search decision-log append failed: %s"
       (Printexc.to_string exn));
  Yojson.Safe.to_string result
;;

let keeper_context_status_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
  =
  let progress_snapshot =
    Keeper_memory_policy.read_progress_snapshot ~config ~name:meta.name
  in
  let checkpoint_snapshot =
    Keeper_memory_policy.latest_state_snapshot_from_messages
      (messages_of_context ctx_work)
  in
  let continuity, recovery_source =
    match progress_snapshot with
    | Some snapshot -> Some snapshot, "progress_log"
    | None ->
      (match checkpoint_snapshot with
       | Some snapshot -> Some snapshot, "checkpoint"
       | None ->
         (match
            Keeper_memory_policy.state_snapshot_of_summary_text meta.continuity_summary
          with
          | Some snapshot -> Some snapshot, "meta_summary"
          | None -> None, "none"))
  in
  let continuity_summary =
    match continuity with
    | None ->
      Keeper_memory_policy.continuity_fallback_summary_text
        ~continuity_summary:meta.continuity_summary
        ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
    | Some snapshot -> Keeper_memory_policy.keeper_state_snapshot_to_summary_text snapshot
  in
  let ctx_tokens = count_context_tokens ctx_work in
  let ctx_max = Keeper_context_runtime.max_tokens_of_context ctx_work in
  let ctx_ratio =
    if ctx_max = 0 then 0.0 else float_of_int ctx_tokens /. float_of_int ctx_max
  in
  (* RFC-0149 §3.1 — route through typed Result resolver so a memory
     bank IO fault surfaces as the sibling [memory_tier_error_class]
     field instead of an empty [memory_tier_summary] that is
     indistinguishable from "no recorded horizons". *)
  let memory_tier_summary, memory_tier_error_class =
    match
      Keeper_memory_recall.read_memory_horizon_counts_result
        config
        ~name:meta.name
        ~max_bytes:(128 * 1024)
        ~max_lines:300
    with
    | Ok counts ->
      let json =
        List.map (fun (horizon, count) -> horizon, `Int count) counts
      in
      json, None
    | Error exn_class ->
      [], Some (Keeper_memory_recall_exn_class.to_label exn_class)
  in
  (* Give the keeper sandbox-relative paths from the SSOT so it never needs
     to interpolate host storage paths such as ".masc/playground/<name>/". *)
  let sandbox = Keeper_sandbox.of_meta ~config ~meta in
  let sandbox_live =
    Keeper_sandbox_control.live_status_json
      ~include_preflight:true
      ~config
      ~meta
      ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
      ~verbose:false
      ()
  in
  Yojson.Safe.to_string
    (`Assoc
        ([ "name", `String meta.name
         ; "trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         ; "generation", `Int meta.runtime.generation
         ; "context_ratio", `Float ctx_ratio
         ; "context_tokens", `Int ctx_tokens
         ; "context_max", `Int ctx_max
         ; "message_count", `Int (List.length (messages_of_context ctx_work))
         ; "last_model_used", `Null
         ]
         @ Keeper_sandbox.context_status_fields sandbox
         @ [ "sandbox_live", sandbox_live
           ; ( "continuity_state"
             , match continuity with
               | None -> `Null
               | Some snapshot ->
                 Keeper_memory_policy.keeper_state_snapshot_to_json snapshot )
           ; "continuity_summary", `String continuity_summary
           ; ( "recent_tool_calls"
             , `List
                 (List.map
                    (fun (s : tool_call_summary) ->
                       `Assoc [ ("tool", `String s.tool_name); ("outcome", `String s.outcome) ])
                    meta.runtime.last_turn_tool_calls) )
           ; "recovery_source", `String recovery_source
           ; "memory_tier_summary", `Assoc memory_tier_summary
           ; ( "memory_tier_error_class"
             , Json_util.string_opt_to_json memory_tier_error_class )
           ]))
;;

(* --- Memory bank search (structured notes from [STATE] blocks) --- *)

(* --- Explicit memory write (RFC-0035 P4 surface) ----------------- *)

(** Maps memory_kind enum to the corresponding [keeper_state_snapshot]
    field. Returns a snapshot with only that field populated.  Mirrors
    the field-to-kind mapping in
    [Keeper_memory_bank.memory_candidates_from_snapshot]:
      goal          -> snapshot.goal (option)
      progress      -> snapshot.progress (option)
      next          -> snapshot.next_items (list)
      decision      -> snapshot.decisions (list)
      open_question -> snapshot.open_questions (list)
      constraints   -> snapshot.constraints (list)
    [long_term] is intentionally not supported via explicit write; it is
    produced from tool-result emission only.  See RFC-0035 §3 (P4). *)
let single_field_snapshot_for_kind ~(kind : string) ~(text : string)
  : Keeper_memory_policy.keeper_state_snapshot option
  =
  let empty = Keeper_memory_policy.empty_keeper_state_snapshot in
  match kind with
  | "goal" -> Some { empty with goal = Some text }
  | "progress" -> Some { empty with progress = Some text }
  | "next" -> Some { empty with next_items = [ text ] }
  | "decision" -> Some { empty with decisions = [ text ] }
  | "open_question" -> Some { empty with open_questions = [ text ] }
  | "constraints" -> Some { empty with constraints = [ text ] }
  | _ -> None
;;

let keeper_memory_write_max_title_chars = 120

(** Pure validation result for a [keeper_memory_write] call. Splitting
    this from the persistence step lets tests pin the error_kind
    taxonomy without constructing a [Workspace.config]. *)
type memory_write_error_kind =
  | Invalid_memory_kind
  | Title_too_long
  | Content_empty
  | Long_term_via_explicit_write_not_yet_supported
  | Rows_dropped_by_cap
  | No_memory_write_error

let memory_write_error_kind_to_string = function
  | Invalid_memory_kind -> "invalid_memory_kind"
  | Title_too_long -> "title_too_long"
  | Content_empty -> "content_empty"
  | Long_term_via_explicit_write_not_yet_supported ->
    "long_term_via_explicit_write_not_yet_supported"
  | Rows_dropped_by_cap -> "rows_dropped_by_cap"
  | No_memory_write_error -> ""
;;

type memory_write_validation =
  | Memory_write_ok of
      { kind : string
      ; body : string
      ; snapshot : Keeper_memory_policy.keeper_state_snapshot
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

let validate_memory_write_args (args : Yojson.Safe.t) : memory_write_validation =
  let kind = Safe_ops.json_string ~default:"" "kind" args |> String.trim in
  let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
  let content = Safe_ops.json_string ~default:"" "content" args |> String.trim in
  if not (List.mem kind Keeper_memory_policy.valid_memory_kind_strings)
  then
    Memory_write_invalid
      { error_kind = Invalid_memory_kind
      ; extras =
          [ "provided_kind", `String kind
          ; ( "supported_kinds"
            , `List
                (List.map
                   (fun k -> `String k)
                   Keeper_memory_policy.valid_memory_kind_strings) )
          ]
      }
  else if String.length title > keeper_memory_write_max_title_chars
  then
    Memory_write_invalid
      { error_kind = Title_too_long
      ; extras =
          [ "max_chars", `Int keeper_memory_write_max_title_chars
          ; "title_chars", `Int (String.length title)
          ]
      }
  else if content = ""
  then Memory_write_invalid { error_kind = Content_empty; extras = [] }
  else if kind = "long_term"
  then
    Memory_write_invalid
      { error_kind = Long_term_via_explicit_write_not_yet_supported; extras = [] }
  else (
    let body = if title = "" then content else Printf.sprintf "**%s** %s" title content in
    match single_field_snapshot_for_kind ~kind ~text:body with
    | None ->
      (* Defensive — validation above should have caught this. *)
      Memory_write_invalid
        { error_kind = Invalid_memory_kind; extras = [ "provided_kind", `String kind ] }
    | Some snapshot -> Memory_write_ok { kind; body; snapshot })
;;

let keeper_memory_write_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : string
  =
  let respond ~ok ~error_kind extras =
    let error_kind = memory_write_error_kind_to_string error_kind in
    Yojson.Safe.to_string
      (`Assoc ([ "ok", `Bool ok; "error_kind", `String error_kind ] @ extras))
  in
  match validate_memory_write_args args with
  | Memory_write_invalid { error_kind; extras } ->
    respond ~ok:false ~error_kind extras
  | Memory_write_ok { kind; body = _; snapshot } ->
    let rows_written, kinds_written =
      Keeper_memory_bank.append_memory_notes_from_reply
        config
        meta
        ~snapshot
        ~turn:0
        ~reply:""
        ()
    in
    if rows_written = 0
    then
      respond
        ~ok:false
        ~error_kind:Rows_dropped_by_cap
        [ "kind", `String kind
        ; ( "hint"
          , `String
              "per-kind or total cap reached; older entries take precedence until \
               rotation lands." )
        ]
    else
      respond
        ~ok:true
        ~error_kind:No_memory_write_error
        [ "rows_written", `Int rows_written
        ; "kinds_written", `List (List.map (fun k -> `String k) kinds_written)
        ; "kind", `String kind
        ]
;;
