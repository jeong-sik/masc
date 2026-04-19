(** Keeper_accountability — evidence-first accountability ledger for keepers.

    Append-only dated JSONL under [.masc/accountability]. This is separate from
    popularity signals such as board karma: it records keeper commitments and
    explicit completion claims, then derives trust/risk summaries from
    deterministic evidence. *)

type claim_kind =
  | Task_commitment
  | Completion_claim

type claim_status =
  | Pending
  | Supported
  | Unsupported
  | Expired
  | Partial

type claim_event = {
  claim_id : string;
  agent_name : string;
  keeper_name : string;
  trace_id : string option;
  turn_number : int option;
  task_id : string option;
  kind : claim_kind;
  subject : string;
  surface : string;
  created_at : string;
  evidence_refs : string list;
  synthetic : bool;
}

type resolution_event = {
  claim_id : string;
  status : claim_status;
  resolved_at : string;
  reason : string option;
  supporting_evidence_refs : string list;
}

type claim_snapshot = {
  claim : claim_event;
  resolution : resolution_event option;
}

let store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4
let store_cache_mu = Eio.Mutex.create ()
let window_read_count_for_testing_ref : int option ref = ref None

let task_commitment_expiry_sec = 72.0 *. 3600.0
let completion_claim_expiry_sec = 24.0 *. 3600.0
let dedupe_window_sec = 3600.0
let summary_window_days = 14

let claim_kind_to_string = function
  | Task_commitment -> "task_commitment"
  | Completion_claim -> "completion_claim"

let claim_kind_of_string = function
  | "task_commitment" -> Some Task_commitment
  | "completion_claim" -> Some Completion_claim
  | _ -> None

let claim_status_to_string = function
  | Pending -> "pending"
  | Supported -> "supported"
  | Unsupported -> "unsupported"
  | Expired -> "expired"
  | Partial -> "partial"

let claim_status_of_string = function
  | "pending" -> Some Pending
  | "supported" -> Some Supported
  | "unsupported" -> Some Unsupported
  | "expired" -> Some Expired
  | "partial" -> Some Partial
  | _ -> None

let normalize_refs refs =
  refs
  |> List.map String.trim
  |> List.filter (fun value -> value <> "")
  |> List.sort_uniq String.compare

let is_keeper_agent_name agent_name =
  Resilience.Zombie.is_keeper_name
    (String.lowercase_ascii (String.trim agent_name))

let keeper_name_of_agent agent_name =
  let trimmed = String.trim agent_name in
  let suffix = "-agent" in
  if String.length trimmed > String.length suffix
     && String.sub trimmed
          (String.length trimmed - String.length suffix)
          (String.length suffix)
        = suffix
  then
    String.sub trimmed 0 (String.length trimmed - String.length suffix)
  else
    trimmed

let accountability_dir base_path =
  Filename.concat base_path ".masc/accountability"

let get_store (config : Coord_query.config) : Dated_jsonl.t =
  let base_path = config.base_path in
  Eio.Mutex.use_rw ~protect:true store_cache_mu (fun () ->
      match Hashtbl.find_opt store_cache base_path with
      | Some store -> store
      | None ->
          let store = Dated_jsonl.create ~base_dir:(accountability_dir base_path) () in
          Hashtbl.replace store_cache base_path store;
          store)

let json_string_opt key json =
  Safe_ops.json_string_opt key json

let json_int_opt key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`Int value) -> Some value
      | Some (`Intlit raw) -> int_of_string_opt raw
      | Some (`Float value) -> Some (int_of_float value)
      | _ -> None)
  | _ -> None

let json_bool key ~default json =
  Safe_ops.json_bool ~default key json

let json_string_list key json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some (`List items) ->
          items
          |> List.filter_map (function
                 | `String value ->
                     let trimmed = String.trim value in
                     if trimmed = "" then None else Some trimmed
                 | _ -> None)
      | _ -> [])
  | _ -> []

let option_string_field key = function
  | Some value when String.trim value <> "" -> [ (key, `String (String.trim value)) ]
  | _ -> []

