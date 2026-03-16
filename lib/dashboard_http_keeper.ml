(** Dashboard HTTP keeper — types, metrics, history, and keepers_dashboard_json.

    Extracted from server_dashboard_http.ml. Contains the keeper dashboard
    rendering: per-keeper metrics series, 24h buckets, conversation history,
    memory bank, and diagnostic summaries. *)

[@@@warning "-32-33-69"]

open Dashboard_http_helpers
open Server_utils

type keeper_gen_window_stats = {
  mutable turns: int;
  mutable input_tokens: int;
  mutable output_tokens: int;
  mutable total_tokens: int;
  mutable handoffs: int;
  mutable compactions: int;
  mutable memory_compactions: int;
  mutable memory_trimmed: int;
  mutable memory_checks: int;
  mutable memory_passed: int;
  mutable memory_notes: int;
  mutable first_ts: float;
  mutable last_ts: float;
  models: (string, int) Hashtbl.t;
  tools: (string, int) Hashtbl.t;
}

let create_keeper_gen_window_stats () : keeper_gen_window_stats =
  {
    turns = 0;
    input_tokens = 0;
    output_tokens = 0;
    total_tokens = 0;
    handoffs = 0;
    compactions = 0;
    memory_compactions = 0;
    memory_trimmed = 0;
    memory_checks = 0;
    memory_passed = 0;
    memory_notes = 0;
    first_ts = 0.0;
    last_ts = 0.0;
    models = Hashtbl.create 8;
    tools = Hashtbl.create 8;
  }

let count_table_incr (tbl : (string, int) Hashtbl.t) (key : string) : unit =
  let key = String.trim key in
  if key <> "" then
    let cur = Option.value ~default:0 (Hashtbl.find_opt tbl key) in
    Hashtbl.replace tbl key (cur + 1)

let utf8_safe_prefix_bytes (s : string) ~(max_bytes : int) : string =
  if max_bytes <= 0 then ""
  else
    let len = String.length s in
    if len <= max_bytes then s
    else
      let rec loop i last_good =
        if i >= len || i >= max_bytes then last_good
        else
          let dec = String.get_utf_8_uchar s i in
          let dlen = Uchar.utf_decode_length dec in
          if dlen <= 0 then last_good
          else
            let next = i + dlen in
            if next > max_bytes then last_good
            else loop next next
      in
      let cut = loop 0 0 in
      if cut <= 0 then ""
      else String.sub s 0 cut

let truncate_text ~(max_len : int) (s : string) : string =
  let s = String.trim s in
  let n = String.length s in
  if n <= max_len then s
  else utf8_safe_prefix_bytes s ~max_bytes:max_len ^ "..."

let contains_ci (haystack : string) (needle : string) : bool =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  if n = "" then false
  else
    try
      ignore (Str.search_forward (Str.regexp_string n) h 0);
      true
    with Not_found ->
      false

let normalize_similarity_text (s : string) : string =
  s
  |> String.lowercase_ascii
  |> Str.global_replace (Str.regexp "[^0-9a-z가-힣]+") " "
  |> Str.global_replace (Str.regexp " +") " "
  |> String.trim

let token_set_of_text (s : string) : (string, unit) Hashtbl.t =
  let tbl : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let norm = normalize_similarity_text s in
  if norm <> "" then
    norm
    |> String.split_on_char ' '
    |> List.iter (fun tok ->
         let tok = String.trim tok in
         if tok <> "" then Hashtbl.replace tbl tok ());
  tbl

let jaccard_similarity_text (a : string) (b : string) : float =
  let sa = token_set_of_text a in
  let sb = token_set_of_text b in
  let na = Hashtbl.length sa in
  let nb = Hashtbl.length sb in
  if na = 0 || nb = 0 then 0.0
  else
    let inter =
      Hashtbl.fold
        (fun tok () acc -> if Hashtbl.mem sb tok then acc + 1 else acc)
        sa 0
    in
    let union = na + nb - inter in
    if union <= 0 then 0.0 else float_of_int inter /. float_of_int union

let take_last (n : int) (xs : 'a list) : 'a list =
  let n = max 0 n in
  let len = List.length xs in
  let drop = max 0 (len - n) in
  let rec drop_n k ys =
    if k <= 0 then ys
    else
      match ys with
      | [] -> []
      | _ :: tl -> drop_n (k - 1) tl
  in
  drop_n drop xs

let proactive_preview_similarity_stats
    ?(window = 8)
    ?(warn_threshold = 0.90)
    (previews : string list) : int * int * float * float * bool =
  let previews =
    previews
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
    |> take_last window
  in
  let sample_count = List.length previews in
  let rec pairwise acc = function
    | a :: (b :: _ as tl) ->
        let sim = jaccard_similarity_text a b in
        pairwise (sim :: acc) tl
    | _ -> List.rev acc
  in
  let sims = pairwise [] previews in
  let pair_count = List.length sims in
  let avg =
    if pair_count = 0 then 0.0
    else List.fold_left ( +. ) 0.0 sims /. float_of_int pair_count
  in
  let max_sim =
    if pair_count = 0 then 0.0
    else List.fold_left max 0.0 sims
  in
  let warn = pair_count >= 2 && max_sim >= warn_threshold in
  (sample_count, pair_count, avg, max_sim, warn)

type keeper_24h_bucket_stats = {
  mutable sample_points: int;
  mutable context_ratio_sum: float;
  mutable proactive_points: int;
  mutable proactive_fallback_count: int;
}

let create_keeper_24h_bucket_stats () : keeper_24h_bucket_stats =
  {
    sample_points = 0;
    context_ratio_sum = 0.0;
    proactive_points = 0;
    proactive_fallback_count = 0;
  }

let keeper_metrics_24h_json
    ~(metrics_path : string)
    ~(now_ts : float) : Yojson.Safe.t * Yojson.Safe.t =
  let max_lines =
    int_of_env_default
      "MASC_DASHBOARD_24H_MAX_LINES"
      ~default:12000
      ~min_v:200
      ~max_v:50000
  in
  let max_bytes =
    int_of_env_default
      "MASC_DASHBOARD_24H_MAX_BYTES"
      ~default:3000000
      ~min_v:200000
      ~max_v:20000000
  in
  let window_sec = 24.0 *. 3600.0 in
  let start_ts = now_ts -. window_sec in
  let lines =
    Keeper_memory.read_file_tail_lines
      metrics_path
      ~max_bytes
      ~max_lines
  in
  let buckets : (int, keeper_24h_bucket_stats) Hashtbl.t = Hashtbl.create 64 in
  let sample_points = ref 0 in
  let proactive_points = ref 0 in
  let proactive_fallback_count = ref 0 in
  List.iter
    (fun line ->
      try
        let j = Yojson.Safe.from_string line in
        let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
        if ts_unix >= start_ts && ts_unix <= (now_ts +. 60.0) then begin
          incr sample_points;
          let bucket_ts =
            int_of_float (floor (ts_unix /. 3600.0) *. 3600.0)
          in
          let b =
            match Hashtbl.find_opt buckets bucket_ts with
            | Some row -> row
            | None ->
                let row = create_keeper_24h_bucket_stats () in
                Hashtbl.replace buckets bucket_ts row;
                row
          in
          let context_ratio = Safe_ops.json_float ~default:0.0 "context_ratio" j in
          b.sample_points <- b.sample_points + 1;
          b.context_ratio_sum <- b.context_ratio_sum +. context_ratio;
          let channel = Safe_ops.json_string ~default:"turn" "channel" j in
          if channel = "proactive" then begin
            incr proactive_points;
            b.proactive_points <- b.proactive_points + 1;
            let proactive_obj = Yojson.Safe.Util.member "proactive" j in
            let fallback_applied =
              Safe_ops.json_bool ~default:false "fallback_applied" proactive_obj
            in
            if fallback_applied then begin
              incr proactive_fallback_count;
              b.proactive_fallback_count <- b.proactive_fallback_count + 1;
            end
          end
        end
      with exn -> Log.Server.info "keeper log parse: %s" (Printexc.to_string exn))
    lines;
  let rows =
    buckets
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ta, _) (tb, _) -> compare ta tb)
    |> List.map (fun (bucket_ts, b) ->
         let context_ratio_avg =
           if b.sample_points = 0 then 0.0
           else b.context_ratio_sum /. float_of_int b.sample_points
         in
         let proactive_fallback_rate =
           if b.proactive_points = 0 then 0.0
           else
             float_of_int b.proactive_fallback_count
             /. float_of_int b.proactive_points
         in
         `Assoc [
           ("bucket_ts_unix", `Int bucket_ts);
           ("sample_points", `Int b.sample_points);
           ("context_ratio_avg", `Float context_ratio_avg);
           ("proactive_points", `Int b.proactive_points);
           ("proactive_fallback_count", `Int b.proactive_fallback_count);
           ("proactive_fallback_rate", `Float proactive_fallback_rate);
           ("proactive_template_fallback_count", `Int b.proactive_fallback_count);
           ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
           ("proactive_template_fallback_numerator", `Int b.proactive_fallback_count);
           ("proactive_template_fallback_denominator", `Int b.proactive_points);
         ])
  in
  let bucket_count = List.length rows in
  let proactive_fallback_rate =
    if !proactive_points = 0 then 0.0
    else
      float_of_int !proactive_fallback_count
      /. float_of_int !proactive_points
  in
  let summary =
    `Assoc [
      ("window_hours", `Float 24.0);
      ("source_max_lines", `Int max_lines);
      ("source_max_bytes", `Int max_bytes);
      ("sample_points", `Int !sample_points);
      ("bucket_count", `Int bucket_count);
      ("from_ts_unix", `Float start_ts);
      ("to_ts_unix", `Float now_ts);
      ("coverage_hours", `Float (float_of_int bucket_count));
      ("proactive_points", `Int !proactive_points);
      ("proactive_fallback_count", `Int !proactive_fallback_count);
      ("proactive_fallback_rate", `Float proactive_fallback_rate);
      ("proactive_template_fallback_count", `Int !proactive_fallback_count);
      ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
      ("proactive_template_fallback_numerator", `Int !proactive_fallback_count);
      ("proactive_template_fallback_denominator", `Int !proactive_points);
    ]
  in
  (`List rows, summary)

