module Types = Keeper_memory_os_types

let ( let* ) = Result.bind

let store_schema = "masc-memory-os-store-v1"
let head_schema = "masc-memory-os-head-v1"

module Sha256 = struct
  type t = string

  let equal = String.equal
  let to_string value = value

  let of_string value =
    match Digestif.SHA256.consistent_of_hex_opt value with
    | Some digest
      when String.equal value (Digestif.SHA256.to_hex digest) ->
      Some value
    | Some _ | None -> None
  ;;
end

type artifact_kind =
  | Fact_object
  | Episode_object
  | Manifest_object
  | Commit_record_object

let artifact_kind_token = function
  | Fact_object -> "facts"
  | Episode_object -> "episode"
  | Manifest_object -> "manifest"
  | Commit_record_object -> "commit"
;;

let artifact_kind_of_token = function
  | "facts" -> Some Fact_object
  | "episode" -> Some Episode_object
  | "manifest" -> Some Manifest_object
  | "commit" -> Some Commit_record_object
  | _ -> None
;;

type immutable_ref =
  { kind : artifact_kind
  ; leaf : string
  ; sha256 : Sha256.t
  ; byte_count : int
  }

let immutable_ref_kind value = value.kind
let immutable_ref_leaf value = value.leaf
let immutable_ref_sha256 value = value.sha256
let immutable_ref_byte_count value = value.byte_count

type state =
  { facts : Types.fact list
  ; episodes : Types.episode list
  }

type 'a observation =
  { value : 'a
  ; settlement_error : Fs_compat.private_jsonl_transaction_error option
  }

