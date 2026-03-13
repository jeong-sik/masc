[@@@warning "-32-33-69"]

open Types
open Server_utils
open Server_auth

(* ================================================================ *)
(* Dashboard Data (Batch API)                                       *)
(* ================================================================ *)

let bool_of_env name =
  match Sys.getenv_opt name with
  | None -> false
  | Some v ->
      let v = v |> String.trim |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "y"

let bool_default_true_of_env name =
  match Sys.getenv_opt name with
  | None -> true
  | Some v ->
      let v = v |> String.trim |> String.lowercase_ascii in
      not (v = "0" || v = "false" || v = "no" || v = "n")

let int_of_env_default name ~default ~min_v ~max_v =
  let v =
    match Sys.getenv_opt name with
    | None -> default
    | Some s ->
        (try int_of_string (String.trim s) with _ -> default)
  in
  max min_v (min max_v v)

let dashboard_semantics_http_json () =
  Dashboard_semantics.json ()

let float_of_env_default name ~default ~min_v ~max_v =
  let v =
    match Sys.getenv_opt name with
    | None -> default
    | Some s ->
        (try float_of_string (String.trim s) with _ -> default)
  in
  max min_v (min max_v v)

let bool_of_tag_value (raw : string) : bool =
  let v = String.trim raw |> String.lowercase_ascii in
  v = "1" || v = "true" || v = "yes" || v = "y" || v = "on"

let parse_tool_call_detail (detail_opt : string option)
  : string * bool * int option =
  match detail_opt with
  | None -> ("unknown", false, None)
  | Some raw ->
      let parts = String.split_on_char '|' raw |> List.map String.trim in
      let tool_name =
        match parts with
        | head :: _ when head <> "" -> head
        | _ -> "unknown"
      in
      let timeout = ref false in
      let duration_ms = ref None in
      let parse_kv token =
        match String.split_on_char '=' token with
        | [k; v] -> Some (String.trim k, String.trim v)
        | _ -> None
      in
      let tags =
        match parts with
        | _ :: tl -> tl
        | [] -> []
      in
      List.iter
        (fun token ->
          match parse_kv token with
          | Some ("timeout", v) ->
              timeout := bool_of_tag_value v
          | Some ("duration_ms", v) ->
              (try duration_ms := Some (max 0 (int_of_string v)) with _ -> ())
          | _ -> ())
        tags;
      (tool_name, !timeout, !duration_ms)

let percentile_int (values : int list) ~(pct : float) : int option =
  match List.sort compare values with
  | [] -> None
  | sorted ->
      let n = List.length sorted in
      let idx =
        int_of_float (ceil (pct *. float_of_int n) -. 1.0)
        |> max 0
        |> min (n - 1)
      in
      Some (List.nth sorted idx)

let tool_call_health_json (config : Room.config) : Yojson.Safe.t =
  let window_hours =
    float_of_env_default
      "MASC_DASHBOARD_TOOL_CALL_WINDOW_HOURS"
      ~default:1.0
      ~min_v:0.1
      ~max_v:168.0
  in
  let since = Time_compat.now () -. (window_hours *. 3600.0) in
  let events = Tool_audit.read_audit_events config ~since in
  let total = ref 0 in
  let failures = ref 0 in
  let timeouts = ref 0 in
  let durations_rev = ref [] in
  let duration_count = ref 0 in
  let duration_sum = ref 0 in
  let keeper_status_calls = ref 0 in
  let keeper_status_failures = ref 0 in
  let keeper_status_timeouts = ref 0 in
  let keeper_msg_calls = ref 0 in
  let keeper_msg_failures = ref 0 in
  let keeper_msg_timeouts = ref 0 in
  List.iter
    (fun (e : Tool_audit.audit_event) ->
      if e.event_type = "tool_call" then begin
        incr total;
        if not e.success then incr failures;
        let (tool_name, timeout_now, duration_ms_opt) =
          parse_tool_call_detail e.detail
        in
        if timeout_now then incr timeouts;
        (match duration_ms_opt with
         | Some d ->
             incr duration_count;
             duration_sum := !duration_sum + d;
             durations_rev := d :: !durations_rev
         | None -> ());
        if tool_name = "masc_keeper_status" then begin
          incr keeper_status_calls;
          if not e.success then incr keeper_status_failures;
          if timeout_now then incr keeper_status_timeouts;
        end else if tool_name = "masc_keeper_msg" then begin
          incr keeper_msg_calls;
          if not e.success then incr keeper_msg_failures;
          if timeout_now then incr keeper_msg_timeouts;
        end
      end)
    events;
  let total_f = float_of_int !total in
  let failure_rate =
    if !total = 0 then 0.0 else float_of_int !failures /. total_f
  in
  let timeout_rate =
    if !total = 0 then 0.0 else float_of_int !timeouts /. total_f
  in
  let avg_duration_ms =
    if !duration_count = 0 then 0.0
    else float_of_int !duration_sum /. float_of_int !duration_count
  in
  let p95_duration_ms = percentile_int !durations_rev ~pct:0.95 in
  let keeper_msg_timeout_sec =
    int_of_env_default
      "MASC_TOOL_TIMEOUT_KEEPER_MSG_SEC"
      ~default:45
      ~min_v:10
      ~max_v:300
  in
  `Assoc [
    ("window_hours", `Float window_hours);
    ("tool_calls", `Int !total);
    ("failures", `Int !failures);
    ("timeouts", `Int !timeouts);
    ("failure_rate", `Float failure_rate);
    ("timeout_rate", `Float timeout_rate);
    ("duration_sample_count", `Int !duration_count);
    ("avg_duration_ms", `Float avg_duration_ms);
    ("p95_duration_ms", match p95_duration_ms with Some v -> `Int v | None -> `Null);
    ("keeper_msg_timeout_sec", `Int keeper_msg_timeout_sec);
    ("keeper_status", `Assoc [
      ("calls", `Int !keeper_status_calls);
      ("failures", `Int !keeper_status_failures);
      ("timeouts", `Int !keeper_status_timeouts);
    ]);
    ("keeper_msg", `Assoc [
      ("calls", `Int !keeper_msg_calls);
      ("failures", `Int !keeper_msg_failures);
      ("timeouts", `Int !keeper_msg_timeouts);
    ]);
  ]

