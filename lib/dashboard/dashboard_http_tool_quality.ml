(** Dashboard Tool Quality API — aggregate tool call quality metrics.

    Reads [.masc/tool_calls/] JSONL via {!Keeper_tool_call_log.read_recent}
    and produces summary statistics for dashboard consumption.

    @since 2.260.0 *)

(** Classify a failed tool call output string into an error category.
    Strips known prefixes ("error: ", "tool_error: ") before JSON parsing
    so prefixed outputs like ["error: {\"ok\":false,\"error\":\"msg\"}"]
    yield the actual error key instead of "parse_error". *)
let normalize_failure_text (text : string) : string =
  let trimmed = String.trim text in
  let lowered = String.lowercase_ascii trimmed in
  let prefix_rules =
    [
      ("path_not_in_allowed_paths:", "path_not_in_allowed_paths");
      ("path_outside_sandbox:", "path_outside_sandbox");
      ("path_not_found_under_allowed_roots:", "path_not_found_under_allowed_roots");
      ("path_outside_project_root:", "path_outside_project_root");
      ("allowed_paths_normalized_empty:", "allowed_paths_normalized_empty");
      ("ambiguous_relative_read_path:", "ambiguous_relative_read_path");
      ("cwd_not_directory:", "cwd_not_directory");
      ("path blocked:", "path_blocked");
      ("query looks like it may contain secrets", "query_secret_like");
      ("web search rate limit exceeded", "web_search_rate_limit");
      ("all web search providers failed", "web_search_provider_failure");
      ("query must be at most", "query_too_long");
      ("query is required", "query_required");
    ]
  in
  match List.find_opt (fun (prefix, _category) ->
    String.starts_with ~prefix lowered
  ) prefix_rules with
  | Some (_, category) -> category
  | None when trimmed = "" -> "empty_output"
  | None -> trimmed