type error =
  | Invalid_layout of string
  | Root_binding_changed
  | Invalid_domain_value of string
  | Conflicting_operation of
      { operation_id : string
      ; committed_payload_sha256 : Sha256.t
      ; requested_payload_sha256 : Sha256.t
      }
  | Store_open_failed of
      { path : string
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Immutable_create_failed of
      artifact_kind * Fs_compat.capability_write_error
  | Immutable_read_failed of
      immutable_ref * exn * Printexc.raw_backtrace
  | Immutable_digest_mismatch of immutable_ref
  | Invalid_store_json of
      { artifact : string
      ; detail : string
      }
  | Head_busy of { lock_path : string }
  | Head_conflict of
      { expected : string
      ; actual : string
      }
  | Head_publication_indeterminate of
      Fs_compat.private_jsonl_transaction_error
  | Head_transaction_failed of
      Fs_compat.private_jsonl_transaction_error

type mutation =
  { operation_id : string
  ; payload_sha256 : Sha256.t
  ; receipt_id : Sha256.t
  ; sequence : int64
  }

type manifest =
  { owner_id : string
  ; sequence : int64
  ; facts_ref : immutable_ref
  ; episode_refs : immutable_ref list
  }

type commit_record =
  { owner_id : string
  ; sequence : int64
  ; parent : immutable_ref option
  ; manifest_ref : immutable_ref
  ; operation_id : string
  ; payload_sha256 : Sha256.t
  ; receipt_id : Sha256.t
  }

type head =
  { owner_id : string
  ; sequence : int64
  ; commit_ref : immutable_ref
  ; mutations : mutation list
  }

type t =
  { root_path : string
  ; owner_id : string
  ; objects : Eio.Fs.dir_ty Eio.Path.t
  ; head_path : string
  }

type snapshot =
  { root_path : string
  ; owner_id : string
  ; cursor : Fs_compat.Private_jsonl_cursor.t
  ; sequence : int64
  ; commit_ref : immutable_ref option
  ; manifest_ref : immutable_ref option
  ; facts_ref : immutable_ref option
  ; episode_objects : (immutable_ref * Types.episode) list
  ; mutations : mutation list
  ; state : state
  }

type prepared_commit =
  { root_path : string
  ; owner_id : string
  ; expected_cursor : Fs_compat.Private_jsonl_cursor.t
  ; sequence : int64
  ; commit_ref : immutable_ref
  ; manifest_ref : immutable_ref
  ; facts_ref : immutable_ref
  ; episode_objects : (immutable_ref * Types.episode) list
  ; mutations : mutation list
  ; state : state
  ; operation_id : string
  ; payload_sha256 : Sha256.t
  ; receipt_id : Sha256.t
  ; head_row : string
  }

type commit_receipt =
  { receipt_id : Sha256.t
  ; operation_id : string
  ; payload_sha256 : Sha256.t
  ; sequence : int64
  ; snapshot : snapshot
  }

type prepare_outcome =
  | Prepared of prepared_commit
  | Already_committed of commit_receipt

let snapshot_state value = value.state
let snapshot_sequence value = value.sequence
let snapshot_head_commit value = value.commit_ref
let committed_snapshot value = value.snapshot
let commit_receipt_id value = value.receipt_id
let commit_receipt_operation_id value = value.operation_id
let commit_receipt_payload_sha256 value = value.payload_sha256
let commit_receipt_sequence value = value.sequence

let error_to_string = function
  | Invalid_layout detail -> "invalid Memory OS store layout: " ^ detail
  | Root_binding_changed -> "Memory OS store root binding changed"
  | Invalid_domain_value detail -> "invalid Memory OS domain value: " ^ detail
  | Conflicting_operation
      { operation_id
      ; committed_payload_sha256
      ; requested_payload_sha256
      } ->
    Printf.sprintf
      "Memory OS operation %S already committed with payload %s, requested %s"
      operation_id
      (Sha256.to_string committed_payload_sha256)
      (Sha256.to_string requested_payload_sha256)
  | Store_open_failed { path; exception_; _ } ->
    Printf.sprintf
      "failed to open Memory OS store %S: %s"
      path
      (Printexc.to_string exception_)
  | Immutable_create_failed (kind, error) ->
    Printf.sprintf
      "failed to create immutable %s object: %s"
      (artifact_kind_token kind)
      (Fs_compat.capability_write_error_to_string error)
  | Immutable_read_failed (reference, exception_, _) ->
    Printf.sprintf
      "failed to read immutable %s object %S: %s"
      (artifact_kind_token reference.kind)
      reference.leaf
      (Printexc.to_string exception_)
  | Immutable_digest_mismatch reference ->
    Printf.sprintf
      "immutable %s object %S does not match its digest"
      (artifact_kind_token reference.kind)
      reference.leaf
  | Invalid_store_json { artifact; detail } ->
    Printf.sprintf "invalid Memory OS %s JSON: %s" artifact detail
  | Head_busy { lock_path } ->
    Printf.sprintf "Memory OS HEAD lock is contended: %s" lock_path
  | Head_conflict { expected; actual } ->
    Printf.sprintf
      "Memory OS HEAD changed: expected %s, actual %s"
      expected
      actual
  | Head_publication_indeterminate error ->
    "Memory OS HEAD publication is indeterminate: "
    ^ Fs_compat.private_jsonl_transaction_error_to_string error
  | Head_transaction_failed error ->
    "Memory OS HEAD transaction failed: "
    ^ Fs_compat.private_jsonl_transaction_error_to_string error
;;

let canonical_json json = Yojson.Safe.to_string json

let hash_domain domain bytes =
  Digestif.SHA256.(
    digest_string ("masc.memory_os.store/v1\000" ^ domain ^ "\000" ^ bytes)
    |> to_hex)
;;

let hash_artifact kind bytes = hash_domain (artifact_kind_token kind) bytes

let sequence_to_json value = `Intlit (Int64.to_string value)

let sequence_of_json = function
  | `Int value when value >= 0 -> Ok (Int64.of_int value)
  | `Intlit value ->
    (match Int64.of_string_opt value with
     | Some parsed when Int64.compare parsed 0L >= 0 -> Ok parsed
     | Some _ | None -> Error "sequence must be a non-negative int64")
  | _ -> Error "sequence must be a non-negative int64"
;;

let exact_assoc expected = function
  | `Assoc fields ->
    let actual = List.map fst fields |> List.sort String.compare in
    let expected = List.sort String.compare expected in
    if List.equal String.equal actual expected
    then Ok fields
    else
      Error
        (Printf.sprintf
           "expected fields [%s], found [%s]"
           (String.concat "," expected)
           (String.concat "," actual))
  | _ -> Error "expected object"
;;

let required_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field " ^ name)
;;

let string_field name fields =
  let* value = required_field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error (name ^ " must be a string")
;;

let int_field name fields =
  let* value = required_field name fields in
  match value with
  | `Int value when value >= 0 -> Ok value
  | _ -> Error (name ^ " must be a non-negative integer")
;;

let sequence_field name fields =
  let* value = required_field name fields in
  sequence_of_json value
;;

let list_field name fields =
  let* value = required_field name fields in
  match value with
  | `List values -> Ok values
  | _ -> Error (name ^ " must be an array")
;;

let rec map_result fn = function
  | [] -> Ok []
  | value :: rest ->
    let* mapped = fn value in
    let* mapped_rest = map_result fn rest in
    Ok (mapped :: mapped_rest)
;;

let immutable_ref_to_json reference =
  `Assoc
    [ "kind", `String (artifact_kind_token reference.kind)
    ; "leaf", `String reference.leaf
    ; "sha256", `String (Sha256.to_string reference.sha256)
    ; "byte_count", `Int reference.byte_count
    ]
;;

let valid_leaf kind leaf =
  let prefix = artifact_kind_token kind ^ "-" in
  let suffix = ".json" in
  if
    (not (String.starts_with ~prefix leaf))
    || not (String.ends_with ~suffix leaf)
  then false
  else
    let uuid_length = String.length leaf - String.length prefix - String.length suffix in
    if uuid_length <> 36
    then false
    else
      let raw = String.sub leaf (String.length prefix) uuid_length in
      match Uuidm.of_string raw with
      | Some uuid -> String.equal raw (Uuidm.to_string uuid)
      | None -> false
;;

let immutable_ref_of_json json =
  let* fields = exact_assoc [ "kind"; "leaf"; "sha256"; "byte_count" ] json in
  let* kind_token = string_field "kind" fields in
  let* kind =
    match artifact_kind_of_token kind_token with
    | Some kind -> Ok kind
    | None -> Error ("unknown artifact kind " ^ kind_token)
  in
  let* leaf = string_field "leaf" fields in
  let* sha256_raw = string_field "sha256" fields in
  let* sha256 =
    match Sha256.of_string sha256_raw with
    | Some digest -> Ok digest
    | None -> Error "sha256 must be canonical lowercase SHA256 hex"
  in
  let* byte_count = int_field "byte_count" fields in
  if not (valid_leaf kind leaf)
  then Error ("invalid immutable leaf " ^ leaf)
  else Ok { kind; leaf; sha256; byte_count }
;;

let option_ref_to_json = function
  | None -> `Null
  | Some reference -> immutable_ref_to_json reference
;;

let option_ref_of_json = function
  | `Null -> Ok None
  | json ->
    let* reference = immutable_ref_of_json json in
    Ok (Some reference)
;;

let mutation_to_json mutation =
  `Assoc
    [ "operation_id", `String mutation.operation_id
    ; "payload_sha256", `String (Sha256.to_string mutation.payload_sha256)
    ; "receipt_id", `String (Sha256.to_string mutation.receipt_id)
    ; "sequence", sequence_to_json mutation.sequence
    ]
;;

let receipt_digest ~operation_id ~payload_sha256 ~sequence =
  canonical_json
    (`Assoc
       [ "operation_id", `String operation_id
       ; "payload_sha256", `String (Sha256.to_string payload_sha256)
       ; "sequence", sequence_to_json sequence
       ])
  |> hash_domain "receipt"
;;

let mutation_of_json json =
  let* fields =
    exact_assoc
      [ "operation_id"; "payload_sha256"; "receipt_id"; "sequence" ]
      json
  in
  let* operation_id = string_field "operation_id" fields in
  let* payload_raw = string_field "payload_sha256" fields in
  let* payload_sha256 =
    match Sha256.of_string payload_raw with
    | Some digest -> Ok digest
    | None -> Error "payload_sha256 must be canonical lowercase SHA256 hex"
  in
  let* receipt_raw = string_field "receipt_id" fields in
  let* receipt_id =
    match Sha256.of_string receipt_raw with
    | Some digest -> Ok digest
    | None -> Error "receipt_id must be canonical lowercase SHA256 hex"
  in
  let* sequence = sequence_field "sequence" fields in
  if String.trim operation_id = ""
  then Error "operation_id must be non-empty"
  else
    let expected = receipt_digest ~operation_id ~payload_sha256 ~sequence in
    if not (Sha256.equal receipt_id expected)
    then Error "receipt_id does not bind operation, payload, and sequence"
    else Ok { operation_id; payload_sha256; receipt_id; sequence }
;;

let manifest_to_json manifest =
  `Assoc
    [ "owner_id", `String manifest.owner_id
    ; "sequence", sequence_to_json manifest.sequence
    ; "facts", immutable_ref_to_json manifest.facts_ref
    ; "episodes", `List (List.map immutable_ref_to_json manifest.episode_refs)
    ]
;;

let manifest_of_json json =
  let* fields = exact_assoc [ "owner_id"; "sequence"; "facts"; "episodes" ] json in
  let* owner_id = string_field "owner_id" fields in
  let* sequence = sequence_field "sequence" fields in
  let* facts_json = required_field "facts" fields in
  let* facts_ref = immutable_ref_of_json facts_json in
  let* episode_json = list_field "episodes" fields in
  let* episode_refs = map_result immutable_ref_of_json episode_json in
  if facts_ref.kind <> Fact_object
  then Error "manifest facts ref has the wrong kind"
  else if List.exists (fun reference -> reference.kind <> Episode_object) episode_refs
  then Error "manifest episode ref has the wrong kind"
  else Ok { owner_id; sequence; facts_ref; episode_refs }
;;

let commit_record_to_json record =
  `Assoc
    [ "owner_id", `String record.owner_id
    ; "sequence", sequence_to_json record.sequence
    ; "parent", option_ref_to_json record.parent
    ; "manifest", immutable_ref_to_json record.manifest_ref
    ; "operation_id", `String record.operation_id
    ; "payload_sha256", `String (Sha256.to_string record.payload_sha256)
    ; "receipt_id", `String (Sha256.to_string record.receipt_id)
    ]
;;

let commit_record_of_json json =
  let* fields =
    exact_assoc
      [ "owner_id"
      ; "sequence"
      ; "parent"
      ; "manifest"
      ; "operation_id"
      ; "payload_sha256"
      ; "receipt_id"
      ]
      json
  in
  let* owner_id = string_field "owner_id" fields in
  let* sequence = sequence_field "sequence" fields in
  let* parent_json = required_field "parent" fields in
  let* parent = option_ref_of_json parent_json in
  let* manifest_json = required_field "manifest" fields in
  let* manifest_ref = immutable_ref_of_json manifest_json in
  let* operation_id = string_field "operation_id" fields in
  let* payload_raw = string_field "payload_sha256" fields in
  let* payload_sha256 =
    match Sha256.of_string payload_raw with
    | Some digest -> Ok digest
    | None -> Error "payload_sha256 must be canonical lowercase SHA256 hex"
  in
  let* receipt_raw = string_field "receipt_id" fields in
  let* receipt_id =
    match Sha256.of_string receipt_raw with
    | Some digest -> Ok digest
    | None -> Error "receipt_id must be canonical lowercase SHA256 hex"
  in
  if manifest_ref.kind <> Manifest_object
  then Error "commit manifest ref has the wrong kind"
  else if Option.exists (fun reference -> reference.kind <> Commit_record_object) parent
  then Error "commit parent ref has the wrong kind"
  else if String.trim operation_id = ""
  then Error "commit operation_id must be non-empty"
  else
    Ok
      { owner_id
      ; sequence
      ; parent
      ; manifest_ref
      ; operation_id
      ; payload_sha256
      ; receipt_id
      }
;;

let head_to_json head =
  `Assoc
    [ "schema", `String head_schema
    ; "owner_id", `String head.owner_id
    ; "sequence", sequence_to_json head.sequence
    ; "commit", immutable_ref_to_json head.commit_ref
    ; "mutation_index", `List (List.map mutation_to_json head.mutations)
    ]
