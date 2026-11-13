(* Goal proof requests and verdicts are bound to one success-criterion revision.
   Mutations use only the primary ledger. Recovery mirrors are read-only evidence.
   The caller holds the Goal lock while binding or committing a current request. *)

open Result.Syntax

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

type verifying_issue =
  | Missing_proof_record
  | Idle_proof_record
  | Mismatched_proof_record
  | Confirmed_proof_record

type verifying_record =
  | Current_pending of record * string * Goal_store.criterion
  | Current_verdict of record * verdict
  | Unavailable_request of verifying_issue

let classify_verifying_record ~goal = function
  | None -> Unavailable_request Missing_proof_record
  | Some record ->
    (match relation_for_goal ~goal record with
     | Stale_criterion -> Unavailable_request Mismatched_proof_record
     | Current ->
       match record.completion with
       | Completion_idle -> Unavailable_request Idle_proof_record
       | Proof_pending pending -> Current_pending (record, pending.request_id, pending.criterion)
       | Proof_proven verdict | Proof_refuted verdict -> Current_verdict (record, verdict)
       | Human_confirmed _ -> Unavailable_request Confirmed_proof_record)

let verifying_issue_to_string = function
  | Missing_proof_record -> "the proof record is missing while the Goal is verifying; an earlier review may still be active"
  | Idle_proof_record -> "the proof record is idle while the Goal is verifying; an earlier review may still be active"
  | Mismatched_proof_record -> "the proof record does not match the current Goal criterion; an earlier review may still be active"
  | Confirmed_proof_record -> "the proof is already confirmed while the Goal is verifying; inspect the Goal and proof record"

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

let verifications_filename = "goal_verifications.json"

let verifications_path config =
  Filename.concat (Workspace_utils.masc_dir config) verifications_filename

let verifications_recovery_path config =
  verifications_path config ^ Common.recovery_mirror_suffix

let ensure_dirs config =
  Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

type prepared_state = {
  state : state;
  records_by_goal_id : record Goal_store.Goal_id_map.t;
}

let prepare_state (state : state) : prepared_state =
  let records_by_goal_id =
    List.fold_left
      (fun acc (record : record) ->
        (* Preserve first-row precedence so [records_by_goal_id] agrees with
           [find_record] when [state.records] contains duplicate goal IDs. *)
        Goal_store.Goal_id_map.update
          record.goal_id
          (function
            | Some existing -> Some existing
            | None -> Some record)
          acc)
      Goal_store.Goal_id_map.empty
      state.records
  in
  { state; records_by_goal_id }

let default_state () =
  { version = 1; updated_at = Masc_domain.now_iso (); records = [] }

let default_prepared_state () =
  { state = default_state (); records_by_goal_id = Goal_store.Goal_id_map.empty }

(* Content-addressed prepared cache — the byte-equality and locking mechanics
   live in [Mirrored_store_cache.Content_cache], shared with the goal store.
   [state] and [record] have no mutable fields. *)
let verifications_cache : prepared_state Mirrored_store_cache.Content_cache.t =
  Mirrored_store_cache.Content_cache.create ()

let clear_verifications_cache_for path =
  Mirrored_store_cache.Content_cache.clear verifications_cache path

(* A failed follow-symlink existence check is not evidence that the directory
   entry is absent. In particular, a dangling link may name an earlier ledger. *)
let local_entry_present path =
  let result = Eio_guard.run_in_systhread ~label:"goal-proof-entry-presence" (fun () ->
    match Unix.lstat path with
    | _ -> Ok true
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
    | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)) in
  Eio_guard.check_if_ready ();
  result

