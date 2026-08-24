(* Goal_verification — per-goal success-condition verification ledger
   (RFC-0387).

   Lives beside [Goal_store] rather than inside it: the goal record is
   constructed by literal in external callers (goal_store.mli), so the
   completion verification state gets its own store, the same way
   [Workspace_goal_index] keeps goal-task links out of goals.json.

   RFC-0387 stage 1 shipped this as a RECORD-ONLY evidence store; stage 2
   (the verifier gate) wires the writers: [mark_*_pending] durable requests
   (creation hook, and before the phase enters [Verifying]) and verdict
   commits from the verifier lane via [masc_goal_transition].

   Invariants carried here:

   - No wall-clock expiry: pending states remain durable until a verdict is
     committed.
   - Failure keeps its evidence: a refuted verdict stays on the record until
     the next request supersedes it.
   - Fail-closed mutations: a store that does not decode refuses every
     mutation, mirroring [Goal_store.update_state].
   - Fail-loud reads: a store that does not decode is an [Error] for every
     reader, never a silent "not verified yet". *)

let ( let* ) = Result.bind

type verdict_outcome =
  | Proven
  | Refuted of { reason : string }

type verdict = {
  outcome : verdict_outcome;
  verification_run_id : string;
  authority : Masc_domain.completion_authority;
  evidence : string;
  recorded_at : string;
}

type completion_state =
  | Completion_idle
  | Proof_pending of { requested_at : string }
  | Proof_proven of verdict
  | Proof_refuted of verdict

type record = {
  goal_id : string;
  completion : completion_state;
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
  ; updated_at = Masc_domain.now_iso ()
  }

(* {1 Codecs}

   Strict, same discipline as [Goal_store.goal_of_yojson]: unknown fields and
   unknown variant strings are decode errors, never a silent default. The only
   lenient case is the absent record itself (a pre-RFC-0387 goal), which
   [get_record] reports as [Ok None] and callers render through
   {!default_record}. *)

