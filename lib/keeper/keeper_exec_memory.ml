open Keeper_types
open Keeper_exec_shared

let contains_ci = String_util.contains_substring_ci

type memory_match = {
  kind: string;
  text: string;
  priority: int;
  generation: int;
  turn: int;
  ts: string;
  score: float;
}

let search_memory_bank
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(query : string)
      ~(kind_filter : string)
      ~(limit : int) : memory_match list * int =
  let path = keeper_memory_bank_path config meta.name in
  let lines = Keeper_memory_recall.read_file_tail_lines path ~max_bytes:(256 * 1024) ~max_lines:500 in
  let now_ts = Time_compat.now () in
  let parsed =
    lines
    |> List.filter_map (fun line ->
         try
           let j = Yojson.Safe.from_string line in
           let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
           let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
           let priority = Safe_ops.json_int ~default:0 "priority" j in
           let generation = Safe_ops.json_int ~default:0 "generation" j in
           let turn = Safe_ops.json_int ~default:0 "turn" j in
           let ts = Safe_ops.json_string ~default:"" "ts" j in
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           if kind = "" || text = "" then None
           else Some { kind; text; priority; generation; turn; ts; score = ts_unix }
         with Yojson.Json_error _ -> None)
  in
  let total_candidates = List.length parsed in
  (* Structured filter: kind (deterministic) *)
  let filtered =
    if kind_filter = "" then parsed
    else List.filter (fun m -> String.lowercase_ascii m.kind = String.lowercase_ascii kind_filter) parsed
  in
  (* Text match: query against text field (non-deterministic data) *)
  let matched =
    if query = "" then filtered
    else List.filter (fun m -> contains_ci m.text query) filtered
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
         let recency_weight =
           max 0.0 (min 1.0 (1.0 -. (0.3 *. (age /. max_age))))
         in
         let synthetic_penalty =
           if contains_ci m.text "[SYNTHETIC]" then -0.1 else 0.0
         in
         let score =
           (float_of_int m.priority /. 100.0) *. recency_weight +. synthetic_penalty
         in
         let rounded = Float.round (score *. 1000.0) /. 1000.0 in
         { m with score = rounded })
  in
  let sorted =
    scored
    |> List.sort (fun a b -> Float.compare b.score a.score)
    |> take limit
  in
  (sorted, total_candidates)

let memory_match_to_json (m : memory_match) : Yojson.Safe.t =
  `Assoc [
    "kind", `String m.kind;
    "text", `String m.text;
    "priority", `Int m.priority;
    "generation", `Int m.generation;
    "turn", `Int m.turn;
    "ts", `String m.ts;
    "score", `Float m.score;
  ]

(* --- History search (cross-generation, retained for backward compat) --- *)

