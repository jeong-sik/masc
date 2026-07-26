module Types = Keeper_memory_os_types
module Head = Fs_compat.Capability_head
module Exact_read = Fs_compat.Capability_exact_read

let ( let* ) = Result.bind

let head_schema = "masc-memory-os-head-v2"
let facts_schema = "masc-memory-os-facts-v2"
let episode_schema = "masc-memory-os-episode-v2"
let manifest_schema = "masc-memory-os-manifest-v2"
let commit_schema = "masc-memory-os-commit-v2"
let state_schema = "masc-memory-os-state-v2"
let head_leaf = "HEAD"
let max_immutable_bytes = Int64.of_int (64 * 1024 * 1024)

module Sha256 = struct
  type t = string

  let equal = String.equal
  let to_string value = value

  let of_string value =
    match Digestif.SHA256.consistent_of_hex_opt value with
    | Some digest when String.equal value (Digestif.SHA256.to_hex digest) ->
      Some value
    | Some _ | None -> None
  ;;
end

let canonical_json json = Yojson.Safe.to_string json

let sha256 bytes =
  Digestif.SHA256.(digest_string bytes |> to_hex)
;;

let hash_domain domain bytes =
  sha256 ("masc.memory_os.store/v2\000" ^ domain ^ "\000" ^ bytes)
;;

type artifact_kind =
  | Facts_object
  | Episode_object
  | Manifest_object
  | Commit_object

let artifact_kind_token = function
  | Facts_object -> "facts"
  | Episode_object -> "episode"
  | Manifest_object -> "manifest"
  | Commit_object -> "commit"
;;

let artifact_kind_of_token = function
  | "facts" -> Some Facts_object
  | "episode" -> Some Episode_object
  | "manifest" -> Some Manifest_object
  | "commit" -> Some Commit_object
  | _ -> None
;;

type immutable_ref =
  { kind : artifact_kind
  ; leaf : string
  ; sha256 : Sha256.t
  ; byte_count : int64
  }

type state =
  { facts : Types.fact list
  ; episodes : Types.episode list
  }

type settlement_warning =
  | Head_settlement_warning of Head.settlement_warning
  | Head_effect_warning of Head.error
  | Head_indeterminate_warning of Head.error
  | Immutable_settlement_warning of immutable_ref * Exact_read.settlement_warning

