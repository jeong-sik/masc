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
let store_identity_schema = "masc-memory-os-store-identity-v1"
let publication_obligation_schema =
  "masc-memory-os-publication-obligation-v1"
let head_leaf = "HEAD"
let store_identity_leaf = "store-identity.json"
(* Private guard for one contiguous OCaml string allocation. This is not a
   product capacity, admission/routing limit, provider/model capability,
   pricing input, or public configuration. *)
let immutable_serialization_safety_ceiling_bytes =
  Int64.of_int (64 * 1024 * 1024)

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
let list_map fn values = List.rev (List.rev_map fn values)

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

type persisted_artifact =
  [ `Facts
  | `Episode
  | `Manifest
  | `Commit
  | `Head_row
  ]

type implementation_safety_violation =
  { artifact : persisted_artifact
  ; observed_at_least_bytes : int64
  ; ceiling_bytes : int64
  }

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
  | Store_identity_settlement_warning of Exact_read.settlement_warning
  | Current_head_settlement_warning of Exact_read.settlement_warning

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
  | Implementation_safety_ceiling_exceeded
      of implementation_safety_violation
  | Byte_accounting_overflow of persisted_artifact
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
  | Store_identity_missing_from_non_fresh_root of int
  | Store_identity_create_failed of Fs_compat.capability_write_error
  | Store_identity_read_failed of Exact_read.error
  | Invalid_store_identity of string
  | Current_head_read_failed of Exact_read.error
  | Current_head_changed_during_read
  | Invalid_publication_obligation of string
  | Publication_obligation_owner_mismatch of
      { obligation_owner_id : string
      ; store_owner_id : string
      }
  | Publication_obligation_store_mismatch of
      { obligation_store_id : string
      ; opened_store_id : string
      }
  | Publication_obligation_mismatch of string

type error =
  { kind : error_kind
  ; settlement_warnings : settlement_warning list
  }

let make_error ?(settlement_warnings = []) (kind : error_kind) =
  ({ kind; settlement_warnings } : error)
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

type store_identity =
  { store_id : string
  ; owner_binding_sha256 : Sha256.t
  }

type t =
  { binding : binding
  ; secure_random : Eio.Flow.source_ty Eio.Resource.t
  ; root : Eio.Fs.dir_ty Eio.Path.t
  ; owner_id : string
  ; store_id : string
  ; opening_warnings : settlement_warning list
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

type head_authority =
  { payload_sha256 : Sha256.t
  ; payload_bytes : int64
  ; store_id : string
  ; generation : int64
  ; commit_ref : immutable_ref
  ; receipt_id : Sha256.t
  }

type authority_token =
  | Empty_authority
  | Head_authority of head_authority

type publication_obligation =
  { owner_id : string
  ; store_id : string
  ; expected : authority_token
  ; desired : head_authority
  ; operation_id : string
  ; state_sha256 : Sha256.t
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

type recovery_outcome =
  | Recovered_committed of commit_receipt
  | Recovered_not_published of snapshot
  | Recovered_superseded of snapshot

type current_head_projection =
  { receipt_id : Sha256.t
  ; operation_id : string
  ; state_digest : Sha256.t
  ; generation : int64
  }

type current_head =
  | Empty
  | Present of current_head_projection

type existing_store =
  | Absent
  | Existing of
      { current_head : current_head
      ; settlement_warnings : settlement_warning list
      }

module Canonical_bytes = struct
  type sink =
    { write : string -> off:int -> len:int -> unit }

  type measurement_error =
    | Ceiling_exceeded of int64
    | Counter_overflow

  exception Measurement_ceiling_exceeded of int64
  exception Measurement_counter_overflow
  exception Render_mismatch of string

  let write sink value =
    sink.write value ~off:0 ~len:(String.length value)
  ;;

  let write_slice sink value ~off ~len =
    if len > 0 then sink.write value ~off ~len
  ;;

  let hex_digit value =
    Char.chr (if value < 10 then value + 48 else value + 87)
  ;;

  let json_string sink value =
    write sink "\"";
    let start = ref 0 in
    let flush stop =
      write_slice sink value ~off:!start ~len:(stop - !start)
    in
    for index = 0 to String.length value - 1 do
      let escaped =
        match value.[index] with
        | '"' -> Some "\\\""
        | '\\' -> Some "\\\\"
        | '\b' -> Some "\\b"
        | '\012' -> Some "\\f"
        | '\n' -> Some "\\n"
        | '\r' -> Some "\\r"
        | '\t' -> Some "\\t"
        | ('\x00' .. '\x1f' | '\x7f') as character ->
          let code = Char.code character in
          let escaped = Bytes.of_string "\\u0000" in
          Bytes.set escaped 4 (hex_digit (code lsr 4));
          Bytes.set escaped 5 (hex_digit (code land 0xf));
          Some (Bytes.unsafe_to_string escaped)
        | _ -> None
      in
      match escaped with
      | None -> ()
      | Some escaped ->
        flush index;
        write sink escaped;
        start := index + 1
    done;
    flush (String.length value);
    write sink "\""
  ;;

  let int_value sink value = write sink (string_of_int value)
  let int64_value sink value = write sink (Int64.to_string value)

  let float_value sink value =
    write sink (Yojson.Safe.to_string (`Float value))
  ;;

  let field sink ~first name =
    if not first then write sink ",";
    json_string sink name;
    write sink ":"
  ;;

  let list emit sink values =
    write sink "[";
    let rec loop first = function
      | [] -> ()
      | value :: rest ->
        if not first then write sink ",";
        emit sink value;
        loop false rest
    in
    loop true values;
    write sink "]"
  ;;

  let measure_bounded ~ceiling emit =
    let count = ref 0L in
    let sink =
      { write =
          (fun _value ~off:_ ~len ->
             let delta = Int64.of_int len in
             if
               Int64.compare
                 !count
                 (Int64.sub Int64.max_int delta)
               > 0
             then raise Measurement_counter_overflow;
             let next = Int64.add !count delta in
             if Int64.compare next ceiling > 0
             then raise (Measurement_ceiling_exceeded next);
             count := next)
      }
    in
    try
      emit sink;
      Ok !count
    with
    | Measurement_ceiling_exceeded observed ->
      Error (Ceiling_exceeded observed)
    | Measurement_counter_overflow -> Error Counter_overflow
  ;;

  let measure_bounded_result ~ceiling emit =
    let count = ref 0L in
    let sink =
      { write =
          (fun _value ~off:_ ~len ->
             let delta = Int64.of_int len in
             if
               Int64.compare
                 !count
                 (Int64.sub Int64.max_int delta)
               > 0
             then raise Measurement_counter_overflow;
             let next = Int64.add !count delta in
             if Int64.compare next ceiling > 0
             then raise (Measurement_ceiling_exceeded next);
             count := next)
      }
    in
    try
      match emit sink with
      | Ok value -> Ok (value, !count)
      | Error error -> Error (`Emitter error)
    with
    | Measurement_ceiling_exceeded observed ->
      Error (`Measurement (Ceiling_exceeded observed))
    | Measurement_counter_overflow ->
      Error (`Measurement Counter_overflow)
  ;;

  let digest ?domain emit =
    let context = ref Digestif.SHA256.empty in
    let feed value ~off ~len =
      context :=
        Digestif.SHA256.feed_string !context ~off ~len value
    in
    (match domain with
     | None -> ()
     | Some domain ->
       let prefix = "masc.memory_os.store/v2\000" in
       feed prefix ~off:0 ~len:(String.length prefix);
       feed domain ~off:0 ~len:(String.length domain);
       feed "\000" ~off:0 ~len:1);
    emit { write = feed };
    Digestif.SHA256.(get !context |> to_hex)
  ;;

  let render_exact ~byte_count emit =
    if
      Int64.compare byte_count 0L < 0
      || Int64.compare
           byte_count
           (Int64.of_int Sys.max_string_length)
         > 0
    then Error "measured byte count is not representable as one OCaml string"
    else
      let expected = Int64.to_int byte_count in
      let output = Bytes.create expected in
      let position = ref 0 in
      let sink =
        { write =
            (fun value ~off ~len ->
               if len < 0 || !position > expected - len
               then
                 raise
                   (Render_mismatch
                      "canonical emitter produced more bytes than measured");
               Bytes.blit_string value off output !position len;
               position := !position + len)
        }
      in
      try
        emit sink;
        if !position <> expected
        then
          Error
            (Printf.sprintf
               "canonical emitter produced %d bytes after measuring %d"
               !position
               expected)
        else Ok (Bytes.unsafe_to_string output)
      with
      | Render_mismatch detail -> Error detail
  ;;
end

let emit_provenance sink (value : Types.provenance_event) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "trace_id";
  Canonical_bytes.json_string sink value.trace_id;
  Canonical_bytes.field sink ~first:false "turn";
  Canonical_bytes.int_value sink value.turn;
  (match value.tool_call_id with
   | None -> ()
   | Some tool_call_id ->
     Canonical_bytes.field sink ~first:false "tool_call_id";
     Canonical_bytes.json_string sink tool_call_id);
  Canonical_bytes.write sink "}"
;;

let emit_string_list sink values =
  Canonical_bytes.list Canonical_bytes.json_string sink values
;;

let emit_fact sink (value : Types.fact) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "claim";
  Canonical_bytes.json_string sink value.claim;
  Canonical_bytes.field sink ~first:false "category";
  Canonical_bytes.json_string
    sink
    (Types.category_to_string value.category);
  Canonical_bytes.field sink ~first:false "source";
  emit_provenance sink value.source;
  Canonical_bytes.field sink ~first:false "first_seen";
  Canonical_bytes.float_value sink value.first_seen;
  Canonical_bytes.field sink ~first:false "schema_version";
  Canonical_bytes.json_string sink value.schema_version;
  (match value.valid_until with
   | None -> ()
   | Some valid_until ->
     Canonical_bytes.field sink ~first:false "valid_until";
     Canonical_bytes.float_value sink valid_until);
  (match value.last_verified_at with
   | None -> ()
   | Some last_verified_at ->
     Canonical_bytes.field sink ~first:false "last_verified_at";
     Canonical_bytes.float_value sink last_verified_at);
  (match value.claim_id with
   | None -> ()
   | Some claim_id ->
     Canonical_bytes.field sink ~first:false "claim_id";
     Canonical_bytes.json_string sink claim_id);
  (match value.claim_kind with
   | None -> ()
   | Some claim_kind ->
     Canonical_bytes.field sink ~first:false "claim_kind";
     Canonical_bytes.json_string
       sink
       (Types.claim_kind_to_string claim_kind));
  Canonical_bytes.write sink "}"
;;

let emit_episode sink (value : Types.episode) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "trace_id";
  Canonical_bytes.json_string sink value.trace_id;
  Canonical_bytes.field sink ~first:false "generation";
  Canonical_bytes.int_value sink value.generation;
  Canonical_bytes.field sink ~first:false "episode_summary";
  Canonical_bytes.json_string sink value.episode_summary;
  Canonical_bytes.field sink ~first:false "claims";
  Canonical_bytes.list emit_fact sink value.claims;
  Canonical_bytes.field sink ~first:false "open_items";
  emit_string_list sink value.open_items;
  Canonical_bytes.field sink ~first:false "constraints";
  emit_string_list sink value.constraints;
  Canonical_bytes.field sink ~first:false "preserved_tool_refs";
  emit_string_list sink value.preserved_tool_refs;
  Canonical_bytes.field sink ~first:false "created_at";
  Canonical_bytes.float_value sink value.created_at;
  Canonical_bytes.field sink ~first:false "schema_version";
  Canonical_bytes.json_string sink value.schema_version;
  (match value.source_turn_range with
   | None -> ()
   | Some (lo, hi) ->
     Canonical_bytes.field sink ~first:false "source_turn_range";
     Canonical_bytes.write sink "{";
     Canonical_bytes.field sink ~first:true "lo";
     Canonical_bytes.int_value sink lo;
     Canonical_bytes.field sink ~first:false "hi";
     Canonical_bytes.int_value sink hi;
     Canonical_bytes.write sink "}");
  (match value.valid_until with
   | None -> ()
   | Some valid_until ->
     Canonical_bytes.field sink ~first:false "valid_until";
     Canonical_bytes.float_value sink valid_until);
  (match value.terminal_marker with
   | None -> ()
   | Some terminal_marker ->
     Canonical_bytes.field sink ~first:false "terminal_marker";
     Canonical_bytes.json_string sink terminal_marker);
  Canonical_bytes.write sink "}"
;;

let emit_immutable_ref sink (value : immutable_ref) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "kind";
  Canonical_bytes.json_string sink (artifact_kind_token value.kind);
  Canonical_bytes.field sink ~first:false "leaf";
  Canonical_bytes.json_string sink value.leaf;
  Canonical_bytes.field sink ~first:false "sha256";
  Canonical_bytes.json_string sink (Sha256.to_string value.sha256);
  Canonical_bytes.field sink ~first:false "byte_count";
  Canonical_bytes.int64_value sink value.byte_count;
  Canonical_bytes.write sink "}"
;;

let emit_head_record sink (value : head_record) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "schema";
  Canonical_bytes.json_string sink head_schema;
  Canonical_bytes.field sink ~first:false "store_id";
  Canonical_bytes.json_string sink value.store_id;
  Canonical_bytes.field sink ~first:false "owner_id";
  Canonical_bytes.json_string sink value.owner_id;
  Canonical_bytes.field sink ~first:false "generation";
  Canonical_bytes.int64_value sink value.generation;
  Canonical_bytes.field sink ~first:false "commit";
  emit_immutable_ref sink value.commit_ref;
  Canonical_bytes.write sink "}"
;;

let emit_facts_object sink (value : facts_object) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "schema";
  Canonical_bytes.json_string sink facts_schema;
  Canonical_bytes.field sink ~first:false "store_id";
  Canonical_bytes.json_string sink value.store_id;
  Canonical_bytes.field sink ~first:false "owner_id";
  Canonical_bytes.json_string sink value.owner_id;
  Canonical_bytes.field sink ~first:false "generation";
  Canonical_bytes.int64_value sink value.generation;
  Canonical_bytes.field sink ~first:false "facts";
  Canonical_bytes.list emit_fact sink value.facts;
  Canonical_bytes.write sink "}"
;;

let emit_episode_object sink (value : episode_object) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "schema";
  Canonical_bytes.json_string sink episode_schema;
  Canonical_bytes.field sink ~first:false "store_id";
  Canonical_bytes.json_string sink value.store_id;
  Canonical_bytes.field sink ~first:false "owner_id";
  Canonical_bytes.json_string sink value.owner_id;
  Canonical_bytes.field sink ~first:false "generation";
  Canonical_bytes.int64_value sink value.generation;
  Canonical_bytes.field sink ~first:false "episode";
  emit_episode sink value.episode;
  Canonical_bytes.write sink "}"
;;

let emit_manifest sink (value : manifest) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "schema";
  Canonical_bytes.json_string sink manifest_schema;
  Canonical_bytes.field sink ~first:false "store_id";
  Canonical_bytes.json_string sink value.store_id;
  Canonical_bytes.field sink ~first:false "owner_id";
  Canonical_bytes.json_string sink value.owner_id;
  Canonical_bytes.field sink ~first:false "generation";
  Canonical_bytes.int64_value sink value.generation;
  Canonical_bytes.field sink ~first:false "facts";
  emit_immutable_ref sink value.facts_ref;
  Canonical_bytes.field sink ~first:false "episodes";
  Canonical_bytes.list emit_immutable_ref sink value.episode_refs;
  Canonical_bytes.write sink "}"
;;

let emit_commit_envelope sink (value : commit_record) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "schema";
  Canonical_bytes.json_string sink commit_schema;
  Canonical_bytes.field sink ~first:false "store_id";
  Canonical_bytes.json_string sink value.store_id;
  Canonical_bytes.field sink ~first:false "owner_id";
  Canonical_bytes.json_string sink value.owner_id;
  Canonical_bytes.field sink ~first:false "generation";
  Canonical_bytes.int64_value sink value.generation;
  Canonical_bytes.field sink ~first:false "operation_id";
  Canonical_bytes.json_string sink value.operation_id;
  Canonical_bytes.field sink ~first:false "manifest";
  emit_immutable_ref sink value.manifest_ref;
  Canonical_bytes.field sink ~first:false "state_sha256";
  Canonical_bytes.json_string sink (Sha256.to_string value.state_sha256);
  Canonical_bytes.write sink "}"
;;

let emit_commit_record sink (value : commit_record) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "schema";
  Canonical_bytes.json_string sink commit_schema;
  Canonical_bytes.field sink ~first:false "store_id";
  Canonical_bytes.json_string sink value.store_id;
  Canonical_bytes.field sink ~first:false "owner_id";
  Canonical_bytes.json_string sink value.owner_id;
  Canonical_bytes.field sink ~first:false "generation";
  Canonical_bytes.int64_value sink value.generation;
  Canonical_bytes.field sink ~first:false "operation_id";
  Canonical_bytes.json_string sink value.operation_id;
  Canonical_bytes.field sink ~first:false "manifest";
  emit_immutable_ref sink value.manifest_ref;
  Canonical_bytes.field sink ~first:false "state_sha256";
  Canonical_bytes.json_string sink (Sha256.to_string value.state_sha256);
  Canonical_bytes.field sink ~first:false "receipt_id";
  Canonical_bytes.json_string sink (Sha256.to_string value.receipt_id);
  Canonical_bytes.write sink "}"
;;

let emit_state sink (value : state) =
  Canonical_bytes.write sink "{";
  Canonical_bytes.field sink ~first:true "schema";
  Canonical_bytes.json_string sink state_schema;
  Canonical_bytes.field sink ~first:false "facts";
  Canonical_bytes.list emit_fact sink value.facts;
  Canonical_bytes.field sink ~first:false "episodes";
  Canonical_bytes.list emit_episode sink value.episodes;
  Canonical_bytes.write sink "}"
;;

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
  | Store_identity_settlement_warning (Exact_read.Close_failed diagnostic) ->
    "store identity close failed: "
    ^ exact_read_diagnostic_to_string diagnostic
  | Store_identity_settlement_warning
      (Exact_read.Settle_resources diagnostic) ->
    "store identity parent resource settlement warning: "
    ^ exact_read_diagnostic_to_string diagnostic
  | Current_head_settlement_warning (Exact_read.Close_failed diagnostic) ->
    "current HEAD close failed: "
    ^ exact_read_diagnostic_to_string diagnostic
  | Current_head_settlement_warning
      (Exact_read.Settle_resources diagnostic) ->
    "current HEAD parent resource settlement warning: "
    ^ exact_read_diagnostic_to_string diagnostic
;;

let error_settlement_warnings (value : error) = value.settlement_warnings

let error_implementation_safety_violation (value : error) =
  match value.kind with
  | Implementation_safety_ceiling_exceeded violation -> Some violation
  | Head_row_too_large observed ->
    Some
      { artifact = `Head_row
      ; observed_at_least_bytes = Int64.of_int observed
      ; ceiling_bytes = Int64.of_int Head.max_row_bytes
      }
  | _ -> None
