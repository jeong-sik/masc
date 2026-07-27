module Exact_output = Agent_sdk.Exact_output

type evidence_kind =
  | Domain_settlement
  | Scope_retirement
  | Measurement_receipt

type measurement_boundary =
  | Before_measurement_dispatch
  | Measurement_terminal

type recovery_origin =
  | Fresh_start
  | Recovered of { evidence_count : int }

type evidence_decode_error =
  | Invalid_domain_settlement_intent of
      { index : int
      ; cause : Exact_output.domain_settlement_intent_decode_error
      }
  | Invalid_scope_retirement_intent of
      { index : int
      ; cause : Exact_output.flow_preference_retirement_intent_decode_error
      }
  | Invalid_measurement_receipt of
      { index : int
      ; cause : Exact_output.measurement_receipt_snapshot_decode_error
      }
  | Invalid_measurement_transition of
      { index : int
      ; operation_id : string
      ; cause : Exact_output.measurement_receipt_transition_conflict
      }

type journal_decode_error =
  | Journal_malformed_json of string
  | Journal_invalid_fields
  | Journal_unknown_format of string
  | Journal_unsupported_version of int
  | Journal_invalid_field of string
  | Journal_owner_mismatch of string
  | Journal_unknown_evidence_kind of
      { index : int
      ; kind : string
      }
  | Journal_invalid_evidence of evidence_decode_error
  | Journal_integrity_mismatch

type load_error =
  | Invalid_owner_identity of string
  | Journal_read_failed of
      { path : string
      ; detail : string
      }
  | Journal_decode_failed of
      { path : string
      ; cause : journal_decode_error
      }
  | Journal_initialize_failed of
      { path : string
      ; cause : Keeper_fs.durable_write_error
      }
  | Preference_recovery_failed of Exact_output.flow_preference_recovery_error

type commit_error =
  | Evidence_conflict of
      { kind : evidence_kind
      ; evidence_id : string
      }
  | Evidence_write_failed of Keeper_fs.durable_write_error
  | Measurement_transition_rejected of
      { boundary : measurement_boundary
      ; operation_id : string
      ; cause : Exact_output.measurement_receipt_transition_conflict
      }

type identity =
  { keeper_name : string
  ; keeper_generation : string
  ; surface : string
  }

type evidence =
  | Domain_settlement_evidence of
      { intent : Exact_output.domain_settlement_intent
      ; encoded : string
      }
  | Scope_retirement_evidence of
      { intent : Exact_output.flow_preference_retirement_intent
      ; encoded : string
      }
  | Measurement_receipt_evidence of
      { snapshot : Exact_output.measurement_receipt_snapshot
      ; encoded : string
      }

type durable_writer =
  on_durable_commit:(unit -> unit)
  -> ownership_root:string
  -> path:string
  -> bytes:string
  -> (Keeper_fs.durable_commit_outcome, Keeper_fs.durable_write_error) result

type t =
  { identity : identity
  ; ownership_root : string
  ; path : string
  ; durable_write : durable_writer
  ; mutex : Eio.Mutex.t
  ; mutable evidence : evidence list
  }

let ( let* ) = Result.bind
let journal_format = "masc.keeper-exact-flow-preference-evidence-journal"
let journal_version = 2
let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let evidence_kind_to_string = function
  | Domain_settlement -> "domain_settlement"
  | Scope_retirement -> "scope_retirement"
  | Measurement_receipt -> "measurement_receipt"
;;

let evidence_kind = function
  | Domain_settlement_evidence _ -> Domain_settlement
  | Scope_retirement_evidence _ -> Scope_retirement
  | Measurement_receipt_evidence _ -> Measurement_receipt
;;

let evidence_encoded = function
  | Domain_settlement_evidence { encoded; _ }
  | Scope_retirement_evidence { encoded; _ }
  | Measurement_receipt_evidence { encoded; _ } -> encoded
;;

