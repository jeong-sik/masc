module U = Yojson.Safe.Util

type strategy =
  | Legacy
  | Best_first_v1

type operation_descriptor = {
  operation_id : string option;
  objective : string;
  assigned_unit_id : string option;
  workload_profile : string;
  stage : string option;
  artifact_scope : string list;
  depends_on_operation_ids : string list;
  created_at : string;
}

type upstream_operation = {
  operation_id : string;
  status : string;
  checkpoint_ref : string option;
}

type dependency_blocker = {
  operation_id : string;
  reason : string;
}

type readiness =
  | Ready
  | Blocked of dependency_blocker list

type candidate_input = {
  unit_id : string;
  label : string;
  capability_profile : string list;
  active_operation_cap : int;
  active_operations : int;
  current_assignment : bool;
}

type stats_entry = {
  unit_id : string;
  workload_profile : string;
  stage : string option;
  alpha : float;
  beta : float;
  updated_at : string;
}

type score_breakdown = {
  capability_match : float;
  artifact_locality : float;
  intent_successor : float;
  verification_readiness : float;
  runtime_fit : float;
  posterior_success : float;
  capacity_headroom : float;
  cost_efficiency : float;
  queue_age : float;
  stickiness : float;
  total : float;
}

type scored_candidate = {
  unit_id : string;
  label : string;
  breakdown : score_breakdown;
  routing_reason : string;
}

type stats_store = stats_entry list

let strategy_to_string = function
  | Legacy -> "legacy"
  | Best_first_v1 -> "best_first_v1"

let strategy_of_string = function
  | Some "best_first_v1" -> Best_first_v1
  | Some "legacy" -> Legacy
  | _ -> Legacy

let normalized_workload_profile raw =
  match String.trim raw |> String.lowercase_ascii with
  | "" | "generic" -> "coding_task"
  | "coding_task" -> "coding_task"
  | "research_pipeline" -> "research_pipeline"
  | other -> other

let normalized_stage = function
  | Some raw ->
      let lowered = String.trim raw |> String.lowercase_ascii in
      if lowered = "" || lowered = "generic" then None else Some lowered
  | None -> None

let default_store = []

let now_iso () = Types.now_iso ()

let ensure_dir path =
  Fs_compat.mkdir_p path

let json_list_of_strings xs =
  `List (List.map (fun value -> `String value) xs)

let stats_entry_to_json (entry : stats_entry) =
  `Assoc
    [
      ("unit_id", `String entry.unit_id);
      ("workload_profile", `String entry.workload_profile);
      ("stage", Json_util.string_opt_to_json entry.stage);
      ("alpha", `Float entry.alpha);
      ("beta", `Float entry.beta);
      ("updated_at", `String entry.updated_at);
    ]

let stats_entry_of_json json =
  try
    let unit_id = json |> U.member "unit_id" |> U.to_string in
    let workload_profile =
      json |> U.member "workload_profile" |> U.to_string_option
      |> Option.value ~default:"coding_task"
      |> normalized_workload_profile
    in
    let stage =
      json |> U.member "stage" |> U.to_string_option |> normalized_stage
    in
    let alpha = json |> U.member "alpha" |> U.to_float in
    let beta = json |> U.member "beta" |> U.to_float in
    let updated_at =
      json |> U.member "updated_at" |> U.to_string_option |> Option.value ~default:(now_iso ())
    in
    if unit_id = "" then
      None
    else
      Some { unit_id; workload_profile; stage; alpha; beta; updated_at }
  with Yojson.Safe.Util.Type_error _ -> None

let load_store path : stats_store =
  if not (Sys.file_exists path) then
    default_store
  else
    try
      match Safe_ops.read_json_eio path with
      | `Assoc fields -> (
          match List.assoc_opt "entries" fields with
          | Some (`List rows) -> List.filter_map stats_entry_of_json rows
          | _ -> default_store)
      | `List rows -> List.filter_map stats_entry_of_json rows
      | _ -> default_store
    with Yojson.Json_error _ | Sys_error _ | Eio.Io _ -> default_store

let save_store path (store : stats_store) =
  ensure_dir (Filename.dirname path);
  Yojson.Safe.to_file path
    (`Assoc
      [
        ("generated_at", `String (now_iso ()));
        ("entries", `List (List.map stats_entry_to_json store));
      ])