;;

let error_to_string (value : error) =
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
  | Implementation_safety_ceiling_exceeded
      { artifact; observed_at_least_bytes; ceiling_bytes } ->
    let artifact =
      match artifact with
      | `Facts -> "facts"
      | `Episode -> "episode"
      | `Manifest -> "manifest"
      | `Commit -> "commit"
      | `Head_row -> "HEAD row"
    in
    Printf.sprintf
      "%s exceeded the private contiguous-allocation safety ceiling: \
       observed at least %Ld bytes, ceiling %Ld"
      artifact
      observed_at_least_bytes
      ceiling_bytes
  | Byte_accounting_overflow artifact ->
    let artifact =
      match artifact with
      | `Facts -> "facts"
      | `Episode -> "episode"
      | `Manifest -> "manifest"
      | `Commit -> "commit"
      | `Head_row -> "HEAD row"
    in
    "Memory OS byte accounting overflowed while measuring " ^ artifact
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
  | Store_identity_missing_from_non_fresh_root entry_count ->
    Printf.sprintf
      "Memory OS store identity is missing from a non-fresh private root with \
       %d entries"
      entry_count
  | Store_identity_create_failed failure ->
    "failed to create Memory OS store identity: "
    ^ Fs_compat.capability_write_error_to_string failure
  | Store_identity_read_failed failure ->
    "failed to read Memory OS store identity: "
    ^ exact_read_error_to_string failure
  | Invalid_store_identity detail ->
    "invalid Memory OS store identity: " ^ detail
  | Current_head_read_failed failure ->
    "failed to read existing Memory OS HEAD: "
    ^ exact_read_error_to_string failure
  | Current_head_changed_during_read ->
    "existing Memory OS HEAD changed during verified read"
  | Invalid_publication_obligation detail ->
    "invalid Memory OS publication obligation: " ^ detail
  | Publication_obligation_owner_mismatch
      { obligation_owner_id; store_owner_id } ->
    Printf.sprintf
      "Memory OS publication obligation owner %S does not match opened owner %S"
      obligation_owner_id
      store_owner_id
  | Publication_obligation_store_mismatch
      { obligation_store_id; opened_store_id } ->
    Printf.sprintf
      "Memory OS publication obligation store %S does not match opened store %S"
      obligation_store_id
      opened_store_id
  | Publication_obligation_mismatch detail ->
    "Memory OS publication obligation does not match current authority: "
    ^ detail
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
    let actual = list_map fst fields |> List.sort String.compare in
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