let option_int_field key = function
  | Some value -> [ (key, `Int value) ]
  | None -> []

let claim_event_to_json (event : claim_event) =
  `Assoc
    ([
       ("event_type", `String "claim_created");
       ("claim_id", `String event.claim_id);
       ("agent_name", `String event.agent_name);
       ("keeper_name", `String event.keeper_name);
       ("kind", `String (claim_kind_to_string event.kind));
       ("subject", `String event.subject);
       ("surface", `String event.surface);
       ("created_at", `String event.created_at);
       ("evidence_refs", `List (List.map (fun r -> `String r) event.evidence_refs));
       ("synthetic", `Bool event.synthetic);
     ]
    @ option_string_field "trace_id" event.trace_id
    @ option_int_field "turn_number" event.turn_number
    @ option_string_field "task_id" event.task_id)

let resolution_event_to_json (event : resolution_event) =
  `Assoc
    ([
       ("event_type", `String "claim_resolved");
       ("claim_id", `String event.claim_id);
       ("status", `String (claim_status_to_string event.status));
       ("resolved_at", `String event.resolved_at);
       ( "supporting_evidence_refs",
         `List (List.map (fun r -> `String r) event.supporting_evidence_refs) );
     ]
    @ option_string_field "reason" event.reason)

let event_date_string ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday

let claim_event_of_json json =
  match json_string_opt "event_type" json with
  | Some "claim_created" -> (
      match claim_kind_of_string (Safe_ops.json_string ~default:"" "kind" json) with
      | Some kind ->
          let claim_id = Safe_ops.json_string ~default:"" "claim_id" json in
          let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
          let keeper_name =
            match json_string_opt "keeper_name" json with
            | Some value when String.trim value <> "" -> String.trim value
            | _ -> keeper_name_of_agent agent_name
          in
          let subject = Safe_ops.json_string ~default:"" "subject" json in
          let surface = Safe_ops.json_string ~default:"task" "surface" json in
          let created_at = Safe_ops.json_string ~default:"" "created_at" json in
          if claim_id = "" || agent_name = "" || subject = "" || created_at = "" then
            None
          else
            Some
              {
                claim_id;
                agent_name;
                keeper_name;
                trace_id = json_string_opt "trace_id" json;
                turn_number = json_int_opt "turn_number" json;
                task_id = json_string_opt "task_id" json;
                kind;
                subject;
                surface;
                created_at;
                evidence_refs = normalize_refs (json_string_list "evidence_refs" json);
                synthetic = json_bool "synthetic" ~default:false json;
              }
      | None -> None)
  | _ -> None

let resolution_event_of_json json =
  match json_string_opt "event_type" json with
  | Some "claim_resolved" -> (
      match claim_status_of_string (Safe_ops.json_string ~default:"" "status" json) with
      | Some status ->
          let claim_id = Safe_ops.json_string ~default:"" "claim_id" json in
          let resolved_at = Safe_ops.json_string ~default:"" "resolved_at" json in
          if claim_id = "" || resolved_at = "" then None
          else
            Some
              {
                claim_id;
                status;
                resolved_at;
                reason = json_string_opt "reason" json;
                supporting_evidence_refs =
                  normalize_refs (json_string_list "supporting_evidence_refs" json);
              }
      | None -> None)
  | _ -> None

let read_window_entries (config : Coord_query.config) =
  (match !window_read_count_for_testing_ref with
  | Some count -> window_read_count_for_testing_ref := Some (count + 1)
  | None -> ());
  let now = Time_compat.now () in
  let since = event_date_string (now -. (float_of_int summary_window_days *. 86400.0)) in
  let until = event_date_string now in
  Dated_jsonl.read_range (get_store config) ~since ~until

let materialize_claims jsons =
  let claims : (string, claim_snapshot) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun json ->
      match claim_event_of_json json, resolution_event_of_json json with
      | Some claim, None ->
          if not (Hashtbl.mem claims claim.claim_id) then
            Hashtbl.replace claims claim.claim_id { claim; resolution = None }
      | None, Some resolution -> (
          match Hashtbl.find_opt claims resolution.claim_id with
          | Some snapshot ->
              Hashtbl.replace claims resolution.claim_id
                { snapshot with resolution = Some resolution }
          | None -> ())
      | _ -> ())
    jsons;
  Hashtbl.to_seq_values claims |> List.of_seq

let created_at_unix claim =
  Types_core.parse_iso8601_opt claim.created_at |> Option.value ~default:0.0