;;

let head_of_json json =
  let* fields =
    exact_assoc
      [ "schema"; "owner_id"; "sequence"; "commit"; "mutation_index" ]
      json
  in
  let* schema = string_field "schema" fields in
  let* owner_id = string_field "owner_id" fields in
  let* sequence = sequence_field "sequence" fields in
  let* commit_json = required_field "commit" fields in
  let* commit_ref = immutable_ref_of_json commit_json in
  let* mutation_json = list_field "mutation_index" fields in
  let* mutations = map_result mutation_of_json mutation_json in
  if not (String.equal schema head_schema)
  then Error ("unsupported HEAD schema " ^ schema)
  else if commit_ref.kind <> Commit_record_object
  then Error "HEAD commit ref has the wrong kind"
  else Ok { owner_id; sequence; commit_ref; mutations }
;;

let object_bytes kind payload =
  canonical_json
    (`Assoc
       [ "store_schema", `String store_schema
       ; "kind", `String (artifact_kind_token kind)
       ; "payload", payload
       ])
;;

let parse_json ~artifact raw =
  try Ok (Yojson.Safe.from_string raw) with
  | Yojson.Json_error detail -> Error (Invalid_store_json { artifact; detail })
;;

let decode_object_envelope ~artifact ~expected_kind json =
  match exact_assoc [ "store_schema"; "kind"; "payload" ] json with
  | Error detail -> Error (Invalid_store_json { artifact; detail })
  | Ok fields ->
    (match string_field "store_schema" fields, string_field "kind" fields with
     | Error detail, _ | _, Error detail ->
       Error (Invalid_store_json { artifact; detail })
     | Ok schema, Ok kind_token when not (String.equal schema store_schema) ->
       Error
         (Invalid_store_json
            { artifact; detail = "unsupported store schema " ^ schema })
     | Ok _, Ok kind_token
       when not (String.equal kind_token (artifact_kind_token expected_kind)) ->
       Error
         (Invalid_store_json
            { artifact; detail = "artifact kind mismatch " ^ kind_token })
     | Ok _, Ok _ ->
       (match required_field "payload" fields with
        | Ok payload -> Ok payload
        | Error detail -> Error (Invalid_store_json { artifact; detail })))
;;

let finite value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false
;;

let validate_fact fact =
  let optional_finite = function
    | None -> true
    | Some value -> finite value
  in
  if not (String.equal fact.Types.schema_version Types.schema_version)
  then Error "fact schema_version is not current"
  else if not (finite fact.first_seen)
  then Error "fact first_seen must be finite"
  else if not (optional_finite fact.valid_until)
  then Error "fact valid_until must be finite"
  else if not (optional_finite fact.last_verified_at)
  then Error "fact last_verified_at must be finite"
  else
    match fact.claim_id with
    | Some value when String.trim value = "" -> Error "fact claim_id must be non-empty"
    | Some _ | None -> Ok ()
;;

let validate_episode episode =
  let optional_finite = function
    | None -> true
    | Some value -> finite value
  in
  if not (String.equal episode.Types.schema_version Types.schema_version)
  then Error "episode schema_version is not current"
  else if String.trim episode.trace_id = ""
  then Error "episode trace_id must be non-empty"
  else if episode.generation < 0
  then Error "episode generation must be non-negative"
  else if not (finite episode.created_at)
  then Error "episode created_at must be finite"
  else if not (optional_finite episode.valid_until)
  then Error "episode valid_until must be finite"
  else
    match episode.source_turn_range with
    | Some (lo, hi) when lo < 0 || hi < lo ->
      Error "episode source_turn_range is invalid"
    | Some _ | None -> map_result validate_fact episode.claims |> Result.map ignore
;;

let validate_state state =
  let* _ = map_result validate_fact state.facts in
  let* _ = map_result validate_episode state.episodes in
  Ok ()
;;

let facts_payload facts =
  `Assoc [ "facts", `List (List.map Types.fact_to_json facts) ]
;;

let facts_of_payload json =
  let* fields = exact_assoc [ "facts" ] json in
  let* facts_json = list_field "facts" fields in
  map_result
    (fun value ->
       match Types.fact_of_json value with
       | Some fact -> Ok fact
       | None -> Error "invalid fact payload")
    facts_json
;;

let episode_of_payload json =
  match Types.episode_of_json json with
  | Some episode -> Ok episode
  | None -> Error "invalid episode payload"
;;

let state_payload state =
  `Assoc
    [ "facts", `List (List.map Types.fact_to_json state.facts)
    ; "episodes", `List (List.map Types.episode_to_json state.episodes)
    ]
;;

let state_digest state =
  state_payload state |> canonical_json |> hash_domain "domain-state"
;;

let rng = Random.State.make_self_init ()
let rng_mutex = Stdlib.Mutex.create ()

let fresh_leaf kind =
  let uuid =
    Stdlib.Mutex.protect rng_mutex (fun () -> Uuidm.v4_gen rng ())
    |> Uuidm.to_string
  in
  artifact_kind_token kind ^ "-" ^ uuid ^ ".json"
;;

let immutable_ref_for_raw kind leaf raw =
  { kind
  ; leaf
  ; sha256 = hash_artifact kind raw
  ; byte_count = String.length raw
  }
;;

let create_raw_object store kind raw =
  let leaf = fresh_leaf kind in
  let reference = immutable_ref_for_raw kind leaf raw in
  match
    Fs_compat.create_capability_file_exclusive
      ~parent:store.objects
      ~leaf
      ~permissions:0o600
      raw
  with
  | Ok () -> Ok reference
  | Error error -> Error (Immutable_create_failed (kind, error))
;;

let create_object store kind payload =
  create_raw_object store kind (object_bytes kind payload)
;;

let same_raw reference kind raw =
  reference.kind = kind
  && reference.byte_count = String.length raw
  && Sha256.equal reference.sha256 (hash_artifact kind raw)
;;

let load_object_payload store reference =
  let raw_result =
    try Ok (Eio.Path.load Eio.Path.(store.objects / reference.leaf)) with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | Eio.Io _ as exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      Error (Immutable_read_failed (reference, exception_, backtrace))
  in
  let* raw = raw_result in
  if
    String.length raw <> reference.byte_count
    || not (Sha256.equal reference.sha256 (hash_artifact reference.kind raw))
  then Error (Immutable_digest_mismatch reference)
  else
    let artifact = artifact_kind_token reference.kind ^ ":" ^ reference.leaf in
    let* json = parse_json ~artifact raw in
    decode_object_envelope ~artifact ~expected_kind:reference.kind json
;;

let invalid_json artifact = function
  | Ok value -> Ok value
  | Error detail -> Error (Invalid_store_json { artifact; detail })
;;

let head_error = function
  | Fs_compat.Stable_lock_contended { lock_path } -> Head_busy { lock_path }
  | Fs_compat.Cursor_mismatch { expected; actual } ->
    Head_conflict
      { expected = Fs_compat.Private_jsonl_cursor.to_string expected
      ; actual = Fs_compat.Private_jsonl_cursor.to_string actual
      }
  | Fs_compat.Rewrite_published_durability_unknown _ as error ->
    Head_publication_indeterminate error
  | error -> Head_transaction_failed error
;;

let with_open ~fs ~root_path ~owner_id fn =
  if String.trim root_path = ""
  then Error (Invalid_layout "root_path must be non-empty")
  else if String.trim owner_id = ""
  then Error (Invalid_layout "owner_id must be non-empty")
  else
    let open_store () =
      let root = Eio.Path.(fs / root_path) in
      let objects_path = Eio.Path.(root / "objects") in
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 root;
      Eio.Path.mkdirs ~exists_ok:true ~perm:0o700 objects_path;
      Eio.Path.with_open_dir objects_path (fun objects ->
        fn
          { root_path
          ; owner_id
          ; objects
          ; head_path = Filename.concat root_path "HEAD.jsonl"
          })
    in
    try open_store () with
    | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
    | Eio.Io _ as exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      Error (Store_open_failed { path = root_path; exception_; backtrace })
;;

let empty_snapshot store cursor =
  { root_path = store.root_path
  ; owner_id = store.owner_id
  ; cursor
  ; sequence = 0L
  ; commit_ref = None
  ; manifest_ref = None
  ; facts_ref = None
  ; episode_objects = []
  ; mutations = []
  ; state = { facts = []; episodes = [] }
  }
;;

let decode_head_bytes raw =
  match String.split_on_char '\n' raw with
  | [ row; "" ] when row <> "" ->
    let* json = parse_json ~artifact:"HEAD" row in
    invalid_json "HEAD" (head_of_json json)
  | _ ->
    Error
      (Invalid_store_json
         { artifact = "HEAD"
         ; detail = "expected exactly one newline-terminated row"
         })
;;

let unique_mutations mutations =
  let rec loop seen previous_sequence = function
    | [] -> Ok ()
    | mutation :: rest ->
      if List.mem mutation.operation_id seen
      then Error ("duplicate operation_id " ^ mutation.operation_id)
      else if Int64.compare mutation.sequence previous_sequence <= 0
      then Error "mutation sequence must increase strictly"
      else loop (mutation.operation_id :: seen) mutation.sequence rest
  in
  loop [] 0L mutations
;;

let load store =
  let head_result =
    Fs_compat.read_private_jsonl_durable_locked_result
      store.head_path
      ~after:None
    |> Fs_compat.private_jsonl_snapshot_success_receipt
  in
  match head_result with
  | Error error -> Error (head_error error)
  | Ok { value = raw_snapshot; settlement_error } ->
    if String.equal raw_snapshot.bytes ""
    then
      Ok
        { value = empty_snapshot store raw_snapshot.cursor
        ; settlement_error
        }
    else
      let* head = decode_head_bytes raw_snapshot.bytes in
      if not (String.equal head.owner_id store.owner_id)
      then Error Root_binding_changed
      else
        let* () = invalid_json "HEAD" (unique_mutations head.mutations) in
        let* commit_payload = load_object_payload store head.commit_ref in
        let* record =
          invalid_json
            ("commit:" ^ head.commit_ref.leaf)
            (commit_record_of_json commit_payload)
        in
        if
          not (String.equal record.owner_id store.owner_id)
          || not (Int64.equal record.sequence head.sequence)
        then Error Root_binding_changed
        else if not (Sha256.equal record.receipt_id
                       (receipt_digest
                          ~operation_id:record.operation_id
                          ~payload_sha256:record.payload_sha256
                          ~sequence:record.sequence))
        then
          Error
            (Invalid_store_json
               { artifact = "commit:" ^ head.commit_ref.leaf
               ; detail = "receipt binding mismatch"
               })
        else
          let current_mutation =
            List.find_opt
              (fun mutation ->
                 Int64.equal mutation.sequence record.sequence
                 && String.equal mutation.operation_id record.operation_id)
              head.mutations
          in
          (match current_mutation with
           | None ->
             Error
               (Invalid_store_json
                  { artifact = "HEAD"
                  ; detail = "current commit is absent from mutation_index"
                  })
           | Some mutation
             when not (Sha256.equal mutation.payload_sha256 record.payload_sha256)
                  || not (Sha256.equal mutation.receipt_id record.receipt_id) ->
             Error
               (Invalid_store_json
                  { artifact = "HEAD"
                  ; detail = "current mutation does not bind the commit record"
                  })
           | Some _ ->
             let* manifest_payload =
               load_object_payload store record.manifest_ref
             in
             let* manifest =
               invalid_json
                 ("manifest:" ^ record.manifest_ref.leaf)
                 (manifest_of_json manifest_payload)
             in
             if
               not (String.equal manifest.owner_id store.owner_id)
               || not (Int64.equal manifest.sequence head.sequence)
             then Error Root_binding_changed
             else
               let* facts_payload_json =
                 load_object_payload store manifest.facts_ref
               in
               let* facts =
                 invalid_json
                   ("facts:" ^ manifest.facts_ref.leaf)
                   (facts_of_payload facts_payload_json)
               in
               let load_episode reference =
                 let* payload = load_object_payload store reference in
                 let* episode =
                   invalid_json
                     ("episode:" ^ reference.leaf)
                     (episode_of_payload payload)
                 in
                 Ok (reference, episode)
               in
               let* episode_objects =
                 map_result load_episode manifest.episode_refs
               in
               let state =
                 { facts
                 ; episodes = List.map snd episode_objects
                 }
               in
               let* () =
                 match validate_state state with
                 | Ok () -> Ok ()
                 | Error detail -> Error (Invalid_domain_value detail)
               in
               Ok
                 { value =
                     { root_path = store.root_path
                     ; owner_id = store.owner_id
                     ; cursor = raw_snapshot.cursor
                     ; sequence = head.sequence
                     ; commit_ref = Some head.commit_ref
                     ; manifest_ref = Some record.manifest_ref
                     ; facts_ref = Some manifest.facts_ref
                     ; episode_objects
                     ; mutations = head.mutations
                     ; state
                     }
                 ; settlement_error
                 })
;;

let create_or_reuse_facts store expected facts =
  let raw = object_bytes Fact_object (facts_payload facts) in
  match expected.facts_ref with
  | Some reference when same_raw reference Fact_object raw -> Ok reference
  | Some _ | None -> create_raw_object store Fact_object raw
;;

let create_or_reuse_episodes store expected episodes =
  let rec loop available created acc = function
    | [] -> Ok (List.rev acc)
    | episode :: rest ->
      let raw = object_bytes Episode_object (Types.episode_to_json episode) in
      let existing =
        List.find_opt
          (fun (reference, _) -> same_raw reference Episode_object raw)
          available
      in
      let existing =
        match existing with
        | Some value -> Some value
        | None ->
          List.find_opt
            (fun (reference, _) -> same_raw reference Episode_object raw)
            created
      in
      (match existing with
       | Some (reference, _) ->
         loop available created ((reference, episode) :: acc) rest
       | None ->
         let* reference = create_raw_object store Episode_object raw in
         let value = reference, episode in
         loop available (value :: created) (value :: acc) rest)
  in
  loop expected.episode_objects [] [] episodes
;;

let receipt_for_mutation snapshot mutation =
  { receipt_id = mutation.receipt_id
  ; operation_id = mutation.operation_id
  ; payload_sha256 = mutation.payload_sha256
  ; sequence = mutation.sequence
  ; snapshot
  }
;;

let prepare store ~expected ~operation_id ~state =
  if
    not (String.equal store.root_path expected.root_path)
    || not (String.equal store.owner_id expected.owner_id)
  then Error Root_binding_changed
  else if String.trim operation_id = ""
  then Error (Invalid_domain_value "operation_id must be non-empty")
  else
    let* () =
      match validate_state state with
      | Ok () -> Ok ()
      | Error detail -> Error (Invalid_domain_value detail)
    in
    let payload_sha256 = state_digest state in
    match
      List.find_opt
        (fun mutation -> String.equal mutation.operation_id operation_id)
        expected.mutations
    with
    | Some mutation when Sha256.equal mutation.payload_sha256 payload_sha256 ->
      Ok (Already_committed (receipt_for_mutation expected mutation))
    | Some mutation ->
      Error
        (Conflicting_operation
           { operation_id
           ; committed_payload_sha256 = mutation.payload_sha256
           ; requested_payload_sha256 = payload_sha256
           })
    | None ->
      if Int64.equal expected.sequence Int64.max_int
      then Error (Invalid_domain_value "store sequence is exhausted")
      else
        let sequence = Int64.succ expected.sequence in
        let receipt_id =
          receipt_digest ~operation_id ~payload_sha256 ~sequence
        in
        let* facts_ref =
          create_or_reuse_facts store expected state.facts
        in
        let* episode_objects =
          create_or_reuse_episodes store expected state.episodes
        in
        let manifest =
          { owner_id = store.owner_id
          ; sequence
          ; facts_ref
          ; episode_refs = List.map fst episode_objects
          }
        in
        let* manifest_ref =
          create_object store Manifest_object (manifest_to_json manifest)
        in
        let record =
          { owner_id = store.owner_id
          ; sequence
          ; parent = expected.commit_ref
          ; manifest_ref
          ; operation_id
          ; payload_sha256
          ; receipt_id
          }
        in
        let* commit_ref =
          create_object
            store
            Commit_record_object
            (commit_record_to_json record)
        in
        let mutation =
          { operation_id; payload_sha256; receipt_id; sequence }
        in
        let mutations = expected.mutations @ [ mutation ] in
        let head =
          { owner_id = store.owner_id
          ; sequence
          ; commit_ref
          ; mutations
          }
        in
        Ok
          (Prepared
             { root_path = store.root_path
             ; owner_id = store.owner_id
             ; expected_cursor = expected.cursor
             ; sequence
             ; commit_ref
             ; manifest_ref
             ; facts_ref
             ; episode_objects
             ; mutations
             ; state
             ; operation_id
             ; payload_sha256
             ; receipt_id
             ; head_row = canonical_json (head_to_json head) ^ "\n"
             })
;;

let publish store prepared =
  if
    not (String.equal store.root_path prepared.root_path)
    || not (String.equal store.owner_id prepared.owner_id)
  then Error Root_binding_changed
  else
    let result =
      Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
        store.head_path
        ~expected:prepared.expected_cursor
        prepared.head_row
      |> Fs_compat.private_jsonl_cursor_success_receipt
    in
    match result with
    | Error error -> Error (head_error error)
    | Ok { value = cursor; settlement_error } ->
      let snapshot =
        { root_path = store.root_path
        ; owner_id = store.owner_id
        ; cursor
        ; sequence = prepared.sequence
        ; commit_ref = Some prepared.commit_ref
        ; manifest_ref = Some prepared.manifest_ref
        ; facts_ref = Some prepared.facts_ref
        ; episode_objects = prepared.episode_objects
        ; mutations = prepared.mutations
        ; state = prepared.state
        }
      in
      Ok
        { value =
            { receipt_id = prepared.receipt_id
            ; operation_id = prepared.operation_id
            ; payload_sha256 = prepared.payload_sha256
            ; sequence = prepared.sequence
            ; snapshot
            }
        ; settlement_error
        }
;;