let read_raw_doc config path : (string option, Workspace_utils.json_doc_error) result =
  let confirmed_local_absence () =
    match local_entry_present path with
    | Ok false -> Ok None
    | Ok true -> Error (Workspace_utils.Json_doc_unreadable "Goal proof entry exists but could not be read")
    | Error detail -> Error (Workspace_utils.Json_doc_unreadable detail) in
  let read_local () =
    (* The read runs under the ledger lock on the change paths. An open that
       waits (a FIFO with no writer) would hold that lock for good, so the
       ledger is read only as a regular file. *)
    match Fs_compat.load_regular_file_opt path with
    | Ok None -> confirmed_local_absence ()
    | Error error ->
        Error
          (Workspace_utils.Json_doc_unreadable
             (Fs_compat.regular_file_read_error_to_string error))
    | Ok (Some content) -> Ok (Some content)
  in
  match Workspace_utils.key_of_path config path with
  | Some key ->
      (match config.Workspace_utils.backend with
       | Workspace_utils.FileSystem _ when Sys.file_exists path -> read_local ()
       | Workspace_utils.Memory _ | Workspace_utils.FileSystem _ ->
           (match Workspace_utils.backend_get config ~key with
            | Error e ->
                Error
                  (Workspace_utils.Json_doc_unreadable
                     (Printf.sprintf "backend_get failed for %s: %s" key
                        (Backend_types.show_error e)))
            | Ok None ->
              (match config.Workspace_utils.backend with
               | Workspace_utils.FileSystem _ -> confirmed_local_absence ()
               | Workspace_utils.Memory _ -> Ok None)
            | Ok (Some content) -> Ok (Some content)))
  | None -> read_local ()

(* An absent ledger reads as [Ok None]; a present ledger that does not decode
   is an [Error] and never licenses a write. *)
let read_state config path : (prepared_state option, string) result =
  match read_raw_doc config path with
  | Error error ->
      clear_verifications_cache_for path;
      Error (Workspace_utils.json_doc_error_to_string error)
  | Ok None ->
      clear_verifications_cache_for path;
      Ok None
  | Ok (Some content) ->
      let cached =
        Mirrored_store_cache.Content_cache.find verifications_cache ~path
          ~bytes:content
      in
      (match cached with
       | Some prepared -> Ok (Some prepared)
       | None ->
           let trimmed = String.trim content in
           if String.equal trimmed "" then (
             clear_verifications_cache_for path;
             Error
               (Workspace_utils.json_doc_error_to_string
                  Workspace_utils.Json_doc_blank))
           else
             (* Parsing a large ledger already left the fiber; decoding it
                into records and indexing them by Goal did not, and for a
                ledger that size they are a run of the same order. The three
                read nothing but the text, so one pool job does them all. A
                small ledger is decoded where it is read, on the boundary
                [Safe_ops.parse_json_off_fiber] uses. *)
             let decode () =
               match Safe_ops.parse_json_safe ~context:path trimmed with
               | Error detail ->
                   Error
                     (Workspace_utils.json_doc_error_to_string
                        (Workspace_utils.Json_doc_unparsable detail))
               | Ok json -> Result.map prepare_state (state_of_yojson json)
             in
             let decoded =
               if String.length trimmed < Safe_ops.json_parse_offload_min_bytes
               then decode ()
               else Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ decode
             in
             match decoded with
             | Error _ as err ->
                 clear_verifications_cache_for path;
                 err
             | Ok prepared ->
                 Mirrored_store_cache.Content_cache.replace
                   verifications_cache path content prepared;
                 Ok (Some prepared))

(* When the primary is absent, an existing or uninspectable mirror cannot be
   treated as a new empty ledger. Inspect the entry itself so a dangling
   symlink or FIFO still counts, without opening the mirror's contents. *)
let recovery_mirror_present config backend =
  let path = verifications_recovery_path config in
  let backend_root = Backend.FileSystem.physical_root backend in
  Eio_guard.check_if_ready ();
  match backend_root with
  | Error error -> Error (Backend_types.show_error error)
  | Ok backend_root ->
    let local_root = Eio_guard.run_in_systhread ~label:"goal-proof-workspace-root" (fun () ->
      match Unix.realpath (Workspace_utils.masc_dir config) with
      | root -> Ok root
      | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)) in
    Eio_guard.check_if_ready ();
    match local_root with
    | Error _ as error -> error
    | Ok local_root when String.equal backend_root local_root -> local_entry_present path
    | Ok _ -> Error "Goal proof backend and workspace roots differ"