let keeper_history_summary_json
    ~(all_keeper_names : string list)
    ~(keeper_name : string)
    ~(history_path : string)
    ~(filter_fragments : bool)
  : Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int * int * int =
  let history_lines =
    Keeper_memory.read_file_tail_lines
      history_path
      ~max_bytes:120000
      ~max_lines:80
  in
  let mention_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let (conversation_rev, k2k_rev, raw_count, fragment_count, filtered_count) =
    List.fold_left (fun (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count) line ->
      try
        let j = Yojson.Safe.from_string line in
        let role = Safe_ops.json_string ~default:"" "role" j |> String.trim in
        let role_lc = String.lowercase_ascii role in
        let content = Safe_ops.json_string ~default:"" "content" j |> String.trim in
        let ts_unix =
          let ts0 = Safe_ops.json_float ~default:0.0 "ts_unix" j in
          if ts0 > 0.0 then ts0 else Safe_ops.json_float ~default:0.0 "timestamp" j
        in
        if role = "" || content = "" then
          (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count)
        else
          let is_fragment =
            role_lc = "assistant"
            && Keeper_execution.looks_fragmentary_history_text content
          in
          let should_filter = filter_fragments && is_fragment in
          let mentions =
            all_keeper_names
            |> List.filter (fun candidate ->
                 candidate <> keeper_name && contains_ci content candidate)
          in
          let (conv_acc, k2k_acc) =
            if should_filter then
              (conv_acc, k2k_acc)
            else
              let () = List.iter (count_table_incr mention_counts) mentions in
              let preview = truncate_text ~max_len:280 content in
              let is_k2k = role_lc = "user" && mentions <> [] in
              let conversation_item =
                `Assoc [
                  ("role", `String role);
                  ("ts_unix", `Float ts_unix);
                  ("content", `String content);
                  ("preview", `String preview);
                  ("mentions", `List (List.map (fun s -> `String s) mentions));
                  ("k2k", `Bool is_k2k);
                  ("is_fragment", `Bool is_fragment);
                ]
              in
              let k2k_acc =
                match mentions with
                | mentioned_keeper :: _ when is_k2k ->
                    (`Assoc [
                       ("keeper", `String keeper_name);
                       ("mentioned", `String mentioned_keeper);
                       ("role", `String role);
                       ("ts_unix", `Float ts_unix);
                       ("preview", `String preview);
                     ]) :: k2k_acc
                | _ -> k2k_acc
              in
              (conversation_item :: conv_acc, k2k_acc)
          in
          ( conv_acc,
            k2k_acc,
            raw_count + 1,
            fragment_count + (if is_fragment then 1 else 0),
            filtered_count + (if should_filter then 1 else 0) )
      with
      | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Not_found ->
        (conv_acc, k2k_acc, raw_count, fragment_count, filtered_count)
    ) ([], [], 0, 0, 0) history_lines
  in
  let conversation = `List (List.rev conversation_rev) in
  let k2k_recent = `List (List.rev k2k_rev) in
  let k2k_mentions =
    mention_counts
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c else String.compare ka kb)
    |> Keeper_types.take 5
    |> List.map (fun (k, v) ->
         `Assoc [("keeper", `String k); ("count", `Int v)])
    |> fun xs -> `List xs
  in
  (conversation, k2k_recent, k2k_mentions, raw_count, fragment_count, filtered_count)

let top_counts_json
    ?(limit = 5)
    ~(name_key : string)
    (tbl : (string, int) Hashtbl.t) : Yojson.Safe.t list =
  tbl
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.sort (fun (ka, va) (kb, vb) ->
       let c = compare vb va in
       if c <> 0 then c else String.compare ka kb)
  |> Keeper_types.take limit
  |> List.map (fun (k, v) ->
       `Assoc [ (name_key, `String k); ("count", `Int v) ])

let top_count_name_and_count
    (tbl : (string, int) Hashtbl.t) : (string * int) option =
  tbl
  |> Hashtbl.to_seq
  |> List.of_seq
  |> List.sort (fun (ka, va) (kb, vb) ->
       let c = compare vb va in
       if c <> 0 then c else String.compare ka kb)
  |> function
  | (k, v) :: _ -> Some (k, v)
  | [] -> None

let get_agent_identity (name : string) =
  let contains s sub =
    let len = String.length s in
    let sub_len = String.length sub in
    if sub_len > len then false
    else
      let rec loop i =
        if i + sub_len > len then false
        else if String.sub s i sub_len = sub then true
        else loop (i + 1)
      in
      loop 0
  in
  let name = String.lowercase_ascii name in
  if contains name "claude" then ("🧠", "클로드")
  else if contains name "gemini" then ("💎", "제미나이")
  else if contains name "codex" then ("🤖", "코덱스")
  else if contains name "lodge" then ("🏠", "롯지 키퍼")
  else if contains name "gardener" then ("🌿", "정원사")
  else if contains name "review" then ("🔍", "리뷰어")
  else if contains name "test" then ("🧪", "테스터")
  else ("🤖", name)

let keepers_dashboard_json ?(compact = false) (config : Room.config) : Yojson.Safe.t =
  let include_goals = bool_of_env "MASC_DASHBOARD_INCLUDE_GOALS" in
  let history_fragment_filter_enabled =
    bool_default_true_of_env "MASC_KEEPER_HISTORY_FRAGMENT_FILTER"
  in
  let series_points = 120 in
  let normalize_model_name s =
    let s = String.trim s in
    let s =
      match String.index_opt s ':' with
      | None -> s
      | Some i ->
          let prefix = String.sub s 0 i |> String.lowercase_ascii in
          if List.mem prefix ["llama"; "glm"; "claude"; "gemini"; "openrouter"] then
            String.sub s (i + 1) (String.length s - i - 1)
          else
            s
    in
    if String.ends_with ~suffix:":latest" s then
      String.sub s 0 (String.length s - String.length ":latest")
    else
      s
  in
  let names =
    Keeper_types.resident_keeper_names config
  in
  let now_ts = Time_compat.now () in
  let summaries =
    List.filter_map (fun name ->
      match Keeper_types.read_meta config name with
      | Error _ -> None
      | Ok None -> None
      | Ok (Some (m : Keeper_types.keeper_meta)) ->
          let agent = Keeper_exec_status.parse_agent_status config ~agent_name:m.agent_name in

          let created_ts =
            Resilience.Time.parse_iso8601_opt m.created_at
            |> Option.value ~default:0.0
          in
          let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
          let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
          let last_handoff_ago_s =
            if m.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.last_handoff_ts
          in
          let last_compaction_ago_s =
            if m.last_compaction_ts <= 0.0 then 0.0 else now_ts -. m.last_compaction_ts
          in
          let last_proactive_ago_s =
            if m.last_proactive_ts <= 0.0 then 0.0 else now_ts -. m.last_proactive_ts
          in
          let trace_history_count = List.length m.trace_history in
          let active_model = Keeper_exec_status.active_model_of_meta m in
          let next_model_hint = Keeper_exec_status.next_model_hint_of_meta m in
          let primary_model =
            match m.models with
            | model :: _ -> model
            | [] -> ""
          in
          let primary_model_norm = normalize_model_name primary_model in
          let last_compaction_saved_tokens =
            max 0 (m.last_compaction_before_tokens - m.last_compaction_after_tokens)
          in

          let metrics_path = Keeper_types.keeper_metrics_path config m.name in
          let (metrics_24h, metrics_24h_summary) =
            if compact then (`Null, `Null)
            else keeper_metrics_24h_json ~metrics_path ~now_ts
          in
            let metrics_window_max_bytes = 200000 in
            let metrics_lines =
              Keeper_memory.read_file_tail_lines
              metrics_path ~max_bytes:metrics_window_max_bytes ~max_lines:series_points
          in
          let parsed_metrics =
            List.filter_map (fun line ->
              try Some (Yojson.Safe.from_string line) with Yojson.Json_error _ -> None
            ) metrics_lines
          in
	          let last_metrics =
	            match List.rev parsed_metrics with
	            | latest :: _ -> Some latest
	            | [] -> None
	          in
	          let (last_skill_primary, last_skill_secondary, last_skill_reason) =
	            let open Yojson.Safe.Util in
	            let rec find_latest = function
	              | [] -> (None, [], None)
	              | j :: tl ->
	                  (match Safe_ops.json_string_opt "skill_primary" j with
	                   | Some primary when String.trim primary <> "" ->
	                       let secondary =
	                         match j |> member "skill_secondary" with
	                         | `List xs ->
	                             xs
	                             |> List.filter_map (fun v ->
	                                    match v with
	                                    | `String s when String.trim s <> "" -> Some s
	                                    | _ -> None)
	                         | _ -> []
	                       in
	                       let reason = Safe_ops.json_string_opt "skill_reason" j in
	                       (Some primary, secondary, reason)
	                   | _ -> find_latest tl)
	            in
	            find_latest (List.rev parsed_metrics)
	          in

	          let (metrics_series, metrics_window_summary, last_handoff_event, last_compaction_event) =
            let open Yojson.Safe.Util in
            let handoff_count = ref 0 in
            let compaction_events = ref 0 in
            let compaction_saved_tokens = ref 0 in
            let compaction_before_tokens = ref 0 in
            let fallback_count = ref 0 in
            let proactive_fallback_count = ref 0 in
            let tool_call_count = ref 0 in
            let turn_points = ref 0 in
            let heartbeat_points = ref 0 in
            let proactive_points = ref 0 in
            let drift_applied_count = ref 0 in
            let auto_reflect_count = ref 0 in
            let auto_plan_count = ref 0 in
            let auto_compact_count = ref 0 in
            let auto_handoff_count = ref 0 in
            let guardrail_stop_count = ref 0 in
            let repetition_risk_sum = ref 0.0 in
            let repetition_risk_points = ref 0 in
            let goal_alignment_sum = ref 0.0 in
            let goal_alignment_points = ref 0 in
            let response_alignment_sum = ref 0.0 in
            let response_alignment_points = ref 0 in
            let goal_drift_sum = ref 0.0 in
            let goal_drift_points = ref 0 in
            let memory_checks = ref 0 in
            let memory_passed = ref 0 in
            let memory_corrections = ref 0 in
            let memory_correction_success = ref 0 in
            let memory_score_sum = ref 0.0 in
            let memory_weather_checks = ref 0 in
            let memory_weather_passed = ref 0 in
            let memory_threshold = ref 0.18 in
            let memory_notes_added = ref 0 in
            let memory_compaction_events = ref 0 in
            let memory_compaction_before_notes = ref 0 in
            let memory_compaction_dropped_notes = ref 0 in
            let memory_compaction_invalid_dropped = ref 0 in
            let work_kind_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
            let model_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
            let tool_counts_window : (string, int) Hashtbl.t = Hashtbl.create 16 in
            let memory_kind_counts_window : (string, int) Hashtbl.t =
              Hashtbl.create 16
            in
            let drift_reason_counts : (string, int) Hashtbl.t =
              Hashtbl.create 16
            in
            let compaction_trigger_counts : (string, int) Hashtbl.t =
              Hashtbl.create 16
            in
            let generation_stats : (int, keeper_gen_window_stats) Hashtbl.t =
              Hashtbl.create 8
            in
            let proactive_previews_rev = ref [] in
            let last_handoff = ref None in
            let last_compaction = ref None in
            let items = List.filter_map (fun j ->
              try
                let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
                let ratio = Safe_ops.json_float ~default:0.0 "context_ratio" j in
                let tokens = Safe_ops.json_int ~default:0 "context_tokens" j in
                let context_max = Safe_ops.json_int ~default:0 "context_max" j in
                let channel = Safe_ops.json_string ~default:"turn" "channel" j in
                let is_turn = channel = "turn" in
                let is_heartbeat = channel = "heartbeat" in
                let is_proactive = channel = "proactive" in
                let is_interaction = is_turn || is_proactive in
                let compacted = Safe_ops.json_bool ~default:false "compacted" j in
                let gen = Safe_ops.json_int ~default:m.generation "generation" j in
                let trace_id = Safe_ops.json_string ~default:"" "trace_id" j in
                let before_tokens = Safe_ops.json_int ~default:0 "compaction_before_tokens" j in
                let after_tokens = Safe_ops.json_int ~default:0 "compaction_after_tokens" j in
                let saved_tokens = max 0 (before_tokens - after_tokens) in
                let compaction_trigger_now =
                  Safe_ops.json_string_opt "compaction_trigger" j
                  |> Option.map String.trim
                  |> function
                     | Some s when s <> "" -> Some s
                     | _ -> None
                in
                let handoff_obj = j |> member "handoff" in
                let handoff_performed = Safe_ops.json_bool ~default:false "performed" handoff_obj in
                let handoff_to_model = Safe_ops.json_string_opt "to_model" handoff_obj in
                let handoff_prev_trace_id =
                  Safe_ops.json_string_opt "prev_trace_id" handoff_obj
                in
                let handoff_new_trace_id =
                  Safe_ops.json_string_opt "new_trace_id" handoff_obj
                in
                let handoff_new_generation =
                  Safe_ops.json_int_opt "new_generation" handoff_obj
                in
                let usage_obj = j |> member "usage" in
                let input_tokens = Safe_ops.json_int ~default:0 "input_tokens" usage_obj in
                let output_tokens = Safe_ops.json_int ~default:0 "output_tokens" usage_obj in
                let total_tokens = Safe_ops.json_int ~default:0 "total_tokens" usage_obj in
                let latency_ms = Safe_ops.json_int ~default:0 "latency_ms" j in
                let cost_usd = Safe_ops.json_float ~default:0.0 "cost_usd" j in
                let model_used = Safe_ops.json_string ~default:"" "model_used" j in
                let message_count = Safe_ops.json_int ~default:0 "message_count" j in
                let model_used_norm = normalize_model_name model_used in
                let model_bucket =
                  if model_used_norm <> "" then model_used_norm else model_used
                in
                let work_kind_raw = Safe_ops.json_string ~default:"" "work_kind" j in
                let memory_check = j |> member "memory_check" in
                let memory_performed =
                  Safe_ops.json_bool ~default:false "performed" memory_check
                in
                let memory_query_kind =
                  Safe_ops.json_string ~default:"none" "query_kind" memory_check
                in
                let memory_passed_now =
                  Safe_ops.json_bool ~default:false "passed" memory_check
                in
                let memory_final_score =
                  Safe_ops.json_float ~default:0.0 "final_score" memory_check
                in
                let memory_threshold_now =
                  Safe_ops.json_float ~default:0.18 "threshold" memory_check
                in
                let memory_correction_applied_now =
                  Safe_ops.json_bool ~default:false "correction_applied" memory_check
                in
                let memory_correction_success_now =
                  Safe_ops.json_bool ~default:false "correction_success" memory_check
                in
                let memory_expected_topic =
                  Safe_ops.json_string_opt "expected_topic" memory_check
                in
                let proactive_obj = j |> member "proactive" in
                let proactive_fallback_applied_now =
                  Safe_ops.json_bool ~default:false "fallback_applied" proactive_obj
                in
                let proactive_preview_now =
                  Safe_ops.json_string_opt "preview" proactive_obj
                  |> Option.map String.trim
                  |> function
                     | Some s when s <> "" -> Some s
                     | _ -> None
                in
                let drift_obj = j |> member "drift" in
                let drift_applied_now =
                  Safe_ops.json_bool ~default:false "applied" drift_obj
                in
                let drift_reason_now =
                  Safe_ops.json_string_opt "reason" drift_obj
                  |> Option.map String.trim
                  |> function
                     | Some s when s <> "" -> Some s
                     | _ -> None
                in
                let auto_rules_obj = j |> member "auto_rules" in
                let auto_reflect_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "reflect" auto_rules_obj)
                    "auto_reflect"
                    j
                in
                let auto_plan_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "plan" auto_rules_obj)
                    "auto_plan"
                    j
                in
                let auto_compact_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "compact" auto_rules_obj)
                    "auto_compact"
                    j
                in
                let auto_handoff_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "handoff" auto_rules_obj)
                    "auto_handoff"
                    j
                in
                let guardrail_stop_now =
                  Safe_ops.json_bool
                    ~default:(Safe_ops.json_bool ~default:false "guardrail_stop" auto_rules_obj)
                    "guardrail_stop"
                    j
                in
                let repetition_risk_opt = Safe_ops.json_float_opt "repetition_risk" j in
                let goal_alignment_opt = Safe_ops.json_float_opt "goal_alignment" j in
                let response_alignment_opt = Safe_ops.json_float_opt "response_alignment" j in
                let goal_drift_opt = Safe_ops.json_float_opt "goal_drift" j in
                let memory_notes_added_now =
                  Safe_ops.json_int ~default:0 "memory_notes_added" j
                in
                let memory_top_kind_now =
                  Safe_ops.json_string_opt "memory_top_kind" j
                in
                let memory_note_kinds =
                  match j |> member "memory_note_kinds" with
                  | `List xs ->
                      List.filter_map
                        (function
                          | `String s when String.trim s <> "" -> Some (String.trim s)
                          | _ -> None)
                        xs
                  | _ -> []
                in
                let memory_compaction_performed_now =
                  Safe_ops.json_bool ~default:false "memory_compaction_performed" j
                in
                let memory_compaction_before_notes_now =
                  Safe_ops.json_int ~default:0 "memory_compaction_before_notes" j
                in
                let memory_compaction_dropped_notes_now =
                  Safe_ops.json_int ~default:0 "memory_compaction_dropped_notes" j
                in
                let memory_compaction_invalid_dropped_now =
                  Safe_ops.json_int ~default:0 "memory_compaction_invalid_dropped" j
                in
                let tools_used =
                  match j |> member "tools_used" with
                  | `List xs ->
                      List.filter_map (function
                        | `String s when String.trim s <> "" -> Some s
                        | _ -> None) xs
                  | _ -> []
                in
                let tool_call_count_now =
                  Safe_ops.json_int ~default:(List.length tools_used) "tool_call_count" j
                in
                let work_kind =
                  if work_kind_raw <> "" then work_kind_raw
                  else if memory_performed then
                    if memory_query_kind <> "" && memory_query_kind <> "none" then
                      memory_query_kind
                    else
                      "memory_recall"
                  else
                    match memory_expected_topic with
                    | Some "weather" -> "weather_answer"
                    | Some "first_question" -> "first_question_answer"
                    | Some topic when topic <> "" -> topic
                    | _ -> "general_chat"
                in
                let memory_is_weather =
                  match memory_expected_topic with Some "weather" -> true | _ -> false
                in
                if handoff_performed then begin
                  if is_interaction then incr handoff_count;
                  last_handoff := Some (`Assoc [
                    ("ts_unix", `Float ts_unix);
                    ("trace_id", `String trace_id);
                    ("generation", `Int gen);
                    ("to_model",
                      match handoff_to_model with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("prev_trace_id",
                      match handoff_prev_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("new_trace_id",
                      match handoff_new_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("new_generation",
                      match handoff_new_generation with
                      | Some g -> `Int g
                      | None -> `Null);
                  ]);
                end;
                if compacted then begin
                  if is_interaction then begin
                    incr compaction_events;
                    compaction_saved_tokens := !compaction_saved_tokens + saved_tokens;
                    compaction_before_tokens := !compaction_before_tokens + before_tokens;
                    (match compaction_trigger_now with
                     | Some reason -> count_table_incr compaction_trigger_counts reason
                     | None -> ());
                  end;
                  last_compaction := Some (`Assoc [
                    ("ts_unix", `Float ts_unix);
                    ("trace_id", `String trace_id);
                    ("generation", `Int gen);
                    ("before_tokens", `Int before_tokens);
                    ("after_tokens", `Int after_tokens);
                    ("saved_tokens", `Int saved_tokens);
                    ("trigger",
                      match compaction_trigger_now with
                      | Some reason -> `String reason
                      | None -> `Null);
                  ]);
                end;
                if is_interaction
                   && primary_model_norm <> ""
                   && model_used_norm <> ""
                   && model_used_norm <> primary_model_norm
                then
                  incr fallback_count;
                if is_turn then incr turn_points;
                if is_proactive then incr proactive_points;
                if is_proactive && proactive_fallback_applied_now then
                  incr proactive_fallback_count;
                if is_proactive then
                  (match proactive_preview_now with
                   | Some preview ->
                       proactive_previews_rev := preview :: !proactive_previews_rev
                   | None -> ());
                if is_interaction then begin
                  if auto_reflect_now then incr auto_reflect_count;
                  if auto_plan_now then incr auto_plan_count;
                  if auto_compact_now then incr auto_compact_count;
                  if auto_handoff_now then incr auto_handoff_count;
                  if guardrail_stop_now then incr guardrail_stop_count;
                  (match repetition_risk_opt with
                   | Some v ->
                       repetition_risk_sum := !repetition_risk_sum +. v;
                       incr repetition_risk_points
                   | None -> ());
                  (match goal_alignment_opt with
                   | Some v ->
                       goal_alignment_sum := !goal_alignment_sum +. v;
                       incr goal_alignment_points
                   | None -> ());
                  (match response_alignment_opt with
                   | Some v ->
                       response_alignment_sum := !response_alignment_sum +. v;
                       incr response_alignment_points
                   | None -> ());
                  (match goal_drift_opt with
                   | Some v ->
                       goal_drift_sum := !goal_drift_sum +. v;
                       incr goal_drift_points
                   | None -> ());
                  if drift_applied_now then begin
                    incr drift_applied_count;
                    (match drift_reason_now with
                     | Some reason -> count_table_incr drift_reason_counts reason
                     | None -> ());
                  end;
                  tool_call_count := !tool_call_count + tool_call_count_now;
                  count_table_incr work_kind_counts work_kind;
                  count_table_incr model_counts_window model_bucket;
                  List.iter (count_table_incr tool_counts_window) tools_used;
                  memory_notes_added := !memory_notes_added + memory_notes_added_now;
                  if memory_compaction_performed_now then begin
                    incr memory_compaction_events;
                    memory_compaction_before_notes :=
                      !memory_compaction_before_notes + memory_compaction_before_notes_now;
                    memory_compaction_dropped_notes :=
                      !memory_compaction_dropped_notes + memory_compaction_dropped_notes_now;
                    memory_compaction_invalid_dropped :=
                      !memory_compaction_invalid_dropped
                      + memory_compaction_invalid_dropped_now;
                  end;
                  List.iter (count_table_incr memory_kind_counts_window) memory_note_kinds;
                  if memory_note_kinds = [] then
                    (match memory_top_kind_now with
                     | Some kind when String.trim kind <> "" ->
                         count_table_incr memory_kind_counts_window kind
                     | _ -> ());
                  if memory_performed then begin
                    incr memory_checks;
                    memory_score_sum := !memory_score_sum +. memory_final_score;
                    memory_threshold := memory_threshold_now;
                    if memory_passed_now then incr memory_passed;
                    if memory_correction_applied_now then incr memory_corrections;
                    if memory_correction_success_now then incr memory_correction_success;
                    if memory_is_weather then begin
                      incr memory_weather_checks;
                      if memory_passed_now then incr memory_weather_passed;
                    end;
                  end;
                  let gen_stats =
                    match Hashtbl.find_opt generation_stats gen with
                    | Some gs -> gs
                    | None ->
                        let gs = create_keeper_gen_window_stats () in
                        Hashtbl.add generation_stats gen gs;
                        gs
                  in
                  gen_stats.turns <- gen_stats.turns + 1;
                  gen_stats.input_tokens <- gen_stats.input_tokens + input_tokens;
                  gen_stats.output_tokens <- gen_stats.output_tokens + output_tokens;
                  gen_stats.total_tokens <- gen_stats.total_tokens + total_tokens;
                  if handoff_performed then gen_stats.handoffs <- gen_stats.handoffs + 1;
                  if compacted then gen_stats.compactions <- gen_stats.compactions + 1;
                  if memory_compaction_performed_now then
                    gen_stats.memory_compactions <- gen_stats.memory_compactions + 1;
                  if memory_compaction_performed_now then
                    gen_stats.memory_trimmed <-
                      gen_stats.memory_trimmed + memory_compaction_dropped_notes_now;
                  if memory_performed then begin
                    gen_stats.memory_checks <- gen_stats.memory_checks + 1;
                    if memory_passed_now then
                      gen_stats.memory_passed <- gen_stats.memory_passed + 1;
                  end;
                  gen_stats.memory_notes <- gen_stats.memory_notes + memory_notes_added_now;
                  if gen_stats.first_ts <= 0.0 || ts_unix < gen_stats.first_ts then
                    gen_stats.first_ts <- ts_unix;
                  if ts_unix > gen_stats.last_ts then
                    gen_stats.last_ts <- ts_unix;
                  count_table_incr gen_stats.models model_bucket;
                  List.iter (count_table_incr gen_stats.tools) tools_used;
                end;
                if is_heartbeat then incr heartbeat_points;
                if compact then None
                else
                  Some (`Assoc [
                    ("ts_unix", `Float ts_unix);
                    ("trace_id", `String trace_id);
                    ("channel", `String channel);
                    ("context_ratio", `Float ratio);
                    ("context_tokens", `Int tokens);
                    ("context_max", `Int context_max);
                    ("message_count", `Int message_count);
                    ("compacted", `Bool compacted);
                    ("handoff", `Bool handoff_performed);
                    ("handoff_to_model",
                      match handoff_to_model with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("handoff_prev_trace_id",
                      match handoff_prev_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("handoff_new_trace_id",
                      match handoff_new_trace_id with
                      | Some s when s <> "" -> `String s
                      | _ -> `Null);
                    ("handoff_new_generation",
                      match handoff_new_generation with
                      | Some g -> `Int g
                      | None -> `Null);
                    ("generation", `Int gen);
                    ("input_tokens", `Int input_tokens);
                    ("output_tokens", `Int output_tokens);
                    ("total_tokens", `Int total_tokens);
                    ("latency_ms", `Int latency_ms);
                    ("cost_usd", `Float cost_usd);
                    ("model_used", `String model_used);
                    ("compaction_before_tokens", `Int before_tokens);
                    ("compaction_after_tokens", `Int after_tokens);
                    ("compaction_saved_tokens", `Int saved_tokens);
                    ("compaction_trigger",
                      match compaction_trigger_now with
                      | Some reason -> `String reason
                      | None -> `Null);
                    ("work_kind", `String work_kind);
                    ("tool_call_count", `Int tool_call_count_now);
                    ("tools_used", `List (List.map (fun s -> `String s) tools_used));
                    ("proactive_fallback_applied", `Bool proactive_fallback_applied_now);
                    ("proactive_preview",
                      match proactive_preview_now with
                      | Some s -> `String s
                      | None -> `Null);
                    ("drift_applied", `Bool drift_applied_now);
                    ("drift_reason",
                      match drift_reason_now with
                      | Some s -> `String s
                      | None -> `Null);
                    ("auto_reflect", `Bool auto_reflect_now);
                    ("auto_plan", `Bool auto_plan_now);
                    ("auto_compact", `Bool auto_compact_now);
                    ("auto_handoff", `Bool auto_handoff_now);
                    ("guardrail_stop", `Bool guardrail_stop_now);
                    ("repetition_risk",
                      match repetition_risk_opt with Some v -> `Float v | None -> `Null);
                    ("goal_alignment",
                      match goal_alignment_opt with Some v -> `Float v | None -> `Null);
                    ("response_alignment",
                      match response_alignment_opt with Some v -> `Float v | None -> `Null);
                    ("goal_drift",
                      match goal_drift_opt with Some v -> `Float v | None -> `Null);
                    ("reflection", j |> member "reflection");
                    ("memory_performed", `Bool memory_performed);
                    ("memory_query_kind", `String memory_query_kind);
                    ("memory_passed", `Bool memory_passed_now);
                    ("memory_final_score", `Float memory_final_score);
                    ("memory_threshold", `Float memory_threshold_now);
                    ("memory_correction_applied", `Bool memory_correction_applied_now);
                    ("memory_correction_success", `Bool memory_correction_success_now);
                    ("memory_notes_added", `Int memory_notes_added_now);
                    ("memory_top_kind",
                      match memory_top_kind_now with
                      | Some s when String.trim s <> "" -> `String s
                      | _ -> `Null);
                    ("memory_note_kinds",
                      `List (List.map (fun s -> `String s) memory_note_kinds));
                    ("memory_compaction_performed", `Bool memory_compaction_performed_now);
                    ("memory_compaction_before_notes", `Int memory_compaction_before_notes_now);
                    ("memory_compaction_dropped_notes", `Int memory_compaction_dropped_notes_now);
                    ("memory_compaction_invalid_dropped", `Int memory_compaction_invalid_dropped_now);
                    ("memory_expected_topic",
                      match memory_expected_topic with
                      | Some s -> `String s
                      | None -> `Null);
                  ])
              with
              | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
            ) parsed_metrics in
            let sample_points = List.length items in
            let turn_points_int = !turn_points in
            let proactive_points_int = !proactive_points in
            let interaction_points_int = turn_points_int + proactive_points_int in
            let fallback_rate =
              if interaction_points_int = 0 then 0.0 else
                float_of_int !fallback_count /. float_of_int interaction_points_int
            in
            let proactive_fallback_rate =
              if proactive_points_int = 0 then 0.0 else
                float_of_int !proactive_fallback_count
                /. float_of_int proactive_points_int
            in
            let intervention_share =
              if interaction_points_int = 0 then 0.0
              else float_of_int proactive_points_int /. float_of_int interaction_points_int
            in
            let intervention_per_turn =
              if turn_points_int = 0 then 0.0
              else float_of_int proactive_points_int /. float_of_int turn_points_int
            in
            let drift_applied_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !drift_applied_count /. float_of_int interaction_points_int
            in
            let auto_reflect_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_reflect_count /. float_of_int interaction_points_int
            in
            let auto_plan_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_plan_count /. float_of_int interaction_points_int
            in
            let auto_compact_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_compact_count /. float_of_int interaction_points_int
            in
            let auto_handoff_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !auto_handoff_count /. float_of_int interaction_points_int
            in
            let guardrail_stop_rate =
              if interaction_points_int = 0 then 0.0
              else float_of_int !guardrail_stop_count /. float_of_int interaction_points_int
            in
            let proactive_previews = List.rev !proactive_previews_rev in
            let proactive_similarity_warn_threshold =
              float_of_env_default
                "MASC_DASHBOARD_PROACTIVE_SIMILARITY_WARN"
                ~default:0.90
                ~min_v:0.0
                ~max_v:1.0
            in
            let proactive_similarity_window = 8 in
            let ( proactive_preview_sample_count,
                  proactive_preview_pair_count,
                  proactive_preview_similarity_avg,
                  proactive_preview_similarity_max,
                  proactive_preview_similarity_warn ) =
              proactive_preview_similarity_stats
                ~window:proactive_similarity_window
                ~warn_threshold:proactive_similarity_warn_threshold
                proactive_previews
            in
            let compaction_saved_ratio =
              if !compaction_before_tokens = 0 then 0.0 else
                float_of_int !compaction_saved_tokens /. float_of_int !compaction_before_tokens
            in
            let avg_compaction_saved_tokens =
              if !compaction_events = 0 then 0.0 else
                float_of_int !compaction_saved_tokens /. float_of_int !compaction_events
            in
            let memory_compaction_drop_ratio =
              if !memory_compaction_before_notes = 0 then 0.0
              else
                float_of_int !memory_compaction_dropped_notes
                /. float_of_int !memory_compaction_before_notes
            in
            let memory_compaction_drop_avg =
              if !memory_compaction_events = 0 then 0.0
              else
                float_of_int !memory_compaction_dropped_notes
                /. float_of_int !memory_compaction_events
            in
            let memory_failed = !memory_checks - !memory_passed in
            let memory_pass_rate =
              if !memory_checks = 0 then 0.0
              else float_of_int !memory_passed /. float_of_int !memory_checks
            in
            let memory_avg_score =
              if !memory_checks = 0 then 0.0
              else !memory_score_sum /. float_of_int !memory_checks
            in
            let memory_weather_pass_rate =
              if !memory_weather_checks = 0 then 0.0
              else
                float_of_int !memory_weather_passed
                /. float_of_int !memory_weather_checks
            in
            let repetition_risk_avg =
              if !repetition_risk_points = 0 then 0.0
              else !repetition_risk_sum /. float_of_int !repetition_risk_points
            in
            let goal_alignment_avg =
              if !goal_alignment_points = 0 then 0.0
              else !goal_alignment_sum /. float_of_int !goal_alignment_points
            in
            let response_alignment_avg =
              if !response_alignment_points = 0 then 0.0
              else !response_alignment_sum /. float_of_int !response_alignment_points
            in
            let goal_drift_avg =
              if !goal_drift_points = 0 then 0.0
              else !goal_drift_sum /. float_of_int !goal_drift_points
            in
            let top_work_kinds =
              top_counts_json ~limit:5 ~name_key:"kind" work_kind_counts
            in
            let top_models =
              top_counts_json ~limit:5 ~name_key:"model" model_counts_window
            in
            let top_tools =
              top_counts_json ~limit:5 ~name_key:"tool" tool_counts_window
            in
            let top_memory_kinds =
              top_counts_json ~limit:5 ~name_key:"kind" memory_kind_counts_window
            in
            let top_drift_reasons =
              top_counts_json ~limit:5 ~name_key:"reason" drift_reason_counts
            in
            let top_compaction_triggers =
              top_counts_json ~limit:5 ~name_key:"reason" compaction_trigger_counts
            in
            let generation_equipment =
              generation_stats
              |> Hashtbl.to_seq
              |> List.of_seq
              |> List.sort (fun (ga, _) (gb, _) -> compare ga gb)
              |> List.map (fun (generation, gs) ->
                   let memory_pass_rate_gen =
                     if gs.memory_checks = 0 then 0.0
                     else
                       float_of_int gs.memory_passed
                       /. float_of_int gs.memory_checks
                   in
                   let top_model =
                     match top_count_name_and_count gs.models with
                     | Some (name, count) ->
                         `Assoc [ ("name", `String name); ("count", `Int count) ]
                     | None -> `Null
                   in
                   let top_tool =
                     match top_count_name_and_count gs.tools with
                     | Some (name, count) ->
                         `Assoc [ ("name", `String name); ("count", `Int count) ]
                     | None -> `Null
                   in
                   `Assoc [
                     ("generation", `Int generation);
                     ("turns", `Int gs.turns);
                     ("input_tokens", `Int gs.input_tokens);
                     ("output_tokens", `Int gs.output_tokens);
                     ("total_tokens", `Int gs.total_tokens);
                     ("handoffs", `Int gs.handoffs);
                     ("compactions", `Int gs.compactions);
                     ("memory_compactions", `Int gs.memory_compactions);
                     ("memory_trimmed", `Int gs.memory_trimmed);
                     ("memory_checks", `Int gs.memory_checks);
                     ("memory_pass_rate", `Float memory_pass_rate_gen);
                     ("memory_notes", `Int gs.memory_notes);
                     ("first_ts_unix", `Float gs.first_ts);
                     ("last_ts_unix", `Float gs.last_ts);
                     ("top_model", top_model);
                     ("top_tool", top_tool);
                   ])
            in
            let summary = `Assoc [
              ("sample_points", `Int sample_points);
              ("window_sample_points", `Int sample_points);
              ("turn_points", `Int turn_points_int);
              ("window_turn_points", `Int turn_points_int);
              ("heartbeat_points", `Int !heartbeat_points);
              ("window_heartbeat_points", `Int !heartbeat_points);
              ("proactive_points", `Int proactive_points_int);
              ("window_proactive_points", `Int proactive_points_int);
              ("window_interactions", `Int interaction_points_int);
              ("window_turns", `Int turn_points_int);
              ("window_series_max_lines", `Int series_points);
              ("window_series_max_bytes", `Int metrics_window_max_bytes);
              ("primary_model", `String primary_model);
              ("handoff_count", `Int !handoff_count);
              ("compaction_events", `Int !compaction_events);
              ("compaction_before_tokens", `Int !compaction_before_tokens);
              ("compaction_saved_tokens", `Int !compaction_saved_tokens);
              ("compaction_saved_ratio", `Float compaction_saved_ratio);
              ("avg_compaction_saved_tokens", `Float avg_compaction_saved_tokens);
              ("fallback_count", `Int !fallback_count);
              ("fallback_rate", `Float fallback_rate);
              ("model_fallback_count", `Int !fallback_count);
              ("model_fallback_rate", `Float fallback_rate);
              ("model_fallback_numerator", `Int !fallback_count);
              ("model_fallback_denominator", `Int interaction_points_int);
              ("proactive_fallback_count", `Int !proactive_fallback_count);
              ("proactive_fallback_rate", `Float proactive_fallback_rate);
              ("proactive_template_fallback_count", `Int !proactive_fallback_count);
              ("proactive_template_fallback_rate", `Float proactive_fallback_rate);
              ("proactive_template_fallback_numerator", `Int !proactive_fallback_count);
              ("proactive_template_fallback_denominator", `Int proactive_points_int);
              ("intervention_share", `Float intervention_share);
              ("intervention_per_turn", `Float intervention_per_turn);
              ("auto_reflect_count", `Int !auto_reflect_count);
              ("auto_plan_count", `Int !auto_plan_count);
              ("auto_compact_count", `Int !auto_compact_count);
              ("auto_handoff_count", `Int !auto_handoff_count);
              ("guardrail_stop_count", `Int !guardrail_stop_count);
              ("auto_reflect_rate", `Float auto_reflect_rate);
              ("auto_plan_rate", `Float auto_plan_rate);
              ("auto_compact_rate", `Float auto_compact_rate);
              ("auto_handoff_rate", `Float auto_handoff_rate);
              ("guardrail_stop_rate", `Float guardrail_stop_rate);
              ("drift_applied_count", `Int !drift_applied_count);
              ("drift_applied_rate", `Float drift_applied_rate);
              ("repetition_risk_avg", `Float repetition_risk_avg);
              ("goal_alignment_avg", `Float goal_alignment_avg);
              ("response_alignment_avg", `Float response_alignment_avg);
              ("goal_drift_avg", `Float goal_drift_avg);
              ("proactive_preview_sample_count", `Int proactive_preview_sample_count);
              ("proactive_preview_pair_count", `Int proactive_preview_pair_count);
              ("proactive_preview_similarity_avg", `Float proactive_preview_similarity_avg);
              ("proactive_preview_similarity_max", `Float proactive_preview_similarity_max);
              ("proactive_preview_similarity_warn", `Bool proactive_preview_similarity_warn);
              ("proactive_preview_similarity_method", `String "jaccard_adjacent_preview");
              ("proactive_preview_similarity_window", `Int proactive_similarity_window);
              ("tool_call_count", `Int !tool_call_count);
              ("memory_checks", `Int !memory_checks);
              ("memory_passed", `Int !memory_passed);
              ("memory_failed", `Int memory_failed);
              ("memory_pass_rate", `Float memory_pass_rate);
              ("memory_avg_score", `Float memory_avg_score);
              ("memory_threshold", `Float !memory_threshold);
              ("memory_corrections", `Int !memory_corrections);
              ("memory_correction_success", `Int !memory_correction_success);
              ("memory_notes_added", `Int !memory_notes_added);
              ("memory_compaction_events", `Int !memory_compaction_events);
              ("memory_compaction_before_notes", `Int !memory_compaction_before_notes);
              ("memory_compaction_dropped_notes", `Int !memory_compaction_dropped_notes);
              ("memory_compaction_invalid_dropped", `Int !memory_compaction_invalid_dropped);
              ("memory_compaction_drop_ratio", `Float memory_compaction_drop_ratio);
              ("memory_compaction_drop_avg", `Float memory_compaction_drop_avg);
              ("memory_weather_checks", `Int !memory_weather_checks);
              ("memory_weather_passed", `Int !memory_weather_passed);
              ("memory_weather_pass_rate", `Float memory_weather_pass_rate);
              ("top_work_kinds", `List top_work_kinds);
              ("top_models", `List top_models);
              ("top_tools", `List top_tools);
              ("top_memory_kinds", `List top_memory_kinds);
              ("top_drift_reasons", `List top_drift_reasons);
              ("top_compaction_triggers", `List top_compaction_triggers);
              ("generation_equipment", `List generation_equipment);
            ] in
            (`List items, summary, !last_handoff, !last_compaction)
          in

          let models_resolved =
            match Keeper_types.model_specs_of_strings m.models with
            | Error _ -> `List []
            | Ok specs ->
                `List (List.map (fun (s : Llm_client.model_spec) ->
                  `Assoc [
                    ("provider", `String (Llm_client.string_of_provider s.provider));
                    ("model_id", `String s.model_id);
                    ("max_context", `Int s.max_context);
                  ]
                ) specs)
          in

          let memory_bank_summary =
            Keeper_memory.read_keeper_memory_summary
              config
              ~name:m.name
              ~max_bytes:120000
              ~max_lines:200
              ~recent_limit:4
          in
          let memory_bank_json =
            Keeper_memory.memory_summary_to_json memory_bank_summary
          in
          let memory_recent_note =
            match memory_bank_summary.Keeper_memory.recent_notes with
            | row :: _ -> Some row.Keeper_memory.text
            | [] -> None
          in
          let history_path =
            Filename.concat
              (Filename.concat (Keeper_types.session_base_dir config) m.trace_id)
              "history.jsonl"
          in
          let ( conversation_tail,
                k2k_recent,
                k2k_mentions,
                conversation_raw_count,
                conversation_fragment_count,
                conversation_fragment_filtered_count ) =
            keeper_history_summary_json
              ~all_keeper_names:names
              ~keeper_name:m.name
              ~history_path
              ~filter_fragments:history_fragment_filter_enabled
          in
          let conversation_tail_count =
            match conversation_tail with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let conversation_items =
            match conversation_tail with
            | `List xs -> xs
            | _ -> []
          in
          let recent_preview_for_role role_name =
            let role_name = String.lowercase_ascii role_name in
            conversation_items
            |> List.fold_left
                 (fun acc item ->
                   let role =
                     Safe_ops.json_string ~default:"" "role" item
                     |> String.lowercase_ascii
                     |> String.trim
                   in
                   if String.equal role role_name then
                     let preview =
                       Safe_ops.json_string ~default:"" "preview" item |> String.trim
                     in
                     if preview = "" then acc else Some preview
                   else
                     acc)
                 None
          in
          let k2k_count =
            match k2k_recent with
            | `List xs -> List.length xs
            | _ -> 0
          in
          let keepalive_running =
            Keeper_keepalive.keeper_keepalive_running m.name
          in

          let context =
            match last_metrics with
            | Some metrics ->
                `Assoc [
                  ("source", `String "metrics");
                  ("context_ratio", `Float (Safe_ops.json_float "context_ratio" metrics));
                  ("context_tokens", `Int (Safe_ops.json_int "context_tokens" metrics));
                  ("context_max", `Int (Safe_ops.json_int "context_max" metrics));
                  ("message_count", `Int (Safe_ops.json_int "message_count" metrics));
                ]
            | None ->
                (match Keeper_types.model_specs_of_strings m.models with
                 | Error _ -> `Assoc [("has_checkpoint", `Bool false)]
                 | Ok specs ->
                     let primary =
                       match specs with m0 :: _ -> m0 | [] -> Llm_client.llama_default
                     in
                     let base_dir = Keeper_types.session_base_dir config in
                     let (_session, ctx_opt) =
                       Keeper_execution.load_context_from_checkpoint
                         ~trace_id:m.trace_id
                         ~primary_model_max_tokens:primary.max_context
                         ~base_dir
                     in
                     match ctx_opt with
                     | None -> `Assoc [("has_checkpoint", `Bool false)]
                     | Some c ->
                         `Assoc [
                           ("has_checkpoint", `Bool true);
                           ("source", `String "checkpoint");
                           ("context_ratio", `Float (Context_manager.context_ratio c));
                           ("context_tokens", `Int c.token_count);
                           ("context_max", `Int c.max_tokens);
                           ("message_count", `Int (List.length c.messages));
                         ])
          in
	          let context_source =
	            match context with
	            | `Assoc fields ->
	                (match List.assoc_opt "source" fields with
	                 | Some s -> s
	                 | None -> `Null)
	            | _ -> `Null
	          in
	          let summary =
	            let compact_ratio_gate = m.compaction_ratio_gate in
	            let compact_message_gate = m.compaction_message_gate in
	            let compact_token_gate = m.compaction_token_gate in
              let recent_tool_names =
                match metrics_window_summary with
                | `Assoc fields -> (
                    match List.assoc_opt "top_tools" fields with
                    | Some (`List items) ->
                        items
                        |> List.filter_map (fun item ->
                               let tool =
                                 Safe_ops.json_string ~default:"" "tool" item |> String.trim
                               in
                               if tool = "" then None else Some tool)
                    | _ -> [])
                | _ -> []
              in
              let diagnostic =
                Keeper_exec_status.keeper_diagnostic_json
                  ~meta:m
                  ~agent_status:agent
                  ~keepalive_running
                  ~history_items:conversation_items
                  ~now_ts
                |> Keeper_exec_status.augment_keeper_diagnostic_json
                     ~desired:true
                     ~meta:m
                     ~keepalive_running
                     ~keepalive_started_at:
                       (Keeper_keepalive.keeper_keepalive_started_at m.name)
                     ~now_ts
              in
              let detail_fields =
                if compact then []
                else [
                  ("last_metrics", match last_metrics with None -> `Null | Some j -> j);
                  ("metrics_series", metrics_series);
                  ("metrics_24h", metrics_24h);
                  ("memory_bank", memory_bank_json);
                  ("conversation_tail", conversation_tail);
                  ("k2k_recent", k2k_recent);
                ]
              in
	            `Assoc ([
              ("name", `String m.name);
              ("runtime_class", `String "resident_keeper");
              ("desired", `Bool true);
              ("resident_registered", `Bool true);
              ("agent_name", `String m.agent_name);
              ("emoji", `String (let (e, _) = get_agent_identity m.name in e));
              ("koreanName", `String (let (_, k) = get_agent_identity m.name in k));
              ("trace_id", `String m.trace_id);
              ("generation", `Int m.generation);
              ("created_at", `String m.created_at);
              ("updated_at", `String m.updated_at);
              ("trace_history_count", `Int trace_history_count);
              ("goal", if include_goals then `String m.goal else `Null);
              ("short_goal", if include_goals then `String m.short_goal else `Null);
              ("mid_goal", if include_goals then `String m.mid_goal else `Null);
              ("long_goal", if include_goals then `String m.long_goal else `Null);
              ( "goal_horizons",
                if include_goals then
                  `Assoc [
                    ("short", `String m.short_goal);
                    ("mid", `String m.mid_goal);
                    ("long", `String m.long_goal);
                  ]
                else
                  `Null );
              ("soul_profile", `String m.soul_profile);
              ("will", if String.trim m.will = "" then `Null else `String m.will);
              ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
              ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ("self_model", `Assoc [
                ("will", if String.trim m.will = "" then `Null else `String m.will);
                ("needs", if String.trim m.needs = "" then `Null else `String m.needs);
                ("desires", if String.trim m.desires = "" then `Null else `String m.desires);
              ]);
              ("models", `List (List.map (fun s -> `String s) m.models));
              ("models_resolved", models_resolved);
              ("primary_model", `String primary_model);
              ("active_model", `String active_model);
              ("next_model_hint", match next_model_hint with Some s -> `String s | None -> `Null);
              ("presence_keepalive", `Bool m.presence_keepalive);
              ("presence_keepalive_sec", `Int m.presence_keepalive_sec);
              ("keepalive_running", `Bool keepalive_running);
              ("auto_handoff", `Bool m.auto_handoff);
              ("handoff_threshold", `Float m.handoff_threshold);
              ("agent", agent);
              ( "status",
                `String
                  (Keeper_exec_status.keeper_surface_status ~agent_status:agent
                     ~diagnostic) );
              ("diagnostic", diagnostic);
              ("keeper_age_s", `Float keeper_age_s);
              ("uptime_hours", `Float (keeper_age_s /. 3600.0));
              ("last_turn_ago_s", `Float last_turn_ago_s);
              ("last_handoff_ago_s", `Float last_handoff_ago_s);
              ("last_compaction_ago_s", `Float last_compaction_ago_s);
              ("last_proactive_ago_s", `Float last_proactive_ago_s);
              ("handoff_count_total", `Int trace_history_count);
              ("total_turns", `Int m.total_turns);
              ("total_input_tokens", `Int m.total_input_tokens);
              ("total_output_tokens", `Int m.total_output_tokens);
              ("total_tokens", `Int m.total_tokens);
              ("total_cost_usd", `Float m.total_cost_usd);
              ("last_model_used", `String m.last_model_used);
              ("last_usage", `Assoc [
                ("input_tokens", `Int m.last_input_tokens);
                ("output_tokens", `Int m.last_output_tokens);
                ("total_tokens", `Int m.last_total_tokens);
              ]);
              ("last_latency_ms", `Int m.last_latency_ms);
              ("compaction_count", `Int m.compaction_count);
              ("last_compaction_saved_tokens", `Int last_compaction_saved_tokens);
              ("compaction_profile", `String m.compaction_profile);
              ("compaction_ratio_gate", `Float compact_ratio_gate);
              ("compaction_message_gate", `Int compact_message_gate);
              ("compaction_token_gate", `Int compact_token_gate);
              ("proactive_enabled", `Bool m.proactive_enabled);
              ("proactive_idle_sec", `Int m.proactive_idle_sec);
              ("proactive_cooldown_sec", `Int m.proactive_cooldown_sec);
              ("proactive_count_total", `Int m.proactive_count_total);
              ("last_proactive_ts", `Float m.last_proactive_ts);
              ("last_proactive_reason",
                if String.trim m.last_proactive_reason = ""
                then `Null
                else `String m.last_proactive_reason);
              ("drift_enabled", `Bool m.drift_enabled);
              ("drift_min_turn_gap", `Int m.drift_min_turn_gap);
              ("drift_count_total", `Int m.drift_count_total);
              ("last_drift_turn", `Int m.last_drift_turn);
              ("last_drift_reason",
                if String.trim m.last_drift_reason = ""
                then `Null
                else `String m.last_drift_reason);
	              ("last_proactive_preview",
	                if String.trim m.last_proactive_preview = ""
	                then `Null
	                else `String m.last_proactive_preview);
	              ("skill_primary",
	                match last_skill_primary with
	                | Some s -> `String s
	                | None -> `Null);
	              ("skill_secondary",
	                `List (List.map (fun s -> `String s) last_skill_secondary));
	              ("skill_reason",
	                match last_skill_reason with
	                | Some s -> `String s
	                | None -> `Null);
              ("metrics_window", metrics_window_summary);
              ("metrics_24h_summary", metrics_24h_summary);
              ("memory_note_count", `Int memory_bank_summary.Keeper_memory.total_notes);
              ("memory_top_kind",
                match memory_bank_summary.Keeper_memory.top_kind with
                | Some kind -> `String kind
                | None -> `Null);
              ("memory_recent_note",
                match memory_recent_note with
                | Some text -> `String text
                | None -> `Null);
              ("recent_input_preview",
                match recent_preview_for_role "user" with
                | Some text -> `String text
                | None -> `Null);
              ("recent_output_preview",
                match recent_preview_for_role "assistant" with
                | Some text -> `String text
                | None -> `Null);
              ("recent_tool_names", `List (List.map (fun item -> `String item) recent_tool_names));
              ("conversation_tail_count", `Int conversation_tail_count);
              ("conversation_raw_count", `Int conversation_raw_count);
              ("conversation_fragment_count", `Int conversation_fragment_count);
              ("conversation_fragment_filtered_count", `Int conversation_fragment_filtered_count);
              ("conversation_fragment_filter_enabled", `Bool history_fragment_filter_enabled);
              ("k2k_count", `Int k2k_count);
              ("k2k_mentions", k2k_mentions);
              ("last_handoff_event", match last_handoff_event with Some j -> j | None -> `Null);
              ("last_compaction_event", match last_compaction_event with Some j -> j | None -> `Null);
              ("context", context);
              ("context_source", context_source);
            ] @ detail_fields)
          in
          Some summary
    ) names
  in
  `Assoc [
    ("keepers", `List summaries);
    ("total", `Int (List.length summaries));
  ]