let map_result fn values =
  let rec loop mapped = function
    | [] -> Ok (List.rev mapped)
    | value :: rest ->
      let* value = fn value in
      loop (value :: mapped) rest
  in
  loop [] values
;;

let iter_result fn values =
  let rec loop = function
    | [] -> Ok ()
    | value :: rest ->
      let* () = fn value in
      loop rest
  in
  loop values
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
  else if
    Int64.compare
      byte_count
      immutable_serialization_safety_ceiling_bytes
    > 0
  then
    Error
      "immutable byte_count exceeds the private implementation safety ceiling"
  else Ok ({ kind; leaf; sha256 = digest; byte_count } : immutable_ref)
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
  else Ok ({ store_id; owner_id; generation; commit_ref } : head_record)
;;

let facts_object_to_json (value : facts_object) =
  `Assoc
    [ "schema", `String facts_schema
    ; "store_id", `String value.store_id
    ; "owner_id", `String value.owner_id
    ; "generation", int64_to_json value.generation
    ; "facts", `List (list_map Types.fact_to_json value.facts)
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
    ; "episodes", `List (list_map immutable_ref_to_json value.episode_refs)
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
  Canonical_bytes.digest
    ~domain:"commit-receipt"
    (fun sink -> emit_commit_envelope sink value)
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

let validate_episode (episode : Types.episode) =
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
      iter_result validate_fact episode.claims
;;

let validate_state (value : state) =
  let* () = iter_result validate_fact value.facts in
  iter_result validate_episode value.episodes
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
  Ok ({ store_id; owner_id; generation; facts } : facts_object)
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
  Ok ({ store_id; owner_id; generation; episode } : episode_object)
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
      (fun (reference : immutable_ref) -> reference.kind <> Episode_object)
      episode_refs
  then Error "manifest episode ref has the wrong kind"
  else
    Ok
      ({ store_id
       ; owner_id
       ; generation
       ; facts_ref
       ; episode_refs
       }
       : manifest)
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
    let value : commit_record =
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

let state_digest (value : state) =
  Canonical_bytes.digest
    ~domain:"state"
    (fun sink -> emit_state sink value)
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

let warnings_of_exact (reference : immutable_ref) values =
  List.map
    (fun value -> Immutable_settlement_warning (reference, value))
    values
;;

type read_context =
  { root : Eio.Fs.dir_ty Eio.Path.t
  ; owner_id : string
  ; store_id : string
  }

let read_context_of_store (store : t) =
  { root = store.root
  ; owner_id = store.owner_id
  ; store_id = store.store_id
  }
;;

let read_object_raw_in (context : read_context) (reference : immutable_ref) =
  match
    Exact_read.read
      ~parent:context.root
      ~leaf:reference.leaf
      ~expected_length:reference.byte_count
      ~max_length:immutable_serialization_safety_ceiling_bytes
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

let read_object_raw store reference =
  read_object_raw_in (read_context_of_store store) reference
;;

let read_object_in
      (context : read_context)
      (reference : immutable_ref)
      ~artifact
      ~decode
      ~encode
  =
  let* raw, warnings = read_object_raw_in context reference in
  match decode_canonical ~artifact ~decode ~encode raw with
  | Ok value -> Ok (value, warnings)
  | Error error -> Error (prepend_warnings warnings error)
;;

let read_object store reference ~artifact ~decode ~encode =
  read_object_in
    (read_context_of_store store)
    reference
    ~artifact
    ~decode
    ~encode
;;

let random_token_from_source secure_random purpose =
  try
    let entropy = Cstruct.create 32 in
    Eio.Flow.read_exact secure_random entropy;
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

let random_token (store : t) purpose =
  random_token_from_source store.secure_random purpose
;;

let store_identity_owner_binding owner_id =
  hash_domain "store-owner-binding" owner_id
;;

let store_identity_payload_to_json (identity : store_identity) =
  `Assoc
    [ "schema", `String store_identity_schema
    ; "store_id", `String identity.store_id
    ; "owner_binding_sha256",
      `String (Sha256.to_string identity.owner_binding_sha256)
    ]
;;

let store_identity_checksum identity =
  store_identity_payload_to_json identity
  |> canonical_json
  |> hash_domain "store-identity"
;;