let evidence_id = function
  | Domain_settlement_evidence { intent; _ } ->
    Exact_output.domain_settlement_intent_id intent
    |> Exact_output.domain_settlement_id_to_string
  | Scope_retirement_evidence { intent; _ } ->
    Exact_output.flow_preference_retirement_intent_id intent
    |> Exact_output.flow_preference_retirement_id_to_string
  | Measurement_receipt_evidence { snapshot; _ } ->
    snapshot
    |> Exact_output.measurement_receipt_operation_id
    |> Exact_output.measurement_operation_id_to_string
;;

let recovery_evidence = function
  | Domain_settlement_evidence { intent; _ } ->
    Some (Exact_output.Domain_settlement_evidence intent)
  | Scope_retirement_evidence { intent; _ } ->
    Some (Exact_output.Scope_retirement_evidence intent)
  | Measurement_receipt_evidence _ -> None
;;

let evidence_to_json evidence =
  `Assoc
    [ "kind", `String (evidence_kind evidence |> evidence_kind_to_string)
    ; "encoded", `String (evidence_encoded evidence)
    ]
;;

let payload_fields identity evidence =
  [ "format", `String journal_format
  ; "version", `Int journal_version
  ; "keeper_name", `String identity.keeper_name
  ; "keeper_generation", `String identity.keeper_generation
  ; "surface", `String identity.surface
  ; "evidence", `List (List.map evidence_to_json evidence)
  ]
;;

let encode_document identity evidence =
  let payload = payload_fields identity evidence in
  let integrity_sha256 = `Assoc payload |> Yojson.Safe.to_string |> sha256 in
  `Assoc (payload @ [ "integrity_sha256", `String integrity_sha256 ])
  |> Yojson.Safe.to_string
;;

let expected_document_fields =
  [ "format"
  ; "version"
  ; "keeper_name"
  ; "keeper_generation"
  ; "surface"
  ; "evidence"
  ; "integrity_sha256"
  ]
;;

let exact_fields expected fields =
  List.map fst fields |> List.sort String.compare
  = List.sort String.compare expected
;;

let find_field fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Journal_invalid_field name)
;;

