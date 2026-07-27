module Head = Fs_compat.Capability_head

open Keeper_lifecycle_admission_durable_types
open Keeper_meta_contract

let schema = "masc.keeper-runtime-meta-transaction.v1"
let head_entropy_bytes = 32 * 33
let leaf_prefix = "runtime-meta-"

type operation =
  | Create
  | Update

type intent =
  { transaction_id : string
  ; owner_id : string
  ; keeper_name : string
  ; operation : operation
  ; previous_runtime : string option
  ; candidate_runtime : string option
  ; previous_meta : keeper_meta option
  ; candidate_meta : keeper_meta
  }

type tombstone =
  { transaction_id : string
  ; keeper_name : string
  }

type row =
  | Active of intent
  | Cleared of tombstone

type error =
  | Authority_failure of string
  | Invalid_current of string
  | Authority_conflict of string

let error_to_string = function
  | Authority_failure detail -> "runtime/meta authority failure: " ^ detail
  | Invalid_current detail -> "invalid current runtime/meta authority: " ^ detail
  | Authority_conflict detail -> "runtime/meta authority conflict: " ^ detail
;;

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
  leaf_prefix
  ^ sha256
      ("keeper-runtime-meta-journal-leaf-v1\000"
       ^ length_delimited keeper_name)
  ^ ".json"
;;

let is_journal_leaf leaf =
  let prefix_length = String.length leaf_prefix in
  String.length leaf > prefix_length
  && String.equal (String.sub leaf 0 prefix_length) leaf_prefix
  && Filename.check_suffix leaf ".json"
;;

let operation_to_string = function
  | Create -> "create"
  | Update -> "update"
;;

let operation_of_string = function
  | "create" -> Ok Create
  | "update" -> Ok Update
  | _ -> Error (Invalid_current "operation is not current")
;;

let option_string_to_json = function
  | None -> `Null
  | Some value -> `String value
;;