let search_history
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(query : string)
      ~(limit : int) : string list =
  let current_history =
    Keeper_memory_recall.load_history_user_messages
      ~path:(keeper_history_path config (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
      ~max_n:50
  in
  let prev_history =
    meta.runtime.trace_history
    |> List.concat_map (fun old_trace_id ->
         Keeper_memory_recall.load_history_user_messages
           ~path:(keeper_history_path config old_trace_id)
           ~max_n:20)
  in
  let checkpoint_user_msgs =
    Keeper_memory_recall.recent_user_messages ctx_work.messages ~max_n:100
  in
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let key_of s =
    let len = min 100 (String.length s) in
    String.sub s 0 len
  in
  List.iter (fun s -> Hashtbl.replace seen (key_of s) ()) checkpoint_user_msgs;
  let dedup lst =
    List.filter (fun s ->
      let k = key_of s in
      if Hashtbl.mem seen k then false
      else (Hashtbl.replace seen k (); true)) lst
  in
  let all_candidates =
    checkpoint_user_msgs
    @ dedup current_history
    @ dedup prev_history
  in
  all_candidates
  |> List.filter (fun msg -> query <> "" && String_util.contains_substring_ci msg query)
  |> List.rev
  |> take limit

(* --- Unified keeper_memory_search dispatch --- *)

let keeper_memory_search_json
      ~(config : Room.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(args : Yojson.Safe.t) =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let limit = max 1 (min 10 (Safe_ops.json_int ~default:5 "limit" args)) in
  let source = Safe_ops.json_string ~default:"memory" "source" args |> String.trim in
  let kind_filter = Safe_ops.json_string ~default:"" "kind" args |> String.trim in
  let result =
    match source with
    | "history" ->
      let matches = search_history ~config ~meta ~ctx_work ~query ~limit in
      let no_match = matches = [] in
      let match_jsons = List.map (fun msg -> `String msg) matches in
      `Assoc ([
        "query", `String query;
        "source", `String "history";
        "match_count", `Int (List.length matches);
        "matches", `List match_jsons;
      ] @ (if no_match then [ "no_match", `Bool true ] else []))
    | "all" ->
      let (bank_matches, bank_total) =
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
      let history_jsons = List.map (fun msg ->
        `Assoc [ "source", `String "history"; "text", `String msg ]
      ) history_matches in
      `Assoc ([
        "query", `String query;
        "source", `String "all";
        "total_candidates", `Int bank_total;
        "match_count", `Int total_matches;
        "matches", `List (bank_jsons @ history_jsons);
      ] @ (if no_match then [ "no_match", `Bool true ] else []))
    | _ (* "memory" *) ->
      let (matches, total_candidates) =
        search_memory_bank ~config ~meta ~query ~kind_filter ~limit
      in
      let no_match = matches = [] in
      let match_jsons = List.map memory_match_to_json matches in
      `Assoc ([
        "query", `String query;
        "source", `String "memory";
        "total_candidates", `Int total_candidates;
        "match_count", `Int (List.length matches);
        "matches", `List match_jsons;
      ] @ (if no_match then [ "no_match", `Bool true ] else [])
      @ (if kind_filter <> "" then [ "kind_filter", `String kind_filter ] else []))
  in
  (* Day-1 search logging: append search event to decisions log.
     Extract match_count and top_score from the already-computed result. *)
  let log_match_count =
    match result with
    | `Assoc fields -> (match List.assoc_opt "match_count" fields with
      | Some (`Int n) -> n | _ -> 0)
    | _ -> 0
  in
  let log_top_score =
    match result with
    | `Assoc fields -> (match List.assoc_opt "matches" fields with
      | Some (`List (first :: _)) ->
        (match first with
         | `Assoc mfields -> (match List.assoc_opt "score" mfields with
           | Some (`Float s) -> Some s | _ -> None)
         | _ -> None)
      | _ -> None)
    | _ -> None
  in
  (try
    let log_entry = `Assoc ([
      "ts_unix", `Float (Time_compat.now ());
      "event", `String "memory_search";
      "query", `String query;
      "source", `String source;
      "kind_filter", `String kind_filter;
      "match_count", `Int log_match_count;
    ] @ (match log_top_score with
         | Some s -> [ "top_score", `Float s ]
         | None -> [])) in
    append_jsonl_line (keeper_decision_log_path config meta.name) log_entry
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
  Yojson.Safe.to_string result
;;

let keeper_context_status_json ~(meta : keeper_meta) ~(ctx_work : working_context) =
  let continuity = Keeper_memory_policy.latest_state_snapshot_from_messages ctx_work.messages in
  let continuity_summary =
    match continuity with
    | None ->
      Keeper_memory_policy.continuity_fallback_summary_text
        ~continuity_summary:meta.continuity_summary
        ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
    | Some snapshot -> Keeper_memory_policy.keeper_state_snapshot_to_summary_text snapshot
  in
  let ctx_tokens = count_context_tokens ctx_work in
  let ctx_ratio =
    if ctx_work.max_tokens = 0
    then 0.0
    else float_of_int ctx_tokens /. float_of_int ctx_work.max_tokens
  in
  (* Give the keeper the three canonical playground paths from the SSOT
     so it does not need to re-interpolate ".masc/playground/<name>/..."
     strings every turn. These are relative to the server base_path. *)
  let playground_bundle = Playground_paths.bundle_root meta.name in
  let playground_mind = Playground_paths.mind_path meta.name in
  let playground_repos = Playground_paths.repos_path meta.name in
  Yojson.Safe.to_string
    (`Assoc
        [ "name", `String meta.name
        ; "trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ; "generation", `Int meta.runtime.generation
        ; "context_ratio", `Float ctx_ratio
        ; "context_tokens", `Int ctx_tokens
        ; "context_max", `Int ctx_work.max_tokens
        ; "message_count", `Int (List.length ctx_work.messages)
        ; "last_model_used", `String meta.runtime.usage.last_model_used
        ; "playground_bundle", `String playground_bundle
        ; "playground_mind", `String playground_mind
        ; "playground_repos", `String playground_repos
        (* Tool-ready short paths: use these directly as path/cwd arguments
           in keeper_shell, keeper_bash, keeper_fs_read.  The tool handler
           resolves them relative to your playground root. *)
        ; "tool_paths", `Assoc
            [ "mind", `String "mind"
            ; "repos", `String "repos"
            ; "bundle", `String "."
            ]
        ; ( "continuity_state"
          , match continuity with
            | None -> `Null
            | Some snapshot -> Keeper_memory_policy.keeper_state_snapshot_to_json snapshot )
        ; "continuity_summary", `String continuity_summary
        ])
;;

(* --- Memory bank search (structured notes from [STATE] blocks) --- *)
