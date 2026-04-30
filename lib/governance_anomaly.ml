open Governance_pipeline_types

(* ── Types ────────────────────────────────────────────────── *)

type stat = {
  mean : float;
  stddev : float;
}

type behavioral_profile = {
  agent_id : string;
  window_days : int;
  sample_count : int;
  activity_volume : stat;
  tool_diversity : stat;
  token_volume : stat option;
  failure_rate : stat;
  hourly_dist : float array;
  updated_at : float;
}

type deviation = {
  dimension : string;
  observed : float;
  expected : float;
  z_score : float;
  severity : risk_level;
}

type anomaly_report = {
  agent_id : string;
  generated_at : float;
  deviations : deviation list;
  overall_risk : risk_level;
}

(* ── Math helpers ─────────────────────────────────────────── *)

let mean values =
  let n = float_of_int (List.length values) in
  if n = 0.0 then 0.0 else List.fold_left (+.) 0.0 values /. n

let stddev values =
  let n = List.length values in
  if n <= 1 then 0.0
  else
    let m = mean values in
    let sq = List.fold_left (fun acc v -> acc +. ((v -. m) *.(v -. m))) 0.0 values in
    sqrt (sq /. float_of_int n)

let z_score ~observed ~mean ~stddev =
  if stddev <= 0.0 then 0.0 else (observed -. mean) /. stddev

let severity_of_z z =
  let a = abs_float z in
  if a < 1.0 then Low
  else if a < 2.0 then Medium
  else if a < 3.0 then High
  else Critical

let max_risk left right =
  if risk_level_to_int left >= risk_level_to_int right then left else right

(* ── Metric extraction from entries ───────────────────────── *)

let tool_name_of_action = function
  | Audit_log.ToolCall name -> Some name
  | _ -> None

(** Span of a batch in hours, floored at one minute to avoid /0. *)
let batch_span_hours entries =
  match entries with
  | [] -> 1.0
  | first :: rest ->
      let first_t = first.Audit_log.timestamp in
      let min_t, max_t =
        List.fold_left
          (fun (min_t, max_t) e ->
            let t = e.Audit_log.timestamp in
            (min min_t t, max max_t t))
          (first_t, first_t) rest
      in
      let span_h = (max_t -. min_t) /. 3600.0 in
      max span_h 0.0167

let activity_volume_of_batch entries =
  let hours = batch_span_hours entries in
  float_of_int (List.length entries) /. hours

let tool_diversity_of_batch entries =
  let tool_calls = List.filter_map (fun e -> tool_name_of_action e.Audit_log.action) entries in
  let total = List.length tool_calls in
  if total = 0 then 0.0
  else
    let unique = List.sort_uniq String.compare tool_calls |> List.length in
    float_of_int unique /. float_of_int total

let token_volume_of_batch entries =
  let counts = List.filter_map (fun e -> e.Audit_log.token_count) entries in
  let n = List.length counts in
  if n = 0 then None
  else
    Some (float_of_int (List.fold_left (+) 0 counts) /. float_of_int n)

let failure_rate_of_batch entries =
  let n = List.length entries in
  if n = 0 then 0.0
  else
    let failures =
      List.filter
        (fun e ->
          match e.Audit_log.outcome with
          | Audit_log.Failure _ -> true
          | _ -> false)
        entries
    in
    float_of_int (List.length failures) /. float_of_int n

let hourly_dist_of_entries entries =
  let arr = Array.make 24 0 in
  List.iter
    (fun e ->
      let tm = Unix.localtime e.Audit_log.timestamp in
      let hour = tm.Unix.tm_hour in
      let hour = if hour < 0 then 0 else if hour > 23 then 23 else hour in
      arr.(hour) <- arr.(hour) + 1)
    entries;
  let total = Array.fold_left (+) 0 arr in
  if total = 0 then Array.make 24 (1.0 /. 24.0)
  else Array.map (fun c -> float_of_int c /. float_of_int total) arr

(** Chop [entries] into chronological batches of ~[batch_hours] each. *)
let batch_entries ~batch_hours entries =
  if entries = [] then []
  else
    let sorted =
      List.sort (fun a b -> Float.compare a.Audit_log.timestamp b.Audit_log.timestamp) entries
    in
    let span_sec = float_of_int batch_hours *. 3600.0 in
    let rec split batch_start batch_acc acc = function
      | [] ->
          let final = List.rev batch_acc in
          if final = [] then List.rev acc else List.rev (final :: acc)
      | e :: rest ->
          if e.Audit_log.timestamp -. batch_start <= span_sec then
            split batch_start (e :: batch_acc) acc rest
          else
            let next_acc = if batch_acc = [] then acc else List.rev batch_acc :: acc in
            split e.Audit_log.timestamp [e] next_acc rest
    in
    match sorted with
    | first :: rest -> split first.Audit_log.timestamp [first] [] rest
    | [] -> []