let same_stage left right =
  Option.equal String.equal (normalized_stage left) (normalized_stage right)

let lookup_stats (store : stats_store) ~unit_id ~workload_profile ~stage =
  let workload_profile = normalized_workload_profile workload_profile in
  let stage = normalized_stage stage in
  match
    store
    |> List.find_opt (fun (entry : stats_entry) ->
           String.equal entry.unit_id unit_id
           && String.equal (normalized_workload_profile entry.workload_profile)
                workload_profile
           && same_stage entry.stage stage)
  with
  | Some entry -> { entry with workload_profile; stage }
  | None ->
      {
        unit_id;
        workload_profile;
        stage;
        alpha = 1.0;
        beta = 1.0;
        updated_at = now_iso ();
      }

let upsert_stats (store : stats_store) (entry : stats_entry) =
  entry
  :: List.filter
       (fun (current : stats_entry) ->
         not
           (String.equal current.unit_id entry.unit_id
            && String.equal (normalized_workload_profile current.workload_profile)
                 (normalized_workload_profile entry.workload_profile)
            && same_stage current.stage entry.stage))
       store

let record_success (store : stats_store) ~unit_id ~workload_profile ~stage =
  let current = lookup_stats store ~unit_id ~workload_profile ~stage in
  upsert_stats store
    { current with alpha = current.alpha +. 1.0; updated_at = now_iso () }

let record_failure (store : stats_store) ~unit_id ~workload_profile ~stage =
  let current = lookup_stats store ~unit_id ~workload_profile ~stage in
  upsert_stats store
    { current with beta = current.beta +. 1.0; updated_at = now_iso () }

