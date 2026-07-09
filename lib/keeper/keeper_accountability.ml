(** Keeper_accountability — evidence-first accountability ledger for keepers.

    Append-only dated JSONL under [.masc/accountability]. This is separate from
    popularity signals such as board karma: it records keeper commitments and
    explicit completion claims, then derives trust/risk summaries from
    deterministic evidence. *)

(* Types, codecs, and store access extracted to
   [Keeper_accountability_types_codec] (godfile decomp). *)
include Keeper_accountability_types_codec

type decision_activity =
  { decision_signal_count : int
  ; latest_decision_at : string option
  ; latest_decision_age_s : float option
  }

let decision_ts_unix_opt json =
  let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" json in
  if ts_unix > 0.0
  then Some ts_unix
  else (
    match json_string_opt "ts" json with
    | Some value -> Types_core.parse_iso8601_opt value
    | None -> None)
;;

let candidate_decision_keeper_names keeper_name =
  let raw = String.trim keeper_name in
  let canonical = normalize_keeper_name raw in
  [ raw; canonical; "keeper-" ^ canonical ]
  |> List.filter (fun value -> value <> "" && value <> "keeper-")
  |> List.sort_uniq String.compare
;;

let keeper_decision_log_path (config : Workspace_query.config) name =
  let keepers_dir =
    Common.keepers_runtime_dir_of_base ~base_path:config.base_path
  in
  Filename.concat keepers_dir (name ^ ".decisions.jsonl")
;;

let tail_decision_log_lines_or_empty path ~max_bytes ~max_lines =
  if max_lines <= 0 || (not (Sys.file_exists path)) || Sys.is_directory path
  then []
  else (
    try
      let size =
        match (Unix.stat path).Unix.st_size with
        | size when size > 0 -> size
        | _ -> 0
      in
      let start = max 0 (size - max_bytes) in
      let ic = open_in_bin path in
      Eio_guard.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           seek_in ic start;
           if start > 0
           then (
             match input_line ic with
             | _partial_prefix -> ()
             | exception End_of_file -> ());
           let lines = ref [] in
           (try
              while true do
                lines := input_line ic :: !lines
              done
            with
            | End_of_file -> ());
           !lines |> List.filteri (fun idx _ -> idx < max_lines) |> List.rev)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> [])
;;

let recent_decision_timestamps config ~keeper_name ~now =
  let cutoff = now -. (float_of_int summary_window_days *. Masc_time_constants.day) in
  candidate_decision_keeper_names keeper_name
  |> List.concat_map (fun candidate ->
    let path = keeper_decision_log_path config candidate in
    tail_decision_log_lines_or_empty path ~max_bytes:500000 ~max_lines:128)
  |> List.filter_map (fun line ->
    try Yojson.Safe.from_string line |> decision_ts_unix_opt with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | Yojson.Json_error _ -> None)
  |> List.filter (fun ts -> ts >= cutoff && ts <= now +. 60.0)
;;

let decision_activity_for_keeper config ~keeper_name ~now =
  let timestamps = recent_decision_timestamps config ~keeper_name ~now in
  let latest =
    List.fold_left
      (fun acc ts ->
         match acc with
         | None -> Some ts
         | Some prev -> Some (Float.max prev ts))
      None
      timestamps
  in
  { decision_signal_count = List.length timestamps
  ; latest_decision_at = Option.map Masc_domain.iso8601_of_unix_seconds latest
  ; latest_decision_age_s = Option.map (fun ts -> Float.max 0.0 (now -. ts)) latest
  }
;;

let materialize_claims jsons =
  let claims : (string, claim_snapshot) Hashtbl.t = Hashtbl.create 64 in
  List.iter
    (fun json ->
       match claim_event_of_json json, resolution_event_of_json json with
       | Some claim, None ->
         if not (Hashtbl.mem claims claim.claim_id)
         then Hashtbl.replace claims claim.claim_id { claim; resolution = None }
       | None, Some resolution ->
         (match Hashtbl.find_opt claims resolution.claim_id with
          | Some snapshot ->
            Hashtbl.replace
              claims
              resolution.claim_id
              { snapshot with resolution = Some resolution }
          | None -> ())
       | _ -> ())
    jsons;
  Hashtbl.to_seq_values claims |> List.of_seq