type authority_backend_error = Memory_proof_authority_unavailable

let authority_backend_error_to_string = function
  | Memory_proof_authority_unavailable ->
    "goal_verification: Memory backend cannot safely provide proof authority; restore a filesystem-backed workspace context"

let filesystem_authority config =
  match config.Workspace_utils.backend with
  | Workspace_utils.Memory _ -> Error Memory_proof_authority_unavailable
  | Workspace_utils.FileSystem backend -> Ok backend

let check_authority_backend config =
  Result.map (fun _ -> ()) (filesystem_authority config)

type primary_unavailable =
  | Primary_undecodable of string
  | Primary_backend_unavailable of authority_backend_error

let load_primary_state config =
  match filesystem_authority config with
  | Error unavailable -> Error (Primary_backend_unavailable unavailable)
  | Ok backend ->
    ensure_dirs config;
    match read_state config (verifications_path config) with
    | Error detail -> Error (Primary_undecodable detail)
    | Ok (Some prepared) -> Ok prepared
    | Ok None ->
        (match recovery_mirror_present config backend with
         | Ok false -> Ok (default_prepared_state ())
         | Ok true -> Error (Primary_undecodable "primary ledger is missing while its recovery mirror exists")
         | Error detail ->
           Error (Primary_undecodable
                    ("primary ledger is missing and its recovery mirror cannot be inspected: " ^ detail)))

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

let primary_unavailable_error config ~writing = function
  | Primary_undecodable detail ->
    if writing then undecodable_store_error config detail
    else undecodable_load_error config detail
  | Primary_backend_unavailable unavailable -> authority_backend_error_to_string unavailable

let write_state_result config state =
  ensure_dirs config;
  let primary = verifications_path config in
  let recovery = verifications_recovery_path config in
  clear_verifications_cache_for primary;
  clear_verifications_cache_for recovery;
  (* One encoding serves both files, on the pool. Each file used to encode
     the document again on the calling fiber: for the 1.3 MB ledger of
     2026-11-12 that was two runs of 129 ms and 120 ms on the main domain for
     one update. The same job decodes the document it encodes -- the state a
     reader decodes from those bytes, with the UTF-8 repair the encoding
     applies -- so the read after this write finds the bytes it reads already
     decoded. *)
  let content, reread =
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
      let json = Safe_ops.sanitize_json_utf8 (state_to_yojson state) in
      ( Workspace_utils.encode_json_pretty json
      , Result.map prepare_state (state_of_yojson json) ))
  in
  let* () = Workspace_utils.write_encoded_json_result config primary content in
  (match reread with
   | Ok prepared ->
     Mirrored_store_cache.Content_cache.replace
       verifications_cache primary (content :> string) prepared
   | Error (_ : string) -> ());
  Goal_store.projection_source_changed config;
  (match Workspace_utils.write_encoded_json_result config recovery content
   with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "goal_verification: primary committed; recovery mirror write failed for \
        %s: %s"
       recovery
       msg);
  Ok ()

(* {1 Record operations}

   Every mutation is a locked read-modify-write that refuses an undecodable
   authoritative store. *)

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
      | Error unavailable -> Error (primary_unavailable_error config ~writing:true unavailable)
      | Ok prepared ->
          let state = prepared.state in
          let current =
            match Goal_store.Goal_id_map.find_opt goal_id prepared.records_by_goal_id with
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
   verification state load once per request via
   {!load_records_by_goal_id_authoritative} and render the error through
   {!ledger_error_to_yojson}. *)
let load_records_by_goal_id_authoritative config =
  match load_primary_state config with
  | Ok prepared -> Ok prepared.records_by_goal_id
  | Error unavailable -> Error (primary_unavailable_error config ~writing:false unavailable)