let string_field fields name =
  let* value = find_field fields name in
  match value with
  | `String value -> Ok value
  | _ -> Error (Journal_invalid_field name)
;;

let decode_evidence index = function
  | `Assoc fields when exact_fields [ "kind"; "encoded" ] fields ->
    let* kind = string_field fields "kind" in
    let* encoded = string_field fields "encoded" in
    (match kind with
     | "domain_settlement" ->
       (match Exact_output.domain_settlement_intent_of_string encoded with
        | Ok intent -> Ok (Domain_settlement_evidence { intent; encoded })
        | Error cause ->
          Error
            (Journal_invalid_evidence
               (Invalid_domain_settlement_intent { index; cause })))
     | "scope_retirement" ->
       (match Exact_output.flow_preference_retirement_intent_of_string encoded with
        | Ok intent -> Ok (Scope_retirement_evidence { intent; encoded })
        | Error cause ->
          Error
            (Journal_invalid_evidence
               (Invalid_scope_retirement_intent { index; cause })))
     | "measurement_receipt" ->
       (match Exact_output.measurement_receipt_snapshot_of_string encoded with
        | Ok snapshot ->
          Ok (Measurement_receipt_evidence { snapshot; encoded })
        | Error cause ->
          Error
            (Journal_invalid_evidence
               (Invalid_measurement_receipt { index; cause })))
     | kind -> Error (Journal_unknown_evidence_kind { index; kind }))
  | `Assoc _
  | _ -> Error (Journal_invalid_field (Printf.sprintf "evidence[%d]" index))
;;

let validate_measurement_history evidence =
  let latest = Hashtbl.create 16 in
  let rec loop index = function
    | [] -> Ok ()
    | (Domain_settlement_evidence _ | Scope_retirement_evidence _) :: rest ->
      loop (index + 1) rest
    | Measurement_receipt_evidence { snapshot; _ } :: rest ->
      let operation_id =
        snapshot
        |> Exact_output.measurement_receipt_operation_id
        |> Exact_output.measurement_operation_id_to_string
      in
      let previous = Hashtbl.find_opt latest operation_id in
      (match
         Exact_output.classify_measurement_receipt_transition
           ~previous
           ~incoming:snapshot
       with
       | Exact_output.Measurement_dispatch_intent
       | Exact_output.Measurement_terminal_advance ->
         Hashtbl.replace latest operation_id snapshot;
         loop (index + 1) rest
       | Exact_output.Measurement_idempotent_replay ->
         Error
           (Journal_invalid_evidence
              (Invalid_measurement_transition
                 { index
                 ; operation_id
                 ; cause = Exact_output.Measurement_evidence_conflict
                 }))
       | Exact_output.Measurement_transition_conflict cause ->
         Error
           (Journal_invalid_evidence
              (Invalid_measurement_transition { index; operation_id; cause })))
  in
  loop 0 evidence
;;

let decode_document identity encoded =
  try
    match Yojson.Safe.from_string encoded with
    | `Assoc fields when exact_fields expected_document_fields fields ->
      let* format = string_field fields "format" in
      let* () =
        if String.equal format journal_format
        then Ok ()
        else Error (Journal_unknown_format format)
      in
      let* version = find_field fields "version" in
      let* () =
        match version with
        | `Int version when version = journal_version -> Ok ()
        | `Int version -> Error (Journal_unsupported_version version)
        | _ -> Error (Journal_invalid_field "version")
      in
      let* keeper_name = string_field fields "keeper_name" in
      let* keeper_generation = string_field fields "keeper_generation" in
      let* surface = string_field fields "surface" in
      let* () =
        if String.equal keeper_name identity.keeper_name
        then Ok ()
        else Error (Journal_owner_mismatch "keeper_name")
      in
      let* () =
        if String.equal keeper_generation identity.keeper_generation
        then Ok ()
        else Error (Journal_owner_mismatch "keeper_generation")
      in
      let* () =
        if String.equal surface identity.surface
        then Ok ()
        else Error (Journal_owner_mismatch "surface")
      in
      let* evidence_json = find_field fields "evidence" in
      let* evidence =
        match evidence_json with
        | `List values ->
          let rec loop index decoded = function
            | [] -> Ok (List.rev decoded)
            | value :: rest ->
              let* evidence = decode_evidence index value in
              loop (index + 1) (evidence :: decoded) rest
          in
          loop 0 [] values
        | _ -> Error (Journal_invalid_field "evidence")
      in
      let* integrity_sha256 = string_field fields "integrity_sha256" in
      let expected_integrity =
        payload_fields identity evidence
        |> fun payload -> `Assoc payload
        |> Yojson.Safe.to_string
        |> sha256
      in
      let* () =
        if String.equal integrity_sha256 expected_integrity
        then Ok ()
        else Error Journal_integrity_mismatch
      in
      let* () = validate_measurement_history evidence in
      Ok evidence
    | `Assoc _ | _ -> Error Journal_invalid_fields
  with
  | Yojson.Json_error detail -> Error (Journal_malformed_json detail)
;;

let journal_path ~base_path identity =
  let identity_digest =
    String.concat
      "\000"
      [ identity.keeper_name; identity.keeper_generation; identity.surface ]
    |> sha256
  in
  Filename.concat
    (Filename.concat
       (Common.keepers_runtime_dir_of_base ~base_path)
       ".exact-flow-preferences")
    (identity_digest ^ ".journal.json")
;;

let production_durable_write ~on_durable_commit ~ownership_root ~path ~bytes =
  Keeper_fs.save_bytes_durable_atomic_observed
    ~on_durable_commit
    ~ownership_root
    path
    bytes
;;

let write_document journal evidence =
  let bytes = encode_document journal.identity evidence in
  match
    journal.durable_write
      ~on_durable_commit:(fun () -> journal.evidence <- evidence)
      ~ownership_root:journal.ownership_root
      ~path:journal.path
      ~bytes
  with
  | Ok Keeper_fs.Committed -> Ok ()
  | Ok (Keeper_fs.Committed_but_observer_failed (exn, backtrace)) ->
    Printexc.raise_with_backtrace exn backtrace
  | Error cause -> Error (Evidence_write_failed cause)
;;

let append journal next =
  Eio_guard.with_mutex journal.mutex (fun () ->
    let next_kind = evidence_kind next in
    let next_id = evidence_id next in
    let existing =
      List.find_opt
        (fun current ->
           evidence_kind current = next_kind
           && String.equal (evidence_id current) next_id)
        journal.evidence
    in
    match existing with
    | Some current
      when String.equal (evidence_encoded current) (evidence_encoded next) -> Ok ()
    | Some _ ->
      Error (Evidence_conflict { kind = next_kind; evidence_id = next_id })
    | None -> write_document journal (journal.evidence @ [ next ]))
;;

let commit_domain_settlement journal intent =
  append
    journal
    (Domain_settlement_evidence
       { intent; encoded = Exact_output.domain_settlement_intent_to_string intent })
;;

let commit_scope_retirement journal intent =
  append
    journal
    (Scope_retirement_evidence
       { intent
       ; encoded = Exact_output.flow_preference_retirement_intent_to_string intent
       })
;;

let measurement_phase snapshot =
  Exact_output.measurement_receipt_phase snapshot
;;

let latest_measurement journal operation_id =
  List.rev journal.evidence
  |> List.find_map (function
    | Measurement_receipt_evidence { snapshot; _ }
      when String.equal (evidence_id (Measurement_receipt_evidence
                                      { snapshot; encoded = "" }))
             operation_id ->
      Some snapshot
    | Domain_settlement_evidence _
    | Scope_retirement_evidence _
    | Measurement_receipt_evidence _ ->
      None)
;;

let reject_measurement boundary operation_id cause =
  Error (Measurement_transition_rejected { boundary; operation_id; cause })
;;

let commit_measurement boundary journal snapshot =
  Eio_guard.with_mutex journal.mutex (fun () ->
    let operation_id =
      snapshot
      |> Exact_output.measurement_receipt_operation_id
      |> Exact_output.measurement_operation_id_to_string
    in
    let previous = latest_measurement journal operation_id in
    let transition =
      Exact_output.classify_measurement_receipt_transition
        ~previous
        ~incoming:snapshot
    in
    let phase = measurement_phase snapshot in
    match boundary, transition with
    | Before_measurement_dispatch, Exact_output.Measurement_dispatch_intent
      when phase = Exact_output.Measurement_fence_committed ->
      write_document
        journal
        (journal.evidence
         @ [ Measurement_receipt_evidence
               { snapshot
               ; encoded =
                   Exact_output.measurement_receipt_snapshot_to_string snapshot
               }
           ])
    | Measurement_terminal, Exact_output.Measurement_terminal_advance
      when phase = Exact_output.Measurement_terminal ->
      write_document
        journal
        (journal.evidence
         @ [ Measurement_receipt_evidence
               { snapshot
               ; encoded =
                   Exact_output.measurement_receipt_snapshot_to_string snapshot
               }
           ])
    | Before_measurement_dispatch, Exact_output.Measurement_idempotent_replay
      when phase = Exact_output.Measurement_fence_committed ->
      Ok ()
    | Measurement_terminal, Exact_output.Measurement_idempotent_replay
      when phase = Exact_output.Measurement_terminal ->
      Ok ()
    | _, Exact_output.Measurement_transition_conflict cause ->
      reject_measurement boundary operation_id cause
    | _, (Exact_output.Measurement_dispatch_intent
         | Exact_output.Measurement_terminal_advance
         | Exact_output.Measurement_idempotent_replay) ->
      reject_measurement
        boundary
        operation_id
        (Exact_output.Measurement_invalid_commit_phase phase))
;;

let commit_measurement_dispatch_intent journal snapshot =
  commit_measurement Before_measurement_dispatch journal snapshot
;;

let commit_measurement_terminal journal snapshot =
  commit_measurement Measurement_terminal journal snapshot
;;

let read_file path =
  try
    Eio_guard.run_in_systhread (fun () ->
      if not (Sys.file_exists path)
      then Ok None
      else
        let channel = open_in_bin path in
        Fun.protect
          ~finally:(fun () -> close_in_noerr channel)
          (fun () ->
             let length = in_channel_length channel in
             Ok (Some (really_input_string channel length))))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let valid_identity_field value = not (String.equal (String.trim value) "")

let initialize_current_journal journal =
  let bytes = encode_document journal.identity [] in
  match
    journal.durable_write
      ~on_durable_commit:(fun () -> journal.evidence <- [])
      ~ownership_root:journal.ownership_root
      ~path:journal.path
      ~bytes
  with
  | Ok Keeper_fs.Committed -> Ok ()
  | Ok (Keeper_fs.Committed_but_observer_failed (exn, backtrace)) ->
    Printexc.raise_with_backtrace exn backtrace
  | Error cause ->
    Error (Journal_initialize_failed { path = journal.path; cause })
;;

let recover_with
      ~durable_write
      ~base_path
      ~keeper_name
      ~keeper_generation
      ~surface
      ~concurrent_scope_budget
  =
  let identity = { keeper_name; keeper_generation; surface } in
  let invalid_identity =
    if not (valid_identity_field keeper_name)
    then Some "keeper_name"
    else if not (valid_identity_field keeper_generation)
    then Some "keeper_generation"
    else if not (valid_identity_field surface)
    then Some "surface"
    else None
  in
  match invalid_identity with
  | Some field -> Error (Invalid_owner_identity field)
  | None ->
    let path = journal_path ~base_path identity in
    let ownership_root = Common.masc_dir_from_base_path ~base_path in
    let* stored =
      read_file path
      |> Result.map_error (fun detail -> Journal_read_failed { path; detail })
    in
    let* evidence, origin =
      match stored with
      | Some encoded ->
        let* evidence =
          decode_document identity encoded
          |> Result.map_error (fun cause -> Journal_decode_failed { path; cause })
        in
        Ok (evidence, Recovered { evidence_count = List.length evidence })
      | None -> Ok ([], Fresh_start)
    in
    let journal =
      { identity
      ; ownership_root
      ; path
      ; durable_write
      ; mutex = Eio.Mutex.create ()
      ; evidence
      }
    in
    let* () =
      match origin with
      | Recovered _ -> Ok ()
      | Fresh_start -> initialize_current_journal journal
    in
    let* preference_store =
      Exact_output.recover_flow_preferences
        ~concurrent_scope_budget
        ~evidence:(List.filter_map recovery_evidence journal.evidence)
      |> Result.map_error (fun cause -> Preference_recovery_failed cause)
    in
    Ok (journal, preference_store, origin)
;;

let recover =
  recover_with ~durable_write:production_durable_write
;;

let path journal = journal.path
let evidence_count journal = List.length journal.evidence

let domain_decode_error_to_string = function
  | Exact_output.Domain_settlement_intent_malformed_json detail ->
    "malformed JSON: " ^ detail
  | Exact_output.Domain_settlement_intent_invalid_fields -> "invalid fields"
  | Exact_output.Domain_settlement_intent_unknown_format format ->
    "unknown format: " ^ format
  | Exact_output.Domain_settlement_intent_unsupported_version version ->
    Printf.sprintf "unsupported version: %d" version
  | Exact_output.Domain_settlement_intent_invalid_field field ->
    "invalid field: " ^ field
  | Exact_output.Domain_settlement_intent_integrity_mismatch ->
    "integrity mismatch"
;;

let retirement_decode_error_to_string = function
  | Exact_output.Flow_preference_retirement_intent_malformed_json detail ->
    "malformed JSON: " ^ detail
  | Exact_output.Flow_preference_retirement_intent_invalid_fields -> "invalid fields"
  | Exact_output.Flow_preference_retirement_intent_unknown_format format ->
    "unknown format: " ^ format
  | Exact_output.Flow_preference_retirement_intent_unsupported_version version ->
    Printf.sprintf "unsupported version: %d" version
  | Exact_output.Flow_preference_retirement_intent_invalid_field field ->
    "invalid field: " ^ field
  | Exact_output.Flow_preference_retirement_intent_integrity_mismatch ->
    "integrity mismatch"
;;

let measurement_transition_conflict_to_string = function
  | Exact_output.Measurement_operation_mismatch -> "operation mismatch"
  | Exact_output.Measurement_operation_binding_mismatch ->
    "operation binding mismatch"
  | Exact_output.Measurement_invalid_commit_phase _ ->
    "invalid callback commit phase"
  | Exact_output.Measurement_phase_regression _ -> "phase regression"
  | Exact_output.Measurement_evidence_conflict -> "evidence conflict"
;;

let journal_decode_error_to_string = function
  | Journal_malformed_json detail -> "malformed journal JSON: " ^ detail
  | Journal_invalid_fields -> "journal has invalid fields"
  | Journal_unknown_format format -> "journal has unknown format: " ^ format
  | Journal_unsupported_version version ->
    Printf.sprintf "journal has unsupported version: %d" version
  | Journal_invalid_field field -> "journal has invalid field: " ^ field
  | Journal_owner_mismatch field -> "journal owner mismatch: " ^ field
  | Journal_unknown_evidence_kind { index; kind } ->
    Printf.sprintf "journal evidence[%d] has unknown kind: %s" index kind
  | Journal_invalid_evidence
      (Invalid_domain_settlement_intent { index; cause }) ->
    Printf.sprintf
      "journal evidence[%d] domain settlement is invalid: %s"
      index
      (domain_decode_error_to_string cause)
  | Journal_invalid_evidence
      (Invalid_scope_retirement_intent { index; cause }) ->
    Printf.sprintf
      "journal evidence[%d] scope retirement is invalid: %s"
      index
      (retirement_decode_error_to_string cause)
  | Journal_invalid_evidence
      (Invalid_measurement_receipt { index; cause }) ->
    Printf.sprintf
      "journal evidence[%d] measurement receipt is invalid: %s"
      index
      (Exact_output.measurement_receipt_snapshot_decode_error_to_string cause)
  | Journal_invalid_evidence
      (Invalid_measurement_transition { index; operation_id; cause }) ->
    Printf.sprintf
      "journal evidence[%d] measurement transition is invalid: operation=%s cause=%s"
      index
      operation_id
      (measurement_transition_conflict_to_string cause)
  | Journal_integrity_mismatch -> "journal complete-evidence integrity mismatch"
;;

let recovery_error_to_string = function
  | Exact_output.Invalid_concurrent_scope_budget budget ->
    Printf.sprintf "invalid concurrent scope budget: %d" budget
  | Exact_output.Conflicting_domain_settlement_evidence id ->
    "conflicting domain settlement evidence: "
    ^ Exact_output.domain_settlement_id_to_string id
  | Exact_output.Conflicting_scope_retirement_evidence id ->
    "conflicting scope retirement evidence: "
    ^ Exact_output.flow_preference_retirement_id_to_string id
;;

let load_error_to_string = function
  | Invalid_owner_identity field -> "invalid exact-flow owner identity: " ^ field
  | Journal_read_failed { path; detail } ->
    Printf.sprintf "cannot read exact-flow evidence journal %s: %s" path detail
  | Journal_decode_failed { path; cause } ->
    Printf.sprintf
      "cannot decode exact-flow evidence journal %s: %s"
      path
      (journal_decode_error_to_string cause)
  | Journal_initialize_failed { path; cause } ->
    Printf.sprintf
      "cannot initialize exact-flow evidence journal %s: %s"
      path
      (Keeper_fs.durable_write_error_to_string cause)
  | Preference_recovery_failed cause ->
    "OAS exact-flow preference recovery failed: " ^ recovery_error_to_string cause
;;

let commit_error_to_string = function
  | Evidence_conflict { kind; evidence_id } ->
    Printf.sprintf
      "conflicting %s evidence id=%s"
      (evidence_kind_to_string kind)
      evidence_id
  | Evidence_write_failed cause ->
    "exact-flow evidence durable write failed: "
    ^ Keeper_fs.durable_write_error_to_string cause
  | Measurement_transition_rejected { boundary; operation_id; cause } ->
    let boundary =
      match boundary with
      | Before_measurement_dispatch -> "before_measurement_dispatch"
      | Measurement_terminal -> "measurement_terminal"
    in
    Printf.sprintf
      "measurement evidence transition rejected boundary=%s operation=%s cause=%s"
      boundary
      operation_id
      (measurement_transition_conflict_to_string cause)
;;

module For_testing = struct
  type nonrec durable_writer = durable_writer

  let recover = recover_with
end