let effective_status ~(now : float) (snapshot : claim_snapshot) =
  match snapshot.resolution with
  | Some resolution -> resolution.status
  | None ->
      let age = now -. created_at_unix snapshot.claim in
      match snapshot.claim.kind with
      | Task_commitment when age > task_commitment_expiry_sec -> Expired
      | Completion_claim when age > completion_claim_expiry_sec -> Unsupported
      | _ -> Pending

let open_recent_claim ~(now : float) snapshots ~agent_name ~kind ~subject ~task_id
    ~max_age_sec =
  List.find_opt
    (fun (snapshot : claim_snapshot) ->
      snapshot.claim.agent_name = agent_name
      && snapshot.claim.kind = kind
      && String.equal snapshot.claim.subject subject
      && snapshot.claim.task_id = task_id
      &&
      let age = now -. created_at_unix snapshot.claim in
      age >= 0.0 && age <= max_age_sec
      &&
      match effective_status ~now snapshot with
      | Pending -> true
      | Supported | Unsupported | Expired | Partial -> false)
    snapshots

let make_claim_id ~agent_name ~kind ~subject ~task_id ~created_at =
  let raw =
    String.concat "|"
      [
        agent_name;
        claim_kind_to_string kind;
        subject;
        Option.value ~default:"" task_id;
        created_at;
      ]
  in
  let digest = Digest.to_hex (Digest.string raw) in
  "acct-" ^ String.sub digest 0 12

let append_claim (config : Coord_query.config) (event : claim_event) =
  Dated_jsonl.append (get_store config) (claim_event_to_json event)

let append_resolution (config : Coord_query.config) (event : resolution_event) =
  Dated_jsonl.append (get_store config) (resolution_event_to_json event)

let task_title_for_id (config : Coord_query.config) task_id =
  Coord_query.get_tasks_safe config
  |> List.find_opt (fun (task : Types.task) -> String.equal task.id task_id)
  |> Option.map (fun (task : Types.task) -> task.title)

let create_task_commitment config ~agent_name ~task_id ~surface =
  let now = Time_compat.now () in
  let title =
    Option.value ~default:task_id (task_title_for_id config task_id)
  in
  let snapshots = materialize_claims (read_window_entries config) in
  match
    open_recent_claim ~now snapshots ~agent_name ~kind:Task_commitment
      ~subject:title ~task_id:(Some task_id)
      ~max_age_sec:task_commitment_expiry_sec
  with
  | Some _ -> ()
  | None ->
      let created_at = Types.now_iso () in
      append_claim config
        {
          claim_id =
            make_claim_id ~agent_name ~kind:Task_commitment ~subject:title
              ~task_id:(Some task_id) ~created_at;
          agent_name;
          keeper_name = keeper_name_of_agent agent_name;
          trace_id = None;
          turn_number = None;
          task_id = Some task_id;
          kind = Task_commitment;
          subject = title;
          surface;
          created_at;
          evidence_refs = [ "task:" ^ task_id ];
          synthetic = false;
        }

let resolve_recent_task_commitment config ~agent_name ~task_id ~status ~reason
    ~evidence_refs ~max_age_sec =
  let now = Time_compat.now () in
  let title =
    Option.value ~default:task_id (task_title_for_id config task_id)
  in
  let snapshots = materialize_claims (read_window_entries config) in
  match
    open_recent_claim ~now snapshots ~agent_name ~kind:Task_commitment
      ~subject:title ~task_id:(Some task_id) ~max_age_sec
  with
  | Some snapshot ->
      append_resolution config
        {
          claim_id = snapshot.claim.claim_id;
          status;
          resolved_at = Types.now_iso ();
          reason;
          supporting_evidence_refs = normalize_refs evidence_refs;
        }
  | None -> ()