let store_identity_to_bytes identity =
  match store_identity_payload_to_json identity with
  | `Assoc fields ->
    canonical_json
      (`Assoc
         (fields
          @ [ ( "checksum_sha256"
              , `String (Sha256.to_string (store_identity_checksum identity)) )
            ]))
  | _ -> assert false
;;

let store_identity_byte_count =
  let placeholder : store_identity =
    { store_id = String.make 64 '0'
    ; owner_binding_sha256 = String.make 64 '0'
    }
  in
  Int64.of_int (String.length (store_identity_to_bytes placeholder))
;;

let decode_store_identity raw =
  try
    let json = Yojson.Safe.from_string raw in
    let* fields =
      exact_assoc
        [ "schema"
        ; "store_id"
        ; "owner_binding_sha256"
        ; "checksum_sha256"
        ]
        json
    in
    let* () = validate_schema store_identity_schema fields in
    let* store_id = string_field "store_id" fields in
    let* owner_binding_raw =
      string_field "owner_binding_sha256" fields
    in
    let* owner_binding_sha256 =
      match Sha256.of_string owner_binding_raw with
      | Some digest -> Ok digest
      | None ->
        Error
          "owner_binding_sha256 must be canonical lowercase SHA-256 hex"
    in
    let* checksum_raw = string_field "checksum_sha256" fields in
    let* checksum =
      match Sha256.of_string checksum_raw with
      | Some digest -> Ok digest
      | None ->
        Error "checksum_sha256 must be canonical lowercase SHA-256 hex"
    in
    if not (valid_store_id store_id)
    then Error "store_id must be canonical lowercase SHA-256 hex"
    else
      let identity : store_identity = { store_id; owner_binding_sha256 } in
      if not (Sha256.equal checksum (store_identity_checksum identity))
      then Error "checksum_sha256 does not bind the canonical store identity"
      else if not (String.equal raw (store_identity_to_bytes identity))
      then Error "store identity bytes are not exact canonical JSON"
      else Ok identity
  with
  | Yojson.Json_error detail -> Error detail
;;

let store_identity_warnings values =
  List.map
    (fun value -> Store_identity_settlement_warning value)
    values
;;

let read_store_identity_with_missing_warnings
      ~on_missing_warnings
      ~root
      ~owner_id
  =
  match
    Exact_read.read
      ~parent:root
      ~leaf:store_identity_leaf
      ~expected_length:store_identity_byte_count
      ~max_length:store_identity_byte_count
  with
  | Error failure ->
    let failure : Exact_read.failure = failure in
    (match failure.error with
     | Exact_read.Missing ->
       let warnings =
         failure.settlement_warnings
         |> on_missing_warnings
         |> store_identity_warnings
       in
       (match warnings with
        | [] -> Ok None
        | _ ->
          Error
            (make_error
               ~settlement_warnings:warnings
               (Store_identity_read_failed Exact_read.Missing)))
     | failure_kind ->
       Error
         (make_error
            ~settlement_warnings:
              (store_identity_warnings failure.settlement_warnings)
            (Store_identity_read_failed failure_kind)))
  | Ok observation ->
    let warnings =
      store_identity_warnings
        (Exact_read.observation_settlement_warnings observation)
    in
    let raw = Exact_read.observation_bytes observation in
    (match decode_store_identity raw with
     | Error detail ->
       Error
         (make_error
            ~settlement_warnings:warnings
            (Invalid_store_identity detail))
     | Ok identity ->
       let expected_owner_binding =
         store_identity_owner_binding owner_id
       in
       if
         not
           (Sha256.equal
              identity.owner_binding_sha256
              expected_owner_binding)
       then
         Error
           (make_error
              ~settlement_warnings:warnings
              (Invalid_store_identity
                 "owner binding does not match the opened owner"))
       else Ok (Some (identity, warnings)))
;;

let read_store_identity ~root ~owner_id =
  read_store_identity_with_missing_warnings
    ~on_missing_warnings:Fun.id
    ~root
    ~owner_id
;;

let private_root_entries root =
  try Ok (Eio.Path.read_dir root) with
  | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break)
    as exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exception_ backtrace
  | exception_ ->
    Error
      (make_error
         (Invalid_layout
            ("failed to inventory private store root: "
             ^ Printexc.to_string exception_)))
;;

let create_store_identity ~secure_random ~root ~owner_id =
  let* store_id = random_token_from_source secure_random "store-id" in
  let identity : store_identity =
    { store_id
    ; owner_binding_sha256 = store_identity_owner_binding owner_id
    }
  in
  match
    Fs_compat.create_capability_file_exclusive
      ~parent:root
      ~leaf:store_identity_leaf
      ~permissions:0o600
      (store_identity_to_bytes identity)
  with
  | Ok () -> Ok (identity, [])
  | Error failure ->
    if failure.target_effect = Fs_compat.Target_unchanged
    then
      (match read_store_identity ~root ~owner_id with
       | Ok (Some observed) -> Ok observed
       | Ok None ->
         Error (make_error (Store_identity_create_failed failure))
       | Error error -> Error error)
    else Error (make_error (Store_identity_create_failed failure))
;;

let open_store_identity ~secure_random ~root ~owner_id =
  let* observed = read_store_identity ~root ~owner_id in
  match observed with
  | Some identity -> Ok identity
  | None ->
    let* entries = private_root_entries root in
    if List.mem store_identity_leaf entries
    then
      (match read_store_identity ~root ~owner_id with
       | Ok (Some identity) -> Ok identity
       | Ok None ->
         Error
           (make_error
              (Invalid_store_identity
                 "identity disappeared during private-root initialization"))
       | Error error -> Error error)
    else if entries <> []
    then
      Error
        (make_error
           (Store_identity_missing_from_non_fresh_root
              (List.length entries)))
    else create_store_identity ~secure_random ~root ~owner_id
;;

let fresh_leaf (store : t) (kind : artifact_kind) =
  let purpose = "leaf/" ^ artifact_kind_token kind in
  let* token = random_token store purpose in
  Ok
    ("memory-os-"
     ^ artifact_kind_token kind
     ^ "-"
     ^ token
     ^ ".json")
;;

let persisted_artifact_of_kind = function
  | Facts_object -> `Facts
  | Episode_object -> `Episode
  | Manifest_object -> `Manifest
  | Commit_object -> `Commit
;;

let measure_artifact ~maximum artifact emit =
  match Canonical_bytes.measure_bounded ~ceiling:maximum emit with
  | Ok byte_count -> Ok byte_count
  | Error (Canonical_bytes.Ceiling_exceeded observed_at_least_bytes) ->
    Error
      (make_error
         (Implementation_safety_ceiling_exceeded
            { artifact
            ; observed_at_least_bytes
            ; ceiling_bytes = maximum
            }))
  | Error Canonical_bytes.Counter_overflow ->
    Error (make_error (Byte_accounting_overflow artifact))
;;

let render_canonical artifact ~byte_count emit =
  match Canonical_bytes.render_exact ~byte_count emit with
  | Ok raw -> Ok raw
  | Error detail ->
    let artifact =
      match artifact with
      | `Facts -> "facts encoder"
      | `Episode -> "episode encoder"
      | `Manifest -> "manifest encoder"
      | `Commit -> "commit encoder"
      | `Head_row -> "HEAD encoder"
    in
    Error (make_error (Invalid_store_json { artifact; detail }))
;;

let create_planned_object
      (store : t)
      (kind : artifact_kind)
      ~byte_count
      emit
  =
  let artifact = persisted_artifact_of_kind kind in
  let* raw = render_canonical artifact ~byte_count emit in
  let digest = Canonical_bytes.digest emit in
  let* leaf = fresh_leaf store kind in
  let reference : immutable_ref =
    { kind; leaf; sha256 = digest; byte_count }
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

let placeholder_digest = String.make 64 '0'

(* These canonical lowercase 64-hex placeholders are byte-sizing witnesses
   only. They are never persisted and never feed state, object, receipt, or
   identity digests; the root store identity is established before the callback
   and real object references are generated only after authority revalidation. *)
let placeholder_leaf kind =
  "memory-os-"
  ^ artifact_kind_token kind
  ^ "-"
  ^ placeholder_digest
  ^ ".json"
;;

let placeholder_ref kind byte_count : immutable_ref =
  { kind
  ; leaf = placeholder_leaf kind
  ; sha256 = placeholder_digest
  ; byte_count
  }
;;

type graph_preflight =
  { generation : int64
  ; state_sha256 : Sha256.t
  ; facts_bytes : int64
  ; manifest_bytes : int64
  ; commit_bytes : int64
  ; head_row_bytes : int64
  }

let measure_manifest_with_episodes
      ~maximum
      ~store_id
      ~owner_id
      ~generation
      ~facts_bytes
      (episodes : Types.episode list)
  =
  let facts_ref = placeholder_ref Facts_object facts_bytes in
  let emit sink =
    Canonical_bytes.write sink "{";
    Canonical_bytes.field sink ~first:true "schema";
    Canonical_bytes.json_string sink manifest_schema;
    Canonical_bytes.field sink ~first:false "store_id";
    Canonical_bytes.json_string sink store_id;
    Canonical_bytes.field sink ~first:false "owner_id";
    Canonical_bytes.json_string sink owner_id;
    Canonical_bytes.field sink ~first:false "generation";
    Canonical_bytes.int64_value sink generation;
    Canonical_bytes.field sink ~first:false "facts";
    emit_immutable_ref sink facts_ref;
    Canonical_bytes.field sink ~first:false "episodes";
    Canonical_bytes.write sink "[";
    let rec loop first = function
      | [] ->
        Canonical_bytes.write sink "]}";
        Ok ()
      | episode :: rest ->
        let episode_object : episode_object =
          { store_id; owner_id; generation; episode }
        in
        let* byte_count =
          measure_artifact
            ~maximum
            `Episode
            (fun episode_sink ->
               emit_episode_object episode_sink episode_object)
        in
        if not first then Canonical_bytes.write sink ",";
        emit_immutable_ref
          sink
          (placeholder_ref Episode_object byte_count);
        loop false rest
    in
    loop true episodes
  in
  match Canonical_bytes.measure_bounded_result ~ceiling:maximum emit with
  | Ok ((), byte_count) -> Ok byte_count
  | Error (`Emitter error) -> Error error
  | Error
      (`Measurement
        (Canonical_bytes.Ceiling_exceeded observed_at_least_bytes)) ->
    Error
      (make_error
         (Implementation_safety_ceiling_exceeded
            { artifact = `Manifest
            ; observed_at_least_bytes
            ; ceiling_bytes = maximum
            }))
  | Error (`Measurement Canonical_bytes.Counter_overflow) ->
    Error (make_error (Byte_accounting_overflow `Manifest))
;;