(* ── Profile construction ─────────────────────────────────── *)

let build_profile ~config ~agent_id ~window_days =
  let entries =
    Audit_log.read_entries ~n:50_000 config
    |> List.filter (fun e -> String.equal e.Audit_log.agent_id agent_id)
  in
  if List.length entries < 3 then None
  else
    let cutoff = Unix.gettimeofday () -. (float_of_int window_days *. 86400.0) in
    let recent = List.filter (fun e -> e.Audit_log.timestamp >= cutoff) entries in
    if List.length recent < 3 then None
    else
      let batches = batch_entries ~batch_hours:6 recent in
      if batches = [] then None
      else
        let activity_volumes = List.map activity_volume_of_batch batches in
        let tool_diversities = List.map tool_diversity_of_batch batches in
        let token_volumes = List.filter_map token_volume_of_batch batches in
        let failure_rates = List.map failure_rate_of_batch batches in
        let activity_stat = { mean = mean activity_volumes; stddev = stddev activity_volumes } in
        let diversity_stat = { mean = mean tool_diversities; stddev = stddev tool_diversities } in
        let token_stat =
          if token_volumes = [] then None
          else Some { mean = mean token_volumes; stddev = stddev token_volumes }
        in
        let failure_stat = { mean = mean failure_rates; stddev = stddev failure_rates } in
        let hourly = hourly_dist_of_entries recent in
        Some
          {
            agent_id;
            window_days;
            sample_count = List.length recent;
            activity_volume = activity_stat;
            tool_diversity = diversity_stat;
            token_volume = token_stat;
            failure_rate = failure_stat;
            hourly_dist = hourly;
            updated_at = Unix.gettimeofday ();
          }

(* ── JSON projection ──────────────────────────────────────── *)

let stat_json s = `Assoc [("mean", `Float s.mean); ("stddev", `Float s.stddev)]

let profile_json p =
  let token_json =
    match p.token_volume with
    | Some s -> stat_json s
    | None -> `Assoc [("mean", `Null); ("stddev", `Null)]
  in
  `Assoc
    [
      ("agent_id", `String p.agent_id);
      ("window_days", `Int p.window_days);
      ("sample_count", `Int p.sample_count);
      ("activity_volume", stat_json p.activity_volume);
      ("tool_diversity", stat_json p.tool_diversity);
      ("token_volume", token_json);
      ("failure_rate", stat_json p.failure_rate);
      ("hourly_dist", `List (Array.to_list p.hourly_dist |> List.map (fun f -> `Float f)));
      ("updated_at", `Float p.updated_at);
    ]

let deviation_json d =
  `Assoc
    [
      ("dimension", `String d.dimension);
      ("observed", `Float d.observed);
      ("expected", `Float d.expected);
      ("z_score", `Float d.z_score);
      ("severity", `String (risk_level_to_string d.severity));
    ]

let report_json r =
  `Assoc
    [
      ("agent_id", `String r.agent_id);
      ("generated_at", `Float r.generated_at);
      ("overall_risk", `String (risk_level_to_string r.overall_risk));
      ("deviations", `List (List.map deviation_json r.deviations));
    ]

(* ── Persistence ──────────────────────────────────────────── *)

let baseline_dir base_path =
  Filename.concat (Coord_utils.masc_dir_from_base_path ~base_path) "governance"
  |> fun d -> Filename.concat d "baselines"

let profile_path base_path agent_id =
  Filename.concat (baseline_dir base_path) (agent_id ^ ".json")

let ensure_dir path = Fs_compat.mkdir_p path

let save_profile ~base_path (profile : behavioral_profile) =
  let path = profile_path base_path profile.agent_id in
  ensure_dir (Filename.dirname path);
  let json = profile_json profile in
  Fs_compat.save_file path (Yojson.Safe.pretty_to_string json)

let load_profile ~base_path ~agent_id =
  let path = profile_path base_path agent_id in
  if not (Sys.file_exists path) then None
  else
    match Safe_ops.read_file_safe path with
    | Error msg ->
        Log.Misc.warn "governance_anomaly: failed to read profile %s: %s" path msg;
        None
    | Ok content -> (
        try
          let json = Yojson.Safe.from_string content in
          match json with
          | `Assoc fields ->
              let get_float key =
                match List.assoc_opt key fields with
                | Some (`Float f) -> Some f
                | Some (`Int i) -> Some (float_of_int i)
                | _ -> None
              in
              let get_string key =
                match List.assoc_opt key fields with
                | Some (`String s) -> Some s
                | _ -> None
              in
              let get_int key =
                match List.assoc_opt key fields with
                | Some (`Int i) -> Some i
                | Some (`Float f) -> Some (int_of_float f)
                | _ -> None
              in
              let get_stat key =
                match List.assoc_opt key fields with
                | Some (`Assoc stat_fields) -> (
                    let mean =
                      match List.assoc_opt "mean" stat_fields with
                      | Some (`Float f) -> Some f
                      | Some (`Int i) -> Some (float_of_int i)
                      | _ -> None
                    in
                    let stddev =
                      match List.assoc_opt "stddev" stat_fields with
                      | Some (`Float f) -> Some f
                      | Some (`Int i) -> Some (float_of_int i)
                      | _ -> None
                    in
                    match (mean, stddev) with
                    | Some m, Some s -> Some { mean = m; stddev = s }
                    | _ -> None)
                | _ -> None
              in
              (match (get_string "agent_id", get_int "window_days", get_int "sample_count") with
              | Some agent_id, Some window_days, Some sample_count -> (
                  match
                    ( get_stat "activity_volume",
                      get_stat "tool_diversity",
                      get_stat "failure_rate" )
                  with
                  | Some activity_volume, Some tool_diversity, Some failure_rate ->
                      let token_volume = get_stat "token_volume" in
                      let hourly_dist =
                        match List.assoc_opt "hourly_dist" fields with
                        | Some (`List items) ->
                            Array.of_list
                              (List.filter_map
                                 (function
                                   | `Float f -> Some f
                                   | `Int i -> Some (float_of_int i)
                                   | _ -> None)
                                 items)
                        | _ -> Array.make 24 (1.0 /. 24.0)
                      in
                      let updated_at =
                        match get_float "updated_at" with
                        | Some f -> f
                        | None -> Unix.gettimeofday ()
                      in
                      Some
                        {
                          agent_id;
                          window_days;
                          sample_count;
                          activity_volume;
                          tool_diversity;
                          token_volume;
                          failure_rate;
                          hourly_dist;
                          updated_at;
                        }
                  | _ -> None)
              | _ -> None)
          | _ -> None
        with
        | Yojson.Json_error _ -> None
        | exn ->
            Log.Governance.warn "load_profile parse error: %s" (Printexc.to_string exn);
            None)