;;

let created_at_unix claim =
  Types_core.parse_iso8601_opt claim.created_at |> Option.value ~default:0.0
;;

let effective_status ~(now : float) (snapshot : claim_snapshot) =
  match snapshot.resolution with
  | Some resolution -> resolution.status
  | None ->
    let age = now -. created_at_unix snapshot.claim in
    (* Per-constructor exhaustive match: a new [claim_kind] (e.g.,
         Verification_claim) triggers a compile error here so its expiry
         rule is an explicit decision, not silently inherited from the
         old wildcard arm. See #8768 / #8765 family. *)
    (match snapshot.claim.kind with
     | Task_commitment -> if age > task_commitment_expiry_sec then Expired else Pending
     | Completion_claim ->
       if age > completion_claim_expiry_sec then Unsupported else Pending)
;;

let open_recent_claim
      ~(now : float)
      snapshots
      ~agent_name
      ~kind
      ~subject
      ~task_id
      ~max_age_sec
  =
  List.find_opt
    (fun (snapshot : claim_snapshot) ->
       snapshot.claim.agent_name = agent_name
       && snapshot.claim.kind = kind
       && String.equal snapshot.claim.subject subject
       && snapshot.claim.task_id = task_id
       &&
       let age = now -. created_at_unix snapshot.claim in
       age >= 0.0
       && age <= max_age_sec
       &&
       match effective_status ~now snapshot with
       | Pending -> true
       | Supported | Unsupported | Expired | Partial -> false)
    snapshots
;;

let make_claim_id ~agent_name ~kind ~subject ~task_id ~created_at =
  let raw =
    String.concat
      "|"
      [ agent_name
      ; claim_kind_to_string kind
      ; subject
      ; Option.value ~default:"" task_id
      ; created_at
      ]
  in
  let digest = Digest.to_hex (Digest.string raw) in
  "acct-" ^ String.sub digest 0 12
;;

let append_claim (config : Workspace_query.config) (event : claim_event) =
  Dated_jsonl.append (get_store config) (claim_event_to_json event)
;;

let append_resolution (config : Workspace_query.config) (event : resolution_event) =
  Dated_jsonl.append (get_store config) (resolution_event_to_json event)
;;

let resolution_for_claim
      ?(resolved_at = Masc_domain.now_iso ())
      ?reason
      ~status
      ~evidence_refs
      (claim : claim_event)
  =
  { claim_id = claim.claim_id
  ; agent_name = Some claim.agent_name
  ; keeper_name = Some claim.keeper_name
  ; task_id = claim.task_id
  ; kind = Some claim.kind
  ; subject = Some claim.subject
  ; status
  ; resolved_at
  ; reason
  ; supporting_evidence_refs = normalize_refs evidence_refs
  }
;;

let task_title_for_id (config : Workspace_query.config) task_id =
  Workspace_query.get_tasks_safe config
  |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  |> Option.map (fun (task : Masc_domain.task) -> task.title)
;;

let create_task_commitment config ~agent_name ~task_id ~surface =
  let now = Time_compat.now () in
  let title = Option.value ~default:task_id (task_title_for_id config task_id) in
  let snapshots = materialize_claims (read_window_entries config) in
  match
    open_recent_claim
      ~now
      snapshots
      ~agent_name
      ~kind:Task_commitment
      ~subject:title
      ~task_id:(Some task_id)
      ~max_age_sec:task_commitment_expiry_sec
  with
  | Some _ -> ()
  | None ->
    let created_at = Masc_domain.now_iso () in
    append_claim
      config
      { claim_id =
          make_claim_id
            ~agent_name
            ~kind:Task_commitment
            ~subject:title
            ~task_id:(Some task_id)
            ~created_at
      ; agent_name
      ; keeper_name = keeper_name_of_agent agent_name
      ; trace_id = None
      ; turn_number = None
      ; task_id = Some task_id
      ; kind = Task_commitment
      ; subject = title
      ; surface
      ; created_at
      ; evidence_refs = [ "task:" ^ task_id ]
      ; synthetic = false
      }
;;

let resolve_recent_task_commitment
      config
      ~agent_name
      ~task_id
      ~status
      ~reason
      ~evidence_refs
      ~max_age_sec
  =
  let now = Time_compat.now () in
  let title = Option.value ~default:task_id (task_title_for_id config task_id) in
  let snapshots = materialize_claims (read_window_entries config) in
  match
    open_recent_claim
      ~now
      snapshots
      ~agent_name
      ~kind:Task_commitment
      ~subject:title
      ~task_id:(Some task_id)
      ~max_age_sec
  with
  | Some snapshot ->
    append_resolution
      config
      (resolution_for_claim snapshot.claim ~status ?reason ~evidence_refs)
  | None -> ()
;;

let maybe_support_recent_completion_claim config ~agent_name ~task_id ~evidence_refs =
  let now = Time_compat.now () in
  let title = Option.value ~default:task_id (task_title_for_id config task_id) in
  let snapshots = materialize_claims (read_window_entries config) in
  match
    open_recent_claim
      ~now
      snapshots
      ~agent_name
      ~kind:Completion_claim
      ~subject:title
      ~task_id:(Some task_id)
      ~max_age_sec:completion_claim_expiry_sec
  with
  | Some snapshot ->
    append_resolution
      config
      (resolution_for_claim
         snapshot.claim
         ~status:Supported
         ~reason:"task_done"
         ~evidence_refs)
  | None ->
    let created_at = Masc_domain.now_iso () in
    let claim_id =
      make_claim_id
        ~agent_name
        ~kind:Completion_claim
        ~subject:title
        ~task_id:(Some task_id)
        ~created_at
    in
    let claim =
      { claim_id
      ; agent_name
      ; keeper_name = keeper_name_of_agent agent_name
      ; trace_id = None
      ; turn_number = None
      ; task_id = Some task_id
      ; kind = Completion_claim
      ; subject = title
      ; surface = "task_transition"
      ; created_at
      ; evidence_refs = normalize_refs evidence_refs
      ; synthetic = true
      }
    in
    append_claim config claim;
    append_resolution
      config
      (resolution_for_claim
         claim
         ~resolved_at:created_at
         ~status:Supported
         ~reason:"task_done"
         ~evidence_refs)
;;

(* #8605 family: exhaustive on [Masc_domain.task_action]. The previous
   string match silently no-oped for typos and any future transition
   string. With the variant the compiler now forces a deliberate
   decision for every task_action constructor; verification-related
   actions explicitly produce no commitment side effects -- their
   accountability tracking lives in [record_completion_claim]. *)
let record_task_transition
      (config : Workspace_query.config)
      ~agent_name
      ~task_id
      ~(transition : Masc_domain.task_action)
      ~details
  =
  if not (is_keeper_agent_name agent_name)
  then
    (* #10314: drop is now visible. *)
    record_emit_skip ~kind:"task_transition" ~reason:"not_keeper_agent_name"
  else (
    match transition with
    | Masc_domain.Claim | Masc_domain.Start ->
      create_task_commitment config ~agent_name ~task_id ~surface:"task_transition"
    | Masc_domain.Done_action ->
      let base_refs = [ "task:" ^ task_id ] in
      resolve_recent_task_commitment
        config
        ~agent_name
        ~task_id
        ~status:Supported
        ~reason:(Some "task_done")
        ~evidence_refs:base_refs
        ~max_age_sec:task_commitment_expiry_sec;
      maybe_support_recent_completion_claim
        config
        ~agent_name
        ~task_id
        ~evidence_refs:base_refs
    | Masc_domain.Release | Masc_domain.Cancel ->
      let reason =
        match json_string_opt "reason" details with
        | Some value ->
          let trimmed = String.trim value in
          if trimmed <> ""
          then Some trimmed
          else Some (Masc_domain.task_action_to_string transition)
        | None -> Some (Masc_domain.task_action_to_string transition)
      in
      resolve_recent_task_commitment
        config
        ~agent_name
        ~task_id
        ~status:Partial
        ~reason
        ~evidence_refs:[ "task:" ^ task_id ]
        ~max_age_sec:task_commitment_expiry_sec
    | Masc_domain.Submit_for_verification
    | Masc_domain.Approve_verification
    | Masc_domain.Reject_verification
    | Masc_domain.Mark_operator_blocked
    | Masc_domain.Unblock -> ())
;;

let supporting_refs_for_turn ~trace_id ~turn_number strong_evidence_refs =
  normalize_refs
    (("turn:" ^ trace_id ^ ":" ^ string_of_int turn_number) :: strong_evidence_refs)
;;

let record_completion_claim
      (config : Workspace_query.config)
      ~keeper_name
      ~agent_name
      ~trace_id
      ~turn_number
      ~subject
      ?task_id
      ?(evidence_refs = [])
      ?(surface = "keeper_turn")
      ~strong_evidence
      ~strong_evidence_refs
      ()
  =
  if not (is_keeper_agent_name agent_name)
  then
    (* #10314: drop is now visible. *)
    record_emit_skip ~kind:"completion_claim" ~reason:"not_keeper_agent_name"
  else (
    let subject = String.trim subject in
    if subject = ""
    then
      (* #10314: empty subject is a separate failure mode — agent
         called but produced no claim text. Distinct reason so
         operators can split the diagnosis. *)
      record_emit_skip ~kind:"completion_claim" ~reason:"empty_subject"
    else (
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
        open_recent_claim
          ~now
          snapshots
          ~agent_name
          ~kind:Completion_claim
          ~subject
          ~task_id:normalized_task_id
          ~max_age_sec:dedupe_window_sec
      in
      let resolution_claim =
        match recent_existing with
        | Some snapshot -> snapshot.claim
        | None ->
          let created_at = Masc_domain.now_iso () in
          let claim_id =
            make_claim_id
              ~agent_name
              ~kind:Completion_claim
              ~subject
              ~task_id:normalized_task_id
              ~created_at
          in
          let claim =
            { claim_id
            ; agent_name
            ; keeper_name = normalize_keeper_name keeper_name
            ; trace_id = Some trace_id
            ; turn_number = Some turn_number
            ; task_id = normalized_task_id
            ; kind = Completion_claim
            ; subject
            ; surface
            ; created_at
            ; evidence_refs = normalize_refs evidence_refs
            ; synthetic = false
            }
          in
          append_claim config claim;
          claim
      in
      if strong_evidence
      then
        append_resolution
          config
          (resolution_for_claim
             resolution_claim
             ~status:Supported
             ~reason:"same_turn_evidence"
             ~evidence_refs:
               (supporting_refs_for_turn ~trace_id ~turn_number strong_evidence_refs))))
;;

let risk_band_of_metrics
      ~evidence_coverage
      ~unsupported_completion_rate
      ~open_overdue_commitments
  =
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
  else "high"
;;

let summary_cutoff now = now -. (float_of_int summary_window_days *. Masc_time_constants.day)

let summary_json_of_snapshots ~keeper_name ~agent_name ~now snapshots =
  let supported_claims = ref 0 in
  let resolved_claims = ref 0 in
  let unsupported_completion_claims = ref 0 in
  let total_completion_claims = ref 0 in
  let task_commitment_count = ref 0 in
  let completion_claim_count = ref 0 in
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
        | Task_commitment ->
          incr task_commitment_count;
          (match status with
           | Supported ->
             incr supported_task_commitments;
             incr resolved_task_commitments
           | Partial | Expired ->
             incr resolved_task_commitments;
             if status = Expired then incr open_overdue_commitments
           | Pending -> ()
           | Unsupported -> ())
        | Completion_claim ->
          incr completion_claim_count;
          if status <> Pending && not snapshot.claim.synthetic
          then incr total_completion_claims;
          if status = Unsupported && not snapshot.claim.synthetic
          then incr unsupported_completion_claims);
       (match status with
        | Supported ->
          incr supported_claims;
          incr resolved_claims;
          if created_unix >= cutoff then incr recent_supported_claims
        | Partial | Expired | Unsupported -> incr resolved_claims
        | Pending -> ());
       if
         snapshot.claim.kind = Task_commitment
         && status = Pending
         && now -. created_unix > task_commitment_expiry_sec
       then incr open_overdue_commitments)
    snapshots;
  let task_followthrough_rate =
    if !resolved_task_commitments = 0
    then 1.0
    else
      float_of_int !supported_task_commitments /. float_of_int !resolved_task_commitments
  in
  let evidence_coverage =
    if !resolved_claims = 0
    then 1.0
    else float_of_int !supported_claims /. float_of_int !resolved_claims
  in
  let unsupported_completion_rate =
    if !total_completion_claims = 0
    then 0.0
    else
      float_of_int !unsupported_completion_claims /. float_of_int !total_completion_claims
  in
  let risk_band =
    risk_band_of_metrics
      ~evidence_coverage
      ~unsupported_completion_rate
      ~open_overdue_commitments:!open_overdue_commitments
  in
  let history =
    snapshots
    |> List.sort (fun a b -> compare (created_at_unix b.claim) (created_at_unix a.claim))
    |> List.filteri (fun idx _ -> idx < 10)
    |> List.map (fun (snapshot : claim_snapshot) ->
      let status = effective_status ~now snapshot in
      `Assoc
        ([ "claim_id", `String snapshot.claim.claim_id
         ; "kind", `String (claim_kind_to_string snapshot.claim.kind)
         ; "status", `String (claim_status_to_string status)
         ; "subject", `String snapshot.claim.subject
         ; "surface", `String snapshot.claim.surface
         ; "created_at", `String snapshot.claim.created_at
         ; "keeper_name", `String snapshot.claim.keeper_name
         ; ( "evidence_refs"
           , `List (List.map (fun r -> `String r) snapshot.claim.evidence_refs) )
         ; "synthetic", `Bool snapshot.claim.synthetic
         ]
         @ option_string_field "task_id" snapshot.claim.task_id
         @ option_string_field "trace_id" snapshot.claim.trace_id
         @ option_int_field "turn_number" snapshot.claim.turn_number
         @
         match snapshot.resolution with
         | Some resolution ->
           [ "resolved_at", `String resolution.resolved_at
           ; ( "supporting_evidence_refs"
             , `List (List.map (fun r -> `String r) resolution.supporting_evidence_refs) )
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
    [ "keeper_name", `String keeper_name
    ; "agent_name", `String agent_name
    ; "window_days", `Int summary_window_days
    ; "task_followthrough_rate", `Float task_followthrough_rate
    ; "evidence_coverage", `Float evidence_coverage
    ; "unsupported_completion_rate", `Float unsupported_completion_rate
    ; "open_overdue_commitments", `Int !open_overdue_commitments
    ; "recent_supported_claims", `Int !recent_supported_claims
    ; "accountability_claim_count", `Int (List.length snapshots)
    ; "task_commitment_count", `Int !task_commitment_count
    ; "completion_claim_count", `Int !completion_claim_count
    ; "risk_band", `String risk_band
    ; "routing_hint", `String routing_hint
    ; "history", `List history
    ]
