(* Goal proof requests and verdicts are bound to one success-criterion revision.
   Mutations use only the primary ledger. Recovery mirrors are read-only evidence.
   The caller holds the Goal lock while binding or committing a current request. *)

let ( let* ) = Result.bind

type verdict_outcome =
  | Proven
  | Refuted of { reason : string }

type verdict = {
  outcome : verdict_outcome;
  request_id : string;
  criterion : Goal_store.criterion;
  verification_run_id : string;
  authority : Masc_domain.completion_authority;
  evidence : string;
  recorded_at : string;
}

type confirmation = { operator_id : string; confirmed_at : string }

type completion_state =
  | Completion_idle
  | Proof_pending of { requested_at : string; request_id : string; criterion : Goal_store.criterion }
  | Proof_proven of verdict
  | Proof_refuted of verdict
  | Human_confirmed of verdict * confirmation

type record = {
  goal_id : string;
  completion : completion_state;
  submitted_evidence : Workspace_verification_store.submitted_evidence_item list;
  updated_at : string;
}

type state = {
  version : int;
  updated_at : string;
  records : record list;
}

let default_record ~goal_id =
  { goal_id
  ; completion = Completion_idle
  ; submitted_evidence = []
  ; updated_at = Masc_domain.now_iso ()
  }

(* Strict wire-boundary parsing: reject unknown and duplicate fields. *)
let object_fields label allowed = function
  | `Assoc fields ->
      let names = List.map fst fields in
      (match List.find_opt (fun name -> not (List.mem name allowed)) names with
       | Some name -> Error (label ^ ": unknown field " ^ name)
       | None ->
         if List.length names <> List.length (List.sort_uniq String.compare names)
         then Error (label ^ ": duplicate field")
         else Ok (`Assoc fields))
  | _ -> Error (label ^ ": expected object")

let required_string json key =
  match Json_util.assoc_member_opt key json with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | _ -> Error ("goal_verification: missing or blank " ^ key)

