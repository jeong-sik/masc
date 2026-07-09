type projection_state =
  | Needs_evidence
  | Source_snapshot_stale
  | Artifact_missing
  | Verified

type projection =
  { target_post_id : string
  ; state : projection_state
  ; total_count : int
  ; allowed_count : int
  ; rejected_count : int
  ; artifact_missing_count : int
  ; artifact_unknown_count : int
  ; missing_source_snapshot_count : int
  ; stale_source_snapshot_count : int
  ; artifact_not_verified_count : int
  ; latest_decision : string option
  ; latest_recorded_at : float option
  }

type counters =
  { target_post_id : string
  ; mutable total_count : int
  ; mutable allowed_count : int
  ; mutable rejected_count : int
  ; mutable artifact_missing_count : int
  ; mutable artifact_unknown_count : int
  ; mutable missing_source_snapshot_count : int
  ; mutable stale_source_snapshot_count : int
  ; mutable artifact_not_verified_count : int
  ; mutable latest_decision : string option
  ; mutable latest_recorded_at : float option
  }

let sidecar_filename = "board_claim_evidence.jsonl"
let sidecar_path () = Filename.concat (Board_paths.board_masc_dir ()) sidecar_filename

let projection_state_to_string = function
  | Needs_evidence -> "needs_evidence"
  | Source_snapshot_stale -> "source_snapshot_stale"
  | Artifact_missing -> "artifact_missing"
  | Verified -> "verified"
;;

let projection_state_label = function
  | Needs_evidence -> "Needs evidence"
  | Source_snapshot_stale -> "Source snapshot stale"
  | Artifact_missing -> "Artifact missing"
  | Verified -> "Verified"
;;

let assoc_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_opt key json =
  match assoc_opt key json with
  | Some (`String value) ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then None else Some trimmed
  | _ -> None
;;

let float_opt key json =
  match assoc_opt key json with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | _ -> None
;;

let has_prefix ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.equal (String.sub s 0 plen) prefix
;;

let reject_reason decision =
  if has_prefix ~prefix:"reject:" decision
  then Some (String.sub decision 7 (String.length decision - 7))
  else None
;;

let resolution_states json =
  match assoc_opt "artifact_resolutions" json with
  | Some (`List rows) -> List.filter_map (string_opt "state") rows
  | _ -> []
;;

let counters target_post_id =
  { target_post_id
  ; total_count = 0
  ; allowed_count = 0
  ; rejected_count = 0
  ; artifact_missing_count = 0
  ; artifact_unknown_count = 0
  ; missing_source_snapshot_count = 0
  ; stale_source_snapshot_count = 0
  ; artifact_not_verified_count = 0
  ; latest_decision = None
  ; latest_recorded_at = None
  }
;;

let remember_latest c ~decision ~recorded_at =
  match recorded_at, c.latest_recorded_at with
  | Some next, Some prev when next < prev -> ()
  | None, Some _ -> ()
  | Some _, _ | None, None ->
    c.latest_decision <- Some decision;
    c.latest_recorded_at <- recorded_at
;;

let apply_record path c json =
  match string_opt "decision" json with
  | None ->
    Log.BoardLog.warn
      "board claim evidence projection ignored record without decision for %s"
      path
  | Some decision ->
    let recorded_at = float_opt "recorded_at" json in
    c.total_count <- c.total_count + 1;
    remember_latest c ~decision ~recorded_at;
    (match reject_reason decision with
     | Some reason ->
       c.rejected_count <- c.rejected_count + 1;
       if String.equal reason "missing_source_post_snapshot"
       then c.missing_source_snapshot_count <- c.missing_source_snapshot_count + 1;
       if String.equal reason "source_post_snapshot_stale"
       then c.stale_source_snapshot_count <- c.stale_source_snapshot_count + 1;
       if String.equal reason "artifact_not_verified"
       then c.artifact_not_verified_count <- c.artifact_not_verified_count + 1
     | None ->
       if String.equal decision "allow" then c.allowed_count <- c.allowed_count + 1);
    List.iter
      (function
        | "missing" -> c.artifact_missing_count <- c.artifact_missing_count + 1
        | "unknown" -> c.artifact_unknown_count <- c.artifact_unknown_count + 1
        | _ -> ())
      (resolution_states json)
;;

let state_of_counters c =
  if c.stale_source_snapshot_count > 0
  then Source_snapshot_stale
  else if c.missing_source_snapshot_count > 0
          || c.artifact_unknown_count > 0
          || c.artifact_not_verified_count > 0
          || c.rejected_count > 0
  then Needs_evidence
  else if c.artifact_missing_count > 0
  then Artifact_missing
  else Verified
;;

let projection_of_counters c =
  { target_post_id = c.target_post_id
  ; state = state_of_counters c
  ; total_count = c.total_count
  ; allowed_count = c.allowed_count
  ; rejected_count = c.rejected_count
  ; artifact_missing_count = c.artifact_missing_count
  ; artifact_unknown_count = c.artifact_unknown_count
  ; missing_source_snapshot_count = c.missing_source_snapshot_count
  ; stale_source_snapshot_count = c.stale_source_snapshot_count
  ; artifact_not_verified_count = c.artifact_not_verified_count
  ; latest_decision = c.latest_decision
  ; latest_recorded_at = c.latest_recorded_at
  }