let preflight_graph
      ~maximum
      (store : t)
      ~(expected : snapshot)
      ~operation_id
      ~(state : state)
  =
  if Int64.equal expected.generation Int64.max_int
  then Error (make_error Generation_exhausted)
  else
    let generation = Int64.succ expected.generation in
    let planned_store_id = store.store_id in
    let facts_value : facts_object =
      { store_id = planned_store_id
      ; owner_id = store.owner_id
      ; generation
      ; facts = state.facts
      }
    in
    let* facts_bytes =
      measure_artifact
        ~maximum
        `Facts
        (fun sink -> emit_facts_object sink facts_value)
    in
    let* manifest_bytes =
      measure_manifest_with_episodes
        ~maximum
        ~store_id:planned_store_id
        ~owner_id:store.owner_id
        ~generation
        ~facts_bytes
        state.episodes
    in
    let commit : commit_record =
      { store_id = planned_store_id
      ; owner_id = store.owner_id
      ; generation
      ; operation_id
      ; manifest_ref = placeholder_ref Manifest_object manifest_bytes
      ; state_sha256 = placeholder_digest
      ; receipt_id = placeholder_digest
      }
    in
    let* commit_bytes =
      measure_artifact
        ~maximum
        `Commit
        (fun sink -> emit_commit_record sink commit)
    in
    let head : head_record =
      { store_id = planned_store_id
      ; owner_id = store.owner_id
      ; generation
      ; commit_ref = placeholder_ref Commit_object commit_bytes
      }
    in
    let* head_row_bytes =
      match
        Canonical_bytes.measure_bounded
          ~ceiling:(Int64.of_int Head.max_row_bytes)
          (fun sink -> emit_head_record sink head)
      with
      | Ok byte_count -> Ok byte_count
      | Error (Canonical_bytes.Ceiling_exceeded observed) ->
        Error (make_error (Head_row_too_large (Int64.to_int observed)))
      | Error Canonical_bytes.Counter_overflow ->
        Error (make_error (Byte_accounting_overflow `Head_row))
    in
    let state_sha256 = state_digest state in
    Ok
      { generation
      ; state_sha256
      ; facts_bytes
      ; manifest_bytes
      ; commit_bytes
      ; head_row_bytes
      }
;;

let same_cursor = Head.cursor_equal

let same_head_authority (left : snapshot) (right : snapshot) =
  same_cursor left.cursor right.cursor
  && left.head_row = right.head_row
;;

let empty_snapshot (store : t) (head_snapshot : Head.snapshot) =
  ({ binding = store.binding
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
       store.opening_warnings
       @ warnings_of_head
           (Head.snapshot_settlement_warnings head_snapshot)
   }
   : snapshot)
;;

type verified_head =
  { head : head_record
  ; commit : commit_record
  ; manifest : manifest
  ; episode_objects : (immutable_ref * Types.episode) list
  ; state : state
  ; warnings : settlement_warning list
  }

let load_verified_row
      (context : read_context)
      ~opening_warnings
      row
  =
  let head_warnings = opening_warnings in
    let* (head : head_record) =
      head_of_row row |> with_prior_warnings head_warnings
    in
    if not (String.equal head.owner_id context.owner_id)
    then
      Error
        (make_error
           ~settlement_warnings:head_warnings
           (Persisted_store_binding_mismatch
              "HEAD owner_id does not match the opened owner"))
    else if not (String.equal head.store_id context.store_id)
    then
      Error
        (make_error
           ~settlement_warnings:head_warnings
           (Persisted_store_binding_mismatch
              "HEAD store_id does not match the private root identity"))
    else
      let commit_artifact = "commit:" ^ head.commit_ref.leaf in
      let* ((commit : commit_record), commit_warnings) =
        read_object_in
          context
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
      let* ((manifest : manifest), manifest_warnings) =
        read_object_in
          context
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
      let* ((facts_object : facts_object), facts_warnings) =
        read_object_in
          context
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
      let rec load_episodes
        (references : immutable_ref list)
        (values : Types.episode list)
        (objects : (immutable_ref * Types.episode) list)
        (warnings_rev : settlement_warning list)
        =
        match references with
        | [] ->
          Ok
            ( List.rev values
            , List.rev objects
            , List.rev warnings_rev )
        | (reference : immutable_ref) :: rest ->
          let artifact = "episode:" ^ reference.leaf in
          let* ((episode_object : episode_object), object_warnings) =
            match
              read_object_in
                context
                reference
                ~artifact
                ~decode:episode_object_of_json
                ~encode:episode_object_to_json
            with
            | Ok value -> Ok value
            | Error error ->
              Error
                (prepend_warnings
                   (List.rev warnings_rev)
                   error)
          in
          let warnings_rev =
            List.rev_append object_warnings warnings_rev
          in
          let* () =
            match
              ensure_identity
                ~artifact
                ~expected_store_id:head.store_id
                ~expected_owner_id:head.owner_id
                ~expected_generation:head.generation
                ~store_id:episode_object.store_id
                ~owner_id:episode_object.owner_id
                ~generation:episode_object.generation
            with
            | Ok () -> Ok ()
            | Error error ->
              Error
                (prepend_warnings
                   (List.rev warnings_rev)
                   error)
          in
          load_episodes
            rest
            (episode_object.episode :: values)
            ((reference, episode_object.episode) :: objects)
            warnings_rev
      in
      let* episodes, episode_objects, warnings =
        load_episodes
          manifest.episode_refs
          []
          []
          (List.rev warnings)
      in
      let state : state = { facts = facts_object.facts; episodes } in
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
          ({ head
           ; commit
           ; manifest
           ; episode_objects
           ; state
           ; warnings
           }
           : verified_head)
;;

let load_from_head (store : t) (head_snapshot : Head.snapshot) =
  let head_warnings =
    store.opening_warnings
    @ warnings_of_head (Head.snapshot_settlement_warnings head_snapshot)
  in
  match Head.snapshot_row head_snapshot with
  | None -> Ok (empty_snapshot store head_snapshot)
  | Some row ->
    let* verified =
      load_verified_row
        (read_context_of_store store)
        ~opening_warnings:head_warnings
        row
    in
    Ok
      ({ binding = store.binding
       ; cursor = Head.snapshot_cursor head_snapshot
       ; head_row = Some row
       ; store_id = Some verified.head.store_id
       ; generation = verified.head.generation
       ; commit_ref = Some verified.head.commit_ref
       ; commit = Some verified.commit
       ; manifest_ref = Some verified.commit.manifest_ref
       ; facts_ref = Some verified.manifest.facts_ref
       ; episode_objects = verified.episode_objects
       ; state = verified.state
       ; settlement_warnings = verified.warnings
       }
       : snapshot)
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
    let* identity, opening_warnings =
      open_store_identity ~secure_random ~root ~owner_id
    in
    Eio.Switch.run (fun sw ->
      let binding : binding = { active = Atomic.make true } in
      Eio.Switch.on_release sw (fun () ->
        Atomic.set binding.active false);
      fn
        ({ binding
         ; secure_random
         ; root
         ; owner_id
         ; store_id = identity.store_id
         ; opening_warnings
         }
         : t))
;;

type existing_root =
  | Existing_root_absent
  | Existing_root_entries of string list

let inspect_existing_root root =
  try Ok (Existing_root_entries (Eio.Path.read_dir root)) with
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _)
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    Ok Existing_root_absent
  | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break)
    as exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exception_ backtrace
  | exception_ ->
    Error
      (make_error
         (Invalid_layout
            ("failed to inspect existing private store root: "
             ^ Printexc.to_string exception_)))
;;

let current_head_warnings values =
  List.map
    (fun value -> Current_head_settlement_warning value)
    values
;;

let corrupt_existing_head detail =
  make_error
    (Head_operation_failed
       { phase = "read-only"
       ; failure = Head.Corrupt_head detail
       })
;;

let row_of_existing_head_payload payload =
  let length = String.length payload in
  if length < 2
  then
    Error
      (corrupt_existing_head
         "HEAD must contain one non-empty LF-terminated row")
  else if not (Char.equal payload.[length - 1] '\n')
  then Error (corrupt_existing_head "HEAD is not LF-terminated")
  else
    let row = String.sub payload 0 (length - 1) in
    if String.length row > Head.max_row_bytes
    then
      Error
        (corrupt_existing_head "HEAD row exceeds max_row_bytes")
    else if
      String.exists
        (fun char -> Char.equal char '\n' || Char.equal char '\r')
        row
    then
      Error
        (corrupt_existing_head "HEAD contains multiple rows or CR")
    else Ok row
;;

let read_existing_head_row ~root =
  let path = Eio.Path.(root / head_leaf) in
  try
    match Eio.Path.kind ~follow:false path with
    | `Not_found -> Ok (None, [])
    | `Regular_file ->
      let stat = Eio.Path.stat ~follow:false path in
      let expected_length = Optint.Int63.to_int64 stat.size in
      let maximum = Int64.of_int (Head.max_row_bytes + 1) in
      (match
         Exact_read.read
           ~parent:root
           ~leaf:head_leaf
           ~expected_length
           ~max_length:maximum
       with
       | Error failure ->
         let failure : Exact_read.failure = failure in
         Error
           (make_error
              ~settlement_warnings:
                (current_head_warnings failure.settlement_warnings)
              (Current_head_read_failed failure.error))
       | Ok observation ->
         let warnings =
           current_head_warnings
             (Exact_read.observation_settlement_warnings observation)
         in
         let* row =
           row_of_existing_head_payload
             (Exact_read.observation_bytes observation)
           |> with_prior_warnings warnings
         in
         Ok (Some row, warnings))
    | `Symbolic_link ->
      Error
        (corrupt_existing_head "HEAD path is a symbolic link")
    | _ ->
      Error
        (corrupt_existing_head "HEAD path is not a regular file")
  with
  | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break)
    as exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exception_ backtrace
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _)
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    Error (make_error (Current_head_read_failed Exact_read.Missing))
  | exception_ ->
    Error
      (make_error
         (Invalid_layout
            ("failed to inspect existing Memory OS HEAD: "
             ^ Printexc.to_string exception_)))