let option_meta_to_json = function
  | None -> `Null
  | Some meta -> Keeper_meta_json.meta_to_json meta
;;

let binding_json
      ~owner_id
      ~keeper_name
      ~operation
      ~previous_runtime
      ~candidate_runtime
      ~previous_meta
      ~candidate_meta
  =
  `Assoc
    [ "owner_id", `String owner_id
    ; "keeper_name", `String keeper_name
    ; "operation", `String (operation_to_string operation)
    ; "previous_runtime", option_string_to_json previous_runtime
    ; "candidate_runtime", option_string_to_json candidate_runtime
    ; "previous_meta", option_meta_to_json previous_meta
    ; "candidate_meta", Keeper_meta_json.meta_to_json candidate_meta
    ]
;;

let transaction_id_for
      ~owner_id
      ~keeper_name
      ~operation
      ~previous_runtime
      ~candidate_runtime
      ~previous_meta
      ~candidate_meta
  =
  binding_json
    ~owner_id
    ~keeper_name
    ~operation
    ~previous_runtime
    ~candidate_runtime
    ~previous_meta
    ~candidate_meta
  |> Yojson.Safe.to_string
  |> fun binding ->
  sha256 ("keeper-runtime-meta-transaction-v1\000" ^ binding)
;;

let is_sha256 value =
  match Digestif.SHA256.consistent_of_hex_opt value with
  | Some digest -> String.equal value (Digestif.SHA256.to_hex digest)
  | None -> false
;;

let canonical_runtime = function
  | None -> Ok ()
  | Some runtime_id
    when not (String.equal runtime_id "")
         && String.equal runtime_id (String.trim runtime_id) ->
    Ok ()
  | Some _ -> Error (Invalid_current "runtime id is not canonical")
;;

let same_identity left right =
  String.equal left.name right.name
  && Keeper_id.Trace_id.equal
       left.runtime.trace_id
       right.runtime.trace_id
  && Int.equal left.runtime.nonce right.runtime.nonce
;;

let validate_intent (intent : intent) =
  let expected_transaction_id =
    transaction_id_for
      ~owner_id:intent.owner_id
      ~keeper_name:intent.keeper_name
      ~operation:intent.operation
      ~previous_runtime:intent.previous_runtime
      ~candidate_runtime:intent.candidate_runtime
      ~previous_meta:intent.previous_meta
      ~candidate_meta:intent.candidate_meta
  in
  if not (is_sha256 intent.transaction_id)
  then Error (Invalid_current "transaction_id is not a canonical SHA-256")
  else if not (String.equal intent.transaction_id expected_transaction_id)
  then Error (Invalid_current "transaction_id does not bind the exact intent")
  else if not (is_sha256 intent.owner_id)
  then Error (Invalid_current "owner_id is not a canonical SHA-256")
  else if
    String.equal intent.keeper_name ""
    || not (String.equal intent.keeper_name (String.trim intent.keeper_name))
  then Error (Invalid_current "keeper_name is not canonical")
  else
    match canonical_runtime intent.previous_runtime with
    | Error _ as error -> error
    | Ok () ->
      (match canonical_runtime intent.candidate_runtime with
       | Error _ as error -> error
       | Ok () ->
         if
           not
             (String.equal
                intent.candidate_meta.name
                intent.keeper_name)
           || intent.candidate_meta.runtime.nonce <= 0
         then Error (Invalid_current "candidate metadata binding is invalid")
         else
           match intent.operation, intent.previous_meta with
           | Create, None when Int.equal intent.candidate_meta.meta_version 0 ->
             Ok ()
           | Create, None ->
             Error
               (Invalid_current
                  "create candidate must begin at metadata version zero")
           | Create, Some _ ->
             Error (Invalid_current "create intent cannot contain previous metadata")
           | Update, None ->
             Error (Invalid_current "update intent requires previous metadata")
           | Update, Some previous
             when previous.runtime.nonce > 0
                  && same_identity previous intent.candidate_meta
                  && Int.equal
                       previous.meta_version
                       intent.candidate_meta.meta_version ->
             Ok ()
           | Update, Some _ ->
             Error
               (Invalid_current
                  "update intent must preserve current identity and metadata version"))
;;

let make_intent
      ~operation
      ~keeper_name
      ~previous_runtime
      ~candidate_runtime
      ~previous_meta
      ~candidate_meta
  =
  try
    let owner_id = sha256 (Crypto_rng.generate 32) in
    let transaction_id =
      transaction_id_for
        ~owner_id
        ~keeper_name
        ~operation
        ~previous_runtime
        ~candidate_runtime
        ~previous_meta
        ~candidate_meta
    in
    let intent =
      { transaction_id
      ; owner_id
      ; keeper_name
      ; operation
      ; previous_runtime
      ; candidate_runtime
      ; previous_meta
      ; candidate_meta
      }
    in
    Result.map (fun () -> intent) (validate_intent intent)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
  | exception_ ->
    Error
      (Authority_failure
         ("transaction entropy failed: " ^ Printexc.to_string exception_))
;;

let stage_to_json = function
  | Active _ -> `Assoc [ "prepared", `Bool true ]
  | Cleared _ -> `Assoc [ "cleared", `Bool true ]
;;

let row_to_json = function
  | Active intent ->
    `Assoc
      [ "schema", `String schema
      ; "transaction_id", `String intent.transaction_id
      ; "owner_id", `String intent.owner_id
      ; "keeper_name", `String intent.keeper_name
      ; "operation", `String (operation_to_string intent.operation)
      ; "previous_runtime", option_string_to_json intent.previous_runtime
      ; "candidate_runtime", option_string_to_json intent.candidate_runtime
      ; "previous_meta", option_meta_to_json intent.previous_meta
      ; "candidate_meta", Keeper_meta_json.meta_to_json intent.candidate_meta
      ; "stage", stage_to_json (Active intent)
      ]
  | Cleared tombstone ->
    `Assoc
      [ "schema", `String schema
      ; "transaction_id", `String tombstone.transaction_id
      ; "keeper_name", `String tombstone.keeper_name
      ; "stage", stage_to_json (Cleared tombstone)
      ]
;;

let row_to_bytes row =
  Yojson.Safe.to_string (row_to_json row)
;;

let exact_fields expected fields =
  let expected = List.sort String.compare expected in
  let observed = List.map fst fields |> List.sort String.compare in
  if List.equal String.equal expected observed
  then Ok ()
  else Error (Invalid_current "runtime/meta journal fields are not exact")
;;

let required_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value)
    when not (String.equal value "")
         && String.equal value (String.trim value) ->
    Ok value
  | Some _ | None ->
    Error (Invalid_current ("journal field " ^ key ^ " is invalid"))
;;

let required_runtime key fields =
  match List.assoc_opt key fields with
  | Some `Null -> Ok None
  | Some (`String value) ->
    Result.map (fun () -> Some value) (canonical_runtime (Some value))
  | Some _ | None ->
    Error (Invalid_current ("journal field " ^ key ^ " is invalid"))
;;

let required_meta key fields =
  match List.assoc_opt key fields with
  | Some json ->
    Keeper_meta_json.meta_of_json json
    |> Result.map_error (fun detail ->
      Invalid_current ("journal metadata " ^ key ^ " is invalid: " ^ detail))
  | None -> Error (Invalid_current ("journal field " ^ key ^ " is missing"))
;;

let required_optional_meta key fields =
  match List.assoc_opt key fields with
  | Some `Null -> Ok None
  | Some json -> Result.map Option.some (required_meta key [ key, json ])
  | None -> Error (Invalid_current ("journal field " ^ key ^ " is missing"))
;;

let row_of_json = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* observed_schema = required_string "schema" fields in
    if not (String.equal observed_schema schema)
    then Error (Invalid_current "unsupported runtime/meta journal schema")
    else
      let* transaction_id = required_string "transaction_id" fields in
      let* keeper_name = required_string "keeper_name" fields in
      (match List.assoc_opt "stage" fields with
       | Some (`Assoc [ "cleared", `Bool true ]) ->
         let* () =
           exact_fields
             [ "schema"; "transaction_id"; "keeper_name"; "stage" ]
             fields
         in
         if not (is_sha256 transaction_id)
         then Error (Invalid_current "cleared transaction_id is invalid")
         else Ok (Cleared { transaction_id; keeper_name })
       | Some (`Assoc [ "prepared", `Bool true ]) ->
         let* () =
           exact_fields
             [ "schema"
             ; "transaction_id"
             ; "owner_id"
             ; "keeper_name"
             ; "operation"
             ; "previous_runtime"
             ; "candidate_runtime"
             ; "previous_meta"
             ; "candidate_meta"
             ; "stage"
             ]
             fields
         in
         let* owner_id = required_string "owner_id" fields in
         let* operation_raw = required_string "operation" fields in
         let* operation = operation_of_string operation_raw in
         let* previous_runtime = required_runtime "previous_runtime" fields in
         let* candidate_runtime = required_runtime "candidate_runtime" fields in
         let* previous_meta = required_optional_meta "previous_meta" fields in
         let* candidate_meta = required_meta "candidate_meta" fields in
         let intent =
           { transaction_id
           ; owner_id
           ; keeper_name
           ; operation
           ; previous_runtime
           ; candidate_runtime
           ; previous_meta
           ; candidate_meta
           }
         in
         let* () = validate_intent intent in
         Ok (Active intent)
       | Some _ | None ->
         Error (Invalid_current "runtime/meta journal stage is invalid"))
  | _ -> Error (Invalid_current "runtime/meta journal must be a JSON object")
;;

let row_of_bytes raw =
  try
    let ( let* ) = Result.bind in
    let* row = row_of_json (Yojson.Safe.from_string raw) in
    if String.equal raw (row_to_bytes row)
    then Ok row
    else Error (Invalid_current "runtime/meta journal is not canonical JSON")
  with
  | Yojson.Json_error _ ->
    Error (Invalid_current "runtime/meta journal is not valid JSON")
;;

let row_keeper_name = function
  | Active intent -> intent.keeper_name
  | Cleared tombstone -> tombstone.keeper_name
;;

let row_transaction_id = function
  | Active intent -> intent.transaction_id
  | Cleared tombstone -> tombstone.transaction_id
;;

let row_evidence row =
  { keeper_name = row_keeper_name row
  ; transaction_id = row_transaction_id row
  ; stage =
      (match row with
       | Active _ -> Reserved
       | Cleared _ -> Cleared)
  }
;;

let parent config =
  try
    let dir = Keeper_fs.ensure_dir (journal_dir config) in
    match Fs_compat.get_fs_opt () with
    | None -> Error (Authority_failure "filesystem capability is unavailable")
    | Some fs -> Ok Eio.Path.(fs / dir)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
  | exception_ ->
    Error
      (Authority_failure
         ("journal directory preparation failed: "
          ^ Printexc.to_string exception_))
;;

let entropy () =
  try
    Ok (Eio.Flow.string_source (Crypto_rng.generate head_entropy_bytes))
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
  | exception_ ->
    Error
      (Authority_failure
         ("journal entropy failed: " ^ Printexc.to_string exception_))
;;

let head_failure_to_string (failure : Head.failure) =
  match failure.error with
  | Head.Invalid_leaf detail -> "invalid leaf: " ^ detail
  | Invalid_row detail -> "invalid row: " ^ detail
  | Busy -> "authority is busy"
  | Conflict _ -> "authority changed concurrently"
  | Corrupt_lock detail -> "corrupt lock: " ^ detail
  | Corrupt_head detail -> "corrupt HEAD: " ^ detail
  | Unsupported detail -> "unsupported filesystem operation: " ^ detail
  | Io_error diagnostic -> "I/O failed: " ^ diagnostic.detail
;;

let read_leaf_with_snapshot config leaf =
  let ( let* ) = Result.bind in
  let* parent = parent config in
  let* secure_random = entropy () in
  match Head.read ~secure_random ~parent ~leaf with
  | Error failure ->
    Error (Authority_failure (head_failure_to_string failure))
  | Ok snapshot ->
    let warnings = Head.snapshot_settlement_warnings snapshot in
    if warnings <> []
    then Error (Authority_failure "authority read settlement failed")
    else
      let* row =
        match Head.snapshot_row snapshot with
        | None -> Ok None
        | Some raw -> Result.map Option.some (row_of_bytes raw)
      in
      (match row with
       | Some observed
         when not
                (String.equal
                   (journal_leaf (row_keeper_name observed))
                   leaf) ->
         Error (Invalid_current "keeper binding differs from hashed leaf")
       | Some _ | None -> Ok (parent, snapshot, row))
;;

let read_leaf config leaf =
  Result.map
    (fun (_, _, row) -> row)
    (read_leaf_with_snapshot config leaf)
;;

let read_current config keeper_name =
  read_leaf config (journal_leaf keeper_name)
;;

let same_intent left right =
  String.equal
    (row_to_bytes (Active left))
    (row_to_bytes (Active right))
;;

let observed_as observed expected =
  match observed, expected with
  | Active observed, Active expected ->
    same_intent observed expected
  | Cleared observed, Cleared expected ->
    String.equal observed.transaction_id expected.transaction_id
    && String.equal observed.keeper_name expected.keeper_name
  | Active _, Cleared _ | Cleared _, Active _ -> false
;;

let publish config ~parent ~snapshot row =
  let ( let* ) = Result.bind in
  let* secure_random = entropy () in
  match
    Head.compare_and_swap
      ~secure_random
      ~parent
      ~leaf:(journal_leaf (row_keeper_name row))
      ~expected:(Head.snapshot_cursor snapshot)
      ~row:(row_to_bytes row)
  with
  | Error failure ->
    Error (Authority_failure (head_failure_to_string failure))
  | Ok publication ->
    if Head.publication_settlement_warnings publication = []
    then Ok ()
    else Error (Authority_failure "authority publication settlement failed")
;;

let reconcile_publication config expected publication_result =
  match read_current config (row_keeper_name expected) with
  | Ok (Some observed) when observed_as observed expected -> Ok ()
  | Ok _ ->
    (match publication_result with
     | Ok () -> Error (Authority_conflict "published row was not observable")
     | Error error -> Error error)
  | Error reread_error ->
    (match publication_result with
     | Ok () -> Error reread_error
     | Error publication_error ->
       Error
         (Authority_failure
            (error_to_string publication_error
             ^ "; reread failed: "
             ^ error_to_string reread_error)))
;;

let reserve config intent =
  let expected = Active intent in
  match read_leaf_with_snapshot config (journal_leaf intent.keeper_name) with
  | Error error -> Error error
  | Ok (_, _, Some (Active current)) when same_intent current intent -> Ok ()
  | Ok (_, _, Some (Active _)) ->
    Error (Authority_conflict "another active runtime/meta transaction remains")
  | Ok (parent, snapshot, (None | Some (Cleared _))) ->
    publish config ~parent ~snapshot expected
    |> reconcile_publication config expected
;;

let clear config (intent : intent) =
  let expected =
    Cleared
      { transaction_id = intent.transaction_id
      ; keeper_name = intent.keeper_name
      }
  in
  match read_leaf_with_snapshot config (journal_leaf intent.keeper_name) with
  | Error error -> Error error
  | Ok (_, _, Some (Cleared current))
    when String.equal current.transaction_id intent.transaction_id ->
    Ok ()
  | Ok (_, _, Some (Cleared _)) ->
    Error (Authority_conflict "cleared authority belongs to another transaction")
  | Ok (_, _, None) ->
    Error (Authority_conflict "active runtime/meta authority is missing")
  | Ok (_, _, Some (Active current)) when not (same_intent current intent) ->
    Error (Authority_conflict "active runtime/meta authority changed")
  | Ok (parent, snapshot, Some (Active _)) ->
    publish config ~parent ~snapshot expected
    |> reconcile_publication config expected
;;

let admission_decision config keeper_name =
  match read_current config keeper_name with
  | Error (Invalid_current _) ->
    Blocked
      (Authority_invalid
         { keeper_name
         ; failure = Invalid_current_schema
         })
  | Error (Authority_failure _ | Authority_conflict _) ->
    Blocked
      (Authority_unreadable
         { keeper_name
         ; failure = Authority_read_failed
         })
  | Ok None -> Admitted None
  | Ok (Some (Active _ as row)) ->
    Blocked (Runtime_meta_authority (row_evidence row))
  | Ok (Some (Cleared _ as row)) ->
    Admitted (Some (row_evidence row))
;;