let maybe_support_recent_completion_claim config ~agent_name ~task_id ~evidence_refs =
  let now = Time_compat.now () in
  let title =
    Option.value ~default:task_id (task_title_for_id config task_id)
  in
  let snapshots = materialize_claims (read_window_entries config) in
  match
    open_recent_claim ~now snapshots ~agent_name ~kind:Completion_claim
      ~subject:title ~task_id:(Some task_id)
      ~max_age_sec:completion_claim_expiry_sec
  with
  | Some snapshot ->
      append_resolution config
        {
          claim_id = snapshot.claim.claim_id;
          status = Supported;
          resolved_at = Types.now_iso ();
          reason = Some "task_done";
          supporting_evidence_refs = normalize_refs evidence_refs;
        }
  | None ->
      let created_at = Types.now_iso () in
      let claim_id =
        make_claim_id ~agent_name ~kind:Completion_claim ~subject:title
          ~task_id:(Some task_id) ~created_at
      in
      append_claim config
        {
          claim_id;
          agent_name;
          keeper_name = keeper_name_of_agent agent_name;
          trace_id = None;
          turn_number = None;
          task_id = Some task_id;
          kind = Completion_claim;
          subject = title;
          surface = "task_transition";
          created_at;
          evidence_refs = normalize_refs evidence_refs;
          synthetic = true;
        };
      append_resolution config
        {
          claim_id;
          status = Supported;
          resolved_at = created_at;
          reason = Some "task_done";
          supporting_evidence_refs = normalize_refs evidence_refs;
        }

let record_task_transition (config : Coord_query.config) ~agent_name ~task_id
    ~transition ~details =
  if not (is_keeper_agent_name agent_name) then ()
  else
    match transition with
    | "claim" | "start" ->
        create_task_commitment config ~agent_name ~task_id
          ~surface:"task_transition"
    | "done" ->
        let base_refs = [ "task:" ^ task_id ] in
        resolve_recent_task_commitment config ~agent_name ~task_id
          ~status:Supported ~reason:(Some "task_done")
          ~evidence_refs:base_refs ~max_age_sec:task_commitment_expiry_sec;
        maybe_support_recent_completion_claim config ~agent_name ~task_id
          ~evidence_refs:base_refs
    | "release" | "cancel" ->
        let reason =
          match json_string_opt "reason" details with
          | Some value when String.trim value <> "" -> Some (String.trim value)
          | _ -> Some transition
        in
        resolve_recent_task_commitment config ~agent_name ~task_id
          ~status:Partial ~reason
          ~evidence_refs:[ "task:" ^ task_id ] ~max_age_sec:task_commitment_expiry_sec
    | _ -> ()

let supporting_refs_for_turn ~trace_id ~turn_number strong_evidence_refs =
  normalize_refs
    (("turn:" ^ trace_id ^ ":" ^ string_of_int turn_number) :: strong_evidence_refs)

let record_completion_claim (config : Coord_query.config) ~keeper_name ~agent_name
    ~trace_id ~turn_number ~subject ?task_id ?(evidence_refs = [])
    ?(surface = "keeper_turn") ~strong_evidence ~strong_evidence_refs () =
  if not (is_keeper_agent_name agent_name) then ()
  else
    let subject = String.trim subject in
    if subject = "" then ()
    else
      let now = Time_compat.now () in
      let snapshots = materialize_claims (read_window_entries config) in
      let normalized_task_id =
        match task_id with
        | Some value ->
            let trimmed = String.trim value in
            if trimmed = "" then None else Some trimmed
        | None -> None
      in
      let recent_existing =
        open_recent_claim ~now snapshots ~agent_name ~kind:Completion_claim
          ~subject ~task_id:normalized_task_id ~max_age_sec:dedupe_window_sec
      in
      let claim_id =
        match recent_existing with
        | Some snapshot -> snapshot.claim.claim_id
        | None ->
            let created_at = Types.now_iso () in
            let claim_id =
              make_claim_id ~agent_name ~kind:Completion_claim ~subject
                ~task_id:normalized_task_id ~created_at
            in
            append_claim config
              {
                claim_id;
                agent_name;
                keeper_name;
                trace_id = Some trace_id;
                turn_number = Some turn_number;
                task_id = normalized_task_id;
                kind = Completion_claim;
                subject;
                surface;
                created_at;
                evidence_refs = normalize_refs evidence_refs;
                synthetic = false;
              };
            claim_id
      in
      if strong_evidence then
        append_resolution config
          {
            claim_id;
            status = Supported;
            resolved_at = Types.now_iso ();
            reason = Some "same_turn_evidence";
            supporting_evidence_refs =
              supporting_refs_for_turn ~trace_id ~turn_number
                strong_evidence_refs;
          }