let json_int_opt = function
  | Some v -> `Int v
  | None -> `Null

let safe_age_seconds_opt ~(now_ts : float) ~(event_ts : float) : int option =
  let delta = now_ts -. event_ts in
  if Float.is_nan delta || Float.is_infinite delta then None
  else
    let bounded = max 0.0 (min delta (float_of_int max_int)) in
    Some (int_of_float bounded)

let board_monitoring_json ~(now_ts : float) : Yojson.Safe.t * bool =
  let warn_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_AGE_WARN_SEC"
      ~default:3600
      ~min_v:60
      ~max_v:604800
  in
  let bad_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_AGE_BAD_SEC"
      ~default:21600
      ~min_v:120
      ~max_v:1209600
  in
  let slo_target_age_s =
    int_of_env_default
      "MASC_DASHBOARD_BOARD_SLO_SEC"
      ~default:900
      ~min_v:30
      ~max_v:86400
  in
  try
    let posts = Board_dispatch.list_posts ~sort_by:Board_dispatch.Updated ~limit:200 () in
    let total_posts = List.length posts in
    let new_posts_24h =
      List.fold_left
        (fun acc (p : Board.post) ->
          if p.created_at >= (now_ts -. (24.0 *. 3600.0)) then acc + 1 else acc)
        0 posts
    in
    let unanswered_posts =
      List.fold_left
        (fun acc (p : Board.post) ->
          if p.reply_count = 0 then acc + 1 else acc)
        0 posts
    in
    let latest_activity_ts_opt =
      List.fold_left
        (fun acc (p : Board.post) ->
          match acc with
          | None -> Some p.updated_at
          | Some prev -> Some (max prev p.updated_at))
        None posts
    in
    let last_activity_age_s =
      match latest_activity_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let alert_level =
      match last_activity_age_s with
      | None -> "warn"
      | Some age when age >= bad_age_s -> "bad"
      | Some age when age >= warn_age_s -> "warn"
      | Some _ -> "ok"
    in
    let slo_breached =
      match last_activity_age_s with
      | Some age -> age >= slo_target_age_s
      | None -> false
    in
    (`Assoc [
      ("alert_level", `String alert_level);
      ("posts_total", `Int total_posts);
      ("new_posts_24h", `Int new_posts_24h);
      ("unanswered_posts", `Int unanswered_posts);
      ("last_activity_age_s", json_int_opt last_activity_age_s);
      ("slo_target_age_s", `Int slo_target_age_s);
      ("slo_breached", `Bool slo_breached);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], true)
  with exn ->
    Printf.eprintf "[dashboard] board_monitoring_json failed: %s\n%!"
      (Printexc.to_string exn);
    (`Assoc [
      ("alert_level", `String "bad");
      ("posts_total", `Int 0);
      ("new_posts_24h", `Int 0);
      ("unanswered_posts", `Int 0);
      ("last_activity_age_s", `Null);
      ("slo_target_age_s", `Int slo_target_age_s);
      ("slo_breached", `Bool false);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], false)

let governance_monitoring_json ~(now_ts : float) ~(base_path : string)
  : Yojson.Safe.t * bool =
  let warn_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_AGE_WARN_SEC"
      ~default:3600
      ~min_v:60
      ~max_v:604800
  in
  let bad_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_AGE_BAD_SEC"
      ~default:21600
      ~min_v:120
      ~max_v:1209600
  in
  let slo_target_quorum_age_s =
    int_of_env_default
      "MASC_DASHBOARD_COUNCIL_SLO_SEC"
      ~default:1800
      ~min_v:30
      ~max_v:86400
  in
  let module GV2 = Council.Governance_v2 in
  try
    let cases : GV2.case_record list = GV2.list_cases base_path in
    let count status =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          if case_.GV2.status = status then acc + 1 else acc)
        0 cases
    in
    let pending_ruling = count GV2.Pending_ruling in
    let ready_auto_execute = count GV2.Ready_auto_execute in
    let needs_human_gate = count GV2.Needs_human_gate in
    let executed = count GV2.Executed in
    let blocked =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          match case_.GV2.status with
          | GV2.Blocked | GV2.Closed -> acc + 1
          | GV2.Pending_ruling | GV2.Ready_auto_execute
          | GV2.Needs_human_gate | GV2.Executed -> acc)
        0 cases
    in
    let cases_open = pending_ruling + ready_auto_execute + needs_human_gate in
    let oldest_open_case_ts_opt =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          match case_.GV2.status with
          | GV2.Pending_ruling | GV2.Ready_auto_execute | GV2.Needs_human_gate ->
              (match acc with
              | None -> Some case_.GV2.updated_at
              | Some prev -> Some (min prev case_.GV2.updated_at))
          | GV2.Executed | GV2.Blocked | GV2.Closed -> acc)
        None cases
    in
    let oldest_open_case_age_s =
      match oldest_open_case_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let latest_activity_ts_opt =
      List.fold_left
        (fun acc (case_ : GV2.case_record) ->
          match acc with
          | None -> Some case_.GV2.updated_at
          | Some prev -> Some (max prev case_.GV2.updated_at))
        None cases
    in
    let last_activity_age_s =
      match latest_activity_ts_opt with
      | None -> None
      | Some ts -> safe_age_seconds_opt ~now_ts ~event_ts:ts
    in
    let base_alert =
      match last_activity_age_s with
      | None -> if cases_open > 0 then "warn" else "ok"
      | Some age when age >= bad_age_s -> "bad"
      | Some age when age >= warn_age_s -> "warn"
      | Some _ -> "ok"
    in
    let slo_breached =
      match oldest_open_case_age_s with
      | Some age -> cases_open > 0 && age >= slo_target_quorum_age_s
      | None -> false
    in
    let judge_json = Dashboard_governance.judge_runtime_json base_path in
    let judge_online =
      match Yojson.Safe.Util.member "judge_online" judge_json with
      | `Bool value -> value
      | _ -> false
    in
    let alert_level =
      if needs_human_gate > 0 then
        match oldest_open_case_age_s with
        | Some age when age >= bad_age_s -> "bad"
        | _ -> "warn"
      else base_alert
    in
    (`Assoc [
      ("alert_level", `String alert_level);
      ("cases_open", `Int cases_open);
      ("pending_ruling", `Int pending_ruling);
      ("ready_auto_execute", `Int ready_auto_execute);
      ("needs_human_gate", `Int needs_human_gate);
      ("executed", `Int executed);
      ("blocked", `Int blocked);
      ("oldest_open_case_age_s", json_int_opt oldest_open_case_age_s);
      ("last_activity_age_s", json_int_opt last_activity_age_s);
      ("slo_target_case_age_s", `Int slo_target_quorum_age_s);
      ("slo_breached", `Bool slo_breached);
      ("judge_online", `Bool judge_online);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], true)
  with exn ->
    Printf.eprintf "[dashboard] governance_monitoring_json failed: %s\n%!"
      (Printexc.to_string exn);
    (`Assoc [
      ("alert_level", `String "bad");
      ("cases_open", `Int 0);
      ("pending_ruling", `Int 0);
      ("ready_auto_execute", `Int 0);
      ("needs_human_gate", `Int 0);
      ("executed", `Int 0);
      ("blocked", `Int 0);
      ("oldest_open_case_age_s", `Null);
      ("last_activity_age_s", `Null);
      ("slo_target_case_age_s", `Int slo_target_quorum_age_s);
      ("slo_breached", `Bool false);
      ("judge_online", `Bool false);
      ("warn_age_s", `Int warn_age_s);
      ("bad_age_s", `Int bad_age_s);
    ], false)

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
      with exn -> Printf.eprintf "[main] keeper log parse: %s\n%!" (Printexc.to_string exn))
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
      with _ ->
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
              try Some (Yojson.Safe.from_string line) with _ -> None
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
              with _ -> None
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

let perpetual_dashboard_json () : Yojson.Safe.t =
  let include_goals = bool_of_env "MASC_DASHBOARD_INCLUDE_GOALS" in
  let items =
    Hashtbl.fold (fun trace_id (state, (config : Perpetual_loop.loop_config)) acc ->
      let base = Perpetual_loop.status state in
      let with_cfg =
        match base with
        | `Assoc fields ->
              let models =
              `List (List.map (fun (m : Llm_client.model_spec) ->
                `Assoc [
                  ("provider", `String (Llm_client.string_of_provider m.provider));
                  ("model_id", `String m.model_id);
                  ("max_context", `Int m.max_context);
                ]
              ) config.model_cascade)
            in
            `Assoc ([
              ("goal", if include_goals then `String config.initial_goal else `Null);
              ("model_cascade", models);
              ("heartbeat_interval_s", `Float config.heartbeat_interval_s);
              ("compact_threshold", `Float config.compact_threshold);
              ("prepare_threshold", `Float config.prepare_threshold);
              ("handoff_threshold", `Float config.handoff_threshold);
            ] @ fields)
        | other -> other
      in
      (trace_id, with_cfg) :: acc
    ) Tool_perpetual.active_agents []
  in
  let items =
    items
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map snd
  in
  `Assoc [
    ("agents", `List items);
    ("total", `Int (List.length items));
  ]

let mdal_status_string (status : Mdal.status) : string =
  Mdal.status_to_string status

let mdal_iteration_record_json (r : Mdal.iteration_record) : Yojson.Safe.t =
  let evidence_json =
    match r.evidence with
    | None -> `Null
    | Some evidence ->
        `Assoc
          [
            ("worker_engine", `String (Mdal.worker_engine_to_string evidence.engine));
            ("worker_model", `String evidence.model_used);
            ("tool_call_count", `Int evidence.tool_call_count);
            ("tool_names", `List (List.map (fun item -> `String item) evidence.tool_names));
            ("session_id", `String evidence.session_id);
            ("evidence_status", `String (Mdal.evidence_status_to_string evidence.status));
          ]
  in
  `Assoc
    [
      ("iteration", `Int r.iteration);
      ("metric_before", `Float r.metric_before);
      ("metric_after", `Float r.metric_after);
      ("delta", `Float r.delta);
      ("changes", `String r.changes);
      ("failed_attempts", `String r.failed_attempts);
      ("next_suggestion", `String r.next_suggestion);
      ("elapsed_ms", `Int r.elapsed_ms);
      ("cost_usd", match r.cost_usd with Some c -> `Float c | None -> `Null);
      ("evidence", evidence_json);
    ]

let mdal_loop_json ~(config : Room.config) ~(history_limit : int)
    (state : Mdal.loop_state) : Yojson.Safe.t =
  let history =
    state.history
    |> take history_limit
    |> List.map mdal_iteration_record_json
  in
  let latest_evidence = Mdal.latest_evidence state in
  `Assoc
    [
      ("loop_id", `String state.loop_id);
      ("status", `String (mdal_status_string state.status));
      ("strict_mode", `Bool state.strict_mode);
      ("error_message",
       match state.error_message with Some msg -> `String msg | None -> `Null);
      ("error_reason",
       match state.error_message with Some msg -> `String msg | None -> `Null);
      ("stop_reason",
       match state.stop_reason with Some reason -> `String reason | None -> `Null);
      ("profile", `String state.profile.name);
      ("current_iteration", `Int state.current_iteration);
      ("max_iterations", `Int state.profile.max_iterations);
      ("baseline_metric", `Float state.baseline_metric);
      ("current_metric", `Float (Mdal.current_metric state));
      ("target", `String state.profile.target);
      ("stagnation_streak", `Int state.stagnation_streak);
      ("stagnation_limit", `Int state.profile.stagnation_count);
      ("elapsed_seconds", `Float (Time_compat.now () -. state.start_time));
      ("start_time", `String (iso8601_of_unix state.start_time));
      ("updated_at", `String (iso8601_of_unix state.updated_at));
      ("stopped_at",
       match state.stopped_at with
       | Some ts -> `String (iso8601_of_unix ts)
       | None -> `Null);
      ("execution_mode",
       `String (Mdal.execution_mode_to_string state.execution_mode));
      ("worker_engine",
       match state.worker_engine with
       | Some engine -> `String (Mdal.worker_engine_to_string engine)
       | None -> `Null);
      ("worker_model",
       match state.worker_model with
       | Some model -> `String model
       | None -> `Null);
      ("evidence_policy", if state.strict_mode then `String "hard" else `String "legacy");
      ("latest_tool_call_count",
       `Int
         (match latest_evidence with
          | Some evidence -> evidence.tool_call_count
          | None -> 0));
      ("latest_tool_names",
       `List
         (match latest_evidence with
          | Some evidence -> List.map (fun item -> `String item) evidence.tool_names
          | None -> []));
      ("session_id",
       match latest_evidence with
       | Some evidence -> `String evidence.session_id
       | None -> `Null);
      ("evidence_status",
       match Mdal.current_evidence_status state with
       | Some status -> `String (Mdal.evidence_status_to_string status)
       | None -> `Null);
      ("durability", `String (Mdal_store.durability config));
      ("persistence_backend", `String (Mdal_store.persistence_backend config));
      ("recoverable", `Bool (Mdal.recoverable state));
      ("history", `List history);
    ]

let parse_mdal_status_filter (raw_opt : string option) : (string option, string) result =
  match raw_opt with
  | None -> Ok None
  | Some raw ->
      let normalized = String.trim raw |> String.lowercase_ascii in
      if normalized = "" then Ok None
      else if normalized = "running"
           || normalized = "interrupted"
           || normalized = "completed"
           || normalized = "stopped"
           || normalized = "error"
      then Ok (Some normalized)
      else
        Error
          (Printf.sprintf
             "invalid status filter: %s (expected running|interrupted|completed|stopped|error)"
             raw)

let mdal_loops_json ~(config : Room.config)
    (request : Httpun.Request.t) : (Yojson.Safe.t, string) result =
  let limit = int_query_param request "limit" ~default:20 |> clamp ~min_v:1 ~max_v:100 in
  let history_limit =
    int_query_param request "history_limit" ~default:50 |> clamp ~min_v:0 ~max_v:500
  in
  match parse_mdal_status_filter (query_param request "status") with
  | Error _ as e -> e
  | Ok status_filter ->
      let loops =
        Tool_mdal.list_loops ~config ()
        |> List.filter (fun (state : Mdal.loop_state) ->
               let status = mdal_status_string state.status in
               match status_filter with
               | None -> true
               | Some expected -> String.equal expected status)
      in
      let loops =
        loops
        |> List.sort (fun (a : Mdal.loop_state) (b : Mdal.loop_state) ->
               let rank (s : Mdal.loop_state) =
                 match s.status with
                 | `Running -> 0
                 | `Interrupted -> 1
                 | _ -> 2
               in
               let by_status = Int.compare (rank a) (rank b) in
               if by_status <> 0 then by_status
               else Float.compare b.start_time a.start_time)
      in
      let total = List.length loops in
      let loops = take limit loops in
      Ok
        (`Assoc
          [
            ("loops", `List (List.map (mdal_loop_json ~config ~history_limit) loops));
            ("total", `Int total);
            ("returned", `Int (List.length loops));
            ("limit", `Int limit);
            ("history_limit", `Int history_limit);
            ("status", match status_filter with Some s -> `String s | None -> `Null);
          ])

let mdal_loops_error_json (msg : string) : Yojson.Safe.t =
  `Assoc [ ("error", `String msg) ]
let dashboard_batch_json ?(compact = false) (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let tempo = Tempo.get_tempo config in
  let tasks = Room.get_tasks_raw config in
  let agents = Room.get_agents_raw config in
  let msgs = Room.get_messages_raw config ~since_seq:0 ~limit:20 in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let social_runtime_json = Social_runtime.status_json ~config in
  let now_ts = Time_compat.now () in
  let (board_monitor_json, board_contract_ok) = board_monitoring_json ~now_ts in
  let (governance_monitor_json, governance_feed_ok) =
    governance_monitoring_json ~now_ts ~base_path:config.base_path
  in

  let proactive_fallback_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_WARN"
      ~default:0.20
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_fallback_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_FALLBACK_BAD"
      ~default:0.40
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_warn =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_WARN"
      ~default:0.90
      ~min_v:0.0
      ~max_v:1.0
  in
  let proactive_similarity_bad =
    float_of_env_default
      "MASC_DASHBOARD_PROACTIVE_SIMILARITY_BAD"
      ~default:0.97
      ~min_v:0.0
      ~max_v:1.0
  in
  let alert_toast_cooldown_sec =
    int_of_env_default
      "MASC_DASHBOARD_ALERT_TOAST_COOLDOWN_SEC"
      ~default:300
      ~min_v:10
      ~max_v:86400
  in
  let status_json =
    `Assoc [
      ( "room",
        `String
          (if Room.is_initialized config then Room.current_room_id config
           else Filename.basename config.base_path) );
      ("room_base_path", `String config.base_path);
      ("cluster", `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME")));
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("tool_call_health", tool_call_health_json config);
      ("alert_thresholds", `Assoc [
        ("proactive_fallback_warn", `Float proactive_fallback_warn);
        ("proactive_fallback_bad", `Float (max proactive_fallback_warn proactive_fallback_bad));
        ("proactive_similarity_warn", `Float proactive_similarity_warn);
        ("proactive_similarity_bad", `Float (max proactive_similarity_warn proactive_similarity_bad));
        ("toast_cooldown_sec", `Int alert_toast_cooldown_sec);
      ]);
      ("monitoring", `Assoc [
        ("board", board_monitor_json);
        ("governance", governance_monitor_json);
      ]);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("data_quality", `Assoc [
        ("board_contract_ok", `Bool board_contract_ok);
        ("governance_feed_ok", `Bool governance_feed_ok);
        ("last_sync_at", `String (Types.now_iso ()));
      ]);
    ]
  in
  let tasks_json =
    List.map (fun (t : Types.task) ->
      `Assoc [
        ("id", `String t.id);
        ("title", `String t.title);
        ("status", `String (Types.string_of_task_status t.task_status));
        ("priority", `Int t.priority);
        ("assignee",
         match t.task_status with
         | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
             `String assignee
         | _ -> `Null);
      ]
    )
      (List.filter
         (fun (t : Types.task) ->
           match t.task_status with
           | Types.Cancelled _ -> false
           | Types.Done _ -> not compact
           | _ -> true)
         tasks)
  in
  let agents_json =
    List.map (fun (a : Types.agent) ->
      let (emoji, korean_name) = get_agent_identity a.name in
      `Assoc [
        ("name", `String a.name);
        ("status", `String (Types.string_of_agent_status a.status));
        ("current_task", match a.current_task with Some t -> `String t | None -> `Null);
        ("last_seen", `String a.last_seen);
        ("emoji", `String emoji);
        ("koreanName", `String korean_name);
        ("generation", `Null);
        ("context_ratio", `Null);
        ("turn_count", `Null);
      ]
    ) agents
  in
  let msgs_json =
    List.map
      (fun (m : Types.message) ->
        `Assoc [
          ("from", `String m.from_agent);
          ("content", `String m.content);
          ("timestamp", `String m.timestamp);
          ("seq", `Int m.seq);
        ])
      (List.filteri (fun idx _ -> idx < 20) msgs)
  in
  `Assoc [
    ("status", status_json);
    ("tasks", `Assoc [ ("tasks", `List tasks_json); ("total", `Int (List.length tasks_json)) ]);
    ("agents", `Assoc [ ("agents", `List agents_json); ("total", `Int (List.length agents_json)) ]);
    ("messages", `Assoc [ ("messages", `List msgs_json); ("total", `Int (List.length msgs_json)) ]);
    ("keepers", keepers_dashboard_json ~compact config);
    ("perpetual", perpetual_dashboard_json ());
  ]

let operator_actor_hint request =
  match agent_from_request request with
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let operator_snapshot_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let include_messages =
    match query_param request "include_messages" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_sessions =
    match query_param request "include_sessions" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  let include_keepers =
    match query_param request "include_keepers" with
    | Some ("0" | "false" | "no") -> false
    | _ -> true
  in
  Operator_control.snapshot_json ?actor:(operator_actor_hint request)
    ~include_messages ~include_sessions ~include_keepers ctx

let operator_digest_http_json ~state ~sw ~clock request =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let target_type = query_param request "target_type" in
  let target_id = query_param request "target_id" in
  let include_workers =
    match query_param request "include_workers" with
    | Some ("0" | "false" | "no") -> Some false
    | Some ("1" | "true" | "yes") -> Some true
    | _ -> None
  in
  Operator_control.digest_json ?actor:(operator_actor_hint request)
    ?target_type ?target_id ?include_workers ctx

let dashboard_mission_http_json ~state ~sw ~clock request =
  Dashboard_mission.json ?actor:(operator_actor_hint request)
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_session_http_json ~state ~sw ~clock request =
  match query_param request "session_id" with
  | Some session_id when String.trim session_id <> "" ->
      Dashboard_mission.session_json ?actor:(operator_actor_hint request)
        ~session_id:(String.trim session_id)
        ~config:state.Mcp_server.room_config ~sw ~clock
        ~proc_mgr:state.Mcp_server.proc_mgr ()
  | _ ->
      `Assoc
        [
          ("generated_at", `String (Types.now_iso ()));
          ("session_id", `Null);
          ("session", `Null);
          ("timeline", `List []);
          ("participants", `List []);
          ("operations", `List []);
          ("keepers", `List []);
          ("error", `String "session_id is required");
        ]

let dashboard_mission_briefing_http_json ~state ~sw ~clock request =
  Dashboard_mission_briefing.json ?actor:(operator_actor_hint request)
    ~force:(bool_query_param request "force" ~default:false)
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_proof_http_json ~state request =
  let session_id = query_param request "session_id" in
  let operation_id = query_param request "operation_id" in
  Dashboard_proof.json ?actor:(operator_actor_hint request) ?session_id
    ?operation_id ~config:state.Mcp_server.room_config ()

let dashboard_shell_status_json (config : Room.config) : Yojson.Safe.t =
  let room_state = Room.read_state config in
  let current_room =
    Room.read_current_room config |> Option.value ~default:"default"
  in
  let tempo = Tempo.get_tempo config in
  let lodge_json = Lodge_heartbeat.(lodge_status () |> lodge_status_to_json) in
  let social_runtime_json = Social_runtime.status_json ~config in
  let gardener_json = Gardener.status_json () in
  let guardian_json = Guardian.status_json () in
  let sentinel_json = Sentinel.status_json () in
  let build = Build_identity.current () in
  `Assoc
    [
      ("room", `String current_room);
      ("current_room", `String current_room);
      ("room_base_path", `String config.base_path);
      ( "cluster",
        `String (Option.value ~default:"unknown" (Sys.getenv_opt "MASC_CLUSTER_NAME"))
      );
      ("project", `String room_state.project);
      ("tempo_interval_s", `Float tempo.current_interval_s);
      ("paused", `Bool room_state.paused);
      ("lodge", lodge_json);
      ("social_runtime", social_runtime_json);
      ("gardener", gardener_json);
      ("guardian", guardian_json);
      ("sentinel", sentinel_json);
      ("version", `String build.release_version);
      ("build", Build_identity.to_yojson build);
    ]

let dashboard_task_assignee (task : Types.task) =
  match task.task_status with
  | Claimed { assignee; _ } | InProgress { assignee; _ } | Done { assignee; _ } ->
      Some assignee
  | Todo | Cancelled _ -> None

let dashboard_task_json (task : Types.task) =
  `Assoc
    [
      ("id", `String task.id);
      ("title", `String task.title);
      ("description", `String task.description);
      ("status", `String (Types.string_of_task_status task.task_status));
      ("priority", `Int task.priority);
      ("assignee", match dashboard_task_assignee task with Some v -> `String v | None -> `Null);
      ("created_at", `String task.created_at);
    ]

let dashboard_agent_json (agent : Types.agent) =
  let (emoji, korean_name) = get_agent_identity agent.name in
  `Assoc
    [
      ("name", `String agent.name);
      ("agent_type", `String agent.agent_type);
      ("status", `String (Types.string_of_agent_status agent.status));
      ("current_task", match agent.current_task with Some task -> `String task | None -> `Null);
      ("joined_at", `String agent.joined_at);
      ("last_seen", `String agent.last_seen);
      ("capabilities", `List (List.map (fun item -> `String item) agent.capabilities));
      ("emoji", `String emoji);
      ("koreanName", `String korean_name);
    ]

let dashboard_message_json (message : Types.message) =
  `Assoc
    [
      ("from", `String message.from_agent);
      ("content", `String message.content);
      ("timestamp", `String message.timestamp);
      ("seq", `Int message.seq);
    ]

let json_list_field key json =
  match Yojson.Safe.Util.member key json with
  | `List items -> items
  | _ -> []

let json_int_field key json ~default =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | `Intlit raw -> (try int_of_string raw with Failure _ -> default)
  | _ -> default

let json_string_field_opt key json =
  match Yojson.Safe.Util.member key json with
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_assoc_field key json =
  match Yojson.Safe.Util.member key json with
  | `Assoc _ as value -> value
  | _ -> `Assoc []

let json_record_field key json =
  match Yojson.Safe.Util.member key json with
  | `Assoc _ as value -> Some value
  | _ -> None

let count_where items predicate =
  List.fold_left
    (fun acc item -> if predicate item then acc + 1 else acc)
    0 items

let dashboard_current_room_id config =
  Room.current_room_id config

let dashboard_tasks_safe config =
  Room.get_tasks_raw_in_room config (dashboard_current_room_id config)

let dashboard_agents_safe config =
  Room.get_agents_raw_in_room config (dashboard_current_room_id config)

let dashboard_messages_safe config ~since_seq ~limit =
  Room.get_messages_raw_in_room config ~room_id:(dashboard_current_room_id config) ~since_seq ~limit

let dashboard_shell_http_json (config : Room.config) : Yojson.Safe.t =
  let agents = dashboard_agents_safe config in
  let tasks = dashboard_tasks_safe config in
  let keepers_json = keepers_dashboard_json ~compact:true config in
  let keepers_total = json_int_field "total" keepers_json ~default:0 in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("status", dashboard_shell_status_json config);
      ( "counts",
        `Assoc
          [
            ("agents", `Int (List.length agents));
            ("tasks", `Int (List.length tasks));
            ("keepers", `Int keepers_total);
          ] );
    ]

let dashboard_tools_http_json ?actor (config : Room.config) : Yojson.Safe.t =
  let ctx : Tool_misc.context =
    {
      config;
      agent_name = Option.value ~default:"dashboard" actor;
    }
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("tool_inventory", Tool_misc.tool_inventory_json ctx ~include_hidden:true ~include_deprecated:true);
      ("tool_usage", Tool_unified.summary_report ());
    ]

let dashboard_execution_http_json ~state ~sw ~clock request =
  let fixture = query_param request "fixture" in
  Dashboard_execution.json ?actor:(operator_actor_hint request) ?fixture
    ~config:state.Mcp_server.room_config ~sw ~clock
    ~proc_mgr:state.Mcp_server.proc_mgr ()

let dashboard_room_truth_http_json ~state ~sw ~clock request =
  let config = state.Mcp_server.room_config in
  let actor = operator_actor_hint request in
  let shell_json = dashboard_shell_http_json config in
  let execution_json = dashboard_execution_http_json ~state ~sw ~clock request in
  let command_summary_json =
    if Room.is_initialized config then
      try
        Server_command_plane_http.command_plane_summary_http_json ~state
      with _ -> `Assoc []
    else
      `Assoc []
  in
  let operator_ctx : _ Operator_control.context =
    {
      config;
      agent_name = Option.value ~default:"dashboard" actor;
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  let operator_digest_json =
    match Operator_control.digest_json ?actor operator_ctx with
    | Ok json -> json
    | Error message ->
        `Assoc
          [
            ("health", `String "warn");
            ("attention_summary", `Assoc [ ("count", `Int 0); ("provenance", `String "derived") ]);
            ("recommendation_summary", `Assoc [ ("count", `Int 0); ("provenance", `String "fallback") ]);
            ("error", `String message);
          ]
  in
  let operator_snapshot_json =
    Operator_control.snapshot_json ?actor
      ~include_messages:false ~include_sessions:false ~include_keepers:false
      operator_ctx
  in
  let orchestra_json =
    if Room.is_initialized config then
      try Command_plane_orchestra.json operator_ctx with _ -> `Assoc []
    else
      `Assoc
        [
          ( "focus",
            `Assoc
              [
                ("label", `String "초기 room truth");
                ("reason", `String "방이 아직 초기화되지 않았습니다. 기본 room 상태부터 확인하세요.");
                ("source", `String "orchestra");
                ("provenance", `String "derived");
                ("target_kind", `String "node");
                ("target_id", `String "room:default");
                ("suggested_surface", `String "summary");
                ("suggested_params", `Assoc []);
              ] );
        ]
  in
  let execution_queue =
    match Yojson.Safe.Util.member "execution_queue" execution_json with
    | `List items -> items
    | _ -> []
  in
  let execution_session_briefs = json_list_field "session_briefs" execution_json in
  let execution_operation_briefs = json_list_field "operation_briefs" execution_json in
  let execution_worker_support =
    json_list_field "worker_support_briefs" execution_json
  in
  let execution_continuity =
    json_list_field "continuity_briefs" execution_json
  in
  let execution_keepers = json_list_field "keepers" execution_json in
  let top_queue =
    match execution_queue with
    | head :: _ -> head
    | [] -> `Null
  in
  let has_text key json =
    match json_string_field_opt key json with
    | Some _ -> true
    | None -> false
  in
  let execution_summary =
    let existing = json_assoc_field "summary" execution_json in
    match Yojson.Safe.Util.member "blocked_sessions" existing with
    | `Int _ | `Intlit _ ->
        existing
    | _ ->
        `Assoc
          [
            ("active_sessions", `Int (List.length execution_session_briefs));
            ( "blocked_sessions",
              `Int
                (count_where execution_session_briefs
                   (fun row ->
                     let health = json_string_field_opt "health" row in
                     let status = json_string_field_opt "status" row in
                     has_text "blocker_summary" row
                     || health = Some "warn"
                     || health = Some "bad"
                     || status = Some "blocked")) );
            ("active_operations", `Int (List.length execution_operation_briefs));
            ( "blocked_operations",
              `Int (count_where execution_operation_briefs (has_text "blocker_summary")) );
            ( "worker_alerts",
              `Int
                (count_where execution_worker_support
                   (fun row ->
                     match json_string_field_opt "tone" row with
                     | Some "warn" | Some "bad" -> true
                     | _ -> false)) );
            ( "continuity_alerts",
              `Int
                (count_where execution_continuity
                   (fun row ->
                     match json_string_field_opt "tone" row with
                     | Some "warn" | Some "bad" -> true
                     | _ -> false)) );
            ("priority_items", `Int (List.length execution_queue));
            ("keepers", `Int (List.length execution_keepers));
          ]
  in
  let command_ops = json_assoc_field "operations" command_summary_json in
  let command_detachments = json_assoc_field "detachments" command_summary_json in
  let command_alerts = json_assoc_field "alerts" command_summary_json in
  let command_decisions = json_assoc_field "decisions" command_summary_json in
  let swarm_status = json_assoc_field "swarm_status" command_summary_json in
  let swarm_overview = json_assoc_field "overview" swarm_status in
  let command_summary =
    `Assoc
      [
        ( "active_operations",
          `Int
            (json_int_field "active" (json_assoc_field "summary" command_ops)
               ~default:0) );
        ( "active_detachments",
          `Int
            (json_int_field "active"
               (json_assoc_field "summary" command_detachments)
               ~default:0) );
        ( "pending_approvals",
          `Int
            (json_int_field "pending"
               (json_assoc_field "summary" command_decisions)
               ~default:0) );
        ( "bad_alerts",
          `Int
            (json_int_field "bad" (json_assoc_field "summary" command_alerts)
               ~default:0) );
        ( "warn_alerts",
          `Int
            (json_int_field "warn" (json_assoc_field "summary" command_alerts)
               ~default:0) );
        ("moving_lanes", `Int (json_int_field "moving_lanes" swarm_overview ~default:0));
        ("active_lanes", `Int (json_int_field "active_lanes" swarm_overview ~default:0));
        ("provenance", `String "truth");
      ]
  in
  let focus_json =
    match json_record_field "focus" orchestra_json with
    | Some focus ->
        let suggested_surface = json_string_field_opt "suggested_surface" focus in
        let suggested_tab =
          match suggested_surface with
          | Some "intervene" -> "intervene"
          | _ -> "command"
        in
        `Assoc
          [
            ("label", Yojson.Safe.Util.member "label" focus);
            ("reason", Yojson.Safe.Util.member "reason" focus);
            ("source", `String "orchestra");
            ("provenance", `String "derived");
            ("target_kind", Yojson.Safe.Util.member "target_kind" focus);
            ("target_id", Yojson.Safe.Util.member "target_id" focus);
            ("suggested_tab", `String suggested_tab);
            ( "suggested_surface",
              match suggested_surface with
              | Some value when not (String.equal value "intervene") -> `String value
              | _ -> `Null );
            ("suggested_params", json_assoc_field "suggested_params" focus);
          ]
    | None -> (
        let recommendation_summary =
          json_assoc_field "recommendation_summary" operator_digest_json
        in
        match json_record_field "top_action" recommendation_summary with
        | Some top_action ->
            `Assoc
              [
                ("label", `String "운영 권고");
                ("reason", Yojson.Safe.Util.member "reason" top_action);
                ("source", `String "operator");
                ( "provenance",
                  match json_string_field_opt "provenance" recommendation_summary with
                  | Some value -> `String value
                  | None -> `String "fallback" );
                ("target_kind", `String "action");
                ("target_id", Yojson.Safe.Util.member "target_id" top_action);
                ("suggested_tab", `String "intervene");
                ("suggested_surface", `Null);
                ( "suggested_params",
                  `Assoc
                    [
                      ("action_type", Yojson.Safe.Util.member "action_type" top_action);
                      ("target_type", Yojson.Safe.Util.member "target_type" top_action);
                      ("target_id", Yojson.Safe.Util.member "target_id" top_action);
                    ] );
              ]
        | None -> `Null)
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "room",
        `Assoc
          [
            ("status", json_assoc_field "status" shell_json);
            ("counts", json_assoc_field "counts" shell_json);
            ("provenance", `String "truth");
          ] );
      ( "execution",
        `Assoc
          [
            ("summary", execution_summary);
            ("top_queue", top_queue);
            ("provenance", `String "derived");
          ] );
      ("command", command_summary);
      ( "operator",
        `Assoc
          [
            ("health", Yojson.Safe.Util.member "health" operator_digest_json);
            ("attention_summary", json_assoc_field "attention_summary" operator_digest_json);
            ( "recommendation_summary",
              json_assoc_field "recommendation_summary" operator_digest_json );
            ( "pending_confirm_summary",
              json_assoc_field "pending_confirm_summary" operator_snapshot_json );
            ("provenance", `String "derived");
          ] );
      ("focus", focus_json);
    ]

