(** Keeper_exec_memory_search — memory search types, history search,
    bank search, and unified dispatch extracted from [Keeper_exec_memory]
    (691 LoC).  Context status and explicit memory write remain in
    the parent.
    @since Keeper 500-line decomposition *)

open Keeper_types
open Keeper_exec_shared
open Keeper_exec_context
module StringSet = Set_util.StringSet




(* Issue #8484: Variant SSOT for memory search scope. Adding a new
   constructor forces compilation in [memory_search_source_to_string]
   AND extends [valid_memory_search_source_strings]; the schema in
   [tool_shard.ml] mirrors the SSOT (cycle: Tool_shard ->
   Keeper_exec_memory -> ... -> Tool_shard prevented via local mirror,
   sync test catches drift). The previous code used a string match
   with a wildcard `_ -> memory` branch which silently routed any
   unknown source to memory — anti-pattern from CLAUDE.md "Unknown ->
   Permissive Default". Now [of_string_opt] returns [None] for
   unknown values and the caller decides the fallback explicitly. *)
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

let memory_bank_persistence_surface = "keeper_exec_memory_bank"

let memory_horizon_of_kind_with_fallback kind =
  match Keeper_memory_policy.memory_horizon_of_kind_opt kind with
  | Some horizon -> horizon
  | None ->
      Log.Memory.warn
        "keeper_exec_memory: unknown memory kind %S -> mid_term (drift; see #8826)"
        kind;
      Keeper_memory_policy.mid_term_horizon
;;

let memory_horizon_of_json_with_fallback ~kind json =
  match Keeper_memory_policy.memory_horizon_of_json_opt json with
  | Some horizon -> horizon
  | None -> memory_horizon_of_kind_with_fallback kind
;;

let report_memory_bank_read_drop ~path ~reason ~detail =
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () ->
      Prometheus.inc_counter
        Prometheus.metric_persistence_read_drops
        ~labels:[ "surface", memory_bank_persistence_surface; "reason", reason ]
        ())
    ~surface:memory_bank_persistence_surface
    ~reason
    ~path
    ~detail
;;

let search_memory_bank
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(query : string)
      ~(kind_filter : string)
      ~(limit : int)
  : memory_match list * int
  =
  let path = Keeper_types_support.keeper_memory_bank_path config meta.name in
  let lines =
    Keeper_memory_recall.read_file_tail_lines path ~max_bytes:(256 * 1024) ~max_lines:500
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
           let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
           let horizon = memory_horizon_of_json_with_fallback ~kind j in
           let source = Safe_ops.json_string ~default:"" "source" j |> String.trim in
           let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
           let priority = Safe_ops.json_int ~default:0 "priority" j in
           let generation = Safe_ops.json_int ~default:0 "generation" j in
           let turn = Safe_ops.json_int ~default:0 "turn" j in
           let ts = Safe_ops.json_string ~default:"" "ts" j in
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           if kind = "" || text = ""
           then (
             report_memory_bank_read_drop
               ~path
               ~reason:Safe_ops.persistence_read_drop_reason_invalid_payload
               ~detail:"memory bank row is missing required kind or text";
             None)
           else
             Some
               { kind
               ; horizon
               ; source = (if source = "" then None else Some source)
               ; text
               ; priority
               ; generation
               ; turn
               ; ts
               ; score = ts_unix
               }
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
  (* Text match: query against text field (non-deterministic data) *)
  let matched =
    if query = ""
    then filtered
    else List.filter (fun m -> String_util.contains_substring_ci m.text query) filtered
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
      let score =
        (float_of_int m.priority /. 100.0 *. recency_weight *. horizon_weight)
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
    ; ( "source"
      , match m.source with
        | Some source -> `String source
        | None -> `Null )
    ; "text", `String m.text
    ; "priority", `Int m.priority
    ; "generation", `Int m.generation
    ; "turn", `Int m.turn
    ; "ts", `String m.ts
    ; "score", `Float m.score
    ]
;;

(* --- History search (cross-generation, retained for backward compat) --- *)

let search_history
      ~(config : Coord.config)
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
  |> List.filter (fun msg -> query <> "" && String_util.contains_substring_ci msg query)
  |> List.rev
  |> take limit
;;

(* --- Unified keeper_memory_search dispatch --- *)

let keeper_memory_search_json
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(args : Yojson.Safe.t)
  =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let limit = max 1 (min 10 (Safe_ops.json_int ~default:5 "limit" args)) in
  let source_raw = Safe_ops.json_string ~default:"memory" "source" args in
  (* Issue #8484: explicit fallback to Memory for back-compat with the
     prior wildcard branch — but unknown values are now visibly mapped,
     not silently absorbed. *)
  let source =
    memory_search_source_of_string_opt source_raw |> Option.value ~default:Memory
  in
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
     Prometheus.inc_counter
       Keeper_metrics.metric_keeper_decision_audit_flush_failures
       ~labels:[ "keeper", meta.name ]
       ();
     Log.Keeper.warn
       "keeper:%s memory_search decision-log append failed: %s"
       meta.name
       (Printexc.to_string exn));
  Yojson.Safe.to_string result
;;