let get_record_authoritative config ~goal_id =
  let* records_by_goal_id = load_records_by_goal_id_authoritative config in
  Ok (Goal_store.Goal_id_map.find_opt goal_id records_by_goal_id)

let ledger_error_to_yojson detail =
  `Assoc [ "state", `String "ledger_error"; "detail", `String detail ]

type reopen_outcome =
  | Proof_unchanged of record option
  | Proof_reset of record

let archive_reopened_proof config ~goal_id ~actor ~at completion =
  Goal_store.append_audit_event_after_pending_locked config
    (`Assoc
      [ "ts", `String at
      ; "goal_id", `String goal_id
      ; "event_type", `String "goal_proof_reopened"
      ; "payload", `Assoc
          [ "phase", Goal_phase.to_yojson Goal_phase.Executing
          ; "actor", `String actor
          ; "previous_completion", completion_state_to_yojson completion
          ]
      ])
  |> Result.map_error (fun detail -> "could not preserve reopened Goal proof: " ^ detail)
;;

let reopen_goal config ~goal_id ~actor ~note =
  let* goal, (outcome, phase_changed) =
    (* The reopen chain is a string [let*]; the store's typed refusal is
       rendered here at its end (RFC-0444 PR-1). *)
    Result.map_error Goal_store.write_error_to_string @@
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
        let* prepared = match load_primary_state config with
          | Ok prepared -> Ok prepared
          | Error unavailable -> Error (primary_unavailable_error config ~writing:true unavailable)
        in
        let state = prepared.state in
        let current =
          Goal_store.Goal_id_map.find_opt goal_id prepared.records_by_goal_id
        in
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

let record_proof_verdict ?before_commit config ~goal_id (verdict : verdict) =
  update_record config ~goal_id (fun current ->
    match current.completion with
    | Proof_proven stored | Proof_refuted stored when same_verdict_payload stored verdict -> Ok current
    | Proof_pending pending
      when String.equal pending.request_id verdict.request_id
        && Goal_store.criterion_equal pending.criterion verdict.criterion ->
        (* Validate the typed write against the same strict persistence codec. *)
        let* _ = verdict_of_yojson (verdict_to_yojson verdict) in
        let* () = match before_commit with None -> Ok () | Some step -> step () in
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

type review_binding_error =
  | No_current_review of string
  | Binding_unavailable of string

let review_binding_error_to_string = function
  | No_current_review detail | Binding_unavailable detail -> detail

let bind_review config ~goal_id =
  match Goal_store.transact_goal config ~goal_id (fun goal ->
    let binding = match goal.Goal_store.phase with
      | Goal_phase.Awaiting_confirmation | Goal_phase.Executing | Goal_phase.Completed | Goal_phase.Dropped
      | Goal_phase.Paused _ | Goal_phase.Blocked _ ->
        Error (No_current_review "goal is not awaiting verification")
      | Goal_phase.Verifying ->
        (match get_record_authoritative config ~goal_id with
         | Error detail -> Error (Binding_unavailable detail)
         | Ok record ->
           match classify_verifying_record ~goal record with
           | Current_pending (record, request_id, criterion) ->
             Ok (request_id, criterion, record.submitted_evidence)
           | Current_verdict _ ->
             Error (No_current_review "goal has a committed proof verdict")
           | Unavailable_request issue ->
             Error (Binding_unavailable (verifying_issue_to_string issue))) in
    Ok (goal, binding)) with
  | Ok (goal, Ok binding) -> Ok (goal, binding)
  | Ok (_, Error error) -> Error error
  | Error (Goal_store.Goal_not_found _ as error) ->
    Error (No_current_review (Goal_store.write_error_to_string error))
  | Error (Goal_store.Store_unavailable _ | Goal_identity_ambiguous _ | Rejected _ | Persist_failed _ as error) ->
    Error (Binding_unavailable (Goal_store.write_error_to_string error))