;;

let read_existing_current_head ~root ~owner_id =
  if String.trim owner_id = ""
  then Error (make_error (Invalid_layout "owner_id must be non-empty"))
  else
    let* root_observation = inspect_existing_root root in
    match root_observation with
    | Existing_root_absent -> Ok Absent
    | Existing_root_entries entries ->
      let* observed_identity = read_store_identity ~root ~owner_id in
      (match observed_identity with
       | None ->
         if entries = []
         then Ok Absent
         else
           Error
             (make_error
                (Store_identity_missing_from_non_fresh_root
                   (List.length entries)))
       | Some (identity, identity_warnings) ->
         let context : read_context =
           { root; owner_id; store_id = identity.store_id }
         in
         let* first_row, first_head_warnings =
           read_existing_head_row ~root
           |> with_prior_warnings identity_warnings
         in
         let opening_warnings =
           identity_warnings @ first_head_warnings
         in
         let* verified =
           match first_row with
           | None -> Ok None
           | Some row ->
             let* loaded =
               load_verified_row
                 context
                 ~opening_warnings
                 row
             in
             Ok (Some loaded)
         in
         let verified_warnings =
           match verified with
           | None -> opening_warnings
           | Some loaded -> loaded.warnings
         in
         let* final_identity =
           read_store_identity ~root ~owner_id
           |> with_prior_warnings verified_warnings
         in
         let* final_identity_warnings =
           match final_identity with
           | None ->
             Error
               (make_error
                  ~settlement_warnings:verified_warnings
                  (Invalid_store_identity
                     "identity disappeared during verified read"))
           | Some (final, warnings) ->
             if String.equal final.store_id identity.store_id
             then Ok warnings
             else
               Error
                 (make_error
                    ~settlement_warnings:
                      (verified_warnings @ warnings)
                    (Invalid_store_identity
                       "identity changed during verified read"))
         in
         let* final_row, final_head_warnings =
           read_existing_head_row ~root
           |> with_prior_warnings
                (verified_warnings @ final_identity_warnings)
         in
         if first_row <> final_row
         then
           Error
              (make_error
                 ~settlement_warnings:
                   (verified_warnings
                    @ final_identity_warnings
                    @ final_head_warnings)
                 Current_head_changed_during_read)
         else
           let current_head =
             match verified with
             | None -> Empty
             | Some loaded ->
               Present
                 { receipt_id = loaded.commit.receipt_id
                 ; operation_id = loaded.commit.operation_id
                 ; state_digest = loaded.commit.state_sha256
                 ; generation = loaded.head.generation
                 }
           in
           Ok
             (Existing
                { current_head
                ; settlement_warnings =
                    verified_warnings
                    @ final_identity_warnings
                    @ final_head_warnings
                }))
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
           (store.opening_warnings
            @ warnings_of_head failure.settlement_warnings)
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
      ({ receipt_id = commit.receipt_id
       ; operation_id = commit.operation_id
       ; state_sha256 = commit.state_sha256
       ; generation = commit.generation
       ; snapshot
       ; settlement_warnings = snapshot.settlement_warnings
       }
       : commit_receipt)
;;

let head_payload_fingerprint row =
  let payload = row ^ "\n" in
  sha256 payload, Int64.of_int (String.length payload)
;;

let authority_of_snapshot (snapshot : snapshot) =
  match
    snapshot.head_row,
    snapshot.store_id,
    snapshot.commit_ref,
    snapshot.commit
  with
  | None, None, None, None when Int64.equal snapshot.generation 0L ->
    Ok Empty_authority
  | Some row, Some store_id, Some commit_ref, Some commit ->
    if
      not (String.equal store_id commit.store_id)
      || not (Int64.equal snapshot.generation commit.generation)
    then
      Error
        (make_error
           ~settlement_warnings:snapshot.settlement_warnings
           (Invalid_store_json
              { artifact = "HEAD authority"
              ; detail = "snapshot and current commit identity diverge"
              }))
    else
      let payload_sha256, payload_bytes =
        head_payload_fingerprint row
      in
      Ok
        (Head_authority
           { payload_sha256
           ; payload_bytes
           ; store_id
           ; generation = snapshot.generation
           ; commit_ref
           ; receipt_id = commit.receipt_id
           })
  | _ ->
    Error
      (make_error
         ~settlement_warnings:snapshot.settlement_warnings
         (Invalid_store_json
            { artifact = "HEAD authority"
            ; detail = "snapshot has an incomplete current authority"
            }))
;;

let authority_of_prepared (prepared : prepared_commit) =
  let payload_sha256, payload_bytes =
    head_payload_fingerprint prepared.head_row
  in
  { payload_sha256
  ; payload_bytes
  ; store_id = prepared.store_id
  ; generation = prepared.generation
  ; commit_ref = prepared.commit_ref
  ; receipt_id = prepared.receipt_id
  }
;;

let same_immutable_ref (left : immutable_ref) (right : immutable_ref) =
  left.kind = right.kind
  && String.equal left.leaf right.leaf
  && Sha256.equal left.sha256 right.sha256
  && Int64.equal left.byte_count right.byte_count
;;

let same_authority left right =
  match left, right with
  | Empty_authority, Empty_authority -> true
  | Head_authority left, Head_authority right ->
    Sha256.equal left.payload_sha256 right.payload_sha256
    && Int64.equal left.payload_bytes right.payload_bytes
    && String.equal left.store_id right.store_id
    && Int64.equal left.generation right.generation
    && same_immutable_ref left.commit_ref right.commit_ref
    && Sha256.equal left.receipt_id right.receipt_id
  | Empty_authority, Head_authority _
  | Head_authority _, Empty_authority ->
    false
;;

let authority_token_to_json = function
  | Empty_authority -> `Assoc [ "kind", `String "empty" ]
  | Head_authority authority ->
    `Assoc
      [ "kind", `String "head"
      ; "payload_sha256",
        `String (Sha256.to_string authority.payload_sha256)
      ; "payload_bytes", int64_to_json authority.payload_bytes
      ; "store_id", `String authority.store_id
      ; "generation", int64_to_json authority.generation
      ; "commit", immutable_ref_to_json authority.commit_ref
      ; "receipt_id", `String (Sha256.to_string authority.receipt_id)
      ]
;;

let canonical_sha256_of_json label = function
  | `String raw ->
    (match Sha256.of_string raw with
     | Some digest -> Ok digest
     | None ->
       Error
         (label ^ " must be canonical lowercase SHA-256 hex"))
  | _ -> Error (label ^ " must be a string")
;;

let sha256_field name fields =
  let* value = required_field name fields in
  canonical_sha256_of_json name value
;;

let authority_token_of_json json =
  let* fields =
    match json with
    | `Assoc fields -> Ok fields
    | _ -> Error "authority must be an object"
  in
  let* kind = string_field "kind" fields in
  match kind with
  | "empty" ->
    let* _ = exact_assoc [ "kind" ] json in
    Ok Empty_authority
  | "head" ->
    let* fields =
      exact_assoc
        [ "kind"
        ; "payload_sha256"
        ; "payload_bytes"
        ; "store_id"
        ; "generation"
        ; "commit"
        ; "receipt_id"
        ]
        json
    in
    let* payload_sha256 = sha256_field "payload_sha256" fields in
    let* payload_bytes = int64_field "payload_bytes" fields in
    let* store_id = string_field "store_id" fields in
    let* generation = int64_field "generation" fields in
    let* commit_json = required_field "commit" fields in
    let* commit_ref = immutable_ref_of_json commit_json in
    let* receipt_id = sha256_field "receipt_id" fields in
    if Int64.compare payload_bytes 0L <= 0
    then Error "authority payload_bytes must be positive"
    else if not (valid_store_id store_id)
    then Error "authority store_id must be canonical lowercase SHA-256 hex"
    else if Int64.compare generation 0L <= 0
    then Error "authority generation must be positive"
    else if commit_ref.kind <> Commit_object
    then Error "authority commit ref has the wrong kind"
    else
      Ok
        (Head_authority
           { payload_sha256
           ; payload_bytes
           ; store_id
           ; generation
           ; commit_ref
           ; receipt_id
           })
  | _ -> Error ("unknown authority kind " ^ kind)
;;

let publication_obligation_payload_fields
      (value : publication_obligation)
  =
  [ "schema", `String publication_obligation_schema
  ; "owner_id", `String value.owner_id
  ; "store_id", `String value.store_id
  ; "expected", authority_token_to_json value.expected
  ; "desired", authority_token_to_json (Head_authority value.desired)
  ; "operation_id", `String value.operation_id
  ; "state_sha256", `String (Sha256.to_string value.state_sha256)
  ]
;;