let authority_to_yojson authority =
  `Assoc
    [ "kind", `String (Masc_domain.completion_authority_kind authority)
    ; "actor", `String (Masc_domain.completion_authority_actor authority) ]

let authority_of_yojson json =
  let* json = object_fields "goal_verification.authority" [ "kind"; "actor" ] json in
  let* actor = required_string json "actor" in
  match Json_util.assoc_member_opt "kind" json with
  | Some (`String "human_operator") -> Ok (Masc_domain.Human_operator { operator_id = actor })
  | Some (`String "system_llm_agent") -> Ok (Masc_domain.System_llm_agent { agent_run_id = actor })
  | _ -> Error "goal_verification: unknown authority kind"

let verdict_to_yojson (v : verdict) =
  let outcome_fields = match v.outcome with
    | Proven -> [ "outcome", `String "proven"; "reason", `Null ]
    | Refuted { reason } -> [ "outcome", `String "refuted"; "reason", `String reason ]
  in
  `Assoc (outcome_fields @
    [ "request_id", `String v.request_id
    ; "criterion", Goal_store.criterion_to_yojson v.criterion
    ; "verification_run_id", `String v.verification_run_id
    ; "authority", authority_to_yojson v.authority
    ; "evidence", `String v.evidence
    ; "recorded_at", `String v.recorded_at ])

let verdict_of_yojson json =
  let* json = object_fields "goal_verification.verdict"
    [ "outcome"; "reason"; "request_id"; "criterion"; "verification_run_id";
      "authority"; "evidence"; "recorded_at" ] json in
  let* request_id = required_string json "request_id" in
  let* criterion = Goal_store.criterion_of_yojson (Yojson.Safe.Util.member "criterion" json) in
  let* verification_run_id = required_string json "verification_run_id" in
  let* evidence = required_string json "evidence" in
  let* recorded_at = required_string json "recorded_at" in
  let* authority = authority_of_yojson (Yojson.Safe.Util.member "authority" json) in
  let* outcome = match Json_util.assoc_member_opt "outcome" json with
    | Some (`String "proven") ->
        (match Json_util.assoc_member_opt "reason" json with
         | Some `Null -> Ok Proven
         | _ -> Error "goal_verification: proven reason must be null")
    | Some (`String "refuted") ->
        let* reason = required_string json "reason" in Ok (Refuted { reason })
    | _ -> Error "goal_verification: unknown verdict outcome"
  in
  Ok { outcome; request_id; criterion; verification_run_id; authority; evidence; recorded_at }

let completion_state_to_yojson = function
  | Human_confirmed (verdict, confirmation) ->
      `Assoc ["state", `String "human_confirmed"; "verdict", verdict_to_yojson verdict;
        "operator_id", `String confirmation.operator_id; "confirmed_at", `String confirmation.confirmed_at]
  | Completion_idle -> `Assoc [ "state", `String "idle" ]
  | Proof_pending { requested_at; request_id; criterion } ->
      `Assoc [ "state", `String "proof_pending"; "requested_at", `String requested_at;
               "request_id", `String request_id; "criterion", Goal_store.criterion_to_yojson criterion ]
  | Proof_proven verdict ->
      `Assoc [ "state", `String "proof_proven"; "verdict", verdict_to_yojson verdict ]
  | Proof_refuted verdict ->
      `Assoc [ "state", `String "proof_refuted"; "verdict", verdict_to_yojson verdict ]

let completion_state_of_yojson json =
  match Json_util.assoc_member_opt "state" json with
  | Some (`String "human_confirmed") ->
      let* json = object_fields "goal_verification.confirmed" ["state"; "verdict"; "operator_id"; "confirmed_at"] json in
      let* verdict = verdict_of_yojson (Yojson.Safe.Util.member "verdict" json) in
      let* operator_id = required_string json "operator_id" in
      let* confirmed_at = required_string json "confirmed_at" in
      (match verdict.outcome with
       | Proven -> Ok (Human_confirmed (verdict, {operator_id; confirmed_at}))
       | Refuted _ -> Error "refuted proof cannot be human confirmed")
  | Some (`String "idle") ->
      let* _ = object_fields "goal_verification.idle" [ "state" ] json in
      Ok Completion_idle
  | Some (`String "proof_pending") ->
      let* json = object_fields "goal_verification.pending"
        [ "state"; "requested_at"; "request_id"; "criterion" ] json in
      let* requested_at = required_string json "requested_at" in
      let* request_id = required_string json "request_id" in
      let* criterion = Goal_store.criterion_of_yojson (Yojson.Safe.Util.member "criterion" json) in
      Ok (Proof_pending { requested_at; request_id; criterion })
  | Some (`String "proof_proven") ->
      let* _ = object_fields "goal_verification.proven" [ "state"; "verdict" ] json in
      let* verdict = verdict_of_yojson (Yojson.Safe.Util.member "verdict" json) in
      (match verdict.outcome with Proven -> Ok (Proof_proven verdict)
       | Refuted _ -> Error "goal_verification: proven state has refuted verdict")
  | Some (`String "proof_refuted") ->
      let* _ = object_fields "goal_verification.refuted" [ "state"; "verdict" ] json in
      let* verdict = verdict_of_yojson (Yojson.Safe.Util.member "verdict" json) in
      (match verdict.outcome with Refuted _ -> Ok (Proof_refuted verdict)
       | Proven -> Error "goal_verification: refuted state has proven verdict")
  | Some (`String state) -> Error ("goal_verification: unknown completion state " ^ state)
  | _ -> Error "goal_verification: missing completion state"

let record_to_yojson (record : record) =
  `Assoc
    [ "goal_id", `String record.goal_id
    ; "completion", completion_state_to_yojson record.completion
    ; "submitted_evidence", `List (List.map Workspace_verification_store.submitted_evidence_item_to_yojson record.submitted_evidence)
    ; "updated_at", `String record.updated_at
    ]

type criterion_relation = Current | Stale_criterion

let relation_for_goal ~goal record =
  let bound = match record.completion with
    | Completion_idle -> None
    | Proof_pending pending -> Some pending.criterion
    | Proof_proven verdict | Proof_refuted verdict | Human_confirmed (verdict, _) -> Some verdict.criterion
  in
  if not (String.equal record.goal_id goal.Goal_store.id) then Stale_criterion
  else match bound with
  | None -> Current
  | Some criterion ->
      if Goal_store.criterion_equal criterion (Goal_store.criterion_of_goal goal)
      then Current else Stale_criterion

let record_to_yojson_for_goal ~goal record =
  match relation_for_goal ~goal record with
  | Current -> `Assoc ["goal_id", `String record.goal_id;
      "completion", completion_state_to_yojson record.completion;
      "submitted_evidence", `List (List.map Workspace_verification_store.submitted_evidence_item_metadata_to_yojson record.submitted_evidence);
      "updated_at", `String record.updated_at]
  | Stale_criterion ->
      `Assoc [ "goal_id", `String record.goal_id;
               "completion", `Assoc [ "state", `String "stale_criterion";
                 "historical_completion", completion_state_to_yojson record.completion ];
               "updated_at", `String record.updated_at ]

let record_of_yojson json =
  let* json = object_fields "goal_verification.record"
    [ "goal_id"; "completion"; "submitted_evidence"; "updated_at" ] json in
  let* goal_id = required_string json "goal_id" in
  let* updated_at = required_string json "updated_at" in
  let* completion = completion_state_of_yojson (Yojson.Safe.Util.member "completion" json) in
      let* submitted_evidence = match Yojson.Safe.Util.member "submitted_evidence" json with
        | `List rows ->
          List.fold_left (fun result row ->
            let* acc = result in
            let* item = Workspace_verification_store.submitted_evidence_item_of_yojson row in
            Ok (item :: acc)) (Ok []) rows |> Result.map List.rev
        | _ -> Error "goal_verification.record: submitted_evidence must be a list" in
  Ok { goal_id; completion; submitted_evidence; updated_at }

let state_to_yojson (state : state) =
  `Assoc
    [ "version", `Int state.version
    ; "updated_at", `String state.updated_at
    ; "records", `List (List.map record_to_yojson state.records)
    ]

let state_of_yojson = function
  | `Assoc _ as json -> (
      let* json = object_fields "goal_verification.state" [ "version"; "updated_at"; "records" ] json in
      match
        ( Json_util.assoc_member_opt "version" json
        , Json_util.assoc_member_opt "updated_at" json
        , Json_util.assoc_member_opt "records" json )
      with
      | Some (`Int version), Some (`String updated_at), Some (`List records_json) ->
          let rec collect acc = function
            | [] -> Ok (List.rev acc)
            | row :: rest -> (
                match record_of_yojson row with
                | Ok record -> collect (record :: acc) rest
                | Error _ as error -> error)
          in
          Result.map
            (fun records -> { version; updated_at; records })
            (let* records = collect [] records_json in
             let ids = List.map (fun record -> record.goal_id) records in
             if List.length ids <> List.length (List.sort_uniq String.compare ids)
             then Error "goal_verification: duplicate goal record"
             else Ok records)
      | _ -> Error "goal_verification.state_of_yojson: invalid state")
  | json ->
      Error ("goal_verification.state_of_yojson: " ^ Yojson.Safe.to_string json)

let validate_state_json json = Result.map (fun _ -> ()) (state_of_yojson json)

(* {1 Persistence} *)

let verifications_path config =
  Filename.concat (Workspace_utils.masc_dir config) "goal_verifications.json"

let verifications_recovery_path config =
  verifications_path config ^ ".last-good"

let ensure_dirs config =
  Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let default_state () =
  { version = 1; updated_at = Masc_domain.now_iso (); records = [] }

(* Same split as [Goal_store.load_state]: an absent store is legitimately
   empty; a present-but-undecodable store must not license a write. *)
type load_outcome =
  | Loaded of state
  | Undecodable of string

let load_state config : load_outcome =
  ensure_dirs config;
  let read path =
    let* json = Workspace_utils.read_json_result config path in
    state_of_yojson json
  in
  let path = verifications_path config in
  let recovery = verifications_recovery_path config in
  let recover primary_detail =
    if Workspace_utils.path_exists config recovery then
      match read recovery with
      | Ok state ->
          Log.Misc.warn "goal_verification: historical recovery read (%s) from %s"
            primary_detail recovery;
          Loaded state
      | Error detail -> Undecodable (primary_detail ^ "; recovery: " ^ detail)
    else Undecodable primary_detail
  in
  if Workspace_utils.path_exists config path then
    match read path with
    | Ok state -> Loaded state
    | Error detail -> recover detail
  else if Workspace_utils.path_exists config recovery then
    recover "primary ledger is missing"
  else Loaded (default_state ())

let load_primary_state config =
  ensure_dirs config;
  let path = verifications_path config in
  if Workspace_utils.path_exists config path then
    match Workspace_utils.read_json_result config path with
    | Error detail -> Undecodable detail
    | Ok json -> (match state_of_yojson json with
        | Ok state -> Loaded state | Error detail -> Undecodable detail)
  else if Workspace_utils.path_exists config (verifications_recovery_path config) then
    Undecodable "primary ledger is missing while its recovery mirror exists"
  else Loaded (default_state ())

let undecodable_store_error config detail =
  Printf.sprintf
    "goal_verification: refusing to write over a store that did not decode (%s); \
     reset or repair %s before writing"
    detail
    (verifications_path config)

let undecodable_load_error config detail =
  Printf.sprintf
    "goal_verification: store did not decode (%s); repair or reset %s"
    detail
    (verifications_path config)

let write_state_result config state =
  ensure_dirs config;
  let json = state_to_yojson state in
  let* () = Workspace_utils.write_json_result config (verifications_path config) json in
  (match Workspace_utils.write_json_result
           config (verifications_recovery_path config) json
   with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "goal_verification: primary committed; recovery mirror write failed for \
        %s: %s"
       (verifications_recovery_path config)
       msg);
  Ok ()

(* {1 Record operations}

   Every mutation is a locked read-modify-write that refuses an undecodable
   store, mirroring [Goal_store.update_state]. *)

let find_record records goal_id =
  List.find_opt (fun (record : record) -> String.equal record.goal_id goal_id) records

let replace_record records updated =
  let rec loop acc = function
    | [] -> List.rev (updated :: acc)
    | (record : record) :: rest ->
        if String.equal record.goal_id updated.goal_id
        then List.rev_append acc (updated :: rest)
        else loop (record :: acc) rest
  in
  loop [] records

let update_record config ~goal_id f =
  Workspace_utils.with_file_lock config (verifications_path config) (fun () ->
      match load_primary_state config with
      | Undecodable detail -> Error (undecodable_store_error config detail)
      | Loaded state ->
          let current =
            match find_record state.records goal_id with
            | Some record -> record
            | None -> default_record ~goal_id
          in
          let now = Masc_domain.now_iso () in
          let* updated = f current in
          if updated = current then Ok current else
          let updated = { updated with updated_at = now } in
          let next_state =
            { version = state.version + 1
            ; updated_at = now
            ; records = replace_record state.records updated
            }
          in
          let* () = write_state_result config next_state in
          Ok updated)

(* Read side: fail LOUD. An undecodable store is an [Error] for every
   consumer — rendering it as "not verified yet" would let a corrupt ledger
   masquerade as a clean one (P1-1). Consumers that show per-goal
   verification state load once per request via {!load_records} and render
   the error through {!ledger_error_to_yojson}. *)
let load_records config : (record list, string) result =
  match load_state config with
  | Undecodable detail -> Error (undecodable_load_error config detail)
  | Loaded state -> Ok state.records

let get_record config ~goal_id : (record option, string) result =
  match load_records config with
  | Error _ as error -> error
  | Ok records -> Ok (find_record records goal_id)

let load_records_authoritative config =
  match load_primary_state config with
  | Loaded state -> Ok state.records
  | Undecodable detail -> Error (undecodable_load_error config detail)

let get_record_authoritative config ~goal_id =
  let* records = load_records_authoritative config in
  Ok (find_record records goal_id)

let ledger_error_to_yojson detail =
  `Assoc [ "state", `String "ledger_error"; "detail", `String detail ]

type reopen_outcome =
  | Proof_unchanged of record option
  | Proof_reset of record

let archive_reopened_proof config ~goal_id ~actor ~at completion =
  let path = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl" in
  try
    Fs_compat.append_jsonl path
      (`Assoc
        [ "ts", `String at
        ; "goal_id", `String goal_id
        ; "event_type", `String "goal_proof_reopened"
        ; "payload", `Assoc
            [ "phase", Goal_phase.to_yojson Goal_phase.Executing
            ; "actor", `String actor
            ; "previous_completion", completion_state_to_yojson completion
            ]
        ]);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _ | Eio.Io _) as exn ->
    Error (Printf.sprintf "could not preserve reopened Goal proof: %s" (Printexc.to_string exn))
;;

let reopen_goal config ~goal_id ~actor ~note =
  let* goal, (outcome, phase_changed) =
    Goal_store.transact_goal config ~goal_id (fun goal ->
      let* transition = Goal_phase.decide_transition ~phase:goal.Goal_store.phase
          ~action:Goal_phase.Reopen in
      let phase_changed, updated_goal = match transition with
        | Goal_phase.Already _ -> false, goal
        | Goal_phase.Move_to phase ->
          let last_review_note, last_review_at = match note with
            | None -> goal.last_review_note, goal.last_review_at
            | Some text -> Some text, Some (Masc_domain.now_iso ()) in
          true, { goal with phase; last_review_note; last_review_at }
      in
      Workspace_utils.with_file_lock config (verifications_path config) (fun () ->
        let* state = match load_primary_state config with
          | Loaded state -> Ok state
          | Undecodable detail -> Error (undecodable_store_error config detail)
        in
        let current = find_record state.records goal_id in
        let reset record =
          let now = Masc_domain.now_iso () in
          let* () = archive_reopened_proof config ~goal_id ~actor ~at:now record.completion in
          let updated = { record with completion = Completion_idle; updated_at = now } in
          let next = { version = state.version + 1; updated_at = now;
            records = replace_record state.records updated } in
          let* () = write_state_result config next in
          Ok (updated_goal, (Proof_reset updated, phase_changed))
        in
        match current with
        | Some ({ completion = Human_confirmed _ | Proof_proven _ | Proof_refuted _ | Proof_pending _; _ } as record)
          when phase_changed -> reset record
        | None | Some { completion = Completion_idle | Proof_pending _
                       | Proof_proven _ | Proof_refuted _ | Human_confirmed _; _ } ->
          Ok (updated_goal, (Proof_unchanged current, phase_changed))))
  in
  Ok (goal, outcome, phase_changed)
;;

(* A repeated request for the same criterion keeps its exact durable identity. *)
let mark_proof_pending ?submitted_evidence config ~goal_id ~criterion =
  update_record config ~goal_id (fun current ->
    let same_criterion = match current.completion with
      | Completion_idle -> false
      | Proof_pending pending -> Goal_store.criterion_equal pending.criterion criterion
      | Proof_proven verdict | Proof_refuted verdict | Human_confirmed (verdict, _) ->
          Goal_store.criterion_equal verdict.criterion criterion in
    let fresh () =
      let submitted_evidence = match submitted_evidence with
        | Some items -> items
        | None when same_criterion -> current.submitted_evidence
        | None -> [] in
      Ok { current with submitted_evidence; completion = Proof_pending
        { requested_at = Masc_domain.now_iso (); request_id = Random_id.hex ~bytes:16; criterion } }
    in
    match current.completion with
    | Proof_pending pending when Goal_store.criterion_equal pending.criterion criterion
        && Option.fold ~none:true ~some:((=) current.submitted_evidence) submitted_evidence -> Ok current
    | Proof_proven verdict | Human_confirmed (verdict, _) when Goal_store.criterion_equal verdict.criterion criterion ->
        Error ("goal_verification: current criterion is already proven for " ^ goal_id)
    | Completion_idle | Proof_pending _ | Proof_proven _ | Proof_refuted _ | Human_confirmed _ -> fresh ())

let same_verdict_payload (stored : verdict) (incoming : verdict) =
  (* A replay may be delivered later. Its observation time cannot rewrite the
     original commit time; every item of proof and provenance must still match. *)
  stored = { incoming with recorded_at = stored.recorded_at }

let record_proof_verdict config ~goal_id (verdict : verdict) =
  update_record config ~goal_id (fun current ->
    match current.completion with
    | Proof_proven stored | Proof_refuted stored when same_verdict_payload stored verdict -> Ok current
    | Proof_pending pending
      when String.equal pending.request_id verdict.request_id
        && Goal_store.criterion_equal pending.criterion verdict.criterion ->
        (* Validate the typed write against the same strict persistence codec. *)
        let* _ = verdict_of_yojson (verdict_to_yojson verdict) in
        let completion = match verdict.outcome with
          | Proven -> Proof_proven verdict | Refuted _ -> Proof_refuted verdict
        in Ok { current with completion }
    | Completion_idle | Proof_pending _ | Proof_proven _ | Proof_refuted _ | Human_confirmed _ ->
        Error ("goal_verification: verdict does not match the pending request for " ^ goal_id))

let record_human_confirmation config ~goal_id verdict ~operator_id =
  update_record config ~goal_id (fun current ->
    if String.trim operator_id = "" then Error "operator identity is required"
    else match current.completion with
    | Human_confirmed (stored, _) when same_verdict_payload stored verdict -> Ok current
    | Proof_proven stored when same_verdict_payload stored verdict ->
        Ok {current with completion = Human_confirmed (stored,
          {operator_id; confirmed_at = Masc_domain.now_iso ()})}
    | Completion_idle | Proof_pending _ | Proof_proven _ | Proof_refuted _ | Human_confirmed _ ->
        Error "human confirmation does not match the current proven request")