let blocker_to_json (blocker : dependency_blocker) =
  `Assoc
    [
      ("operation_id", `String blocker.operation_id);
      ("reason", `String blocker.reason);
    ]

let breakdown_to_json (breakdown : score_breakdown) =
  `Assoc
    [
      ("capability_match", `Float breakdown.capability_match);
      ("artifact_locality", `Float breakdown.artifact_locality);
      ("intent_successor", `Float breakdown.intent_successor);
      ("verification_readiness", `Float breakdown.verification_readiness);
      ("runtime_fit", `Float breakdown.runtime_fit);
      ("posterior_success", `Float breakdown.posterior_success);
      ("capacity_headroom", `Float breakdown.capacity_headroom);
      ("cost_efficiency", `Float breakdown.cost_efficiency);
      ("queue_age", `Float breakdown.queue_age);
      ("stickiness", `Float breakdown.stickiness);
      ("total", `Float breakdown.total);
    ]

let scored_candidate_to_json (candidate : scored_candidate) =
  `Assoc
    [
      ("unit_id", `String candidate.unit_id);
      ("label", `String candidate.label);
      ("score", `Float candidate.breakdown.total);
      ("score_breakdown", breakdown_to_json candidate.breakdown);
      ("routing_reason", `String candidate.routing_reason);
    ]

let readiness_to_json = function
  | Ready -> `String "ready"
  | Blocked blockers ->
      `Assoc
        [
          ("status", `String "blocked");
          ("dependency_blockers", `List (List.map blocker_to_json blockers));
        ]

let parse_iso_timestamp iso =
  try
    Scanf.sscanf iso "%d-%d-%dT%d:%d:%dZ" (fun year mon day hour min sec ->
        let tm =
          {
            Unix.tm_sec = sec;
            Unix.tm_min = min;
            Unix.tm_hour = hour;
            Unix.tm_mday = day;
            Unix.tm_mon = mon - 1;
            Unix.tm_year = year - 1900;
            Unix.tm_wday = 0;
            Unix.tm_yday = 0;
            Unix.tm_isdst = false;
          }
        in
        let local_epoch, _ = Unix.mktime tm in
        let utc_as_local, _ = Unix.mktime (Unix.gmtime local_epoch) in
        let tz_offset = local_epoch -. utc_as_local in
        Some (local_epoch +. tz_offset))
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None

let stop_words =
  [
    "the";
    "and";
    "for";
    "with";
    "from";
    "that";
    "this";
    "into";
    "then";
    "stage";
    "pipeline";
    "operation";
    "managed";
  ]

let normalize_word raw =
  let buf = Buffer.create (String.length raw) in
  String.iter
    (fun ch ->
      match ch with
      | 'a' .. 'z' | '0' .. '9' -> Buffer.add_char buf ch
      | 'A' .. 'Z' -> Buffer.add_char buf (Char.lowercase_ascii ch)
      | _ -> ())
    raw;
  Buffer.contents buf

let extract_keywords text =
  text
  |> String.split_on_char ' '
  |> List.concat_map (String.split_on_char '-')
  |> List.concat_map (String.split_on_char '_')
  |> List.map normalize_word
  |> List.filter (fun word -> String.length word >= 3)
  |> List.filter (fun word -> not (List.mem word stop_words))
  |> List.sort_uniq String.compare

let path_keywords path =
  path
  |> String.split_on_char '/'
  |> List.concat_map (fun part ->
         let trimmed = String.trim part in
         if trimmed = "" then [] else part :: String.split_on_char '.' part)
  |> List.concat_map extract_keywords

let extract_tag_value prefix raw =
  let prefix = String.lowercase_ascii prefix ^ ":" in
  let lowered = String.lowercase_ascii (String.trim raw) in
  let prefix_len = String.length prefix in
  if String.length lowered > prefix_len
     && String.sub lowered 0 prefix_len = prefix
  then
    Some (String.sub lowered prefix_len (String.length lowered - prefix_len))
  else
    None

let tag_values prefix xs =
  xs |> List.filter_map (extract_tag_value prefix)

let has_tag prefix xs = tag_values prefix xs <> []

let any_contains needles haystack =
  List.exists (fun needle ->
      let needle = String.lowercase_ascii needle in
      List.exists
        (fun value ->
          let value = String.lowercase_ascii value in
          let needle_len = String.length needle in
          let value_len = String.length value in
          let rec loop idx =
            if needle_len = 0 then true
            else if idx > value_len - needle_len then false
            else if String.sub value idx needle_len = needle then true
            else loop (idx + 1)
          in
          needle_len > 0 && value_len >= needle_len && loop 0)
        haystack)
    needles

let demand_keywords (operation : operation_descriptor) =
  let profile_keyword =
    match normalized_workload_profile operation.workload_profile with
    | "" -> []
    | profile -> [ profile ]
  in
  let stage_keyword =
    match operation.stage with
      | Some stage when String.trim stage <> "" -> [ String.lowercase_ascii (String.trim stage) ]
      | _ -> []
  in
  let objective_keywords = extract_keywords operation.objective in
  let artifact_keywords =
    operation.artifact_scope |> List.concat_map path_keywords
  in
  List.sort_uniq String.compare
    (profile_keyword @ stage_keyword @ objective_keywords @ artifact_keywords)

let candidate_keywords (candidate : candidate_input) =
  let id_keywords = extract_keywords candidate.unit_id in
  let label_keywords = extract_keywords candidate.label in
  let capability_keywords =
    candidate.capability_profile
    |> List.map String.lowercase_ascii
    |> List.concat_map (fun raw ->
           raw
           :: (match String.split_on_char ':' raw with
              | [] -> []
              | _prefix :: rest -> rest)
           |> List.concat_map extract_keywords)
  in
  List.sort_uniq String.compare
    (id_keywords @ label_keywords @ capability_keywords)

let keyword_overlap reference candidate =
  if reference = [] then
    0.0
  else
    let matches =
      reference
      |> List.filter (fun needed ->
             List.exists
               (fun current ->
                 String.equal needed current
                 || (String.length current >= 3
                    && String.length needed >= 3
                    && (String.contains current needed.[0] || String.contains needed current.[0])
                    &&
                    let shorter, longer =
                      if String.length needed <= String.length current then
                        (needed, current)
                      else
                        (current, needed)
                    in
                    let shorter_len = String.length shorter in
                    let longer_len = String.length longer in
                    let rec loop idx =
                      if idx > longer_len - shorter_len then
                        false
                      else if String.sub longer idx shorter_len = shorter then
                        true
                      else
                        loop (idx + 1)
                    in
                    loop 0))
               candidate)
    in
    float_of_int (List.length matches) /. float_of_int (List.length reference)

let readiness_for_operation ~(upstreams : upstream_operation list) :
    readiness =
  let blockers =
    upstreams
    |> List.filter_map (fun upstream ->
           let done_by_status =
             match String.lowercase_ascii upstream.status with
             | "completed" -> true
             | _ -> false
           in
           let done_by_checkpoint = Option.is_some upstream.checkpoint_ref in
           if done_by_status || done_by_checkpoint then
             None
           else
             Some
               {
                 operation_id = upstream.operation_id;
                 reason =
                   (match upstream.checkpoint_ref with
                   | Some _ -> "upstream_pending_commit"
                   | None -> "upstream_incomplete");
               })
  in
  if blockers = [] then Ready else Blocked blockers

let posterior_mean entry =
  entry.alpha /. (entry.alpha +. entry.beta)

let clamp min_v max_v value =
  max min_v (min max_v value)

let queue_age_score created_at =
  match parse_iso_timestamp created_at with
  | None -> 0.0
  | Some ts ->
      let age_sec = max 0.0 (Unix.gettimeofday () -. ts) in
      let normalized = min 1.0 (age_sec /. 3600.0) in
      normalized *. 10.0

let capacity_score (candidate : candidate_input) =
  if candidate.active_operation_cap <= 0 then
    0.0
  else
    let free_slots =
      max 0 (candidate.active_operation_cap - candidate.active_operations)
    in
    let ratio =
      float_of_int free_slots /. float_of_int candidate.active_operation_cap
    in
    min 10.0 (ratio *. 10.0)

let capability_score (operation : operation_descriptor)
    (candidate : candidate_input) =
  let demand = demand_keywords operation in
  let supply = candidate_keywords candidate in
  let stage_bonus =
    match operation.stage with
    | Some stage ->
        let stage_key = normalize_word stage in
        if stage_key <> "" && List.mem stage_key supply then 10.0 else 0.0
    | None -> 0.0
  in
  min 25.0 (stage_bonus +. (keyword_overlap demand supply *. 15.0))

let artifact_locality_score (operation : operation_descriptor)
    (candidate : candidate_input) =
  let workload_profile = normalized_workload_profile operation.workload_profile in
  let scope_keywords = operation.artifact_scope |> List.concat_map path_keywords in
  match scope_keywords with
  | [] -> (
      match workload_profile, normalized_stage operation.stage with
      | "coding_task", Some "decompose" -> 10.0
      | _ -> 0.0)
  | _ -> min 20.0 (keyword_overlap scope_keywords (candidate_keywords candidate) *. 20.0)

let runtime_fit_score (operation : operation_descriptor)
    (candidate : candidate_input) =
  let runtime_tags = tag_values "runtime" candidate.capability_profile in
  let model_tags = tag_values "model" candidate.capability_profile in
  let tool_tags = tag_values "tool" candidate.capability_profile in
  let base =
    (if runtime_tags <> [] then 7.5 else 0.0)
    +. if model_tags <> [] then 7.5 else 0.0
  in
  match normalized_workload_profile operation.workload_profile, normalized_stage operation.stage with
  | "coding_task", Some ("implement" | "verify") when tool_tags <> [] ->
      min 15.0 (base +. 3.0)
  | "coding_task", Some ("inspect" | "review")
    when runtime_tags <> [] && model_tags <> [] ->
      15.0
  | _ -> min 15.0 base

let cost_efficiency_score (candidate : candidate_input) =
  let runtime_tags = tag_values "runtime" candidate.capability_profile in
  let model_tags = tag_values "model" candidate.capability_profile in
  let cheap_hints =
    runtime_tags @ model_tags @ candidate.capability_profile
  in
  if any_contains [ "local64"; "cheap"; "small"; "mini"; "flash"; "q8"; "1b"; "3b"; "7b" ] cheap_hints then
    5.0
  else if model_tags <> [] then
    2.5
  else
    0.0

let candidate_breakdown ~store ~(operation : operation_descriptor)
    (candidate : candidate_input) =
  let stage = normalized_stage operation.stage in
  let workload_profile = normalized_workload_profile operation.workload_profile in
  let stats =
    lookup_stats store ~unit_id:candidate.unit_id ~workload_profile ~stage
  in
  let breakdown =
    {
      capability_match = capability_score operation candidate;
      artifact_locality = artifact_locality_score operation candidate;
      intent_successor = 0.0;
      verification_readiness = 0.0;
      runtime_fit = runtime_fit_score operation candidate;
      posterior_success = posterior_mean stats *. 15.0;
      capacity_headroom = capacity_score candidate;
      cost_efficiency = cost_efficiency_score candidate;
      queue_age = min 5.0 (queue_age_score operation.created_at /. 2.0);
      stickiness = if candidate.current_assignment then 5.0 else 0.0;
      total = 0.0;
    }
  in
  let total =
    breakdown.capability_match
    +. breakdown.artifact_locality
    +. breakdown.intent_successor
    +. breakdown.verification_readiness
    +. breakdown.runtime_fit
    +. breakdown.posterior_success
    +. breakdown.capacity_headroom
    +. breakdown.cost_efficiency
    +. breakdown.queue_age
    +. breakdown.stickiness
  in
  let final_breakdown = { breakdown with total } in
  let reason =
    Printf.sprintf
      "cap=%.1f artifact=%.1f runtime=%.1f posterior=%.1f headroom=%.1f cost=%.1f"
      final_breakdown.capability_match final_breakdown.artifact_locality
      final_breakdown.runtime_fit final_breakdown.posterior_success
      final_breakdown.capacity_headroom final_breakdown.cost_efficiency
  in
  { unit_id = candidate.unit_id; label = candidate.label; breakdown = final_breakdown; routing_reason = reason }

let score_candidates ~store ~(operation : operation_descriptor)
    ~(candidates : candidate_input list) =
  candidates
  |> List.map (candidate_breakdown ~store ~operation)
  |> List.sort (fun left right ->
         compare
           (right.breakdown.total, right.breakdown.capability_match, right.label)
           (left.breakdown.total, left.breakdown.capability_match, left.label))

let should_rebalance ~current ~best ~min_gain =
  best.breakdown.total -. current.breakdown.total >= min_gain

let summary_json ~strategy ~readiness ~(candidates : scored_candidate list)
    ~selected_unit_id =
  `Assoc
    [
      ("strategy", `String (strategy_to_string strategy));
      ( "readiness",
        match readiness with
        | Ready -> `String "ready"
        | Blocked _ -> `String "blocked" );
      ( "dependency_blockers",
        match readiness with
        | Ready -> `List []
        | Blocked blockers -> `List (List.map blocker_to_json blockers) );
      ("selected_unit_id", Json_util.string_opt_to_json selected_unit_id);
      ("candidates", `List (List.map scored_candidate_to_json candidates));
    ]

let store_to_json store =
  `Assoc
    [
      ("generated_at", `String (now_iso ()));
      ("entries", `List (List.map stats_entry_to_json store));
    ]

let store_of_json json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "entries" fields with
      | Some (`List rows) -> List.filter_map stats_entry_of_json rows
      | _ -> default_store)
  | `List rows -> List.filter_map stats_entry_of_json rows
  | _ -> default_store