let risk_band_of_metrics ~evidence_coverage ~unsupported_completion_rate
    ~open_overdue_commitments =
  if
    evidence_coverage >= 0.80
    && unsupported_completion_rate < 0.10
    && open_overdue_commitments = 0
  then "low"
  else if
    evidence_coverage >= 0.60
    && unsupported_completion_rate < 0.25
    && open_overdue_commitments <= 2
  then "medium"
  else
    "high"

let summary_cutoff now =
  now -. (float_of_int summary_window_days *. 86400.0)

let summary_json_of_snapshots ~keeper_name ~agent_name ~now snapshots =
  let supported_claims = ref 0 in
  let resolved_claims = ref 0 in
  let unsupported_completion_claims = ref 0 in
  let total_completion_claims = ref 0 in
  let open_overdue_commitments = ref 0 in
  let supported_task_commitments = ref 0 in
  let resolved_task_commitments = ref 0 in
  let recent_supported_claims = ref 0 in
  let cutoff = summary_cutoff now in
  List.iter
    (fun (snapshot : claim_snapshot) ->
      let status = effective_status ~now snapshot in
      let created_unix = created_at_unix snapshot.claim in
      (match snapshot.claim.kind with
      | Task_commitment -> (
          match status with
          | Supported ->
              incr supported_task_commitments;
              incr resolved_task_commitments
          | Partial | Expired ->
              incr resolved_task_commitments;
              if status = Expired then incr open_overdue_commitments
          | Pending -> ()
          | Unsupported -> ())
      | Completion_claim ->
          if status <> Pending && not snapshot.claim.synthetic then
            incr total_completion_claims;
          if status = Unsupported && not snapshot.claim.synthetic then
            incr unsupported_completion_claims);
      (match status with
      | Supported ->
          incr supported_claims;
          incr resolved_claims;
          if created_unix >= cutoff then incr recent_supported_claims
      | Partial | Expired | Unsupported -> incr resolved_claims
      | Pending -> ());
      if snapshot.claim.kind = Task_commitment
         && status = Pending
         && now -. created_unix > task_commitment_expiry_sec
      then
        incr open_overdue_commitments)
    snapshots;
  let task_followthrough_rate =
    if !resolved_task_commitments = 0 then 1.0
    else
      float_of_int !supported_task_commitments
      /. float_of_int !resolved_task_commitments
  in
  let evidence_coverage =
    if !resolved_claims = 0 then 1.0
    else float_of_int !supported_claims /. float_of_int !resolved_claims
  in
  let unsupported_completion_rate =
    if !total_completion_claims = 0 then 0.0
    else
      float_of_int !unsupported_completion_claims
      /. float_of_int !total_completion_claims
  in
  let risk_band =
    risk_band_of_metrics ~evidence_coverage ~unsupported_completion_rate
      ~open_overdue_commitments:!open_overdue_commitments
  in
  let history =
    snapshots
    |> List.sort (fun a b ->
           compare (created_at_unix b.claim) (created_at_unix a.claim))
    |> List.filteri (fun idx _ -> idx < 10)
    |> List.map (fun (snapshot : claim_snapshot) ->
           let status = effective_status ~now snapshot in
           `Assoc
             ([
                ("claim_id", `String snapshot.claim.claim_id);
                ("kind", `String (claim_kind_to_string snapshot.claim.kind));
                ("status", `String (claim_status_to_string status));
                ("subject", `String snapshot.claim.subject);
                ("surface", `String snapshot.claim.surface);
                ("created_at", `String snapshot.claim.created_at);
                ("keeper_name", `String snapshot.claim.keeper_name);
                ("evidence_refs", `List (List.map (fun r -> `String r) snapshot.claim.evidence_refs));
                ("synthetic", `Bool snapshot.claim.synthetic);
              ]
             @ option_string_field "task_id" snapshot.claim.task_id
             @ option_string_field "trace_id" snapshot.claim.trace_id
             @ option_int_field "turn_number" snapshot.claim.turn_number
             @
             match snapshot.resolution with
             | Some resolution ->
                 [
                   ("resolved_at", `String resolution.resolved_at);
                   ( "supporting_evidence_refs",
                     `List
                       (List.map (fun r -> `String r)
                          resolution.supporting_evidence_refs) );
                 ]
                 @ option_string_field "reason" resolution.reason
             | None -> []))
  in
  let routing_hint =
    match risk_band with
    | "high" -> "manual_review_recommended"
    | "medium" -> "prefer_low_risk_when_equivalent"
    | _ -> "normal_routing"
  in
  `Assoc
    [
      ("keeper_name", `String keeper_name);
      ("agent_name", `String agent_name);
      ("window_days", `Int summary_window_days);
      ("task_followthrough_rate", `Float task_followthrough_rate);
      ("evidence_coverage", `Float evidence_coverage);
      ("unsupported_completion_rate", `Float unsupported_completion_rate);
      ("open_overdue_commitments", `Int !open_overdue_commitments);
      ("recent_supported_claims", `Int !recent_supported_claims);
      ("risk_band", `String risk_band);
      ("routing_hint", `String routing_hint);
      ("history", `List history);
    ]