let authority_to_yojson authority =
  `Assoc
    [ "kind", `String (Masc_domain.completion_authority_kind authority)
    ; "actor", `String (Masc_domain.completion_authority_actor authority)
    ]

let authority_of_yojson json =
  match
    Json_util.assoc_member_opt "kind" json, Json_util.assoc_member_opt "actor" json
  with
  | Some (`String "human_operator"), Some (`String actor) ->
      Ok (Masc_domain.Human_operator { operator_id = actor })
  | Some (`String "system_llm_agent"), Some (`String actor) ->
      Ok (Masc_domain.System_llm_agent { agent_run_id = actor })
  | _ ->
      Error
        ("goal_verification.authority_of_yojson: " ^ Yojson.Safe.to_string json)

let verdict_to_yojson (v : verdict) =
  let outcome_fields =
    match v.outcome with
    | Proven -> [ "outcome", `String "proven"; "reason", `Null ]
    | Refuted { reason } ->
        [ "outcome", `String "refuted"; "reason", `String reason ]
  in
  `Assoc
    (outcome_fields
     @ [ "verification_run_id", `String v.verification_run_id
       ; "authority", authority_to_yojson v.authority
       ; "evidence", `String v.evidence
       ; "recorded_at", `String v.recorded_at
       ])

let verdict_of_yojson = function
  | `Assoc fields -> (
      let unknown =
        List.find_map
          (fun (field, _) ->
            (* strict wire-boundary decoder: rejects unknown fields. STR-OK *)
            if List.mem field
                 [ "outcome"
                 ; "reason"
                 ; "verification_run_id"
                 ; "authority"
                 ; "evidence"
                 ; "recorded_at"
                 ]
            then None
            else Some field)
          fields
      in
      match unknown with
      | Some field ->
          Error
            (Printf.sprintf
               "goal_verification.verdict_of_yojson: unknown field %S" field)
      | None -> (
          let json = `Assoc fields in
          match
            ( Json_util.assoc_member_opt "outcome" json
            , Json_util.get_string json "verification_run_id"
            , Json_util.get_string json "evidence"
            , Json_util.assoc_member_opt "recorded_at" json )
          with
          | ( Some (`String outcome)
            , Some verification_run_id
            , Some evidence
            , Some (`String recorded_at) ) -> (
              if String.trim verification_run_id = ""
              then
                Error
                  "goal_verification.verdict_of_yojson: verification_run_id is blank"
              else
              match authority_of_yojson (Yojson.Safe.Util.member "authority" json) with
              | Error _ as error -> error
              | Ok authority -> (
                  match outcome with
                  | "proven" ->
                      Ok
                        { outcome = Proven
                        ; verification_run_id
                        ; authority
                        ; evidence
                        ; recorded_at
                        }
                  | "refuted" -> (
                      match Json_util.get_string json "reason" with
                      | Some reason ->
                          Ok
                            { outcome = Refuted { reason }
                            ; verification_run_id
                            ; authority
                            ; evidence
                            ; recorded_at
                            }
                      | None ->
                          Error
                            "goal_verification.verdict_of_yojson: refuted verdict \
                             has no reason")
                  | other ->
                      Error
                        ("goal_verification.verdict_of_yojson: unknown outcome "
                         ^ other)))
          | _ ->
              Error
                "goal_verification.verdict_of_yojson: outcome, \
                 verification_run_id, evidence and recorded_at are required"))
  | json ->
      Error ("goal_verification.verdict_of_yojson: " ^ Yojson.Safe.to_string json)

let completion_state_to_yojson = function
  | Completion_idle -> `Assoc [ "state", `String "idle" ]
  | Proof_pending { requested_at } ->
      `Assoc
        [ "state", `String "proof_pending"
        ; "requested_at", `String requested_at
        ]
  | Proof_proven verdict ->
      `Assoc
        [ "state", `String "proof_proven"; "verdict", verdict_to_yojson verdict ]
  | Proof_refuted verdict ->
      `Assoc
        [ "state", `String "proof_refuted"; "verdict", verdict_to_yojson verdict ]

let completion_state_of_yojson json =
  match Json_util.assoc_member_opt "state" json with
  | Some (`String "idle") -> Ok Completion_idle
  | Some (`String "proof_pending") -> (
      match Json_util.assoc_member_opt "requested_at" json with
      | Some (`String requested_at) -> Ok (Proof_pending { requested_at })
      | _ -> Error "goal_verification: proof_pending has no requested_at")
  | Some (`String "proof_proven") -> (
      match verdict_of_yojson (Yojson.Safe.Util.member "verdict" json) with
      | Ok verdict -> Ok (Proof_proven verdict)
      | Error _ as error -> error)
  | Some (`String "proof_refuted") -> (
      match verdict_of_yojson (Yojson.Safe.Util.member "verdict" json) with
      | Ok verdict -> Ok (Proof_refuted verdict)
      | Error _ as error -> error)
  | Some (`String other) ->
      Error ("goal_verification: unknown completion state " ^ other)
  | _ -> Error "goal_verification: completion state missing"

let record_to_yojson (record : record) =
  `Assoc
    [ "goal_id", `String record.goal_id
    ; "completion", completion_state_to_yojson record.completion
    ; "updated_at", `String record.updated_at
    ]

let record_of_yojson = function
  | `Assoc fields -> (
      let unknown =
        List.find_map
          (fun (field, _) ->
            (* strict wire-boundary decoder: this membership test *rejects*
               unknown record fields (constitution strict-parse). STR-OK *)
            if List.mem field [ "goal_id"; "completion"; "updated_at" ]
            then None
            else Some field)
          fields
      in
      match unknown with
      | Some field ->
          Error
            (Printf.sprintf
               "goal_verification.record_of_yojson: unknown field %S" field)
      | None -> (
          let json = `Assoc fields in
          match
            Json_util.assoc_member_opt "goal_id" json
          , Json_util.assoc_member_opt "updated_at" json
          with
          | Some (`String goal_id), Some (`String updated_at) -> (
              match
                completion_state_of_yojson
                  (Yojson.Safe.Util.member "completion" json)
              with
              | Ok completion -> Ok { goal_id; completion; updated_at }
              | Error _ as error -> error)
          | _ ->
              Error "goal_verification.record_of_yojson: goal_id and updated_at \
                     are required"))
  | json ->
      Error ("goal_verification.record_of_yojson: " ^ Yojson.Safe.to_string json)

let state_to_yojson (state : state) =
  `Assoc
    [ "version", `Int state.version
    ; "updated_at", `String state.updated_at
    ; "records", `List (List.map record_to_yojson state.records)
    ]

let state_of_yojson = function
  | `Assoc _ as json -> (
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
            (collect [] records_json)
      | _ -> Error "goal_verification.state_of_yojson: invalid state")
  | json ->
      Error ("goal_verification.state_of_yojson: " ^ Yojson.Safe.to_string json)

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
  let path = verifications_path config in
  if Workspace_utils.path_exists config path then
    match Workspace_utils.read_json_result config path with
    | Ok json -> (
        match state_of_yojson json with
        | Ok state -> Loaded state
        | Error primary_msg ->
            let recovery = verifications_recovery_path config in
            if Workspace_utils.path_exists config recovery then
              match Workspace_utils.read_json_result config recovery with
              | Ok recovery_json -> (
                  match state_of_yojson recovery_json with
                  | Ok state ->
                      Log.Misc.warn
                        "goal_verification: primary store corrupt (%s), recovered \
                         from %s"
                        primary_msg recovery;
                      Loaded state
                  | Error recovery_msg ->
                      Undecodable
                        (Printf.sprintf "primary: %s; recovery: %s"
                           primary_msg recovery_msg))
              | Error recovery_read_msg ->
                  Undecodable
                    (Printf.sprintf "primary: %s; recovery unreadable: %s"
                       primary_msg recovery_read_msg)
            else Undecodable primary_msg)
    | Error primary_msg ->
        let recovery = verifications_recovery_path config in
        if Workspace_utils.path_exists config recovery then
          match Workspace_utils.read_json_result config recovery with
          | Ok recovery_json -> (
              match state_of_yojson recovery_json with
              | Ok state ->
                  Log.Misc.warn
                    "goal_verification: primary store unreadable (%s), recovered \
                     from %s"
                    primary_msg recovery;
                  Loaded state
              | Error recovery_msg ->
                  Undecodable
                    (Printf.sprintf "primary unreadable: %s; recovery: %s"
                       primary_msg recovery_msg))
          | Error recovery_msg ->
              Undecodable
                (Printf.sprintf
                   "primary unreadable: %s; recovery unreadable: %s"
                   primary_msg recovery_msg)
        else Undecodable primary_msg
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
      match load_state config with
      | Undecodable detail -> Error (undecodable_store_error config detail)
      | Loaded state ->
          let current =
            match find_record state.records goal_id with
            | Some record -> record
            | None -> default_record ~goal_id
          in
          let now = Masc_domain.now_iso () in
          let* updated = f { current with updated_at = now } in
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

let ledger_error_to_yojson detail =
  `Assoc [ "state", `String "ledger_error"; "detail", `String detail ]

(* {1 Durable proof request (RFC-0387 §4.1)}

   [mark_proof_pending] runs before the phase enters [Verifying], so the
   request survives a crash between the ledger write and the phase write. It
   is a locked read-modify-write via [update_record], idempotent on an
   already-pending state (a repeated [request_complete] re-arms rather than
   failing), and refuses to overwrite a committed [Proof_proven] verdict — a
   new request does supersede a standing [Proof_refuted], per this module's
   header: a refuted verdict stays on the record until the next request
   supersedes it, and the refuted goal returns to [Executing] where
   re-requesting completion is the way forward. *)

let mark_proof_pending config ~goal_id =
  update_record config ~goal_id (fun current ->
      match current.completion with
      | Proof_pending _ -> Ok current
      | Completion_idle ->
          Ok
            { current with
              completion = Proof_pending { requested_at = current.updated_at }
            }
      | Proof_refuted _ ->
          (* The next request supersedes the standing refutation; the verdict
             itself remains readable in the state history until this write. *)
          Ok
            { current with
              completion = Proof_pending { requested_at = current.updated_at }
            }
      | Proof_proven _ ->
          Error
            (Printf.sprintf
               "goal_verification: proof for %s is already proven; refusing \
                to overwrite the verdict with a pending request"
               goal_id))

(* A proof verdict is only committable against a pending proof — or against
   the same outcome already committed. The latter is the crash-between-writes
   case: the ledger write landed but the phase write did not, and the retried
   transition must be able to re-commit the identical outcome rather than
   wedge the goal. A commit in the OPPOSITE direction of a standing verdict is
   a stale verifier answer and stays an [Error]. The [Proof_pending] rows this
   matches against are written by [mark_proof_pending]
   (persist-before-model-call).

   This is the only thing the commit refuses, and it is about the record's own
   history: whether this verdict can follow the one already standing. It does
   not read any other fact and decline on that basis. Whether the goal reached
   its target is what the verdict says; nothing here decides that for it. *)
let record_proof_verdict config ~goal_id (verdict : verdict) =
  update_record config ~goal_id (fun current ->
      let committable =
        match current.completion, verdict.outcome with
        | Proof_pending _, _ -> true
        | Proof_proven _, Proven -> true
        | Proof_refuted _, Refuted _ -> true
        | ( Proof_proven _, Refuted _ )
        | ( Proof_refuted _, Proven )
        | Completion_idle, _ -> false
      in
      if not committable
      then
        Error
          (Printf.sprintf
             "goal_verification: proof verdict for %s has no pending proof \
              request"
             goal_id)
      else
        let completion =
          match verdict.outcome with
          | Proven -> Proof_proven verdict
          | Refuted _ -> Proof_refuted verdict
        in
        Ok { current with completion })