;;

let projection_to_yojson (p : projection) =
  `Assoc
    (List.concat
       [ [ "source", `String sidecar_filename
         ; "target_post_id", `String p.target_post_id
         ; "state", `String (projection_state_to_string p.state)
         ; "label", `String (projection_state_label p.state)
         ; "total_count", `Int p.total_count
         ; "allowed_count", `Int p.allowed_count
         ; "rejected_count", `Int p.rejected_count
         ; "artifact_missing_count", `Int p.artifact_missing_count
         ; "artifact_unknown_count", `Int p.artifact_unknown_count
         ; "missing_source_snapshot_count", `Int p.missing_source_snapshot_count
         ; "stale_source_snapshot_count", `Int p.stale_source_snapshot_count
         ; "artifact_not_verified_count", `Int p.artifact_not_verified_count
         ]
       ; (match p.latest_decision with
          | Some value -> [ "latest_decision", `String value ]
          | None -> [])
       ; (match p.latest_recorded_at with
          | Some value -> [ "latest_recorded_at", `Float value ]
          | None -> [])
       ])
;;

let parse_line path line_no line =
  try Some (Yojson.Safe.from_string line) with
  | exn ->
    Log.BoardLog.warn
      "board claim evidence projection ignored malformed %s:%d: %s"
      path
      line_no
      (Printexc.to_string exn);
    None
;;

let load_records path =
  if not (Sys.file_exists path)
  then []
  else (
    try
      let ic = open_in path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           let rec loop line_no acc =
             match input_line ic with
             | line ->
               let acc =
                 match parse_line path line_no line with
                 | Some json -> json :: acc
                 | None -> acc
               in
               loop (line_no + 1) acc
             | exception End_of_file -> List.rev acc
           in
           loop 1 [])
    with
    | exn ->
      Log.BoardLog.warn
        "board claim evidence projection read failed for %s: %s"
        path
        (Printexc.to_string exn);
      [])
;;

(* --- Phase 1: target-post high-risk detection --- *)

(** Typed claim kinds — single source of truth. *)
type claim_kind =
  | Artifact_exists
  | Artifact_missing
  | Artifact_created
  | Artifact_endorsed
  | Verification_endorsement
  | Task_completion
  | Pr_state
  | Retraction_ack
  | Opinion_or_routing
;;

let claim_kind_is_high_risk = function
  | Opinion_or_routing -> false
  | _ -> true
;;

let claim_kind_of_string raw =
  let normal = raw |> String.trim |> String.lowercase_ascii
    |> String.map (function '-' | ' ' -> '_' | ch -> ch)
  in
  match normal with
  | "artifact_exists" -> Some Artifact_exists
  | "artifact_missing" -> Some Artifact_missing
  | "artifact_created" -> Some Artifact_created
  | "artifact_endorsed" -> Some Artifact_endorsed
  | "verification_endorsement" -> Some Verification_endorsement
  | "task_completion" -> Some Task_completion
  | "pr_state" -> Some Pr_state
  | "retraction_ack" -> Some Retraction_ack
  | "opinion_or_routing" | "opinion" | "routing" -> Some Opinion_or_routing
  | _ -> None
;;

(** [post_has_high_risk_evidence post_id] scans the sidecar ledger for
    any record targeting [post_id] that carries typed claims beyond
    [opinion_or_routing].  Used by the board claim gate (Phase 1) to
    force source_post_snapshot requirements on replies to high-risk
    posts even when the replying keeper omits explicit claim args.

    Unknown/unrecognised claim strings are treated as high-risk
    (fail-closed): if the sidecar contains a claim we cannot parse,
    we assume it is high-risk rather than silently ignoring it. *)
let post_has_high_risk_evidence post_id =
  let records = load_records (sidecar_path ()) in
  List.exists
    (fun json ->
      let matches_target =
        match string_opt "target_post_id" json with
        | Some pid -> String.equal pid post_id
        | None -> false
      in
      if not matches_target
      then false
      else
        let claims =
          match assoc_opt "claims" json with
          | Some (`List items) ->
            List.filter_map
              (function `String s -> Some s | _ -> None)
              items
          | _ -> []
        in
        (* Any claim beyond opinion_or_routing makes the post high-risk.
           Unknown/unrecognised claim strings are treated as high-risk
           (fail-closed): if the sidecar contains a claim we cannot parse,
           we assume it is high-risk rather than silently ignoring it. *)
        List.exists
          (fun c ->
            match claim_kind_of_string c with
            | Some k -> claim_kind_is_high_risk k
            | None -> true)
          claims)
    records
;;

let projection_lookup () =
  let table = Hashtbl.create 16 in
  let path = sidecar_path () in
  path
  |> load_records
  |> List.iter (fun json ->
    match string_opt "target_post_id" json with
    | None -> ()
    | Some target_post_id ->
      let c =
        match Hashtbl.find_opt table target_post_id with
        | Some value -> value
        | None ->
          let value = counters target_post_id in
          Hashtbl.add table target_post_id value;
          value
      in
      apply_record path c json);
  fun target_post_id ->
    Hashtbl.find_opt table target_post_id |> Option.map projection_of_counters
;;