let dashboard_memory_http_json request : Yojson.Safe.t =
  let hearth = query_param request "hearth" in
  let sort_by = board_sort_order_of_request request in
  let exclude_system = bool_query_param request "exclude_system" ~default:false in
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let fetch_limit = board_fetch_limit ~exclude_system ~limit ~offset in
  let posts = Board_dispatch.list_posts ?hearth ~sort_by ~limit:fetch_limit () in
  let posts = filter_board_posts ~exclude_system posts in
  let karma_map = Board_dispatch.get_all_karma () in
  let get_karma author =
    Option.value ~default:0 (List.assoc_opt author karma_map)
  in
  let paged = posts |> drop offset |> take limit in
  let posts_json =
    List.map
      (fun (post : Board.post) ->
        let author = Board.Agent_id.to_string post.author in
        board_post_dashboard_json ~author_karma:(get_karma author) post)
      paged
  in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("visible_posts", `Int (List.length posts_json));
            ("sort_by", `String (board_sort_label sort_by));
            ("exclude_system", `Bool exclude_system);
          ] );
      ("posts", `List posts_json);
      ("count", `Int (List.length posts_json));
      ("limit", `Int limit);
      ("offset", `Int offset);
      ("sort_by", `String (board_sort_label sort_by));
    ]

let dashboard_governance_http_json request ~base_path : Yojson.Safe.t =
  let limit = int_query_param request "limit" ~default:50 |> clamp ~min_v:1 ~max_v:200 in
  let offset = int_query_param request "offset" ~default:0 |> clamp ~min_v:0 ~max_v:5000 in
  let status_filter =
    match query_param request "status" with
    | None -> None
    | Some raw -> (
        match String.lowercase_ascii (String.trim raw) with
        | "pending_ruling" -> Some Council.Governance_v2.Pending_ruling
        | "ready_auto_execute" -> Some Council.Governance_v2.Ready_auto_execute
        | "needs_human_gate" -> Some Council.Governance_v2.Needs_human_gate
        | "executed" -> Some Council.Governance_v2.Executed
        | "blocked" -> Some Council.Governance_v2.Blocked
        | "closed" -> Some Council.Governance_v2.Closed
        | _ -> None)
  in
  Dashboard_governance.dashboard_json ~base_path ~limit ~offset
    ~status_filter

