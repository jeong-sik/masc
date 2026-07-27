module Head = Fs_compat.Capability_head
module Payload = Keeper_dead_revival_payload

open Keeper_lifecycle_admission_durable_types

let journal_schema = "masc.keeper-dead-revival-journal.v3"
let head_entropy_bytes = 32 * 33

let sha256 value =
  Digestif.SHA256.(to_hex (digest_string value))
;;

let length_delimited value =
  Printf.sprintf "%d:%s" (String.length value) value
;;

let journal_dir config =
  Filename.concat
    (Workspace.masc_root_dir config)
    "keeper-lifecycle-transactions"
;;

let journal_leaf keeper_name =
  "revival-"
  ^ sha256
      ("keeper-dead-revival-journal-leaf-v1\000"
       ^ length_delimited keeper_name)
  ^ ".json"
;;

let revival_authority_lock_path config authority_leaf =
  try
    let dir = Keeper_fs.ensure_dir (journal_dir config) in
    let lock_leaf =
      "authority-"
      ^ sha256
          ("keeper-dead-revival-authority-lock-v1\000"
           ^ length_delimited authority_leaf)
      ^ ".lock"
    in
    Ok (Filename.concat dir lock_leaf)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
  | _ -> Error Authority_path_unavailable
;;

let authority_lock_path config keeper_name =
  match Payload.authority_shard_for_keeper ~keeper_name with
  | Error _ -> Error Authority_path_unavailable
  | Ok shard ->
    revival_authority_lock_path
      config
      (Payload.authority_shard_leaf shard)
;;

let exact_fields expected fields =
  let expected = List.sort String.compare expected in
  let observed = List.map fst fields |> List.sort String.compare in
  List.equal String.equal expected observed
;;

let required_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value)
    when not (String.equal (String.trim value) "") ->
    Ok value
  | Some _ | None -> Error ()
;;

let required_sha256 key fields =
  let ( let* ) = Result.bind in
  let* value = required_string key fields in
  match Digestif.SHA256.consistent_of_hex_opt value with
  | Some digest
    when String.equal value (Digestif.SHA256.to_hex digest) ->
    Ok value
  | Some _ | None -> Error ()
;;

let required_stage fields =
  match List.assoc_opt "stage" fields with
  | Some (`Assoc [ "reserved", `Bool true ]) -> Ok Reserved
  | Some (`Assoc [ "durable_committed", `Bool true ]) ->
    Ok Durable_committed
  | Some (`Assoc [ "launch_committed", `Bool true ]) ->
    Ok Launch_committed
  | Some (`Assoc [ "rollback_reserved", `Bool true ]) ->
    Ok Rollback_reserved
  | Some (`Assoc [ "rollback_durable_committed", `Bool true ]) ->
    Ok Rollback_durable_committed
  | Some (`Assoc [ "forward_cleanup_pending", `Bool true ]) ->
    Ok Forward_cleanup_pending
  | Some
      (`Assoc
        [ ( "rollback_cleanup_pending"
          , `Assoc [ "from_reserved", `Bool true ] )
        ]) ->
    Ok Rollback_cleanup_pending_from_reserved
  | Some
      (`Assoc
        [ ( "rollback_cleanup_pending"
          , `Assoc [ "from_durable_committed", `Bool true ] )
        ]) ->
    Ok Rollback_cleanup_pending_from_durable_committed
  | Some (`Assoc [ "cleared", `Bool true ]) -> Ok Cleared
  | Some _ | None -> Error ()
;;

let stage_to_json = function
  | Reserved -> `Assoc [ "reserved", `Bool true ]
  | Durable_committed ->
    `Assoc [ "durable_committed", `Bool true ]
  | Launch_committed ->
    `Assoc [ "launch_committed", `Bool true ]
  | Rollback_reserved ->
    `Assoc [ "rollback_reserved", `Bool true ]
  | Rollback_durable_committed ->
    `Assoc [ "rollback_durable_committed", `Bool true ]
  | Forward_cleanup_pending ->
    `Assoc [ "forward_cleanup_pending", `Bool true ]
  | Rollback_cleanup_pending_from_reserved ->
    `Assoc
      [ ( "rollback_cleanup_pending"
        , `Assoc [ "from_reserved", `Bool true ] )
      ]
  | Rollback_cleanup_pending_from_durable_committed ->
    `Assoc
      [ ( "rollback_cleanup_pending"
        , `Assoc [ "from_durable_committed", `Bool true ] )
      ]
  | Cleared -> `Assoc [ "cleared", `Bool true ]
;;