let publication_obligation_payload_to_json
      (value : publication_obligation)
  =
  `Assoc (publication_obligation_payload_fields value)
;;

let publication_obligation_checksum value =
  publication_obligation_payload_to_json value
  |> canonical_json
  |> hash_domain "publication-obligation"
;;

let publication_obligation_to_bytes value =
  canonical_json
    (`Assoc
       (publication_obligation_payload_fields value
        @ [ ( "checksum_sha256"
            , `String
                (Sha256.to_string
                   (publication_obligation_checksum value)) )
          ]))
;;

let validate_publication_obligation
      (value : publication_obligation)
  =
  if String.trim value.owner_id = ""
  then Error "owner_id must be non-empty"
  else if not (valid_store_id value.store_id)
  then Error "store_id must be canonical lowercase SHA-256 hex"
  else if String.trim value.operation_id = ""
  then Error "operation_id must be non-empty"
  else
    let desired = value.desired in
    match value.expected with
    | Empty_authority ->
      if not (String.equal desired.store_id value.store_id)
      then Error "desired authority store identifier differs from scope"
      else if Int64.equal desired.generation 1L
      then Ok ()
      else Error "genesis desired generation must be one"
    | Head_authority expected ->
      if
        not (String.equal desired.store_id value.store_id)
        || not (String.equal expected.store_id value.store_id)
      then Error "authority store identifier differs from scope"
      else if not (String.equal desired.store_id expected.store_id)
      then Error "expected and desired store identifiers differ"
      else if Int64.equal expected.generation Int64.max_int
      then Error "expected authority generation is exhausted"
      else if
        not
          (Int64.equal
             desired.generation
             (Int64.succ expected.generation))
      then Error "desired generation does not immediately follow expected"
      else Ok ()
;;

let decode_publication_obligation raw =
  try
    let json = Yojson.Safe.from_string raw in
    let* fields =
      exact_assoc
        [ "schema"
        ; "owner_id"
        ; "store_id"
        ; "expected"
        ; "desired"
        ; "operation_id"
        ; "state_sha256"
        ; "checksum_sha256"
        ]
        json
    in
    let* () = validate_schema publication_obligation_schema fields in
    let* owner_id = string_field "owner_id" fields in
    let* store_id = string_field "store_id" fields in
    let* expected_json = required_field "expected" fields in
    let* expected = authority_token_of_json expected_json in
    let* desired_json = required_field "desired" fields in
    let* desired_token = authority_token_of_json desired_json in
    let* desired =
      match desired_token with
      | Empty_authority ->
        Error "desired authority must name a HEAD commit"
      | Head_authority desired -> Ok desired
    in
    let* operation_id = string_field "operation_id" fields in
    let* state_sha256 = sha256_field "state_sha256" fields in
    let* checksum = sha256_field "checksum_sha256" fields in
    let value : publication_obligation =
      { owner_id
      ; store_id
      ; expected
      ; desired
      ; operation_id
      ; state_sha256
      }
    in
    let* () = validate_publication_obligation value in
    let expected_checksum = publication_obligation_checksum value in
    if not (Sha256.equal checksum expected_checksum)
    then Error "checksum_sha256 does not bind the canonical obligation"
    else
      let canonical = publication_obligation_to_bytes value in
      if String.equal canonical raw
      then Ok value
      else Error "obligation bytes are not exact canonical JSON"
  with
  | Yojson.Json_error detail -> Error detail
;;

let publication_obligation_of_bytes raw =
  match decode_publication_obligation raw with
  | Ok value -> Ok value
  | Error detail ->
    Error (make_error (Invalid_publication_obligation detail))
;;

let publication_obligation_operation_id
      (value : publication_obligation)
  =
  value.operation_id
;;

let publication_obligation_desired_receipt_id
      (value : publication_obligation)
  =
  value.desired.receipt_id
;;

let publication_obligation_desired_state_sha256
      (value : publication_obligation)
  =
  value.state_sha256
;;

let publication_obligation_desired_generation
      (value : publication_obligation)
  =
  value.desired.generation
;;

let publication_obligation_of_prepared
      (store : t)
      (prepared : prepared_commit)
  =
  let* () =
    check_binding
      store
      prepared.binding
      prepared.settlement_warnings
  in
  let* expected = authority_of_snapshot prepared.previous in
  let value : publication_obligation =
    { owner_id = store.owner_id
    ; store_id = store.store_id
    ; expected
    ; desired = authority_of_prepared prepared
    ; operation_id = prepared.operation_id
    ; state_sha256 = prepared.state_sha256
    }
  in
  match validate_publication_obligation value with
  | Ok () -> Ok value
  | Error detail ->
    Error
      (make_error
         ~settlement_warnings:prepared.settlement_warnings
         (Invalid_publication_obligation detail))
;;

let validate_publication_obligation_scope
      (store : t)
      (obligation : publication_obligation)
  =
  let desired = obligation.desired in
  let artifact = "obligation commit:" ^ desired.commit_ref.leaf in
  let* ((commit : commit_record), warnings) =
    read_object
      store
      desired.commit_ref
      ~artifact
      ~decode:commit_record_of_json
      ~encode:commit_record_to_json
  in
  let* () =
    ensure_identity
      ~artifact
      ~expected_store_id:desired.store_id
      ~expected_owner_id:obligation.owner_id
      ~expected_generation:desired.generation
      ~store_id:commit.store_id
      ~owner_id:commit.owner_id
      ~generation:commit.generation
    |> with_prior_warnings warnings
  in
  if
    not (Sha256.equal commit.receipt_id desired.receipt_id)
    || not (String.equal commit.operation_id obligation.operation_id)
    || not (Sha256.equal commit.state_sha256 obligation.state_sha256)
  then
    Error
      (make_error
         ~settlement_warnings:warnings
         (Publication_obligation_mismatch
            "desired commit scope proof diverges from receipt metadata"))
  else Ok warnings
;;

let validate_superseding_authority
      ~(current : snapshot)
      ~(current_authority : authority_token)
      (obligation : publication_obligation)
  =
  let mismatch detail =
    Error
      (make_error
         ~settlement_warnings:current.settlement_warnings
         (Publication_obligation_mismatch detail))
  in
  let desired = obligation.desired in
  match obligation.expected, current_authority with
  | Empty_authority, Empty_authority ->
    mismatch "empty authority should have matched the genesis expectation"
  | Empty_authority, Head_authority observed ->
    if Sha256.equal observed.receipt_id desired.receipt_id
    then mismatch "desired receipt appears under different HEAD authority"
    else Ok ()
  | Head_authority _, Empty_authority ->
    mismatch "current authority regressed below the non-empty expectation"
  | Head_authority expected, Head_authority observed ->
    if not (String.equal observed.store_id desired.store_id)
    then mismatch "current authority belongs to a different persisted store"
    else if Int64.compare observed.generation desired.generation < 0
    then mismatch "current authority generation regressed below the desired generation"
    else if
      Sha256.equal observed.receipt_id desired.receipt_id
      || Sha256.equal observed.receipt_id expected.receipt_id
    then mismatch "known receipt appears under different HEAD authority"
    else Ok ()
;;

let recover_publication
      (store : t)
      (obligation : publication_obligation)
  =
  let* () = check_active store in
  if not (String.equal obligation.owner_id store.owner_id)
  then
    Error
      (make_error
         (Publication_obligation_owner_mismatch
            { obligation_owner_id = obligation.owner_id
            ; store_owner_id = store.owner_id
            }))
  else if not (String.equal obligation.store_id store.store_id)
  then
    Error
      (make_error
         (Publication_obligation_store_mismatch
            { obligation_store_id = obligation.store_id
            ; opened_store_id = store.store_id
            }))
  else
    let* current = load store in
    let* current_authority = authority_of_snapshot current in
    if
      same_authority
        current_authority
        (Head_authority obligation.desired)
    then
      (match receipt_of_snapshot current with
       | Some receipt
         when
           let desired = obligation.desired in
           Int64.equal receipt.generation desired.generation
           && Sha256.equal receipt.receipt_id desired.receipt_id
           && String.equal receipt.operation_id obligation.operation_id
           && Sha256.equal receipt.state_sha256 obligation.state_sha256 ->
         Ok (Recovered_committed receipt)
       | Some _ | None ->
         Error
           (make_error
              ~settlement_warnings:current.settlement_warnings
              (Publication_obligation_mismatch
                 "desired HEAD receipt metadata diverges")))
    else
      let* scope_warnings =
        validate_publication_obligation_scope store obligation
      in
      let current =
        { current with
          settlement_warnings =
            current.settlement_warnings @ scope_warnings
        }
      in
      if same_authority current_authority obligation.expected
      then Ok (Recovered_not_published current)
      else
        let* () =
          validate_superseding_authority
            ~current
            ~current_authority
            obligation
        in
        Ok (Recovered_superseded current)
;;

let create_episode_objects
      (store : t)
      ~maximum
      ~store_id
      ~owner_id
      ~generation
      (episodes : Types.episode list)
  =
  let rec loop objects = function
    | [] -> Ok (List.rev objects)
    | episode :: rest ->
      let value : episode_object =
        { store_id; owner_id; generation; episode }
      in
      let* byte_count =
        measure_artifact
          ~maximum
          `Episode
          (fun sink -> emit_episode_object sink value)
      in
      let* reference =
        create_planned_object
          store
          Episode_object
          ~byte_count
          (fun sink -> emit_episode_object sink value)
      in
      loop
        ((reference, episode) :: objects)
        rest
  in
  loop [] episodes
;;

let prepare_with_implementation_ceiling
      maximum
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
  else if Int64.compare maximum 0L <= 0
  then
    Error
      (make_error
         ~settlement_warnings:expected.settlement_warnings
         (Invalid_layout
            "implementation safety ceiling must be positive"))
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
    let* preflight =
      preflight_graph
        ~maximum
        store
        ~expected
        ~operation_id
        ~state
      |> with_prior_warnings expected.settlement_warnings
    in
    let requested_state_sha256 = preflight.state_sha256 in
    let* (current : snapshot) = load store in
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
          let store_id = store.store_id in
          let generation = preflight.generation in
          let facts_value : facts_object =
            { store_id
            ; owner_id = store.owner_id
            ; generation
            ; facts = state.facts
            }
          in
          let* facts_ref =
            create_planned_object
              store
              Facts_object
              ~byte_count:preflight.facts_bytes
              (fun sink -> emit_facts_object sink facts_value)
            |> with_prior_warnings current.settlement_warnings
          in
          let* episode_objects =
            create_episode_objects
              store
              ~maximum
              ~store_id
              ~owner_id:store.owner_id
              ~generation
              state.episodes
            |> with_prior_warnings current.settlement_warnings
          in
          let manifest : manifest =
            { store_id
            ; owner_id = store.owner_id
            ; generation
            ; facts_ref
            ; episode_refs = list_map fst episode_objects
            }
          in
          let* manifest_ref =
            create_planned_object
              store
              Manifest_object
              ~byte_count:preflight.manifest_bytes
              (fun sink -> emit_manifest sink manifest)
            |> with_prior_warnings current.settlement_warnings
          in
          let provisional_commit : commit_record =
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
          let commit : commit_record =
            { provisional_commit with receipt_id }
          in
          let* commit_ref =
            create_planned_object
              store
              Commit_object
              ~byte_count:preflight.commit_bytes
              (fun sink -> emit_commit_record sink commit)
            |> with_prior_warnings current.settlement_warnings
          in
          let head : head_record =
            { store_id
            ; owner_id = store.owner_id
            ; generation
            ; commit_ref
            }
          in
          let* head_row =
            render_canonical
              `Head_row
              ~byte_count:preflight.head_row_bytes
              (fun sink -> emit_head_record sink head)
            |> with_prior_warnings current.settlement_warnings
          in
          Ok
            (Prepared
               ({ binding = store.binding
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
                }
                : prepared_commit))
;;

let prepare store ~expected ~operation_id ~state =
  prepare_with_implementation_ceiling
    immutable_serialization_safety_ceiling_bytes
    store
    ~expected
    ~operation_id
    ~state
;;

let snapshot_of_prepared
      (prepared : prepared_commit)
      (cursor : Head.cursor)
      (warnings : settlement_warning list)
  =
  ({ binding = prepared.binding
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
   : snapshot)
;;

let receipt_of_prepared
      (prepared : prepared_commit)
      (cursor : Head.cursor)
      (warnings : settlement_warning list)
  =
  let snapshot = snapshot_of_prepared prepared cursor warnings in
  ({ receipt_id = prepared.receipt_id
   ; operation_id = prepared.operation_id
   ; state_sha256 = prepared.state_sha256
   ; generation = prepared.generation
   ; snapshot
   ; settlement_warnings = warnings
   }
   : commit_receipt)
;;

let add_snapshot_warnings warnings (snapshot : snapshot) =
  { snapshot with
    settlement_warnings = warnings @ snapshot.settlement_warnings
  }
;;

let publish_with_compare_and_swap
      compare_and_swap
      (store : t)
      (prepared : prepared_commit)
  =
  let* () =
    check_binding
      store
      prepared.binding
      prepared.settlement_warnings
  in
  match
    compare_and_swap
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

let publish store prepared =
  publish_with_compare_and_swap Head.compare_and_swap store prepared
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

module For_testing = struct
  type error_tag =
    | Invalid_layout_error
    | Store_not_active_error
    | Runtime_store_binding_mismatch_error
    | Persisted_store_binding_mismatch_error
    | Invalid_domain_value_error
    | Conflicting_operation_error
    | Generation_exhausted_error
    | Entropy_source_failed_error
    | Implementation_safety_ceiling_exceeded_error
    | Byte_accounting_overflow_error
    | Immutable_create_failed_error
    | Immutable_read_failed_error
    | Immutable_digest_mismatch_error
    | Invalid_store_json_error
    | Head_busy_unchanged_error
    | Head_operation_failed_error
    | Head_row_too_large_error
    | Pending_publication_mismatch_error
    | Store_identity_missing_from_non_fresh_root_error
    | Store_identity_create_failed_error
    | Store_identity_read_failed_error
    | Invalid_store_identity_error
    | Current_head_read_failed_error
    | Current_head_changed_during_read_error
    | Invalid_publication_obligation_error
    | Publication_obligation_owner_mismatch_error
    | Publication_obligation_store_mismatch_error
    | Publication_obligation_mismatch_error

  type warning_tag =
    | Head_settlement_warning_tag
    | Head_effect_warning_tag
    | Head_indeterminate_warning_tag
    | Immutable_settlement_warning_tag
    | Store_identity_settlement_warning_tag
    | Current_head_settlement_warning_tag

  let error_tag (value : error) =
    match value.kind with
    | Invalid_layout _ -> Invalid_layout_error
    | Store_not_active -> Store_not_active_error
    | Runtime_store_binding_mismatch ->
      Runtime_store_binding_mismatch_error
    | Persisted_store_binding_mismatch _ ->
      Persisted_store_binding_mismatch_error
    | Invalid_domain_value _ -> Invalid_domain_value_error
    | Conflicting_operation _ -> Conflicting_operation_error
    | Generation_exhausted -> Generation_exhausted_error
    | Entropy_source_failed _ -> Entropy_source_failed_error
    | Implementation_safety_ceiling_exceeded _ ->
      Implementation_safety_ceiling_exceeded_error
    | Byte_accounting_overflow _ -> Byte_accounting_overflow_error
    | Immutable_create_failed _ -> Immutable_create_failed_error
    | Immutable_read_failed _ -> Immutable_read_failed_error
    | Immutable_digest_mismatch _ -> Immutable_digest_mismatch_error
    | Invalid_store_json _ -> Invalid_store_json_error
    | Head_operation_failed { failure = Head.Busy; _ } ->
      Head_busy_unchanged_error
    | Head_operation_failed _ -> Head_operation_failed_error
    | Head_row_too_large _ -> Head_row_too_large_error
    | Pending_publication_mismatch -> Pending_publication_mismatch_error
    | Store_identity_missing_from_non_fresh_root _ ->
      Store_identity_missing_from_non_fresh_root_error
    | Store_identity_create_failed _ -> Store_identity_create_failed_error
    | Store_identity_read_failed _ -> Store_identity_read_failed_error
    | Invalid_store_identity _ -> Invalid_store_identity_error
    | Current_head_read_failed _ -> Current_head_read_failed_error
    | Current_head_changed_during_read ->
      Current_head_changed_during_read_error
    | Invalid_publication_obligation _ ->
      Invalid_publication_obligation_error
    | Publication_obligation_owner_mismatch _ ->
      Publication_obligation_owner_mismatch_error
    | Publication_obligation_store_mismatch _ ->
      Publication_obligation_store_mismatch_error
    | Publication_obligation_mismatch _ ->
      Publication_obligation_mismatch_error
  ;;

  let warning_tag = function
    | Head_settlement_warning _ -> Head_settlement_warning_tag
    | Head_effect_warning _ -> Head_effect_warning_tag
    | Head_indeterminate_warning _ -> Head_indeterminate_warning_tag
    | Immutable_settlement_warning _ -> Immutable_settlement_warning_tag
    | Store_identity_settlement_warning _ ->
      Store_identity_settlement_warning_tag
    | Current_head_settlement_warning _ ->
      Current_head_settlement_warning_tag
  ;;

  let read_store_identity_with_parent_settlement_failure ~root ~owner_id =
    let on_missing_warnings warnings =
      warnings
      @ [ Exact_read.Settle_resources
            { operation = Exact_read.Settle_parent_resources
            ; detail = "injected parent settlement failure"
            }
        ]
    in
    match
      read_store_identity_with_missing_warnings
        ~on_missing_warnings
        ~root
        ~owner_id
    with
    | Ok None -> Ok false
    | Ok (Some _) -> Ok true
    | Error error -> Error error
  ;;

  let publish_with_head_hooks hooks store prepared =
    publish_with_compare_and_swap
      (Head.For_testing.compare_and_swap hooks)
      store
      prepared
  ;;

  let prepare_with_implementation_ceiling
        ~maximum
        store
        ~expected
        ~operation_id
        ~state
    =
    prepare_with_implementation_ceiling
      maximum
      store
      ~expected
      ~operation_id
      ~state
  ;;

  let canonical_state_bytes state =
    let emit sink = emit_state sink state in
    match
      Canonical_bytes.measure_bounded
        ~ceiling:(Int64.of_int Sys.max_string_length)
        emit
    with
    | Error (Canonical_bytes.Ceiling_exceeded observed_at_least_bytes) ->
      Error
        (make_error
           (Implementation_safety_ceiling_exceeded
              { artifact = `Facts
              ; observed_at_least_bytes
              ; ceiling_bytes = Int64.of_int Sys.max_string_length
              }))
    | Error Canonical_bytes.Counter_overflow ->
      Error (make_error (Byte_accounting_overflow `Facts))
    | Ok byte_count -> render_canonical `Facts ~byte_count emit
  ;;

  let state_sha256 = state_digest
end