(* ── Deviation detection ──────────────────────────────────── *)

let detect_deviations ~profile ~entries ~threshold =
  if entries = [] then []
  else
    let observed_activity = activity_volume_of_batch entries in
    let observed_diversity = tool_diversity_of_batch entries in
    let observed_token = token_volume_of_batch entries in
    let observed_failure = failure_rate_of_batch entries in
    let deviations = ref [] in
    let add dimension observed expected stat =
      let z = z_score ~observed ~mean:stat.mean ~stddev:stat.stddev in
      if abs_float z >= threshold then
        deviations :=
          { dimension; observed; expected = stat.mean; z_score = z; severity = severity_of_z z }
          :: !deviations
    in
    add "activity_volume" observed_activity profile.activity_volume.mean profile.activity_volume;
    add "tool_diversity" observed_diversity profile.tool_diversity.mean profile.tool_diversity;
    (match (observed_token, profile.token_volume) with
    | Some obs, Some stat -> add "token_volume" obs stat.mean stat
    | _ -> ());
    add "failure_rate" observed_failure profile.failure_rate.mean profile.failure_rate;
    List.rev !deviations

(* ── Top-level convenience ────────────────────────────────── *)

let check_agent ~config ~agent_id ~window_days ~threshold =
  let entries =
    Audit_log.read_entries ~n:50_000 config
    |> List.filter (fun e -> String.equal e.Audit_log.agent_id agent_id)
  in
  if List.length entries < 3 then None
  else
    let profile_opt =
      match load_profile ~base_path:config.Coord.base_path ~agent_id with
      | Some p when p.sample_count >= 3 && p.window_days = window_days -> Some p
      | _ -> build_profile ~config ~agent_id ~window_days
    in
    match profile_opt with
    | None -> None
    | Some profile ->
        save_profile ~base_path:config.Coord.base_path profile;
        let cutoff = Unix.gettimeofday () -. 3600.0 in
        let recent = List.filter (fun e -> e.Audit_log.timestamp >= cutoff) entries in
        let deviations = detect_deviations ~profile ~entries:recent ~threshold in
        let overall_risk = List.fold_left (fun acc d -> max_risk acc d.severity) Low deviations in
        Some { agent_id; generated_at = Unix.gettimeofday (); deviations; overall_risk }