let decode_exact raw =
  let ( let* ) = Result.bind in
  try
    match Yojson.Safe.from_string raw with
    | `Assoc fields ->
      let* schema = required_string "schema" fields in
      let* transaction_id = required_sha256 "transaction_id" fields in
      let* keeper_name = required_string "keeper_name" fields in
      let* stage = required_stage fields in
      if not (String.equal schema journal_schema)
      then Error ()
      else
        let evidence = { keeper_name; transaction_id; stage } in
        (match stage with
         | Cleared ->
           if
             not
               (exact_fields
                  [ "schema"; "transaction_id"; "keeper_name"; "stage" ]
                  fields)
           then Error ()
           else
             let canonical =
               `Assoc
                 [ "schema", `String schema
                 ; "transaction_id", `String transaction_id
                 ; "keeper_name", `String keeper_name
                 ; "stage", stage_to_json stage
                 ]
               |> Yojson.Safe.to_string
             in
             if String.equal raw canonical
             then Ok { evidence; owner_id = None }
             else Error ()
         | Reserved
         | Durable_committed
         | Launch_committed
         | Rollback_reserved
         | Rollback_durable_committed
         | Forward_cleanup_pending
         | Rollback_cleanup_pending_from_reserved
         | Rollback_cleanup_pending_from_durable_committed ->
           if
             not
               (exact_fields
                  [ "schema"
                  ; "transaction_id"
                  ; "owner_id"
                  ; "keeper_name"
                  ; "expected_trace_id"
                  ; "expected_generation"
                  ; "payload_ref"
                  ; "stage"
                  ]
                  fields)
           then Error ()
           else
             let* owner_id = required_string "owner_id" fields in
             let* expected_trace_id =
               required_string "expected_trace_id" fields
             in
             let* expected_generation =
               match List.assoc_opt "expected_generation" fields with
               | Some (`Int value) when value > 0 -> Ok value
               | Some (`Int _) -> Error ()
               | Some _ | None -> Error ()
             in
             let* () =
               Keeper_id.Trace_id.of_string expected_trace_id
               |> Result.map (fun _ -> ())
               |> Result.map_error (fun _ -> ())
             in
             let* payload_ref =
               match List.assoc_opt "payload_ref" fields with
               | Some json ->
                 Payload.immutable_ref_of_json json
                 |> Result.map_error (fun _ -> ())
               | None -> Error ()
             in
             let* shard =
               Payload.authority_shard_for_keeper ~keeper_name
               |> Result.map_error (fun _ -> ())
             in
             let* transaction_leaf =
               Payload.transaction_leaf_for_id ~transaction_id
               |> Result.map_error (fun _ -> ())
             in
             if
               not
                 (String.equal
                    (Payload.immutable_ref_authority_leaf payload_ref)
                    (Payload.authority_shard_leaf shard))
               || not
                    (String.equal
                       (Payload.immutable_ref_transaction_leaf payload_ref)
                       transaction_leaf)
             then Error ()
             else
               let canonical =
                 `Assoc
                   [ "schema", `String schema
                   ; "transaction_id", `String transaction_id
                   ; "owner_id", `String owner_id
                   ; "keeper_name", `String keeper_name
                   ; "expected_trace_id", `String expected_trace_id
                   ; "expected_generation", `Int expected_generation
                   ; "payload_ref", Payload.immutable_ref_to_json payload_ref
                   ; "stage", stage_to_json stage
                   ]
                 |> Yojson.Safe.to_string
               in
               if String.equal raw canonical
               then Ok { evidence; owner_id = Some owner_id }
               else Error ())
    | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null
    | `String _ -> Error ()
  with
  | Yojson.Json_error _ -> Error ()
;;

let journal_parent config =
  try
    let dir = Keeper_fs.ensure_dir (journal_dir config) in
    match Fs_compat.get_fs_opt () with
    | None -> Error Filesystem_capability_unavailable
    | Some fs -> Ok Eio.Path.(fs / dir)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
  | _ -> Error Authority_path_unavailable
;;

let journal_entropy () =
  try
    Ok (Eio.Flow.string_source (Crypto_rng.generate head_entropy_bytes))
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
  | _ -> Error Entropy_unavailable
;;

let read_revival_locked config keeper_name =
  match journal_parent config, journal_entropy () with
  | Error failure, _ | _, Error failure ->
    Blocked (Authority_unreadable { keeper_name; failure })
  | Ok parent, Ok secure_random ->
    (match
       Head.read
         ~secure_random
         ~parent
         ~leaf:(journal_leaf keeper_name)
     with
     | Error _ ->
       Blocked
         (Authority_unreadable
            { keeper_name; failure = Authority_read_failed })
     | Ok snapshot
       when Head.snapshot_settlement_warnings snapshot <> [] ->
       Blocked
         (Authority_unreadable
            { keeper_name
            ; failure = Authority_read_settlement_failed
            })
     | Ok snapshot ->
       (match Head.snapshot_row snapshot with
        | None -> Admitted None
        | Some raw ->
          (match decode_exact raw with
           | Error () ->
             Blocked
               (Authority_invalid
                  { keeper_name
                  ; failure = Invalid_current_schema
                  })
           | Ok decoded
             when not
                    (String.equal
                       decoded.evidence.keeper_name
                       keeper_name) ->
             Blocked
               (Authority_invalid
                  { keeper_name
                  ; failure = Invalid_current_schema
                  })
           | Ok { evidence = ({ stage; _ } as evidence); _ } ->
             (match stage with
              | Reserved
              | Durable_committed
              | Rollback_reserved
              | Rollback_durable_committed
              | Rollback_cleanup_pending_from_reserved
                | Rollback_cleanup_pending_from_durable_committed ->
                  Blocked (Rollback_capable_authority evidence)
                | Launch_committed
                | Forward_cleanup_pending ->
                  Blocked (Forward_cleanup_authority evidence)
                | Cleared ->
                  Admitted (Some evidence)))))
;;

let read_locked config keeper_name =
  match read_revival_locked config keeper_name with
  | Blocked _ as blocked -> blocked
  | Admitted revival_evidence ->
    (match
       Keeper_runtime_meta_journal.admission_decision
         config
         keeper_name
     with
     | Blocked _ as blocked -> blocked
     | Admitted (Some evidence) -> Admitted (Some evidence)
     | Admitted None -> Admitted revival_evidence)
;;