type error_kind =
  | Invalid_layout of string
  | Store_not_active
  | Runtime_store_binding_mismatch
  | Persisted_store_binding_mismatch of string
  | Invalid_domain_value of string
  | Conflicting_operation of
      { operation_id : string
      ; committed_state_sha256 : Sha256.t
      ; requested_state_sha256 : Sha256.t
      }
  | Generation_exhausted
  | Entropy_source_failed of
      { purpose : string
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Immutable_object_too_large of
      { kind : artifact_kind
      ; byte_count : int64
      ; maximum : int64
      }
  | Immutable_create_failed of
      { kind : artifact_kind
      ; leaf : string
      ; failure : Fs_compat.capability_write_error
      }
  | Immutable_read_failed of immutable_ref * Exact_read.error
  | Immutable_digest_mismatch of immutable_ref
  | Invalid_store_json of
      { artifact : string
      ; detail : string
      }
  | Head_operation_failed of
      { phase : string
      ; failure : Head.error
      }
  | Head_row_too_large of int
  | Pending_publication_mismatch

type error =
  { kind : error_kind
  ; settlement_warnings : settlement_warning list
  }

let make_error ?(settlement_warnings = []) kind =
  { kind; settlement_warnings }
;;

let prepend_warnings warnings (error : error) =
  { error with
    settlement_warnings = warnings @ error.settlement_warnings
  }
;;

let with_prior_warnings warnings = function
  | Ok value -> Ok value
  | Error error -> Error (prepend_warnings warnings error)
;;

type binding = { active : bool Atomic.t }

type head_record =
  { store_id : string
  ; owner_id : string
  ; generation : int64
  ; commit_ref : immutable_ref
  }

type facts_object =
  { store_id : string
  ; owner_id : string
  ; generation : int64
  ; facts : Types.fact list
  }

type episode_object =
  { store_id : string
  ; owner_id : string
  ; generation : int64
  ; episode : Types.episode
  }

type manifest =
  { store_id : string
  ; owner_id : string
  ; generation : int64
  ; facts_ref : immutable_ref
  ; episode_refs : immutable_ref list
  }

type commit_record =
  { store_id : string
  ; owner_id : string
  ; generation : int64
  ; operation_id : string
  ; manifest_ref : immutable_ref
  ; state_sha256 : Sha256.t
  ; receipt_id : Sha256.t
  }

type t =
  { binding : binding
  ; secure_random : Eio.Flow.source_ty Eio.Resource.t
  ; root : Eio.Fs.dir_ty Eio.Path.t
  ; owner_id : string
  }

type snapshot =
  { binding : binding
  ; cursor : Head.cursor
  ; head_row : string option
  ; store_id : string option
  ; generation : int64
  ; commit_ref : immutable_ref option
  ; commit : commit_record option
  ; manifest_ref : immutable_ref option
  ; facts_ref : immutable_ref option
  ; episode_objects : (immutable_ref * Types.episode) list
  ; state : state
  ; settlement_warnings : settlement_warning list
  }

type prepared_commit =
  { binding : binding
  ; expected_cursor : Head.cursor
  ; previous : snapshot
  ; store_id : string
  ; generation : int64
  ; commit_ref : immutable_ref
  ; commit : commit_record
  ; manifest_ref : immutable_ref
  ; facts_ref : immutable_ref
  ; episode_objects : (immutable_ref * Types.episode) list
  ; state : state
  ; operation_id : string
  ; state_sha256 : Sha256.t
  ; receipt_id : Sha256.t
  ; head_row : string
  ; settlement_warnings : settlement_warning list
  }

type commit_receipt =
  { receipt_id : Sha256.t
  ; operation_id : string
  ; state_sha256 : Sha256.t
  ; generation : int64
  ; snapshot : snapshot
  ; settlement_warnings : settlement_warning list
  }

type pending_publication =
  { binding : binding
  ; prepared : prepared_commit
  ; settlement_warnings : settlement_warning list
  }

type prepare_outcome =
  | Prepared of prepared_commit
  | Current_commit_replay of commit_receipt
  | Stale_expected of snapshot

type publish_outcome =
  | Committed of commit_receipt
  | Stale of snapshot
  | Indeterminate of pending_publication

type settle_outcome =
  | Settled_committed of commit_receipt
  | Settled_not_published of snapshot
  | Still_indeterminate of pending_publication

let snapshot_state (value : snapshot) = value.state
let snapshot_generation (value : snapshot) = value.generation

let snapshot_settlement_warnings (value : snapshot) =
  value.settlement_warnings
;;

let committed_snapshot (value : commit_receipt) = value.snapshot
let commit_receipt_id (value : commit_receipt) = value.receipt_id

let commit_receipt_operation_id (value : commit_receipt) =
  value.operation_id
;;

let commit_receipt_state_sha256 (value : commit_receipt) =
  value.state_sha256
;;

let commit_receipt_generation (value : commit_receipt) = value.generation

let commit_receipt_settlement_warnings (value : commit_receipt) =
  value.settlement_warnings
;;

let pending_publication_operation_id (value : pending_publication) =
  value.prepared.operation_id
;;

let pending_publication_generation (value : pending_publication) =
  value.prepared.generation
;;

let pending_publication_receipt_id (value : pending_publication) =
  value.prepared.receipt_id
;;

let pending_publication_settlement_warnings (value : pending_publication) =
  value.settlement_warnings
;;

let head_operation_to_string = function
  | Head.Pin_parent -> "pin_parent"
  | Head.Open_lock -> "open_lock"
  | Head.Acquire_cross_process_lock -> "acquire_cross_process_lock"
  | Head.Read_lock_marker -> "read_lock_marker"
  | Head.Initialize_lock_marker -> "initialize_lock_marker"
  | Head.Read_head -> "read_head"
  | Head.Create_stage -> "create_stage"
  | Head.Write_stage -> "write_stage"
  | Head.Sync_stage -> "sync_stage"
  | Head.Close_stage -> "close_stage"
  | Head.Revalidate -> "revalidate"
  | Head.Rename_head -> "rename_head"
  | Head.Sync_parent -> "sync_parent"
  | Head.Verify_publication -> "verify_publication"
  | Head.Cleanup_stage -> "cleanup_stage"
  | Head.Settle_resources -> "settle_resources"
;;

let head_diagnostic_to_string diagnostic =
  Printf.sprintf
    "%s: %s"
    (head_operation_to_string diagnostic.Head.operation)
    diagnostic.detail
;;

let unix_file_kind_to_string = function
  | Unix.S_REG -> "regular"
  | Unix.S_DIR -> "directory"
  | Unix.S_CHR -> "character-device"
  | Unix.S_BLK -> "block-device"
  | Unix.S_LNK -> "symbolic-link"
  | Unix.S_FIFO -> "fifo"
  | Unix.S_SOCK -> "socket"
;;

let exact_read_operation_to_string = function
  | Exact_read.Pin_parent -> "pin_parent"
  | Exact_read.Open_parent_descriptor -> "open_parent_descriptor"
  | Exact_read.Open_leaf -> "open_leaf"
  | Exact_read.Inspect_opened -> "inspect_opened"
  | Exact_read.Allocate -> "allocate"
  | Exact_read.Read_exact -> "read_exact"
  | Exact_read.Inspect_after_read -> "inspect_after_read"
  | Exact_read.Close_leaf -> "close_leaf"
  | Exact_read.Settle_parent_resources -> "settle_parent_resources"
  | Exact_read.Observe_parent_cancellation -> "observe_parent_cancellation"
;;

let exact_read_diagnostic_to_string diagnostic =
  Printf.sprintf
    "%s: %s"
    (exact_read_operation_to_string diagnostic.Exact_read.operation)
    diagnostic.detail
;;

let head_error_to_string = function
  | Head.Invalid_leaf detail -> "invalid leaf: " ^ detail
  | Head.Invalid_row detail -> "invalid row: " ^ detail
  | Head.Busy -> "stable HEAD lock is contended"
  | Head.Conflict _ -> "HEAD cursor conflict"
  | Head.Corrupt_lock detail -> "corrupt stable HEAD lock: " ^ detail
  | Head.Corrupt_head detail -> "corrupt HEAD: " ^ detail
  | Head.Unsupported detail -> "unsupported HEAD operation: " ^ detail
  | Head.Io_error diagnostic -> head_diagnostic_to_string diagnostic
;;

let exact_read_error_to_string = function
  | Exact_read.Invalid_leaf detail -> "invalid leaf: " ^ detail
  | Exact_read.Invalid_length_bounds { expected_length; max_length } ->
    Printf.sprintf
      "invalid length bounds expected=%Ld maximum=%Ld"
      expected_length
      max_length
  | Exact_read.Length_not_representable length ->
    Printf.sprintf "length is not representable: %Ld" length
  | Exact_read.Cancelled diagnostic ->
    "immutable observation was cancelled: "
    ^ exact_read_diagnostic_to_string diagnostic
  | Exact_read.Parent_descriptor_unavailable ->
    "parent descriptor is unavailable"
  | Exact_read.Missing -> "object is missing"
  | Exact_read.Symbolic_link -> "object is a symbolic link"
  | Exact_read.Not_regular kind ->
    "object is not regular: " ^ unix_file_kind_to_string kind
  | Exact_read.Unsafe_link_count observed ->
    Printf.sprintf
      "object link count is unsafe: expected exactly 1, observed %d"
      observed
  | Exact_read.Unsafe_mode observed ->
    Printf.sprintf
      "object mode is unsafe: expected 0600 without special bits, observed 0%o"
      observed
  | Exact_read.Length_exceeds_max { max_length; observed_length } ->
    Printf.sprintf
      "object length %Ld exceeds maximum %Ld"
      observed_length
      max_length
  | Exact_read.Length_mismatch { expected_length; observed_length } ->
    Printf.sprintf
      "object length mismatch expected=%Ld observed=%Ld"
      expected_length
      observed_length
  | Exact_read.Changed_during_read -> "object changed during exact read"
  | Exact_read.Io_error diagnostic ->
    exact_read_diagnostic_to_string diagnostic
;;

let settlement_warning_to_string = function
  | Head_settlement_warning (Head.Cleanup_failed diagnostic) ->
    "HEAD cleanup failed: " ^ head_diagnostic_to_string diagnostic
  | Head_settlement_warning (Head.Resource_settlement_failed diagnostic) ->
    "HEAD resource settlement failed: " ^ head_diagnostic_to_string diagnostic
  | Head_effect_warning failure ->
    "HEAD effect was established with a later failure: "
    ^ head_error_to_string failure
  | Head_indeterminate_warning failure ->
    "HEAD publication remained indeterminate after: "
    ^ head_error_to_string failure
  | Immutable_settlement_warning
      (reference, Exact_read.Close_failed diagnostic) ->
    Printf.sprintf
      "immutable %s object %S close failed: %s"
      (artifact_kind_token reference.kind)
      reference.leaf
      (exact_read_diagnostic_to_string diagnostic)
  | Immutable_settlement_warning
      (reference, Exact_read.Settle_resources diagnostic) ->
    Printf.sprintf
      "immutable %s object %S parent resource settlement warning: %s"
      (artifact_kind_token reference.kind)
      reference.leaf
      (exact_read_diagnostic_to_string diagnostic)
;;

let error_settlement_warnings (value : error) = value.settlement_warnings

let error_to_string value =
  match value.kind with
  | Invalid_layout detail ->
    "invalid Memory OS store layout: " ^ detail
  | Store_not_active ->
    "Memory OS store callback lifetime has ended"
  | Runtime_store_binding_mismatch ->
    "Memory OS value belongs to a different open store instance"
  | Persisted_store_binding_mismatch detail ->
    "Memory OS persisted store binding mismatch: " ^ detail
  | Invalid_domain_value detail ->
    "invalid Memory OS domain value: " ^ detail
  | Conflicting_operation
      { operation_id
      ; committed_state_sha256
      ; requested_state_sha256
      } ->
    Printf.sprintf
      "current Memory OS operation %S commits state %s, requested %s"
      operation_id
      (Sha256.to_string committed_state_sha256)
      (Sha256.to_string requested_state_sha256)
  | Generation_exhausted ->
    "Memory OS store generation is exhausted"
  | Entropy_source_failed { purpose; exception_; _ } ->
    Printf.sprintf
      "Memory OS secure entropy failed for %s: %s"
      purpose
      (Printexc.to_string exception_)
  | Immutable_object_too_large { kind; byte_count; maximum } ->
    Printf.sprintf
      "immutable %s object is too large: %Ld bytes, maximum %Ld"
      (artifact_kind_token kind)
      byte_count
      maximum
  | Immutable_create_failed { kind; leaf; failure } ->
    Printf.sprintf
      "failed to durably create immutable %s object %S: %s"
      (artifact_kind_token kind)
      leaf
      (Fs_compat.capability_write_error_to_string failure)
  | Immutable_read_failed (reference, failure) ->
    Printf.sprintf
      "failed to read immutable %s object %S: %s"
      (artifact_kind_token reference.kind)
      reference.leaf
      (exact_read_error_to_string failure)
  | Immutable_digest_mismatch reference ->
    Printf.sprintf
      "immutable %s object %S does not match its SHA-256 digest"
      (artifact_kind_token reference.kind)
      reference.leaf
  | Invalid_store_json { artifact; detail } ->
    Printf.sprintf "invalid Memory OS %s JSON: %s" artifact detail
  | Head_operation_failed { phase; failure } ->
    Printf.sprintf
      "Memory OS HEAD %s failed: %s"
      phase
      (head_error_to_string failure)
  | Head_row_too_large byte_count ->
    Printf.sprintf
      "Memory OS HEAD row is %d bytes, maximum %d"
      byte_count
      Head.max_row_bytes
  | Pending_publication_mismatch ->
    "settled Memory OS HEAD does not match the pending publication receipt"
;;

let int64_to_json value = `Intlit (Int64.to_string value)

let non_negative_int64_of_json = function
  | `Int value when value >= 0 -> Ok (Int64.of_int value)
  | `Intlit raw ->
    (match Int64.of_string_opt raw with
     | Some value
       when Int64.compare value 0L >= 0
            && String.equal raw (Int64.to_string value) ->
       Ok value
     | Some _ | None -> Error "expected a canonical non-negative int64")
  | _ -> Error "expected a canonical non-negative int64"
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
  | _ -> Error "expected an object"
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

let int64_field name fields =
  let* value = required_field name fields in
  non_negative_int64_of_json value
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

let valid_store_id value = Option.is_some (Sha256.of_string value)

let valid_leaf kind leaf =
  let prefix = "memory-os-" ^ artifact_kind_token kind ^ "-" in
  let suffix = ".json" in
  if
    not (String.starts_with ~prefix leaf)
    || not (String.ends_with ~suffix leaf)
  then false
  else
    let token_length =
      String.length leaf - String.length prefix - String.length suffix
    in
    token_length = 64
    &&
    let token = String.sub leaf (String.length prefix) token_length in
    Option.is_some (Sha256.of_string token)
;;

let immutable_ref_to_json (reference : immutable_ref) =
  `Assoc
    [ "kind", `String (artifact_kind_token reference.kind)
    ; "leaf", `String reference.leaf
    ; "sha256", `String (Sha256.to_string reference.sha256)
    ; "byte_count", int64_to_json reference.byte_count
    ]
;;

let immutable_ref_of_json json =
  let* fields =
    exact_assoc [ "kind"; "leaf"; "sha256"; "byte_count" ] json
  in
  let* kind_token = string_field "kind" fields in
  let* kind =
    match artifact_kind_of_token kind_token with
    | Some kind -> Ok kind
    | None -> Error ("unknown artifact kind " ^ kind_token)
  in
  let* leaf = string_field "leaf" fields in
  let* digest_raw = string_field "sha256" fields in
  let* digest =
    match Sha256.of_string digest_raw with
    | Some digest -> Ok digest
    | None -> Error "sha256 must be canonical lowercase SHA-256 hex"
  in
  let* byte_count = int64_field "byte_count" fields in
  if not (valid_leaf kind leaf)
  then Error ("invalid immutable leaf " ^ leaf)
  else if Int64.compare byte_count 0L <= 0
  then Error "immutable byte_count must be positive"
  else if Int64.compare byte_count max_immutable_bytes > 0
  then Error "immutable byte_count exceeds the store maximum"
  else Ok { kind; leaf; sha256 = digest; byte_count }
;;

let validate_schema expected fields =
  let* actual = string_field "schema" fields in
  if String.equal actual expected
  then Ok ()
  else Error ("unsupported schema " ^ actual)
;;

let validate_persisted_identity ~store_id ~owner_id ~generation =
  if not (valid_store_id store_id)
  then Error "store_id must be a canonical 256-bit lowercase hex value"
  else if String.trim owner_id = ""
  then Error "owner_id must be non-empty"
  else if Int64.compare generation 0L <= 0
  then Error "generation must be positive"
  else Ok ()
;;

let head_record_to_json (value : head_record) =
  `Assoc
    [ "schema", `String head_schema
    ; "store_id", `String value.store_id
    ; "owner_id", `String value.owner_id
    ; "generation", int64_to_json value.generation
    ; "commit", immutable_ref_to_json value.commit_ref
    ]
;;

let head_record_of_json json =
  let* fields =
    exact_assoc
      [ "schema"; "store_id"; "owner_id"; "generation"; "commit" ]
      json
  in
  let* () = validate_schema head_schema fields in
  let* store_id = string_field "store_id" fields in
  let* owner_id = string_field "owner_id" fields in
  let* generation = int64_field "generation" fields in
  let* commit_json = required_field "commit" fields in
  let* commit_ref = immutable_ref_of_json commit_json in
  let* () =
    validate_persisted_identity ~store_id ~owner_id ~generation
  in
  if commit_ref.kind <> Commit_object
  then Error "HEAD commit ref has the wrong kind"
  else Ok { store_id; owner_id; generation; commit_ref }
;;

let facts_object_to_json (value : facts_object) =
  `Assoc
    [ "schema", `String facts_schema
    ; "store_id", `String value.store_id
    ; "owner_id", `String value.owner_id
    ; "generation", int64_to_json value.generation
    ; "facts", `List (List.map Types.fact_to_json value.facts)
    ]
;;

let episode_object_to_json (value : episode_object) =
  `Assoc
    [ "schema", `String episode_schema
    ; "store_id", `String value.store_id
    ; "owner_id", `String value.owner_id
    ; "generation", int64_to_json value.generation
    ; "episode", Types.episode_to_json value.episode
    ]
;;

let manifest_to_json (value : manifest) =
  `Assoc
    [ "schema", `String manifest_schema
    ; "store_id", `String value.store_id
    ; "owner_id", `String value.owner_id
    ; "generation", int64_to_json value.generation
    ; "facts", immutable_ref_to_json value.facts_ref
    ; "episodes", `List (List.map immutable_ref_to_json value.episode_refs)
    ]
;;

let commit_envelope_to_json (value : commit_record) =
  `Assoc
    [ "schema", `String commit_schema
    ; "store_id", `String value.store_id
    ; "owner_id", `String value.owner_id
    ; "generation", int64_to_json value.generation
    ; "operation_id", `String value.operation_id
    ; "manifest", immutable_ref_to_json value.manifest_ref
    ; "state_sha256", `String (Sha256.to_string value.state_sha256)
    ]
;;

let commit_record_to_json (value : commit_record) =
  `Assoc
    [ "schema", `String commit_schema
    ; "store_id", `String value.store_id
    ; "owner_id", `String value.owner_id
    ; "generation", int64_to_json value.generation
    ; "operation_id", `String value.operation_id
    ; "manifest", immutable_ref_to_json value.manifest_ref
    ; "state_sha256", `String (Sha256.to_string value.state_sha256)
    ; "receipt_id", `String (Sha256.to_string value.receipt_id)
    ]
;;

let receipt_digest (value : commit_record) =
  commit_envelope_to_json value
  |> canonical_json
  |> hash_domain "commit-receipt"
;;

let finite value =
  match classify_float value with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false
;;

let validate_fact (fact : Types.fact) =
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
    | Some value when String.trim value = "" ->
      Error "fact claim_id must be non-empty"
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
    | Some _ | None ->
      map_result validate_fact episode.claims |> Result.map ignore
;;

let validate_state (value : state) =
  let* _ = map_result validate_fact value.facts in
  let* _ = map_result validate_episode value.episodes in
  Ok ()
;;

let fact_of_json json =
  match Types.fact_of_json json with
  | Some fact ->
    let* () = validate_fact fact in
    Ok fact
  | None -> Error "invalid current fact payload"
;;

let episode_of_json json =
  match Types.episode_of_json json with
  | Some episode ->
    let* () = validate_episode episode in
    Ok episode
  | None -> Error "invalid current episode payload"
;;

let facts_object_of_json json =
  let* fields =
    exact_assoc
      [ "schema"; "store_id"; "owner_id"; "generation"; "facts" ]
      json
  in
  let* () = validate_schema facts_schema fields in
  let* store_id = string_field "store_id" fields in
  let* owner_id = string_field "owner_id" fields in
  let* generation = int64_field "generation" fields in
  let* facts_json = list_field "facts" fields in
  let* facts = map_result fact_of_json facts_json in
  let* () =
    validate_persisted_identity ~store_id ~owner_id ~generation
  in
  Ok { store_id; owner_id; generation; facts }
;;

let episode_object_of_json json =
  let* fields =
    exact_assoc
      [ "schema"; "store_id"; "owner_id"; "generation"; "episode" ]
      json
  in
  let* () = validate_schema episode_schema fields in
  let* store_id = string_field "store_id" fields in
  let* owner_id = string_field "owner_id" fields in
  let* generation = int64_field "generation" fields in
  let* episode_json = required_field "episode" fields in
  let* episode = episode_of_json episode_json in
  let* () =
    validate_persisted_identity ~store_id ~owner_id ~generation
  in
  Ok { store_id; owner_id; generation; episode }
;;

let manifest_of_json json =
  let* fields =
    exact_assoc
      [ "schema"
      ; "store_id"
      ; "owner_id"
      ; "generation"
      ; "facts"
      ; "episodes"
      ]
      json
  in
  let* () = validate_schema manifest_schema fields in
  let* store_id = string_field "store_id" fields in
  let* owner_id = string_field "owner_id" fields in
  let* generation = int64_field "generation" fields in
  let* facts_json = required_field "facts" fields in
  let* facts_ref = immutable_ref_of_json facts_json in
  let* episode_json = list_field "episodes" fields in
  let* episode_refs = map_result immutable_ref_of_json episode_json in
  let* () =
    validate_persisted_identity ~store_id ~owner_id ~generation
  in
  if facts_ref.kind <> Facts_object
  then Error "manifest facts ref has the wrong kind"
  else if
    List.exists
      (fun reference -> reference.kind <> Episode_object)
      episode_refs
  then Error "manifest episode ref has the wrong kind"
  else
    Ok
      { store_id
      ; owner_id
      ; generation
      ; facts_ref
      ; episode_refs
      }
;;

let commit_record_of_json json =
  let* fields =
    exact_assoc
      [ "schema"
      ; "store_id"
      ; "owner_id"
      ; "generation"
      ; "operation_id"
      ; "manifest"
      ; "state_sha256"
      ; "receipt_id"
      ]
      json
  in
  let* () = validate_schema commit_schema fields in
  let* store_id = string_field "store_id" fields in
  let* owner_id = string_field "owner_id" fields in
  let* generation = int64_field "generation" fields in
  let* operation_id = string_field "operation_id" fields in
  let* manifest_json = required_field "manifest" fields in
  let* manifest_ref = immutable_ref_of_json manifest_json in
  let* state_raw = string_field "state_sha256" fields in
  let* state_sha256 =
    match Sha256.of_string state_raw with
    | Some digest -> Ok digest
    | None ->
      Error "state_sha256 must be canonical lowercase SHA-256 hex"
  in
  let* receipt_raw = string_field "receipt_id" fields in
  let* receipt_id =
    match Sha256.of_string receipt_raw with
    | Some digest -> Ok digest
    | None ->
      Error "receipt_id must be canonical lowercase SHA-256 hex"
  in
  let* () =
    validate_persisted_identity ~store_id ~owner_id ~generation
  in
  if String.trim operation_id = ""
  then Error "operation_id must be non-empty"
  else if manifest_ref.kind <> Manifest_object
  then Error "commit manifest ref has the wrong kind"
  else
    let value =
      { store_id
      ; owner_id
      ; generation
      ; operation_id
      ; manifest_ref
      ; state_sha256
      ; receipt_id
      }
    in
    if not (Sha256.equal receipt_id (receipt_digest value))
    then Error "receipt_id does not bind the exact commit envelope"
    else Ok value
;;

let state_to_json (value : state) =
  `Assoc
    [ "schema", `String state_schema
    ; "facts", `List (List.map Types.fact_to_json value.facts)
    ; "episodes", `List (List.map Types.episode_to_json value.episodes)
    ]
;;

let state_digest value =
  state_to_json value |> canonical_json |> hash_domain "state"
;;

let invalid_json artifact detail =
  make_error (Invalid_store_json { artifact; detail })
;;

let parse_json ~artifact raw =
  try Ok (Yojson.Safe.from_string raw) with
  | Yojson.Json_error detail -> Error (invalid_json artifact detail)
;;

let decode_canonical ~artifact ~decode ~encode raw =
  let* json = parse_json ~artifact raw in
  match decode json with
  | Error detail -> Error (invalid_json artifact detail)
  | Ok value ->
    if String.equal raw (canonical_json (encode value))
    then Ok value
    else
      Error
        (invalid_json
           artifact
           "payload is not in the canonical current encoding")
;;

let head_of_row raw =
  decode_canonical
    ~artifact:"HEAD"
    ~decode:head_record_of_json
    ~encode:head_record_to_json
    raw
;;

let ensure_identity
      ~artifact
      ~expected_store_id
      ~expected_owner_id
      ~expected_generation
      ~store_id
      ~owner_id
      ~generation
  =
  if not (String.equal store_id expected_store_id)
  then
    Error
      (make_error
         (Persisted_store_binding_mismatch
            (artifact ^ " has a foreign store_id")))
  else if not (String.equal owner_id expected_owner_id)
  then
    Error
      (make_error
         (Persisted_store_binding_mismatch
            (artifact ^ " has a foreign owner_id")))
  else if not (Int64.equal generation expected_generation)
  then
    Error
      (make_error
         (Persisted_store_binding_mismatch
            (artifact ^ " has a foreign generation")))
  else Ok ()
;;

let warnings_of_head values =
  List.map (fun value -> Head_settlement_warning value) values
;;

let warnings_of_exact reference values =
  List.map
    (fun value -> Immutable_settlement_warning (reference, value))
    values
;;

let read_object_raw store reference =
  match
    Exact_read.read
      ~parent:store.root
      ~leaf:reference.leaf
      ~expected_length:reference.byte_count
      ~max_length:max_immutable_bytes
  with
  | Error failure ->
    let failure : Exact_read.failure = failure in
    Error
      (make_error
         ~settlement_warnings:
           (warnings_of_exact reference failure.settlement_warnings)
         (Immutable_read_failed (reference, failure.error)))
  | Ok observation ->
    let warnings =
      warnings_of_exact
        reference
        (Exact_read.observation_settlement_warnings observation)
    in
    let raw = Exact_read.observation_bytes observation in
    if not (Sha256.equal reference.sha256 (sha256 raw))
    then
      Error
        (make_error
           ~settlement_warnings:warnings
           (Immutable_digest_mismatch reference))
    else Ok (raw, warnings)
;;

let read_object store reference ~artifact ~decode ~encode =
  let* raw, warnings = read_object_raw store reference in
  match decode_canonical ~artifact ~decode ~encode raw with
  | Ok value -> Ok (value, warnings)
  | Error error -> Error (prepend_warnings warnings error)
;;

let random_token store purpose =
  try
    let entropy = Cstruct.create 32 in
    Eio.Flow.read_exact store.secure_random entropy;
    Ok (hash_domain purpose (Cstruct.to_string entropy))
  with
  | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break)
    as exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exception_ backtrace
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Error
      (make_error
         (Entropy_source_failed { purpose; exception_; backtrace }))
;;

let fresh_leaf store kind =
  let purpose = "leaf/" ^ artifact_kind_token kind in
  let* token = random_token store purpose in
  Ok
    ("memory-os-"
     ^ artifact_kind_token kind
     ^ "-"
     ^ token
     ^ ".json")
;;

let create_raw_object store kind raw =
  let byte_count = Int64.of_int (String.length raw) in
  if
    Int64.compare byte_count 0L <= 0
    || Int64.compare byte_count max_immutable_bytes > 0
  then
    Error
      (make_error
         (Immutable_object_too_large
            { kind; byte_count; maximum = max_immutable_bytes }))
  else
    let* leaf = fresh_leaf store kind in
    let reference =
      { kind; leaf; sha256 = sha256 raw; byte_count }
    in
    match
      Fs_compat.create_capability_file_exclusive
        ~parent:store.root
        ~leaf
        ~permissions:0o600
        raw
    with
    | Ok () -> Ok reference
    | Error failure ->
      Error
        (make_error
           (Immutable_create_failed { kind; leaf; failure }))
;;

let create_object store kind encode value =
  create_raw_object store kind (canonical_json (encode value))
;;

let same_cursor = Head.cursor_equal

let same_head_authority (left : snapshot) (right : snapshot) =
  same_cursor left.cursor right.cursor
  && left.head_row = right.head_row
;;

let empty_snapshot binding head_snapshot =
  { binding
  ; cursor = Head.snapshot_cursor head_snapshot
  ; head_row = None
  ; store_id = None
  ; generation = 0L
  ; commit_ref = None
  ; commit = None
  ; manifest_ref = None
  ; facts_ref = None
  ; episode_objects = []
  ; state = { facts = []; episodes = [] }
  ; settlement_warnings =
      warnings_of_head
        (Head.snapshot_settlement_warnings head_snapshot)
  }
;;

let load_from_head (store : t) (head_snapshot : Head.snapshot) =
  let head_warnings =
    warnings_of_head (Head.snapshot_settlement_warnings head_snapshot)
  in
  match Head.snapshot_row head_snapshot with
  | None -> Ok (empty_snapshot store.binding head_snapshot)
  | Some row ->
    let* head =
      head_of_row row |> with_prior_warnings head_warnings
    in
    if not (String.equal head.owner_id store.owner_id)
    then
      Error
        (make_error
           ~settlement_warnings:head_warnings
           (Persisted_store_binding_mismatch
              "HEAD owner_id does not match the opened owner"))
    else
      let commit_artifact = "commit:" ^ head.commit_ref.leaf in
      let* commit, commit_warnings =
        read_object
          store
          head.commit_ref
          ~artifact:commit_artifact
          ~decode:commit_record_of_json
          ~encode:commit_record_to_json
        |> with_prior_warnings head_warnings
      in
      let warnings = head_warnings @ commit_warnings in
      let* () =
        ensure_identity
          ~artifact:commit_artifact
          ~expected_store_id:head.store_id
          ~expected_owner_id:head.owner_id
          ~expected_generation:head.generation
          ~store_id:commit.store_id
          ~owner_id:commit.owner_id
          ~generation:commit.generation
        |> with_prior_warnings warnings
      in
      let manifest_artifact = "manifest:" ^ commit.manifest_ref.leaf in
      let* manifest, manifest_warnings =
        read_object
          store
          commit.manifest_ref
          ~artifact:manifest_artifact
          ~decode:manifest_of_json
          ~encode:manifest_to_json
        |> with_prior_warnings warnings
      in
      let warnings = warnings @ manifest_warnings in
      let* () =
        ensure_identity
          ~artifact:manifest_artifact
          ~expected_store_id:head.store_id
          ~expected_owner_id:head.owner_id
          ~expected_generation:head.generation
          ~store_id:manifest.store_id
          ~owner_id:manifest.owner_id
          ~generation:manifest.generation
        |> with_prior_warnings warnings
      in
      let facts_artifact = "facts:" ^ manifest.facts_ref.leaf in
      let* facts_object, facts_warnings =
        read_object
          store
          manifest.facts_ref
          ~artifact:facts_artifact
          ~decode:facts_object_of_json
          ~encode:facts_object_to_json
        |> with_prior_warnings warnings
      in
      let warnings = warnings @ facts_warnings in
      let* () =
        ensure_identity
          ~artifact:facts_artifact
          ~expected_store_id:head.store_id
          ~expected_owner_id:head.owner_id
          ~expected_generation:head.generation
          ~store_id:facts_object.store_id
          ~owner_id:facts_object.owner_id
          ~generation:facts_object.generation
        |> with_prior_warnings warnings
      in
      let rec load_episodes references values objects warnings =
        match references with
        | [] -> Ok (List.rev values, List.rev objects, warnings)
        | reference :: rest ->
          let artifact = "episode:" ^ reference.leaf in
          let* episode_object, object_warnings =
            read_object
              store
              reference
              ~artifact
              ~decode:episode_object_of_json
              ~encode:episode_object_to_json
            |> with_prior_warnings warnings
          in
          let warnings = warnings @ object_warnings in
          let* () =
            ensure_identity
              ~artifact
              ~expected_store_id:head.store_id
              ~expected_owner_id:head.owner_id
              ~expected_generation:head.generation
              ~store_id:episode_object.store_id
              ~owner_id:episode_object.owner_id
              ~generation:episode_object.generation
            |> with_prior_warnings warnings
          in
          load_episodes
            rest
            (episode_object.episode :: values)
            ((reference, episode_object.episode) :: objects)
            warnings
      in
      let* episodes, episode_objects, warnings =
        load_episodes manifest.episode_refs [] [] warnings
      in
      let state = { facts = facts_object.facts; episodes } in
      let* () =
        match validate_state state with
        | Ok () -> Ok ()
        | Error detail ->
          Error
            (make_error
               ~settlement_warnings:warnings
               (Invalid_domain_value detail))
      in
      let observed_state_sha256 = state_digest state in
      if not (Sha256.equal observed_state_sha256 commit.state_sha256)
      then
        Error
          (make_error
             ~settlement_warnings:warnings
             (Invalid_store_json
                { artifact = commit_artifact
                ; detail =
                    "state_sha256 does not bind the reachable state"
                }))
      else
        Ok
          { binding = store.binding
          ; cursor = Head.snapshot_cursor head_snapshot
          ; head_row = Some row
          ; store_id = Some head.store_id
          ; generation = head.generation
          ; commit_ref = Some head.commit_ref
          ; commit = Some commit
          ; manifest_ref = Some commit.manifest_ref
          ; facts_ref = Some manifest.facts_ref
          ; episode_objects
          ; state
          ; settlement_warnings = warnings
          }
;;

let check_active (store : t) =
  if Atomic.get store.binding.active
  then Ok ()
  else Error (make_error Store_not_active)
;;

let check_binding (store : t) (binding : binding) warnings =
  let* () = check_active store |> with_prior_warnings warnings in
  if store.binding == binding
  then Ok ()
  else
    Error
      (make_error
         ~settlement_warnings:warnings
         Runtime_store_binding_mismatch)
;;

let with_store ~secure_random ~root ~owner_id fn =
  if String.trim owner_id = ""
  then Error (make_error (Invalid_layout "owner_id must be non-empty"))
  else
    Eio.Switch.run (fun sw ->
      let binding = { active = Atomic.make true } in
      Eio.Switch.on_release sw (fun () ->
        Atomic.set binding.active false);
      fn { binding; secure_random; root; owner_id })
;;

let load store =
  let* () = check_active store in
  match
    Head.read
      ~secure_random:store.secure_random
      ~parent:store.root
      ~leaf:head_leaf
  with
  | Ok head_snapshot -> load_from_head store head_snapshot
  | Error failure ->
    let failure : Head.failure = failure in
    Error
      (make_error
         ~settlement_warnings:
           (warnings_of_head failure.settlement_warnings)
         (Head_operation_failed
            { phase = "read"; failure = failure.error }))
;;

type terminal_revalidation =
  | Terminal_current of snapshot
  | Terminal_stale of snapshot

let revalidate_terminal_current (store : t) (current : snapshot) =
  match
    Head.read
      ~secure_random:store.secure_random
      ~parent:store.root
      ~leaf:head_leaf
  with
  | Error failure ->
    let failure : Head.failure = failure in
    Error
      (make_error
         ~settlement_warnings:
           (current.settlement_warnings
            @ warnings_of_head failure.settlement_warnings)
         (Head_operation_failed
            { phase = "terminal revalidation"; failure = failure.error }))
  | Ok head_snapshot ->
    let observed_cursor = Head.snapshot_cursor head_snapshot in
    let observed_row = Head.snapshot_row head_snapshot in
    if same_cursor observed_cursor current.cursor
       && observed_row = current.head_row
    then
      Ok
        (Terminal_current
           { current with
             settlement_warnings =
               current.settlement_warnings
               @ warnings_of_head
                   (Head.snapshot_settlement_warnings head_snapshot)
           })
    else
      (match load_from_head store head_snapshot with
       | Error error ->
         Error (prepend_warnings current.settlement_warnings error)
       | Ok authoritative ->
         Ok
           (Terminal_stale
              { authoritative with
                settlement_warnings =
                  current.settlement_warnings
                  @ authoritative.settlement_warnings
              }))
;;

let receipt_of_snapshot (snapshot : snapshot) =
  match snapshot.commit with
  | None -> None
  | Some commit ->
    Some
      { receipt_id = commit.receipt_id
      ; operation_id = commit.operation_id
      ; state_sha256 = commit.state_sha256
      ; generation = commit.generation
      ; snapshot
      ; settlement_warnings = snapshot.settlement_warnings
      }
;;

let create_episode_objects
      store
      ~store_id
      ~owner_id
      ~generation
      episodes
  =
  let rec loop objects = function
    | [] -> Ok (List.rev objects)
    | episode :: rest ->
      let value = { store_id; owner_id; generation; episode } in
      let* reference =
        create_object store Episode_object episode_object_to_json value
      in
      loop ((reference, episode) :: objects) rest
  in
  loop [] episodes
;;

let prepare
      (store : t)
      ~(expected : snapshot)
      ~operation_id
      ~(state : state)
  =
  let* () =
    check_binding
      store
      expected.binding
      expected.settlement_warnings
  in
  if String.trim operation_id = ""
  then
    Error
      (make_error
         ~settlement_warnings:expected.settlement_warnings
         (Invalid_domain_value "operation_id must be non-empty"))
  else
    let* () =
      match validate_state state with
      | Ok () -> Ok ()
      | Error detail ->
        Error
          (make_error
             ~settlement_warnings:expected.settlement_warnings
             (Invalid_domain_value detail))
    in
    let requested_state_sha256 = state_digest state in
    let* current = load store in
    if not (same_head_authority expected current)
    then Ok (Stale_expected current)
    else
      match current.commit with
      | Some commit when String.equal commit.operation_id operation_id ->
        let* terminal = revalidate_terminal_current store current in
        (match terminal with
         | Terminal_stale authoritative ->
           Ok (Stale_expected authoritative)
         | Terminal_current current ->
           if Sha256.equal commit.state_sha256 requested_state_sha256
           then
             (match receipt_of_snapshot current with
              | Some receipt -> Ok (Current_commit_replay receipt)
              | None ->
                Error
                  (make_error
                     ~settlement_warnings:current.settlement_warnings
                     (Invalid_store_json
                        { artifact = "HEAD"
                        ; detail = "current commit receipt is absent"
                        })))
           else
             Error
               (make_error
                  ~settlement_warnings:current.settlement_warnings
                  (Conflicting_operation
                     { operation_id
                     ; committed_state_sha256 = commit.state_sha256
                     ; requested_state_sha256
                     })))
      | Some _ | None ->
        if Int64.equal current.generation Int64.max_int
        then
          Error
            (make_error
               ~settlement_warnings:current.settlement_warnings
               Generation_exhausted)
        else
          let* store_id =
            match current.store_id with
            | Some store_id -> Ok store_id
            | None -> random_token store "store-id"
          in
          let generation = Int64.succ current.generation in
          let facts_value =
            { store_id
            ; owner_id = store.owner_id
            ; generation
            ; facts = state.facts
            }
          in
          let* facts_ref =
            create_object
              store
              Facts_object
              facts_object_to_json
              facts_value
            |> with_prior_warnings current.settlement_warnings
          in
          let* episode_objects =
            create_episode_objects
              store
              ~store_id
              ~owner_id:store.owner_id
              ~generation
              state.episodes
            |> with_prior_warnings current.settlement_warnings
          in
          let manifest =
            { store_id
            ; owner_id = store.owner_id
            ; generation
            ; facts_ref
            ; episode_refs = List.map fst episode_objects
            }
          in
          let* manifest_ref =
            create_object
              store
              Manifest_object
              manifest_to_json
              manifest
            |> with_prior_warnings current.settlement_warnings
          in
          let provisional_commit =
            { store_id
            ; owner_id = store.owner_id
            ; generation
            ; operation_id
            ; manifest_ref
            ; state_sha256 = requested_state_sha256
            ; receipt_id = ""
            }
          in
          let receipt_id = receipt_digest provisional_commit in
          let commit = { provisional_commit with receipt_id } in
          let* commit_ref =
            create_object
              store
              Commit_object
              commit_record_to_json
              commit
            |> with_prior_warnings current.settlement_warnings
          in
          let head =
            { store_id
            ; owner_id = store.owner_id
            ; generation
            ; commit_ref
            }
          in
          let head_row = canonical_json (head_record_to_json head) in
          if String.length head_row > Head.max_row_bytes
          then
            Error
              (make_error
                 ~settlement_warnings:current.settlement_warnings
                 (Head_row_too_large (String.length head_row)))
          else
            Ok
              (Prepared
                 { binding = store.binding
                 ; expected_cursor = current.cursor
                 ; previous = current
                 ; store_id
                 ; generation
                 ; commit_ref
                 ; commit
                 ; manifest_ref
                 ; facts_ref
                 ; episode_objects
                 ; state
                 ; operation_id
                 ; state_sha256 = requested_state_sha256
                 ; receipt_id
                 ; head_row
                 ; settlement_warnings =
                     current.settlement_warnings
                 })
;;

let snapshot_of_prepared
      (prepared : prepared_commit)
      cursor
      warnings
  =
  { binding = prepared.binding
  ; cursor
  ; head_row = Some prepared.head_row
  ; store_id = Some prepared.store_id
  ; generation = prepared.generation
  ; commit_ref = Some prepared.commit_ref
  ; commit = Some prepared.commit
  ; manifest_ref = Some prepared.manifest_ref
  ; facts_ref = Some prepared.facts_ref
  ; episode_objects = prepared.episode_objects
  ; state = prepared.state
  ; settlement_warnings = warnings
  }
;;

let receipt_of_prepared prepared cursor warnings =
  let snapshot = snapshot_of_prepared prepared cursor warnings in
  { receipt_id = prepared.receipt_id
  ; operation_id = prepared.operation_id
  ; state_sha256 = prepared.state_sha256
  ; generation = prepared.generation
  ; snapshot
  ; settlement_warnings = warnings
  }
;;

let add_snapshot_warnings warnings (snapshot : snapshot) =
  { snapshot with
    settlement_warnings = warnings @ snapshot.settlement_warnings
  }
;;

let publish (store : t) (prepared : prepared_commit) =
  let* () =
    check_binding
      store
      prepared.binding
      prepared.settlement_warnings
  in
  match
    Head.compare_and_swap
      ~secure_random:store.secure_random
      ~parent:store.root
      ~leaf:head_leaf
      ~expected:prepared.expected_cursor
      ~row:prepared.head_row
  with
  | Ok publication ->
    let evidence = Head.publication_evidence publication in
    let warnings =
      prepared.settlement_warnings
      @ warnings_of_head
          (Head.publication_settlement_warnings publication)
    in
    Ok
      (Committed
         (receipt_of_prepared
            prepared
            evidence.published_cursor
            warnings))
  | Error failure ->
    let failure : Head.failure = failure in
    let settlement_warnings =
      prepared.settlement_warnings
      @ warnings_of_head failure.settlement_warnings
    in
    (match failure.target_effect with
     | Head.Published evidence ->
       let warnings =
         settlement_warnings @ [ Head_effect_warning failure.error ]
       in
       Ok
         (Committed
            (receipt_of_prepared
               prepared
               evidence.published_cursor
               warnings))
     | Head.Publication_indeterminate _ ->
       let warnings =
         settlement_warnings
         @ [ Head_indeterminate_warning failure.error ]
       in
       Ok
         (Indeterminate
            { binding = store.binding
            ; prepared
            ; settlement_warnings = warnings
            })
     | Head.Unchanged ->
       (match failure.error with
        | Head.Conflict head_snapshot ->
          (match load_from_head store head_snapshot with
           | Ok current ->
             Ok (Stale (add_snapshot_warnings settlement_warnings current))
           | Error error ->
             Error (prepend_warnings settlement_warnings error))
        | head_error ->
          Error
            (make_error
               ~settlement_warnings
               (Head_operation_failed
                  { phase = "publish"; failure = head_error }))))
;;

let snapshot_matches_pending
      (snapshot : snapshot)
      (pending : pending_publication)
  =
  match snapshot.commit, snapshot.store_id with
  | Some commit, Some store_id ->
    String.equal store_id pending.prepared.store_id
    && Int64.equal snapshot.generation pending.prepared.generation
    && String.equal commit.operation_id pending.prepared.operation_id
    && Sha256.equal commit.receipt_id pending.prepared.receipt_id
    && Sha256.equal
         commit.state_sha256
         pending.prepared.state_sha256
  | None, _ | _, None -> false
;;

let settle (store : t) (pending : pending_publication) =
  let* () =
    check_binding
      store
      pending.binding
      pending.settlement_warnings
  in
  match
    Head.read
      ~secure_random:store.secure_random
      ~parent:store.root
      ~leaf:head_leaf
  with
  | Error failure ->
    let failure : Head.failure = failure in
    Error
      (make_error
         ~settlement_warnings:
           (pending.settlement_warnings
            @ warnings_of_head failure.settlement_warnings)
         (Head_operation_failed
            { phase = "settlement read"; failure = failure.error }))
  | Ok head_snapshot ->
    let observed_row = Head.snapshot_row head_snapshot in
    if observed_row = Some pending.prepared.head_row
    then
      (match load_from_head store head_snapshot with
       | Error error ->
         Error (prepend_warnings pending.settlement_warnings error)
       | Ok current ->
         let current =
           add_snapshot_warnings
             pending.settlement_warnings
             current
         in
         if snapshot_matches_pending current pending
         then
           (match receipt_of_snapshot current with
            | Some receipt -> Ok (Settled_committed receipt)
            | None ->
              Error
                (make_error
                   ~settlement_warnings:current.settlement_warnings
                   Pending_publication_mismatch))
         else
           Error
             (make_error
                ~settlement_warnings:current.settlement_warnings
                Pending_publication_mismatch))
    else if
      same_cursor
        (Head.snapshot_cursor head_snapshot)
        pending.prepared.previous.cursor
      && observed_row = pending.prepared.previous.head_row
    then
      (match load_from_head store head_snapshot with
       | Error error ->
         Error (prepend_warnings pending.settlement_warnings error)
       | Ok current ->
         Ok
           (Settled_not_published
              (add_snapshot_warnings
                 pending.settlement_warnings
                 current)))
    else
      let settlement_warnings =
        pending.settlement_warnings
        @ warnings_of_head
            (Head.snapshot_settlement_warnings head_snapshot)
      in
      Ok
        (Still_indeterminate
           { pending with settlement_warnings })
;;