let accountability_summary_lookup (config : Coord_query.config) =
  let now = Time_compat.now () in
  let cutoff = summary_cutoff now in
  let by_agent : (string, claim_snapshot list) Hashtbl.t = Hashtbl.create 32 in
  (* Request-local pre-aggregation: the dashboard rebuilds this lookup per
     render, so the next request naturally refreshes the window contents. *)
  materialize_claims (read_window_entries config)
  |> List.iter (fun snapshot ->
         if created_at_unix snapshot.claim >= cutoff then
           let existing =
             match Hashtbl.find_opt by_agent snapshot.claim.agent_name with
             | Some items -> items
             | None -> []
           in
           Hashtbl.replace by_agent snapshot.claim.agent_name
             (snapshot :: existing));
  fun ~keeper_name ~agent_name ->
    let snapshots =
      match Hashtbl.find_opt by_agent agent_name with
      | Some items -> items
      | None -> []
    in
    summary_json_of_snapshots ~keeper_name ~agent_name ~now snapshots

let accountability_summary_json (config : Coord_query.config) ~keeper_name
    ~agent_name =
  accountability_summary_lookup config ~keeper_name ~agent_name

let enable_window_read_count_for_testing () =
  window_read_count_for_testing_ref := Some 0

let disable_window_read_count_for_testing () =
  window_read_count_for_testing_ref := None

let window_read_count_for_testing () =
  match !window_read_count_for_testing_ref with
  | Some count -> count
  | None -> 0

let accountability_risk_is_high config ~keeper_name ~agent_name =
  match accountability_summary_json config ~keeper_name ~agent_name with
  | `Assoc fields -> (
      match List.assoc_opt "risk_band" fields with
      | Some (`String "high") -> true
      | _ -> false)
  | _ -> false

(* --- Attribution envelope conversion (Layer 1) ---
   All accountability verdicts are Det — [effective_status] is a pure
   function of snapshot + time. The claim_snapshot type stays private to
   this module; callers provide their own evidence payload. *)

let attribution_from_status (status : claim_status) ~evidence
    ?resolution_reason ?(evidence_refs_count = 0) () : Attribution.t option =
  match status with
  | Pending -> None
  | Supported ->
    Some (Attribution.passed ~origin:Det ~gate:"accountability" ~evidence)
  | Unsupported ->
    let reason = Option.value resolution_reason
                   ~default:"claim not supported by evidence"
    in
    Some (Attribution.policy_failed ~origin:Det ~gate:"accountability"
            ~evidence ~reason)
  | Expired ->
    let reason = Option.value resolution_reason
                   ~default:"claim expired"
    in
    Some (Attribution.policy_failed ~origin:Det ~gate:"accountability"
            ~evidence ~reason)
  | Partial ->
    (* Score from evidence_refs_count: heuristic 0.5 baseline, +0.1 per
       evidence ref up to 1.0. No domain-specific normalization available
       here — dashboard aggregates the raw count separately. *)
    let score =
      Float.min 1.0 (0.5 +. 0.1 *. Float.of_int evidence_refs_count)
    in
    let rationale = Option.value resolution_reason
                      ~default:"claim partially supported"
    in
    Some (Attribution.partial_pass ~origin:Det ~gate:"accountability"
            ~evidence ~score ~rationale)