let classify_process_status (json : Yojson.Safe.t) : string option =
  match Json_util.assoc_member_opt "status" json with
  | Some (`Assoc _ as status) ->
    let kind = Safe_ops.json_string_opt "kind" status |> Option.value ~default:"unknown" in
    let op = Safe_ops.json_string_opt "op" json |> Option.value ~default:"tool" in
    begin match kind with
    | "timeout" ->
      Some (Printf.sprintf "%s_timeout" op)
    | "signaled" ->
      let signal = Safe_ops.json_int ~default:(-1) "signal" status in
      Some (Printf.sprintf "%s_signaled_%d" op signal)
    | "stopped" ->
      let signal = Safe_ops.json_int ~default:(-1) "signal" status in
      Some (Printf.sprintf "%s_stopped_%d" op signal)
    | "exit" ->
      let code = Safe_ops.json_int ~default:0 "code" status in
      if code = 0 then None else Some (Printf.sprintf "%s_exit_%d" op code)
    | _ -> None
    end
  | _ -> None

let classify_failure_output (output : string) : string =
  if String.length output = 0 then "empty_output"
  else
    let json_str =
      let prefixes = ["error: "; "tool_error: "] in
      match List.find_opt (fun p ->
        String.length output > String.length p
        && String.starts_with output ~prefix:p
      ) prefixes with
      | Some p -> String.sub output (String.length p)
                    (String.length output - String.length p)
      | None -> output
    in
    match Yojson.Safe.from_string json_str with
    | j ->
      let semantic_status =
        Safe_ops.json_string_opt "semantic_status" j |> Option.map String.trim
      in
      let failure_class =
        Safe_ops.json_string_opt "failure_class" j |> Option.map String.trim
      in
      let diagnosis = Option.value ~default:`Null (Json_util.assoc_member_opt "diagnosis" j) in
      let diagnosis_rule =
        Safe_ops.json_string_opt "rule_id" diagnosis |> Option.map String.trim
      in
      let fallback_category () =
        match Safe_ops.json_string_opt "error" j |> Option.map String.trim with
        | Some "command_blocked_readonly" ->
          (* The block payload normally carries a [category] string
             naming which readonly policy rule fired (e.g. "write",
             "exec", "network").  Dashboard groups on the full key
             [command_blocked_readonly:<category>], so a bare "unknown"
             tells the operator the rule fired but hides which policy
             class.  Use a structured marker so the operator can grep
             the source events and find the producer that omitted the
             field. *)
          let category =
            Safe_ops.json_string_opt "category" j
            |> Option.value ~default:"<missing category field>"
          in
          Printf.sprintf "command_blocked_readonly:%s" category
        | Some error when error <> "" -> normalize_failure_text error
        | _ ->
          (match Safe_ops.json_string_opt "message" j |> Option.map String.trim with
           | Some message when message <> "" -> normalize_failure_text message
           | _ ->
             classify_process_status j |> Option.value ~default:"unknown_error")
      in
      (match Safe_ops.json_string_opt "shape_block" j |> Option.map String.trim with
       | Some shape when shape <> "" -> "shape_block:" ^ shape
       | _ ->
         (match diagnosis_rule with
          | Some rule when rule <> "" -> normalize_failure_text rule
          | _ ->
            (match failure_class, semantic_status with
             | Some "workflow_rejection", Some "blocked" -> "workflow_rejection:blocked"
             | _, Some (("timeout" | "runtime_error" | "partial") as status) ->
               "semantic_status:" ^ status
             | _ -> fallback_category ())))
    | exception Yojson.Json_error _ -> "parse_error"

let bucket_key record field ~default =
  Safe_ops.json_string_opt field record |> Option.value ~default

let unknown_runtime_profile_bucket = "unknown_runtime_profile"

let runtime_bucket_key record =
  match Safe_ops.json_string_opt "runtime_profile" record with
  | Some value when String.trim value <> "" -> value
  | _ ->
    let runtime_contract = Option.value ~default:`Null (Json_util.assoc_member_opt "runtime_contract" record) in
    (match Safe_ops.json_string_opt "runtime_profile" runtime_contract with
     | Some value when String.trim value <> "" -> value
     | _ -> unknown_runtime_profile_bucket)

(* Split the two failure modes that previously collapsed to the
   bare "unknown" bucket so a non-zero count on either tells the
   operator a distinct producer fix: missing/non-bool field vs
   non-object record envelope. *)
let thinking_mode_of_record record =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "thinking_enabled" fields with
     | Some (`Bool true) -> "enabled"
     | Some (`Bool false) -> "disabled"
     | _ -> "<missing thinking_enabled field>")
  | _ -> "<non-object record envelope>"

let bool_field_opt record field =
  match record with
  | `Assoc fields ->
    (match List.assoc_opt field fields with
     | Some (`Bool value) -> Some value
     | _ -> None)
  | _ -> None

let tool_success_of_record record =
  match bool_field_opt record "semantic_success" with
  | Some value -> value
  | None ->
    (match bool_field_opt record "success" with
     | Some value -> value
     | None -> false)

let semantic_outcome_of_record record ~ok =
  match Safe_ops.json_string_opt "semantic_outcome" record with
  | Some value when String.trim value <> "" -> value
  | _ -> if ok then "success" else "tool_failure"

let hour_key_of_record record =
  let hour_of_unix ts =
    let tm = Unix.gmtime ts in
    Printf.sprintf "%04d-%02d-%02dT%02d"
      (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
      tm.Unix.tm_hour
  in
  match record with
  | `Assoc fields ->
    (match List.assoc_opt "ts" fields with
     | Some (`Float f) -> hour_of_unix f
     | Some (`Int i) -> hour_of_unix (Float.of_int i)
     | Some (`String s) when String.length s >= 13 -> String.sub s 0 13
     | Some (`String s) -> s
     | _ -> "<missing or non-numeric ts field>")
  | _ -> "<non-object record envelope>"

let update_rate_table table key ok =
  let key = if String.trim key = "" then "unknown" else key in
  let calls, successes =
    match Hashtbl.find_opt table key with
    | Some counts -> counts
    | None ->
      let counts = (ref 0, ref 0) in
      Hashtbl.replace table key counts;
      counts
  in
  incr calls;
  if ok then incr successes

let render_rate_table ~field table =
  Hashtbl.fold (fun name (c, s) acc ->
    let calls = !c in
    let successes = !s in
    let pct =
      if calls > 0
      then Float.of_int successes /. Float.of_int calls *. 100.0
      else 0.0
    in
    let failures = calls - successes in
    let failure_pct =
      if calls > 0
      then Float.of_int failures /. Float.of_int calls *. 100.0
      else 0.0
    in
    ( (calls, failures), `Assoc [
      (field, `String name);
      ("calls", `Int calls);
      ("successes", `Int successes);
      ("failures", `Int failures);
      ("success_pct", `Float (Float.round pct /. 10.0) /. 10.0);
      ("failure_pct", `Float (Float.round failure_pct /. 10.0) /. 10.0);
    ]) :: acc
  ) table []
  |> List.sort (fun ((ca, _), _) ((cb, _), _) -> Int.compare cb ca)
  |> List.map snd

let dashboard_surface = "/api/v1/dashboard/tool-quality"

let source_metadata_fields () =
  Dashboard_tool_source_freshness.keeper_tool_call_io_fields
    ~dashboard_surface ()

let empty_summary ~window_hours ~n ~sampling_mode =
  `Assoc
    (source_metadata_fields ()
    @ [ ("generated_at", `String (Masc_domain.now_iso ()))
    ; ("sampling_mode", `String sampling_mode)
    ; ( "sample_limit",
        match sampling_mode with
        | "recent_n" -> `Int n
        | _ -> `Null )
    ; ( "window_hours",
        match window_hours with
        | Some hours -> `Float hours
        | None -> `Null )
    ; ("total", `Int 0)
    ; ("success", `Int 0)
    ; ("failure", `Int 0)
    ; ("success_rate", `Float 0.0)
    ; ("failure_concentration", `Assoc [("top2_pct", `Float 0.0); ("top2_keepers", `List [])])
    ; ("by_tool", `List [])
    ; ("by_keeper", `List [])
    ; ("by_runtime", `List [])
    ; ("by_model", `List [])
    ; ("by_lane", `List [])
    ; ("by_thinking_mode", `List [])
    ; ("by_tool_choice", `List [])
    ; ("by_semantic_outcome", `List [])
    ; ("failure_categories", `List [])
    ; ("hourly_trend", `List [])
    ])

let aggregate ?(n = 5000) ?window_hours () : Yojson.Safe.t =
  let records, sampling_mode, window_hours =
    match window_hours with
    | Some hours when hours > 0.0 ->
      ( Keeper_tool_call_log.read_window ~window_hours:hours ()
      , "window_hours"
      , Some hours )
    | _ ->
      (Keeper_tool_call_log.read_recent ~n (), "recent_n", None)
  in
  if records = [] then
    empty_summary ~window_hours ~n ~sampling_mode
  else
  let total = ref 0 in
  let success = ref 0 in
  (* hourly trend: hour_key -> (calls, successes) *)
  let hourly_trend : (string, int ref * int ref) Hashtbl.t = Hashtbl.create 48 in
  (* tool -> (calls, successes, total_ms, truncated_count, total_output_chars) *)
  let tool_stats : (string, int ref * int ref * float ref * int ref * int ref) Hashtbl.t =
    Hashtbl.create 64
  in
  (* keeper -> (calls, successes) *)
  let keeper_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 16
  in
  (* model/lane/thinking/tool_choice -> (calls, successes) *)
  let runtime_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 16
  in
  let model_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 16
  in
  let lane_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 8
  in
  let thinking_mode_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 4
  in
  let tool_choice_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 8
  in
  let semantic_outcome_stats : (string, int ref * int ref) Hashtbl.t =
    Hashtbl.create 8
  in
  (* error category -> count *)
  let failure_cats : (string, int ref) Hashtbl.t = Hashtbl.create 32 in
  List.iter (fun record ->
    incr total;
    (* [tool] and [keeper] become bucket keys in the dashboard
       histogram.  A bare "unknown" bucket appears in the same column
       as a legitimate tool named "unknown", so the operator cannot
       tell "the tool field was missing from N records" apart from
       "tool 'unknown' was invoked N times".  Use structured markers
       so a non-zero bucket on either is a producer-side fix
       signal. *)
    let tool =
      Safe_ops.json_string_opt "tool" record
      |> Option.value ~default:"<missing tool field>"
    in
    let keeper =
      Safe_ops.json_string_opt "keeper" record
      |> Option.value ~default:"<missing keeper field>"
    in
    let ok = tool_success_of_record record in
    let semantic_outcome = semantic_outcome_of_record record ~ok in
    let dur = match record with
      | `Assoc fields ->
        (match List.assoc_opt "duration_ms" fields with
         | Some (`Float f) -> f
         | Some (`Int i) -> Float.of_int i
         | _ -> 0.0)
      | _ -> 0.0
    in
    let output_chars = match record with
      | `Assoc fields ->
        (match List.assoc_opt "result_bytes" fields with
         | Some (`Int i) -> i
         | _ ->
           (* Fallback for old entries that pre-date [result_bytes].
              Output may be either an inline string (legacy) or a
              normalized blob object {"_blob":{...,"bytes":N,...}}
              (new format introduced when marker double-escape was
              eliminated from the telemetry layer). *)
           (match List.assoc_opt "output" fields with
            | Some (`String s) -> String.length s
            | Some (`Assoc [("_blob", `Assoc blob)]) ->
              (match List.assoc_opt "bytes" blob with
               | Some (`Int n) -> n
               | _ -> 0)
            | _ -> 0))
      | _ -> 0
    in
    let was_truncated = match record with
      | `Assoc fields -> List.assoc_opt "truncated_to" fields <> None
      | _ -> false
    in
    if ok then incr success;
    (* hourly trend bucketing *)
    let hour_key = hour_key_of_record record in
    let (hc, hs) =
      match Hashtbl.find_opt hourly_trend hour_key with
      | Some v -> v
      | None ->
        let v = (ref 0, ref 0) in
        Hashtbl.replace hourly_trend hour_key v; v
    in
    incr hc; if ok then incr hs;
    (* tool stats *)
    let (tc, ts, td, ttrunc, tochars) =
      match Hashtbl.find_opt tool_stats tool with
      | Some v -> v
      | None ->
        let v = (ref 0, ref 0, ref 0.0, ref 0, ref 0) in
        Hashtbl.replace tool_stats tool v; v
    in
    incr tc; if ok then incr ts; td := !td +. dur;
    tochars := !tochars + output_chars;
    if was_truncated then incr ttrunc;
    (* keeper stats *)
    let (kc, ks) =
      match Hashtbl.find_opt keeper_stats keeper with
      | Some v -> v
      | None ->
        let v = (ref 0, ref 0) in
        Hashtbl.replace keeper_stats keeper v; v
    in
    incr kc; if ok then incr ks;
    update_rate_table runtime_stats (runtime_bucket_key record) ok;
    update_rate_table model_stats (bucket_key record "model" ~default:"unknown") ok;
    update_rate_table lane_stats (bucket_key record "lane" ~default:"unknown") ok;
    update_rate_table thinking_mode_stats (thinking_mode_of_record record) ok;
    update_rate_table tool_choice_stats
      (bucket_key record "tool_choice" ~default:"unknown") ok;
    update_rate_table semantic_outcome_stats semantic_outcome ok;
    (* failure category *)
    if not ok then begin
      let output =
        match record with
        | `Assoc fields ->
          (match List.assoc_opt "output" fields with
           | Some (`String s) -> s
           | Some (`Assoc [("_blob", `Assoc blob)]) ->
             (* Normalized blob object — failure classifier wants the
                preview (where the error JSON body lives) rather than
                the marker envelope. *)
             (match List.assoc_opt "preview" blob with
              | Some (`String p) -> p
              | _ -> "")
           | _ -> "")
        | _ -> ""
      in
      let cat =
        match semantic_outcome with
        | "policy_denied" | "structured_error" -> semantic_outcome
        | _ -> classify_failure_output output
      in
      let r = match Hashtbl.find_opt failure_cats cat with
        | Some r -> r
        | None -> let r = ref 0 in Hashtbl.replace failure_cats cat r; r
      in
      incr r
    end
  ) records;
  let total_n = !total in
  let success_n = !success in
  let rate =
    if total_n = 0 then 0.0
    else Float.of_int success_n /. Float.of_int total_n *. 100.0
  in
  (* Sort by call count descending *)
  let by_tool =
    Hashtbl.fold (fun name (c, s, d, ttrunc, tochars) acc ->
      let calls = !c in
      let successes = !s in
      let avg_ms = if calls > 0 then !d /. Float.of_int calls else 0.0 in
      let pct = if calls > 0
        then Float.of_int successes /. Float.of_int calls *. 100.0
        else 0.0
      in
      let avg_output = if calls > 0
        then Float.of_int !tochars /. Float.of_int calls
        else 0.0
      in
      (calls, `Assoc [
        ("name", `String name);
        ("calls", `Int calls);
        ("success_pct", `Float pct);
        ("avg_ms", `Float (Float.round (avg_ms *. 10.0) /. 10.0));
        ("output_truncated_count", `Int !ttrunc);
        ("avg_output_chars", `Float (Float.round (avg_output *. 10.0) /. 10.0));
      ]) :: acc
    ) tool_stats []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd
  in
  let by_keeper =
    render_rate_table ~field:"name" keeper_stats
  in
  let failure_concentration =
    let total_failures = total_n - success_n in
    if total_failures = 0 then
      (`Float 0.0, `List [])
    else
      let keepers =
        Hashtbl.fold (fun name (c, s) acc ->
          let calls = !c in
          let failures = calls - !s in
          if failures > 0 then (name, failures) :: acc else acc
        ) keeper_stats []
        |> List.sort (fun (_, a) (_, b) -> Int.compare b a)
      in
      let top2 =
        let rec sum n acc = function
          | [] -> acc
          | (_, f) :: rest when n > 0 -> sum (n - 1) (acc + f) rest
          | _ -> acc
        in
        sum 2 0 keepers
      in
      let pct =
        Float.round
          (Float.of_int top2 /. Float.of_int total_failures *. 1000.0)
        /. 10.0
      in
      let top2_names =
        let rec take n acc = function
          | [] -> List.rev acc
          | (name, _) :: rest when n > 0 -> take (n - 1) (name :: acc) rest
          | _ -> List.rev acc
        in
        take 2 [] keepers
      in
      (`Float pct, `List (List.map (fun n -> `String n) top2_names))
  in
  let by_runtime = render_rate_table ~field:"name" runtime_stats in
  let by_model = render_rate_table ~field:"name" model_stats in
  let by_lane = render_rate_table ~field:"name" lane_stats in
  let by_thinking_mode =
    render_rate_table ~field:"name" thinking_mode_stats
  in
  let by_tool_choice =
    render_rate_table ~field:"name" tool_choice_stats
  in
  let by_semantic_outcome =
    render_rate_table ~field:"name" semantic_outcome_stats
  in
  let failure_categories =
    Hashtbl.fold (fun cat r acc ->
      (!r, `Assoc [("category", `String cat); ("count", `Int !r)]) :: acc
    ) failure_cats []
    |> List.sort (fun (a, _) (b, _) -> Int.compare b a)
    |> List.map snd
  in
  let hourly =
    Hashtbl.fold (fun hour (c, s) acc ->
      let calls = !c in
      let successes = !s in
      let pct = if calls > 0
        then Float.of_int successes /. Float.of_int calls *. 100.0
        else 0.0
      in
      (hour, `Assoc [
        ("hour", `String hour);
        ("calls", `Int calls);
        ("success", `Int successes);
        ("success_rate", `Float (Float.round (pct *. 10.0) /. 10.0));
      ]) :: acc
    ) hourly_trend []
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map snd
  in
  `Assoc (
    source_metadata_fields ()
    @ [
    ("generated_at", `String (Masc_domain.now_iso ()));
    ("sampling_mode", `String sampling_mode);
    ( "sample_limit",
      match sampling_mode with
      | "recent_n" -> `Int n
      | _ -> `Null );
    ( "window_hours",
      match window_hours with
      | Some hours -> `Float hours
      | None -> `Null );
    ("total", `Int total_n);
    ("success", `Int success_n);
    ("failure", `Int (total_n - success_n));
    ("success_rate", `Float (Float.round (rate *. 100.0) /. 100.0));
    ("failure_concentration", `Assoc [
      ("top2_pct", fst failure_concentration);
      ("top2_keepers", snd failure_concentration);
    ]);
    ("by_tool", `List by_tool);
    ("by_keeper", `List by_keeper);
    ("by_runtime", `List by_runtime);
    ("by_model", `List by_model);
    ("by_lane", `List by_lane);
    ("by_thinking_mode", `List by_thinking_mode);
    ("by_tool_choice", `List by_tool_choice);
    ("by_semantic_outcome", `List by_semantic_outcome);
    ("failure_categories", `List failure_categories);
    ("hourly_trend", `List hourly);
  ])
