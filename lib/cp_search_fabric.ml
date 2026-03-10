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
  stage : string;
  alpha : float;
  beta : float;
  updated_at : string;
}

type score_breakdown = {
  capability_match : float;
  capacity_headroom : float;
  posterior_success : float;
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

let normalized_stage = function
  | Some raw ->
      let lowered = String.trim raw |> String.lowercase_ascii in
      if lowered = "" then "generic" else lowered
  | None -> "generic"

let default_store = []

let now_iso () = Types.now_iso ()

let ensure_dir path =
  let rec mkdir_p dir =
    if dir <> "" && not (Sys.file_exists dir) then begin
      mkdir_p (Filename.dirname dir);
      (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  mkdir_p path

let json_list_of_strings xs =
  `List (List.map (fun value -> `String value) xs)

let stats_entry_to_json (entry : stats_entry) =
  `Assoc
    [
      ("unit_id", `String entry.unit_id);
      ("stage", `String entry.stage);
      ("alpha", `Float entry.alpha);
      ("beta", `Float entry.beta);
      ("updated_at", `String entry.updated_at);
    ]

let stats_entry_of_json json =
  try
    let unit_id = json |> U.member "unit_id" |> U.to_string in
    let stage = json |> U.member "stage" |> U.to_string in
    let alpha = json |> U.member "alpha" |> U.to_float in
    let beta = json |> U.member "beta" |> U.to_float in
    let updated_at =
      json |> U.member "updated_at" |> U.to_string_option |> Option.value ~default:(now_iso ())
    in
    if unit_id = "" || stage = "" then
      None
    else
      Some { unit_id; stage; alpha; beta; updated_at }
  with Yojson.Safe.Util.Type_error _ -> None

let load_store path : stats_store =
  if not (Sys.file_exists path) then
    default_store
  else
    try
      match Yojson.Safe.from_file path with
      | `Assoc fields -> (
          match List.assoc_opt "entries" fields with
          | Some (`List rows) -> List.filter_map stats_entry_of_json rows
          | _ -> default_store)
      | `List rows -> List.filter_map stats_entry_of_json rows
      | _ -> default_store
    with Yojson.Json_error _ | Sys_error _ -> default_store

let save_store path (store : stats_store) =
  ensure_dir (Filename.dirname path);
  Yojson.Safe.to_file path
    (`Assoc
      [
        ("generated_at", `String (now_iso ()));
        ("entries", `List (List.map stats_entry_to_json store));
      ])

let lookup_stats (store : stats_store) ~unit_id ~stage =
  let stage = normalized_stage (Some stage) in
  store
  |> List.find_opt (fun (entry : stats_entry) ->
         String.equal entry.unit_id unit_id && String.equal entry.stage stage)
  |> Option.value
       ~default:{ unit_id; stage; alpha = 1.0; beta = 1.0; updated_at = now_iso () }

let upsert_stats (store : stats_store) (entry : stats_entry) =
  entry
  :: List.filter
       (fun (current : stats_entry) ->
         not (String.equal current.unit_id entry.unit_id && String.equal current.stage entry.stage))
       store

let record_success (store : stats_store) ~unit_id ~stage =
  let current = lookup_stats store ~unit_id ~stage in
  upsert_stats store
    { current with alpha = current.alpha +. 1.0; updated_at = now_iso () }

let record_failure (store : stats_store) ~unit_id ~stage =
  let current = lookup_stats store ~unit_id ~stage in
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
      ("capacity_headroom", `Float breakdown.capacity_headroom);
      ("posterior_success", `Float breakdown.posterior_success);
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
        Some (fst (Unix.mktime tm)))
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
    "generic";
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

let demand_keywords (operation : operation_descriptor) =
  let profile_keyword =
    match String.trim operation.workload_profile with
    | "" | "generic" -> []
    | profile -> [ String.lowercase_ascii profile ]
  in
  let stage_keyword =
    match operation.stage with
    | Some stage when String.trim stage <> "" -> [ String.lowercase_ascii (String.trim stage) ]
    | _ -> []
  in
  let objective_keywords = extract_keywords operation.objective in
  List.sort_uniq String.compare (profile_keyword @ stage_keyword @ objective_keywords)

let candidate_keywords (candidate : candidate_input) =
  let id_keywords = extract_keywords candidate.unit_id in
  let label_keywords = extract_keywords candidate.label in
  let capability_keywords =
    candidate.capability_profile
    |> List.map String.lowercase_ascii
    |> List.concat_map extract_keywords
  in
  List.sort_uniq String.compare (id_keywords @ label_keywords @ capability_keywords)

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
    min 20.0 (ratio *. 20.0)

let capability_score operation candidate =
  let demand = demand_keywords operation in
  let supply = candidate_keywords candidate in
  let stage_bonus =
    match operation.stage with
    | Some stage ->
        let stage_key = normalize_word stage in
        if stage_key <> "" && List.mem stage_key supply then 20.0 else 0.0
    | None -> 0.0
  in
  min 40.0 (stage_bonus +. (keyword_overlap demand supply *. 20.0))

let candidate_breakdown ~store ~(operation : operation_descriptor)
    (candidate : candidate_input) =
  let stage = normalized_stage operation.stage in
  let stats = lookup_stats store ~unit_id:candidate.unit_id ~stage in
  let breakdown =
    {
      capability_match = capability_score operation candidate;
      capacity_headroom = capacity_score candidate;
      posterior_success = posterior_mean stats *. 20.0;
      queue_age = queue_age_score operation.created_at;
      stickiness = if candidate.current_assignment then 10.0 else 0.0;
      total = 0.0;
    }
  in
  let total =
    breakdown.capability_match
    +. breakdown.capacity_headroom
    +. breakdown.posterior_success
    +. breakdown.queue_age
    +. breakdown.stickiness
  in
  let final_breakdown = { breakdown with total } in
  let reason =
    Printf.sprintf "cap=%.1f posterior=%.1f headroom=%.1f queue=%.1f"
      final_breakdown.capability_match final_breakdown.posterior_success
      final_breakdown.capacity_headroom final_breakdown.queue_age
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
      ("selected_unit_id", match selected_unit_id with Some value -> `String value | None -> `Null);
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