let dashboard_planning_http_json request ~(config : Room.config) : Yojson.Safe.t =
  let goals = Goal_store.list_goals config () in
  let rollup = Goal_store.compute_rollup goals in
  let mdal_json =
    match mdal_loops_json ~config request with
    | Ok json -> json
    | Error message -> `Assoc [ ("error", `String message); ("loops", `List []) ]
  in
  let task_rollup =
    dashboard_tasks_safe config
    |> List.fold_left
         (fun (todo, claimed, running, done_count, cancelled) (task : Types.task) ->
           match task.task_status with
           | Todo -> (todo + 1, claimed, running, done_count, cancelled)
           | Claimed _ -> (todo, claimed + 1, running, done_count, cancelled)
           | InProgress _ -> (todo, claimed, running + 1, done_count, cancelled)
           | Done _ -> (todo, claimed, running, done_count + 1, cancelled)
           | Cancelled _ -> (todo, claimed, running, done_count, cancelled + 1))
         (0, 0, 0, 0, 0)
  in
  let (todo_count, claimed_count, running_count, done_count, cancelled_count) = task_rollup in
  `Assoc
    [
      ("generated_at", `String (Types.now_iso ()));
      ("goals", `List (List.map Goal_store.goal_to_yojson goals));
      ("rollup", Goal_store.rollup_to_yojson rollup);
      ("mdal", mdal_json);
      ( "task_backlog",
        `Assoc
          [
            ("todo", `Int todo_count);
            ("claimed", `Int claimed_count);
            ("in_progress", `Int running_count);
            ("done", `Int done_count);
            ("cancelled", `Int cancelled_count);
          ] );
    ]

let operator_action_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  Operator_control.action_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_confirm_http_json ~state ~sw ~clock request ~args =
  let ctx : _ Operator_control.context =
    {
      config = state.Mcp_server.room_config;
      agent_name = Option.value ~default:"dashboard" (operator_actor_hint request);
      sw;
      clock;
      proc_mgr = state.Mcp_server.proc_mgr;
      mcp_session_id = None;
    }
  in
  Operator_control.confirm_json ?actor_hint:(operator_actor_hint request) ctx args

let operator_error_json message =
  `Assoc [ ("status", `String "error"); ("message", `String message) ]