;;

let source_label ~source ~keeper_name ~coverage_gap =
  match source with
  | "direct_agent" -> "Direct runtime alias history"
  | "canonical_keeper_fallback" ->
    Printf.sprintf "Inherited from canonical identity: %s" keeper_name
  | _ when coverage_gap -> "No accountability history; recent decision activity exists"
  | _ -> "No accountability history"
;;

let with_accountability_source ~source ~keeper_name ~coverage_gap json =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ "source", `String source
         ; "source_label", `String (source_label ~source ~keeper_name ~coverage_gap)
         ])
  | other -> other
;;

let assoc_replace key value fields =
  let replaced = ref false in
  let mapped =
    List.map
      (fun (field_key, field_value) ->
         if String.equal field_key key
         then (
           replaced := true;
           field_key, value)
         else field_key, field_value)
      fields
  in
  if !replaced then mapped else mapped @ [ key, value ]
;;

let with_accountability_coverage ~coverage_gap ~decision_activity json =
  let coverage_health =
    if coverage_gap
    then "coverage_gap"
    else if decision_activity.decision_signal_count = 0
    then "no_recent_activity"
    else "ok"
  in
  let coverage_routing_hint =
    if coverage_gap then "accountability_coverage_gap_review" else "normal"
  in
  let coverage_fields =
    [ "coverage_health", `String coverage_health
    ; "coverage_gap", `Bool coverage_gap
    ; ( "coverage_gap_reason"
      , if coverage_gap
        then `String "recent_decisions_without_accountability_claims"
        else `Null )
    ; "decision_signal_count", `Int decision_activity.decision_signal_count
    ; ( "latest_decision_at", Json_util.string_opt_to_json decision_activity.latest_decision_at )
    ; ( "latest_decision_age_s", Json_util.float_opt_to_json decision_activity.latest_decision_age_s )
    ; "coverage_routing_hint", `String coverage_routing_hint
    ]
  in
  match json with
  | `Assoc fields ->
    let fields =
      if coverage_gap
      then
        assoc_replace "routing_hint" (`String "accountability_coverage_gap_review") fields
      else fields
    in
    `Assoc (fields @ coverage_fields)
  | other -> other
;;

type accountability_snapshot = {
  snap_now : float;
  by_agent : (string, claim_snapshot list) Hashtbl.t;
  by_keeper : (string, claim_snapshot list) Hashtbl.t;
}

let accountability_snapshot_cache :
    (string, float * accountability_snapshot) Hashtbl.t =
  Hashtbl.create 4

let accountability_snapshot_cache_mu = Eio.Mutex.create ()

(* compute_reputation calls accountability_summary_json once per unique post
   author in a board render; rebuilding the windowed claim aggregation
   (read_window_entries + materialize_claims + bucketing) per author was
   O(authors x window). The aggregation is a pure function of the window files,
   so memoizing it per base path collapses a render's per-author calls (and
   back-to-back renders) to a single build, at the cost of <= TTL staleness in
   the accountability bands. The per-keeper decision activity below stays per
   call; it is per-keeper and cheap relative to the window scan. *)
let accountability_snapshot_ttl_s = 3.0

let build_accountability_snapshot (config : Workspace_query.config) :
    accountability_snapshot =
  let now = Time_compat.now () in
  let cutoff = summary_cutoff now in
  let by_agent : (string, claim_snapshot list) Hashtbl.t = Hashtbl.create 32 in
  let by_keeper : (string, claim_snapshot list) Hashtbl.t = Hashtbl.create 32 in
  let add_snapshot table key snapshot =
    let existing =
      match Hashtbl.find_opt table key with
      | Some items -> items
      | None -> []
    in
    Hashtbl.replace table key (snapshot :: existing)
  in
  materialize_claims (read_window_entries config)
  |> List.iter (fun snapshot ->
    if created_at_unix snapshot.claim >= cutoff
    then (
      add_snapshot by_agent snapshot.claim.agent_name snapshot;
      add_snapshot by_keeper snapshot.claim.keeper_name snapshot));
  { snap_now = now; by_agent; by_keeper }

let cached_accountability_snapshot (config : Workspace_query.config) :
    accountability_snapshot =
  let key = config.base_path in
  let now = Time_compat.now () in
  let is_fresh = function
    | Some (built_at, _snap) -> now -. built_at < accountability_snapshot_ttl_s
    | None -> false
  in
  match Hashtbl.find_opt accountability_snapshot_cache key with
  | Some (built_at, snap) as cached when is_fresh cached -> snap
  | _ ->
      Eio.Mutex.use_rw ~protect:true accountability_snapshot_cache_mu
      @@ fun () ->
      (match Hashtbl.find_opt accountability_snapshot_cache key with
       | Some (built_at, snap) as cached when is_fresh cached -> snap
       | _ ->
           let snap = build_accountability_snapshot config in
           Hashtbl.replace accountability_snapshot_cache key (now, snap);
           snap)

let accountability_summary_lookup (config : Workspace_query.config) =
  let { snap_now = now; by_agent; by_keeper } =
    cached_accountability_snapshot config
  in
  fun ~keeper_name ~agent_name ->
    let keeper_name = normalize_keeper_name keeper_name in
    let source, snapshots =
      match Hashtbl.find_opt by_agent agent_name with
      | Some items -> "direct_agent", items
      | None ->
        (match Hashtbl.find_opt by_keeper keeper_name with
         | Some items -> "canonical_keeper_fallback", items
         | None -> "none", [])
    in
    let decision_activity = decision_activity_for_keeper config ~keeper_name ~now in
    let coverage_gap =
      String.equal source "none"
      && snapshots = []
      && decision_activity.decision_signal_count > 0
    in
    summary_json_of_snapshots ~keeper_name ~agent_name ~now snapshots
    |> with_accountability_source ~source ~keeper_name ~coverage_gap
    |> with_accountability_coverage ~coverage_gap ~decision_activity
;;

let accountability_summary_json (config : Workspace_query.config) ~keeper_name ~agent_name =
  accountability_summary_lookup config ~keeper_name ~agent_name
;;

let enable_window_read_count_for_testing () =
  (* tla-lint: allow-mutation: test hook — initialise opt-in counter from test setup *)
  window_read_count_for_testing_ref := Some 0
;;

let disable_window_read_count_for_testing () =
  (* tla-lint: allow-mutation: test hook — clear opt-in counter from test teardown *)
  window_read_count_for_testing_ref := None
;;

let window_read_count_for_testing () =
  match !window_read_count_for_testing_ref with
  | Some count -> count
  | None -> 0
;;

let accountability_risk_is_high config ~keeper_name ~agent_name =
  match accountability_summary_json config ~keeper_name ~agent_name with
  | `Assoc fields ->
    (match List.assoc_opt "risk_band" fields with
     | Some (`String "high") -> true
     | _ -> false)
  | _ -> false
;;

(* --- Attribution envelope conversion (Layer 1) ---
   All accountability verdicts are Det — [effective_status] is a pure
   function of snapshot + time. The claim_snapshot type stays private to
   this module; callers provide their own evidence payload. *)

let attribution_from_status
      (status : claim_status)
      ~evidence
      ?resolution_reason
      ?(evidence_refs_count = 0)
      ()
  : Attribution.t option
  =
  match status with
  | Pending -> None
  | Supported -> Some (Attribution.passed ~origin:Det ~gate:"accountability" ~evidence)
  | Unsupported ->
    let reason =
      Option.value resolution_reason ~default:"claim not supported by evidence"
    in
    Some (Attribution.policy_failed ~origin:Det ~gate:"accountability" ~evidence ~reason)
  | Expired ->
    let reason = Option.value resolution_reason ~default:"claim expired" in
    Some (Attribution.policy_failed ~origin:Det ~gate:"accountability" ~evidence ~reason)
  | Partial ->
    (* Score from evidence_refs_count: heuristic 0.5 baseline, +0.1 per
       evidence ref up to 1.0. No domain-specific normalization available
       here — dashboard aggregates the raw count separately. *)
    let score = Float.min 1.0 (0.5 +. (0.1 *. Float.of_int evidence_refs_count)) in
    let rationale = Option.value resolution_reason ~default:"claim partially supported" in
    Some
      (Attribution.partial_pass
         ~origin:Det
         ~gate:"accountability"
         ~evidence
         ~score
         ~rationale)
;;
