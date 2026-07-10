(** Durable per-keeper post-turn memory jobs. *)

let job_schema = "masc.keeper_memory_job.v1"
let envelope_schema = "masc.keeper_memory_job_envelope.v1"
let receipt_schema = "masc.keeper_memory_job_receipt.v2"
let jobs_dirname = "memory-jobs"
let awaiting_dirname = "awaiting-turn-commit"
let pending_dirname = "pending"
let inflight_dirname = "inflight"
let receipts_dirname = "receipts"
let operations_dirname = "operations"
let recovered_atomic_writes_dirname = "recovered-atomic-writes"
let json_suffix = ".json"
let private_directory_mode = 0o700
let private_file_mode = 0o600

type job =
  { id : string
  ; keeper_name : string
  ; trace_id : string
  ; generation : int
  ; turn : int
  ; oas_turn_count : int
  ; enqueued_at : float
  ; payload : Yojson.Safe.t
  }

type lease =
  { job : job
  ; started_at : float
  }

type admission =
  | Staged_awaiting_turn_commit
  | Already_awaiting
  | Already_pending
  | Already_inflight
  | Already_completed

type activation =
  | Activated
  | Activation_already_pending
  | Activation_already_inflight
  | Activation_already_completed

type terminal_outcome =
  | Succeeded
  | Failed

type receipt_identity =
  { id : string
  ; keeper_name : string
  ; trace_id : string
  ; generation : int
  ; turn : int
  ; oas_turn_count : int
  ; enqueued_at : float
  ; payload_sha256 : string
  }

type terminal_receipt =
  { identity : receipt_identity
  ; started_at : float
  ; ended_at : float
  ; outcome : terminal_outcome
  ; detail : Yojson.Safe.t
  }

type io_operation =
  | Ensure_directory
  | Set_permissions
  | Sync
  | Inspect
  | List_directory
  | Read
  | Write
  | Remove

type error =
  | Invalid_keeper_name of string
  | Invalid_trace_id of string
  | Invalid_turn_identity of
      { generation : int
      ; turn : int
      ; oas_turn_count : int
      }
  | Invalid_enqueue_time of float
  | Invalid_claim_time of float
  | Invalid_json_value of string
  | Invalid_terminal_timestamps of
      { started_at : float
      ; ended_at : float
      }
  | Invalid_job_id of string
  | Missing_inflight_lease of
      { job_id : string
      ; path : string
      }
  | Inflight_lease_conflict of
      { job_id : string
      ; path : string
      ; expected_started_at : float
      ; actual_started_at : float
      }
  | Pending_already_inflight of
      { job_id : string
      ; pending_path : string
      ; inflight_path : string
      }
  | Unexpected_queue_entry of string
  | Decode_error of
      { path : string
      ; detail : string
      }
  | Identity_conflict of
      { job_id : string
      ; path : string
      }
  | Io_error of
      { operation : io_operation
      ; path : string
      ; detail : string
      }

type cleanup_report =
  { cleanup_errors : error list
  }

type recovery_report =
  { replayed : int
  ; cleanup_errors : error list
  }

type claim_report =
  { leases : lease list
  ; cleanup_errors : error list
  ; blocked : error option
  }

let io_operation_to_string = function
  | Ensure_directory -> "ensure_directory"
  | Set_permissions -> "set_permissions"
  | Sync -> "sync"
  | Inspect -> "inspect"
  | List_directory -> "list_directory"
  | Read -> "read"
  | Write -> "write"
  | Remove -> "remove"
;;

let error_to_string = function
  | Invalid_keeper_name name ->
    Printf.sprintf "invalid keeper name: %S" name
  | Invalid_trace_id detail -> detail
  | Invalid_turn_identity { generation; turn; oas_turn_count } ->
    Printf.sprintf
      "invalid memory job turn identity generation=%d turn=%d oas_turn_count=%d"
      generation
      turn
      oas_turn_count
  | Invalid_enqueue_time value ->
    Printf.sprintf "invalid memory job enqueue time: %g" value
  | Invalid_claim_time value ->
    Printf.sprintf "invalid memory job claim time: %g" value
  | Invalid_json_value detail ->
    Printf.sprintf "invalid memory job JSON value: %s" detail
  | Invalid_terminal_timestamps { started_at; ended_at } ->
    Printf.sprintf
      "invalid memory job terminal timestamps started_at=%g ended_at=%g"
      started_at
      ended_at
  | Invalid_job_id id -> Printf.sprintf "invalid memory job id: %S" id
  | Missing_inflight_lease { job_id; path } ->
    Printf.sprintf
      "memory job completion has no inflight lease id=%s path=%s"
      job_id
      path
  | Inflight_lease_conflict
      { job_id
      ; path
      ; expected_started_at
      ; actual_started_at
      } ->
    Printf.sprintf
      "memory job inflight lease mismatch id=%s path=%s expected_started_at=%g actual_started_at=%g"
      job_id
      path
      expected_started_at
      actual_started_at
  | Pending_already_inflight { job_id; pending_path; inflight_path } ->
    Printf.sprintf
      "memory job pending claim already has an inflight lease id=%s pending=%s inflight=%s"
      job_id
      pending_path
      inflight_path
  | Unexpected_queue_entry path ->
    Printf.sprintf "unexpected entry in memory job queue: %s" path
  | Decode_error { path; detail } ->
    Printf.sprintf "memory job decode failed path=%s: %s" path detail
  | Identity_conflict { job_id; path } ->
    Printf.sprintf
      "memory job identity conflict id=%s path=%s"
      job_id
      path
  | Io_error { operation; path; detail } ->
    Printf.sprintf
      "memory job %s failed path=%s: %s"
      (io_operation_to_string operation)
      path
      detail
;;

let ( let* ) = Result.bind

let keeper_name_is_valid keeper_name =
  Result.is_ok (Keeper_id.Keeper_name.of_string keeper_name)
;;

let protect_io operation path f =
  try Ok (f ()) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Io_error
         { operation
         ; path
         ; detail = Printexc.to_string exn
         })
;;

let keeper_jobs_dir ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.keepers_runtime_dir_of_base ~base_path)
       keeper_name)
    jobs_dirname
;;

let pending_dir ~base_path ~keeper_name =
  Filename.concat (keeper_jobs_dir ~base_path ~keeper_name) pending_dirname
;;

let awaiting_dir ~base_path ~keeper_name =
  Filename.concat
    (keeper_jobs_dir ~base_path ~keeper_name)
    awaiting_dirname
;;

let inflight_dir ~base_path ~keeper_name =
  Filename.concat (keeper_jobs_dir ~base_path ~keeper_name) inflight_dirname
;;

let receipts_dir ~base_path ~keeper_name =
  Filename.concat (keeper_jobs_dir ~base_path ~keeper_name) receipts_dirname
;;

let operation_stages_dir_for_keepers_dir ~keepers_dir ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat keepers_dir keeper_name)
       jobs_dirname)
    operations_dirname
;;

let operations_dir ~base_path ~keeper_name =
  operation_stages_dir_for_keepers_dir
    ~keepers_dir:(Common.keepers_runtime_dir_of_base ~base_path)
    ~keeper_name
;;

let path_for_id dir id = Filename.concat dir (id ^ json_suffix)

let pending_path ~base_path (job : job) =
  path_for_id (pending_dir ~base_path ~keeper_name:job.keeper_name) job.id
;;

let awaiting_path ~base_path (job : job) =
  path_for_id (awaiting_dir ~base_path ~keeper_name:job.keeper_name) job.id
;;

let inflight_path ~base_path (job : job) =
  path_for_id (inflight_dir ~base_path ~keeper_name:job.keeper_name) job.id
;;

let receipt_path ~base_path (job : job) =
  path_for_id (receipts_dir ~base_path ~keeper_name:job.keeper_name) job.id
;;

let receipt_path_for_identity ~base_path (identity : receipt_identity) =
  path_for_id
    (receipts_dir ~base_path ~keeper_name:identity.keeper_name)
    identity.id
;;

let operation_stage_path_for_keepers_dir_unchecked
      ~keepers_dir
      ~keeper_name
      ~operation_id
  =
  path_for_id
    (operation_stages_dir_for_keepers_dir ~keepers_dir ~keeper_name)
    operation_id
;;

let operation_stage_path ~base_path ~keeper_name ~operation_id =
  path_for_id (operations_dir ~base_path ~keeper_name) operation_id
;;

let inspect_path path =
  try Ok (Some (Unix.lstat path)) with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path
         ; detail = Printexc.to_string exn
         })
;;

let sync_directory path =
  match Fs_compat.fsync_directory path with
  | Ok () -> Ok ()
  | Error detail -> Error (Io_error { operation = Sync; path; detail })
;;

let not_real_directory_error path =
  Io_error
    { operation = Inspect
    ; path
    ; detail = "memory job store path is not a real directory"
    }
;;

let require_existing_real_directory path =
  let* stat = protect_io Inspect path (fun () -> Unix.lstat path) in
  if stat.Unix.st_kind = Unix.S_DIR
  then Ok ()
  else Error (not_real_directory_error path)
;;

let ensure_real_directory ~owned path =
  let* before = inspect_path path in
  let* created =
    match before with
    | Some _ -> Ok false
    | None ->
      let mode = if owned then private_directory_mode else 0o755 in
      let* () =
        protect_io Ensure_directory path (fun () ->
          try Unix.mkdir path mode with
          | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
      in
      Ok true
  in
  let* () = require_existing_real_directory path in
  let* () = if created then sync_directory (Filename.dirname path) else Ok () in
  if not owned
  then Ok ()
  else
    let* () =
      protect_io Set_permissions path (fun () ->
        Unix.chmod path private_directory_mode)
    in
    sync_directory path
;;

let managed_root_directories ~base_path =
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  [ masc_dir; Common.keepers_runtime_dir_of_base ~base_path ]
;;

let keeper_ancestor_directories ~base_path ~keeper_name =
  let keepers_root = Common.keepers_runtime_dir_of_base ~base_path in
  [ Filename.concat keepers_root keeper_name
  ; keeper_jobs_dir ~base_path ~keeper_name
  ]
;;

let validate_real_directory_chain paths =
  let rec loop = function
    | [] -> Ok true
    | path :: rest ->
      let* stat = inspect_path path in
      (match stat with
       | None -> Ok false
       | Some stat when stat.Unix.st_kind = Unix.S_DIR -> loop rest
       | Some _ -> Error (not_real_directory_error path))
  in
  loop paths
;;

let require_real_directory_chain paths =
  let rec loop = function
    | [] -> Ok ()
    | path :: rest ->
      let* () = require_existing_real_directory path in
      loop rest
  in
  loop paths
;;

let validate_managed_root_if_present ~base_path =
  validate_real_directory_chain
    (base_path :: managed_root_directories ~base_path)
;;

let validate_keeper_ancestors_if_present ~base_path ~keeper_name =
  validate_real_directory_chain
    (base_path
     :: (managed_root_directories ~base_path
         @ keeper_ancestor_directories ~base_path ~keeper_name))
;;

let ensure_store_dirs ~base_path ~keeper_name =
  let keepers_root = Common.keepers_runtime_dir_of_base ~base_path in
  let keeper_dir = Filename.concat keepers_root keeper_name in
  let* () = require_existing_real_directory base_path in
  let parent_dirs =
    managed_root_directories ~base_path @ [ keeper_dir ]
  in
  let owned_dirs =
    [ keeper_jobs_dir ~base_path ~keeper_name
    ; pending_dir ~base_path ~keeper_name
    ; awaiting_dir ~base_path ~keeper_name
    ; inflight_dir ~base_path ~keeper_name
    ; receipts_dir ~base_path ~keeper_name
    ; operations_dir ~base_path ~keeper_name
    ]
  in
  let rec loop ~owned = function
    | [] -> Ok ()
    | dir :: rest ->
      let* () = ensure_real_directory ~owned dir in
      loop ~owned rest
  in
  let* () = loop ~owned:false parent_dirs in
  let* () = loop ~owned:true owned_dirs in
  require_real_directory_chain
    (base_path :: (parent_dirs @ owned_dirs))
;;

let valid_job_id id =
  String.length id = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       id
;;

let is_valid_job_id = valid_job_id

let rec validate_json_value = function
  | `Float value when not (Float.is_finite value) ->
    Error (Invalid_json_value "floating-point values must be finite")
  | `Assoc fields ->
    let names = List.map fst fields |> List.sort String.compare in
    let rec reject_duplicate_names = function
      | left :: (right :: _) when String.equal left right ->
        Error
          (Invalid_json_value
             (Printf.sprintf "duplicate object field %S" left))
      | _ :: rest -> reject_duplicate_names rest
      | [] -> Ok ()
    in
    let* () = reject_duplicate_names names in
    let rec validate_fields = function
      | [] -> Ok ()
      | (_, value) :: rest ->
        let* () = validate_json_value value in
        validate_fields rest
    in
    validate_fields fields
  | `List values ->
    let rec validate_values = function
      | [] -> Ok ()
      | value :: rest ->
        let* () = validate_json_value value in
        validate_values rest
    in
    validate_values values
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _ -> Ok ()
;;

let validate_json_value_for_decode json =
  validate_json_value json |> Result.map_error error_to_string
;;

let operation_stage_path_for_keepers_dir
      ~keepers_dir
      ~keeper_name
      ~operation_id
  =
  match Keeper_id.Keeper_name.of_string keeper_name with
  | Error _ -> Error (Invalid_keeper_name keeper_name)
  | Ok keeper_name ->
    if not (valid_job_id operation_id)
    then Error (Invalid_job_id operation_id)
    else
      Ok
        (operation_stage_path_for_keepers_dir_unchecked
           ~keepers_dir
           ~keeper_name:(Keeper_id.Keeper_name.to_string keeper_name)
           ~operation_id)
;;

let job_identity_string ~keeper_name ~trace_id ~generation ~turn ~oas_turn_count =
  String.concat
    "\000"
    [ keeper_name
    ; trace_id
    ; string_of_int generation
    ; string_of_int turn
    ; string_of_int oas_turn_count
    ]
;;

let make_job
      ~keeper_name
      ~trace_id
      ~generation
      ~turn
      ~oas_turn_count
      ~enqueued_at
      ~payload
  =
  match Keeper_id.Keeper_name.of_string keeper_name with
  | Error _ -> Error (Invalid_keeper_name keeper_name)
  | Ok keeper_name_t ->
    (match Keeper_id.Trace_id.of_string trace_id with
     | Error detail -> Error (Invalid_trace_id detail)
     | Ok trace_id_t ->
       if generation < 0 || turn < 0 || oas_turn_count < 0
       then Error (Invalid_turn_identity { generation; turn; oas_turn_count })
       else if (not (Float.is_finite enqueued_at)) || enqueued_at < 0.0
       then Error (Invalid_enqueue_time enqueued_at)
       else
         let* () = validate_json_value payload in
         let keeper_name = Keeper_id.Keeper_name.to_string keeper_name_t in
         let trace_id = Keeper_id.Trace_id.to_string trace_id_t in
         let id =
           job_identity_string
             ~keeper_name
             ~trace_id
             ~generation
             ~turn
             ~oas_turn_count
           |> Digestif.SHA256.digest_string
           |> Digestif.SHA256.to_hex
         in
         Ok
           { id
           ; keeper_name
           ; trace_id
           ; generation
           ; turn
           ; oas_turn_count
           ; enqueued_at
           ; payload
           })
;;

let job_to_json (job : job) =
  `Assoc
    [ "schema", `String job_schema
    ; "id", `String job.id
    ; "keeper_name", `String job.keeper_name
    ; "trace_id", `String job.trace_id
    ; "generation", `Int job.generation
    ; "turn", `Int job.turn
    ; "oas_turn_count", `Int job.oas_turn_count
    ; "enqueued_at", `Float job.enqueued_at
    ; "payload", job.payload
    ]
;;

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, canonical_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _) as json ->
    json
;;

let payload_sha256 payload =
  canonical_json payload
  |> Yojson.Safe.to_string
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let receipt_identity_of_job (job : job) =
  { id = job.id
  ; keeper_name = job.keeper_name
  ; trace_id = job.trace_id
  ; generation = job.generation
  ; turn = job.turn
  ; oas_turn_count = job.oas_turn_count
  ; enqueued_at = job.enqueued_at
  ; payload_sha256 = payload_sha256 job.payload
  }
;;

let make_terminal_receipt lease ~ended_at ~outcome ~detail =
  let started_at = lease.started_at in
  if
    (not (Float.is_finite started_at))
    || started_at < 0.0
    || not (Float.is_finite ended_at)
    || ended_at < started_at
  then
    Error
      (Invalid_terminal_timestamps
         { started_at
         ; ended_at
         })
  else
    let* () = validate_json_value detail in
    Ok
      { identity = receipt_identity_of_job lease.job
      ; started_at
      ; ended_at
      ; outcome
      ; detail
      }
;;

let receipt_identity_matches_retry identity (job : job) =
  String.equal identity.id job.id
  && String.equal identity.keeper_name job.keeper_name
  && String.equal identity.trace_id job.trace_id
  && identity.generation = job.generation
  && identity.turn = job.turn
  && identity.oas_turn_count = job.oas_turn_count
  && String.equal identity.payload_sha256 (payload_sha256 job.payload)
;;

let receipt_identity_matches_job identity (job : job) =
  receipt_identity_matches_retry identity job
  && Float.equal identity.enqueued_at job.enqueued_at
;;

let receipt_identity_equal left right =
  String.equal left.id right.id
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.trace_id right.trace_id
  && left.generation = right.generation
  && left.turn = right.turn
  && left.oas_turn_count = right.oas_turn_count
  && Float.equal left.enqueued_at right.enqueued_at
  && String.equal left.payload_sha256 right.payload_sha256
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (Printf.sprintf "field %s must be a string" name)
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let int_field name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error (Printf.sprintf "field %s must be an int" name)
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let float_field name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some _ -> Error (Printf.sprintf "field %s must be a number" name)
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let json_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field %s" name)
;;

let job_of_json json =
  let* () = validate_json_value_for_decode json in
  match json with
  | `Assoc fields ->
    let* schema = string_field "schema" fields in
    if not (String.equal schema job_schema)
    then Error (Printf.sprintf "unsupported memory job schema: %s" schema)
    else
      let* id = string_field "id" fields in
      let* keeper_name = string_field "keeper_name" fields in
      let* trace_id = string_field "trace_id" fields in
      let* generation = int_field "generation" fields in
      let* turn = int_field "turn" fields in
      let* oas_turn_count = int_field "oas_turn_count" fields in
      let* enqueued_at = float_field "enqueued_at" fields in
      let* payload = json_field "payload" fields in
      let* () =
        validate_json_value payload
        |> Result.map_error error_to_string
      in
      if not (valid_job_id id)
      then Error (Printf.sprintf "invalid memory job id: %S" id)
      else
        let* keeper_name =
          Keeper_id.Keeper_name.of_string keeper_name
        in
        let* trace_id = Keeper_id.Trace_id.of_string trace_id in
        if generation < 0 || turn < 0 || oas_turn_count < 0
        then Error "turn identity values must be non-negative"
        else if (not (Float.is_finite enqueued_at)) || enqueued_at < 0.0
        then Error "enqueued_at must be finite and non-negative"
        else
          let keeper_name = Keeper_id.Keeper_name.to_string keeper_name in
          let trace_id = Keeper_id.Trace_id.to_string trace_id in
          let expected_id =
            job_identity_string
              ~keeper_name
              ~trace_id
              ~generation
              ~turn
              ~oas_turn_count
            |> Digestif.SHA256.digest_string
            |> Digestif.SHA256.to_hex
          in
          if not (String.equal id expected_id)
          then Error "memory job id does not match its typed turn identity"
          else
            Ok
              { id
              ; keeper_name
              ; trace_id
              ; generation
              ; turn
              ; oas_turn_count
              ; enqueued_at
              ; payload
              }
  | _ -> Error "memory job must be a JSON object"
;;

type persisted_state =
  | Awaiting_turn_commit
  | Pending
  | Inflight of { started_at : float }

type envelope =
  { job : job
  ; state : persisted_state
  }

let state_to_json = function
  | Awaiting_turn_commit ->
    `Assoc [ "kind", `String "awaiting_turn_commit" ]
  | Pending -> `Assoc [ "kind", `String "pending" ]
  | Inflight { started_at } ->
    `Assoc
      [ "kind", `String "inflight"
      ; "started_at", `Float started_at
      ]
;;

let envelope_to_json envelope =
  `Assoc
    [ "schema", `String envelope_schema
    ; "job", job_to_json envelope.job
    ; "state", state_to_json envelope.state
    ]
;;

let state_of_json json =
  let* () = validate_json_value_for_decode json in
  match json with
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "awaiting_turn_commit" -> Ok Awaiting_turn_commit
     | "pending" -> Ok Pending
     | "inflight" ->
       let* started_at = float_field "started_at" fields in
       if (not (Float.is_finite started_at)) || started_at < 0.0
       then Error "inflight started_at must be finite and non-negative"
       else Ok (Inflight { started_at })
     | other -> Error (Printf.sprintf "unknown memory job state: %s" other))
  | _ -> Error "memory job state must be an object"
;;

let envelope_of_json json =
  let* () = validate_json_value_for_decode json in
  match json with
  | `Assoc fields ->
    let* schema = string_field "schema" fields in
    if not (String.equal schema envelope_schema)
    then Error (Printf.sprintf "unsupported memory job envelope schema: %s" schema)
    else
      let* job_json = json_field "job" fields in
      let* state_json = json_field "state" fields in
      let* job = job_of_json job_json in
      let* state = state_of_json state_json in
      Ok { job; state }
  | _ -> Error "memory job envelope must be a JSON object"
;;

let terminal_outcome_to_string = function
  | Succeeded -> "succeeded"
  | Failed -> "failed"
;;

let terminal_outcome_of_string = function
  | "succeeded" -> Ok Succeeded
  | "failed" -> Ok Failed
  | value -> Error (Printf.sprintf "unknown terminal outcome: %s" value)
;;

let receipt_identity_to_json identity =
  `Assoc
    [ "id", `String identity.id
    ; "keeper_name", `String identity.keeper_name
    ; "trace_id", `String identity.trace_id
    ; "generation", `Int identity.generation
    ; "turn", `Int identity.turn
    ; "oas_turn_count", `Int identity.oas_turn_count
    ; "enqueued_at", `Float identity.enqueued_at
    ; "payload_sha256", `String identity.payload_sha256
    ]
;;

let receipt_identity_of_json json =
  let* () = validate_json_value_for_decode json in
  match json with
  | `Assoc fields ->
    let* id = string_field "id" fields in
    let* keeper_name = string_field "keeper_name" fields in
    let* trace_id = string_field "trace_id" fields in
    let* generation = int_field "generation" fields in
    let* turn = int_field "turn" fields in
    let* oas_turn_count = int_field "oas_turn_count" fields in
    let* enqueued_at = float_field "enqueued_at" fields in
    let* payload_sha256 = string_field "payload_sha256" fields in
    let* keeper_name = Keeper_id.Keeper_name.of_string keeper_name in
    let* trace_id = Keeper_id.Trace_id.of_string trace_id in
    let keeper_name = Keeper_id.Keeper_name.to_string keeper_name in
    let trace_id = Keeper_id.Trace_id.to_string trace_id in
    let expected_id =
      job_identity_string
        ~keeper_name
        ~trace_id
        ~generation
        ~turn
        ~oas_turn_count
      |> Digestif.SHA256.digest_string
      |> Digestif.SHA256.to_hex
    in
    if generation < 0 || turn < 0 || oas_turn_count < 0
    then Error "receipt turn identity values must be non-negative"
    else if (not (Float.is_finite enqueued_at)) || enqueued_at < 0.0
    then Error "receipt enqueued_at must be finite and non-negative"
    else if not (valid_job_id id) || not (String.equal id expected_id)
    then Error "receipt id does not match its typed turn identity"
    else if not (valid_job_id payload_sha256)
    then Error "receipt payload_sha256 must be a lowercase SHA-256 digest"
    else
      Ok
        { id
        ; keeper_name
        ; trace_id
        ; generation
        ; turn
        ; oas_turn_count
        ; enqueued_at
        ; payload_sha256
        }
  | _ -> Error "receipt job identity must be a JSON object"
;;

let receipt_to_json (receipt : terminal_receipt) =
  `Assoc
    [ "schema", `String receipt_schema
    ; "job_identity", receipt_identity_to_json receipt.identity
    ; "started_at", `Float receipt.started_at
    ; "ended_at", `Float receipt.ended_at
    ; "outcome", `String (terminal_outcome_to_string receipt.outcome)
    ; "detail", receipt.detail
    ]
;;

let receipt_of_json json =
  let* () = validate_json_value_for_decode json in
  match json with
  | `Assoc fields ->
    let* schema = string_field "schema" fields in
    if not (String.equal schema receipt_schema)
    then Error (Printf.sprintf "unsupported memory job receipt schema: %s" schema)
    else
      let* identity_json = json_field "job_identity" fields in
      let* identity = receipt_identity_of_json identity_json in
      let* started_at = float_field "started_at" fields in
      let* ended_at = float_field "ended_at" fields in
      let* outcome_string = string_field "outcome" fields in
      let* outcome = terminal_outcome_of_string outcome_string in
      let* detail = json_field "detail" fields in
      let* () =
        validate_json_value detail
        |> Result.map_error error_to_string
      in
      if
        (not (Float.is_finite started_at))
        || started_at < 0.0
        || not (Float.is_finite ended_at)
        || ended_at < started_at
      then Error "receipt timestamps must be finite, non-negative, and ordered"
      else Ok { identity; started_at; ended_at; outcome; detail }
  | _ -> Error "memory job receipt must be a JSON object"
;;

let read_json path =
  let* stat = protect_io Inspect path (fun () -> Unix.lstat path) in
  if stat.Unix.st_kind <> Unix.S_REG
  then
    Error
      (Io_error
         { operation = Inspect
         ; path
         ; detail = "memory job artifact is not a regular file"
         })
  else
    match
      try
        Fs_compat.load_file_unix path
        |> Safe_ops.parse_json_safe ~context:path
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    with
    | Ok json -> Ok json
    | Error detail -> Error (Io_error { operation = Read; path; detail })
;;

let read_envelope path =
  let* json = read_json path in
  envelope_of_json json
  |> Result.map_error (fun detail -> Decode_error { path; detail })
;;

let read_receipt path =
  let* json = read_json path in
  receipt_of_json json
  |> Result.map_error (fun detail -> Decode_error { path; detail })
;;

let save_json path json =
  match
    Fs_compat.save_file_atomic_unix
      path
      (Yojson.Safe.pretty_to_string json)
  with
  | Ok () ->
    protect_io Set_permissions path (fun () -> Unix.chmod path private_file_mode)
  | Error detail -> Error (Io_error { operation = Write; path; detail })
;;

let file_exists path =
  try
    ignore (Unix.lstat path);
    Ok true
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path
         ; detail = Printexc.to_string exn
         })
;;

let remove_if_exists path =
  let* exists = file_exists path in
  if not exists
  then Ok ()
  else protect_io Remove path (fun () -> Sys.remove path)
;;

let cleanup_paths paths =
  List.fold_left
    (fun errors path ->
       match remove_if_exists path with
       | Ok () -> errors
       | Error error -> error :: errors)
    []
    paths
  |> List.rev
;;

let reconcile_atomic_orphan dir name =
  let path = Filename.concat dir name in
  let recovered_root =
    Filename.concat
      (Filename.dirname dir)
      recovered_atomic_writes_dirname
  in
  let bucket = Filename.basename dir in
  let recovered_dir =
    Filename.concat
      recovered_root
      bucket
  in
  let* () = ensure_real_directory ~owned:true recovered_root in
  let* () = ensure_real_directory ~owned:true recovered_dir in
  match Fs_compat.recover_atomic_orphan ~path ~recovered_root ~bucket with
  | Error detail -> Error (Io_error { operation = Inspect; path; detail })
  | Ok Fs_compat.Deleted_zero_length ->
    Log.Keeper.warn "memory job queue removed zero-length atomic orphan path=%s" path;
    Ok ()
  | Ok (Fs_compat.Preserved_nonempty destination) ->
    (match
       protect_io Set_permissions recovered_dir (fun () ->
         Unix.chmod recovered_dir private_directory_mode)
     with
     | Error _ as error -> error
     | Ok () ->
       let* () =
         protect_io Set_permissions destination (fun () ->
           Unix.chmod destination private_file_mode)
       in
       Log.Keeper.error
         "memory job queue preserved non-empty atomic orphan source=%s destination=%s"
         path
         destination;
       Ok ())
;;

let list_json_paths dir =
  let* exists = file_exists dir in
  if not exists
  then Ok []
  else
    let* stat = protect_io Inspect dir (fun () -> Unix.lstat dir) in
    let* () =
      if stat.Unix.st_kind = Unix.S_DIR
      then Ok ()
      else
        Error
          (Io_error
             { operation = Inspect
             ; path = dir
             ; detail = "memory job queue path is not a real directory"
             })
    in
    let* entries =
      protect_io List_directory dir (fun () -> Sys.readdir dir |> Array.to_list)
    in
    let rec validate acc = function
      | [] -> Ok (List.sort String.compare acc)
      | name :: rest ->
        let path = Filename.concat dir name in
        if Filename.check_suffix name json_suffix
        then validate (path :: acc) rest
        else if Fs_compat.is_atomic_orphan_name name
        then
          let* () = reconcile_atomic_orphan dir name in
          validate acc rest
        else Error (Unexpected_queue_entry path)
    in
    validate [] entries
;;

let reconcile_atomic_orphans_in_dir dir =
  let* exists = file_exists dir in
  if not exists
  then Ok ()
  else
    let* stat = protect_io Inspect dir (fun () -> Unix.lstat dir) in
    let* () =
      if stat.Unix.st_kind = Unix.S_DIR
      then Ok ()
      else
        Error
          (Io_error
             { operation = Inspect
             ; path = dir
             ; detail = "memory job queue path is not a real directory"
             })
    in
    let* entries =
      protect_io List_directory dir (fun () -> Sys.readdir dir |> Array.to_list)
    in
    let rec loop = function
      | [] -> Ok ()
      | name :: rest ->
        if Fs_compat.is_atomic_orphan_name name
        then
          let* () = reconcile_atomic_orphan dir name in
          loop rest
        else loop rest
    in
    loop entries
;;

let job_equal left right =
  String.equal left.id right.id
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.trace_id right.trace_id
  && left.generation = right.generation
  && left.turn = right.turn
  && left.oas_turn_count = right.oas_turn_count
  && String.equal (payload_sha256 left.payload) (payload_sha256 right.payload)
;;

let ensure_same_job ~expected ~path envelope =
  if job_equal expected envelope.job
  then Ok ()
  else Error (Identity_conflict { job_id = expected.id; path })
;;

type expected_envelope_state =
  | Expect_awaiting
  | Expect_pending
  | Expect_inflight

let ensure_expected_state ~expected ~path envelope =
  match expected, envelope.state with
  | Expect_awaiting, Awaiting_turn_commit
  | Expect_pending, Pending
  | Expect_inflight, Inflight _ -> Ok ()
  | Expect_awaiting, (Pending | Inflight _)
  | Expect_pending, (Awaiting_turn_commit | Inflight _)
  | Expect_inflight, (Awaiting_turn_commit | Pending) ->
    let expected_label =
      match expected with
      | Expect_awaiting -> "awaiting-turn-commit"
      | Expect_pending -> "pending"
      | Expect_inflight -> "inflight"
    in
    Error
      (Decode_error
         { path
         ; detail =
             Printf.sprintf
               "%s directory contains an envelope with a different state"
               expected_label
         })
;;

let ensure_queue_coordinates ~expected_keeper_name ~path envelope =
  let expected_name = envelope.job.id ^ json_suffix in
  let actual_name = Filename.basename path in
  if not (String.equal envelope.job.keeper_name expected_keeper_name)
  then
    Error
      (Decode_error
         { path
         ; detail =
             Printf.sprintf
               "queue keeper coordinate mismatch expected=%s actual=%s"
               expected_keeper_name
               envelope.job.keeper_name
         })
  else if not (String.equal actual_name expected_name)
  then
    Error
      (Decode_error
         { path
         ; detail =
             Printf.sprintf
               "queue filename coordinate mismatch expected=%s actual=%s"
               expected_name
               actual_name
         })
  else Ok ()
;;

let classify_existing_envelope ~expected_job ~expected_state ~path outcome =
  let* exists = file_exists path in
  if not exists
  then Ok None
  else
    let* envelope = read_envelope path in
    let* () =
      ensure_queue_coordinates
        ~expected_keeper_name:expected_job.keeper_name
        ~path
        envelope
    in
    let* () = ensure_same_job ~expected:expected_job ~path envelope in
    let* () = ensure_expected_state ~expected:expected_state ~path envelope in
    Ok (Some outcome)
;;

let stage_awaiting_turn_commit ~base_path job =
  let* () = ensure_store_dirs ~base_path ~keeper_name:job.keeper_name in
  let receipt_path = receipt_path ~base_path job in
  let* receipt_exists = file_exists receipt_path in
  if receipt_exists
  then
    let* receipt = read_receipt receipt_path in
    if receipt_identity_matches_retry receipt.identity job
    then
      let cleanup_errors =
        cleanup_paths
          [ awaiting_path ~base_path job
          ; pending_path ~base_path job
          ; inflight_path ~base_path job
          ; operation_stage_path
              ~base_path
              ~keeper_name:job.keeper_name
              ~operation_id:job.id
          ]
      in
      List.iter
        (fun error ->
           Log.Keeper.error ~keeper_name:job.keeper_name
             "memory job completed-state cleanup debt job_id=%s: %s"
             job.id
             (error_to_string error))
        cleanup_errors;
      Ok Already_completed
    else Error (Identity_conflict { job_id = job.id; path = receipt_path })
  else
    let awaiting_path = awaiting_path ~base_path job in
    let pending_path = pending_path ~base_path job in
    let inflight_path = inflight_path ~base_path job in
    let* awaiting =
      classify_existing_envelope
        ~expected_job:job
        ~expected_state:Expect_awaiting
        ~path:awaiting_path
        Already_awaiting
    in
    match awaiting with
    | Some outcome -> Ok outcome
    | None ->
    let* pending =
      classify_existing_envelope
        ~expected_job:job
        ~expected_state:Expect_pending
        ~path:pending_path
        Already_pending
    in
    match pending with
    | Some outcome -> Ok outcome
    | None ->
      let* inflight =
        classify_existing_envelope
          ~expected_job:job
          ~expected_state:Expect_inflight
          ~path:inflight_path
          Already_inflight
      in
      (match inflight with
       | Some outcome -> Ok outcome
       | None ->
         let envelope = { job; state = Awaiting_turn_commit } in
         let* () = save_json awaiting_path (envelope_to_json envelope) in
         Ok Staged_awaiting_turn_commit)
;;

let compare_job_order left right =
  let by_turn = Int.compare left.turn right.turn in
  if by_turn <> 0
  then by_turn
  else
    let by_generation = Int.compare left.generation right.generation in
    if by_generation <> 0
    then by_generation
    else
      let by_oas_turn = Int.compare left.oas_turn_count right.oas_turn_count in
      if by_oas_turn <> 0
      then by_oas_turn
      else
        let by_enqueued = Float.compare left.enqueued_at right.enqueued_at in
        if by_enqueued <> 0 then by_enqueued else String.compare left.id right.id
;;

let load_envelopes ~expected_keeper_name ~expected_state paths =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | path :: rest ->
      let* envelope = read_envelope path in
      let* () =
        ensure_queue_coordinates ~expected_keeper_name ~path envelope
      in
      let* () = ensure_expected_state ~expected:expected_state ~path envelope in
      loop ((path, envelope) :: acc) rest
  in
  loop [] paths
;;

let list_awaiting ~base_path ~keeper_name =
  if not (keeper_name_is_valid keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    let* () = ensure_store_dirs ~base_path ~keeper_name in
    let* paths = list_json_paths (awaiting_dir ~base_path ~keeper_name) in
    let* envelopes =
      load_envelopes
        ~expected_keeper_name:keeper_name
        ~expected_state:Expect_awaiting
        paths
    in
    Ok (List.map (fun (_, envelope) -> envelope.job) envelopes)
;;

let activate ~base_path (job : job) =
  let* () = ensure_store_dirs ~base_path ~keeper_name:job.keeper_name in
  let awaiting = awaiting_path ~base_path job in
  let pending = pending_path ~base_path job in
  let inflight = inflight_path ~base_path job in
  let receipt = receipt_path ~base_path job in
  let operation =
    operation_stage_path
      ~base_path
      ~keeper_name:job.keeper_name
      ~operation_id:job.id
  in
  let* receipt_exists = file_exists receipt in
  if receipt_exists
  then
    let* terminal = read_receipt receipt in
    if not (receipt_identity_matches_retry terminal.identity job)
    then Error (Identity_conflict { job_id = job.id; path = receipt })
    else
      let cleanup_errors = cleanup_paths [ awaiting; pending; inflight; operation ] in
      Ok (Activation_already_completed, { cleanup_errors })
  else
    let* pending_state =
      classify_existing_envelope
        ~expected_job:job
        ~expected_state:Expect_pending
        ~path:pending
        Activation_already_pending
    in
    (match pending_state with
     | Some activation ->
       let cleanup_errors = cleanup_paths [ awaiting ] in
       Ok (activation, { cleanup_errors })
     | None ->
       let* inflight_state =
         classify_existing_envelope
           ~expected_job:job
           ~expected_state:Expect_inflight
           ~path:inflight
           Activation_already_inflight
       in
       (match inflight_state with
        | Some activation ->
          let cleanup_errors = cleanup_paths [ awaiting ] in
          Ok (activation, { cleanup_errors })
        | None ->
          let* awaiting_exists = file_exists awaiting in
          if not awaiting_exists
          then
            Error
              (Decode_error
                 { path = awaiting
                 ; detail =
                     "cannot activate a memory job without its awaiting-turn-commit envelope"
                 })
          else
            let* envelope = read_envelope awaiting in
            let* () =
              ensure_queue_coordinates
                ~expected_keeper_name:job.keeper_name
                ~path:awaiting
                envelope
            in
            let* () = ensure_same_job ~expected:job ~path:awaiting envelope in
            let* () =
              ensure_expected_state
                ~expected:Expect_awaiting
                ~path:awaiting
                envelope
            in
            let* () =
              save_json
                pending
                (envelope_to_json
                   { job = envelope.job
                   ; state = Pending
                   })
            in
            let cleanup_errors = cleanup_paths [ awaiting ] in
            Ok (Activated, { cleanup_errors })))
;;

let abort_awaiting ~base_path (job : job) =
  let* () = ensure_store_dirs ~base_path ~keeper_name:job.keeper_name in
  let path = awaiting_path ~base_path job in
  let* exists = file_exists path in
  if not exists
  then Ok ()
  else
    let* envelope = read_envelope path in
    let* () =
      ensure_queue_coordinates
        ~expected_keeper_name:job.keeper_name
        ~path
        envelope
    in
    let* () = ensure_same_job ~expected:job ~path envelope in
    let* () =
      ensure_expected_state ~expected:Expect_awaiting ~path envelope
    in
    remove_if_exists path
;;

let recover_one ~base_path (inflight_path, envelope) =
  match envelope.state with
  | Awaiting_turn_commit | Pending ->
    Error
      (Decode_error
         { path = inflight_path
         ; detail = "inflight directory contains a pending envelope"
         })
  | Inflight { started_at } ->
    let job = envelope.job in
    let receipt_path = receipt_path ~base_path job in
    let* receipt_exists = file_exists receipt_path in
    if receipt_exists
    then
      let* receipt = read_receipt receipt_path in
      if not (receipt_identity_matches_job receipt.identity job)
      then Error (Identity_conflict { job_id = job.id; path = receipt_path })
      else if not (Float.equal receipt.started_at started_at)
      then
        Error
          (Inflight_lease_conflict
             { job_id = job.id
             ; path = inflight_path
             ; expected_started_at = receipt.started_at
             ; actual_started_at = started_at
             })
      else
        let cleanup_errors =
          cleanup_paths
            [ operation_stage_path
                ~base_path
                ~keeper_name:job.keeper_name
                ~operation_id:job.id
            ; awaiting_path ~base_path job
            ; pending_path ~base_path job
            ; inflight_path
            ]
        in
        Ok (false, cleanup_errors)
    else
      let pending_path = pending_path ~base_path job in
      let* pending_exists = file_exists pending_path in
      let* () =
        if pending_exists
        then
          let* pending = read_envelope pending_path in
          let* () = ensure_same_job ~expected:job ~path:pending_path pending in
          ensure_expected_state
            ~expected:Expect_pending
            ~path:pending_path
            pending
        else save_json pending_path (envelope_to_json { job; state = Pending })
      in
      let cleanup_errors = cleanup_paths [ inflight_path ] in
      Ok (true, cleanup_errors)
;;

let recover_inflight ~base_path ~keeper_name =
  if not (keeper_name_is_valid keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    let* () = ensure_store_dirs ~base_path ~keeper_name in
    let* () =
      reconcile_atomic_orphans_in_dir
        (receipts_dir ~base_path ~keeper_name)
    in
    let* () =
      reconcile_atomic_orphans_in_dir
        (operations_dir ~base_path ~keeper_name)
    in
    let dir = inflight_dir ~base_path ~keeper_name in
    let* paths = list_json_paths dir in
    let* envelopes =
      load_envelopes
        ~expected_keeper_name:keeper_name
        ~expected_state:Expect_inflight
        paths
    in
    let rec loop replayed cleanup_errors = function
      | [] -> Ok { replayed; cleanup_errors = List.rev cleanup_errors }
      | item :: rest ->
        let* did_recover, item_cleanup_errors = recover_one ~base_path item in
        loop
          (if did_recover then replayed + 1 else replayed)
          (List.rev_append item_cleanup_errors cleanup_errors)
          rest
    in
    loop 0 [] envelopes
;;

let claim_all ~base_path ~keeper_name ~now =
  if not (keeper_name_is_valid keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else if (not (Float.is_finite now)) || now < 0.0
  then Error (Invalid_claim_time now)
  else
    let* () = ensure_store_dirs ~base_path ~keeper_name in
    let dir = pending_dir ~base_path ~keeper_name in
    let* paths = list_json_paths dir in
    let* envelopes =
      load_envelopes
        ~expected_keeper_name:keeper_name
        ~expected_state:Expect_pending
        paths
    in
    let ordered =
      envelopes
      |> List.map (fun (path, envelope) -> path, envelope.job)
      |> List.sort (fun (_, left) (_, right) -> compare_job_order left right)
    in
    let process_item path job =
      let receipt_path = receipt_path ~base_path job in
      let* receipt_exists = file_exists receipt_path in
      if receipt_exists
      then
        let* receipt = read_receipt receipt_path in
        if not (receipt_identity_matches_job receipt.identity job)
        then Error (Identity_conflict { job_id = job.id; path = receipt_path })
        else
          Ok
            (`Skipped
              (cleanup_paths
                 [ path
                 ; awaiting_path ~base_path job
                 ; inflight_path ~base_path job
                 ; operation_stage_path
                     ~base_path
                     ~keeper_name:job.keeper_name
                     ~operation_id:job.id
                 ]))
      else
        let lease = { job; started_at = now } in
        let destination = inflight_path ~base_path job in
        let* inflight_exists = file_exists destination in
        if inflight_exists
        then
          let* inflight = read_envelope destination in
          let* () =
            ensure_queue_coordinates
              ~expected_keeper_name:keeper_name
              ~path:destination
              inflight
          in
          let* () = ensure_same_job ~expected:job ~path:destination inflight in
          let* () =
            ensure_expected_state
              ~expected:Expect_inflight
              ~path:destination
              inflight
          in
          Error
            (Pending_already_inflight
               { job_id = job.id
               ; pending_path = path
               ; inflight_path = destination
               })
        else
          let* () =
            save_json
              destination
              (envelope_to_json
                 { job
                 ; state = Inflight { started_at = lease.started_at }
                 })
          in
          Ok (`Claimed (lease, cleanup_paths [ path ]))
    in
    let rec claim leases cleanup_errors = function
      | [] ->
        Ok
          { leases = List.rev leases
          ; cleanup_errors = List.rev cleanup_errors
          ; blocked = None
          }
      | (path, job) :: rest ->
        (match process_item path job with
         | Error error ->
           Ok
             { leases = List.rev leases
             ; cleanup_errors = List.rev cleanup_errors
             ; blocked = Some error
             }
         | Ok (`Skipped item_cleanup_errors) ->
           claim
             leases
             (List.rev_append item_cleanup_errors cleanup_errors)
             rest
         | Ok (`Claimed (lease, item_cleanup_errors)) ->
           claim
             (lease :: leases)
             (List.rev_append item_cleanup_errors cleanup_errors)
             rest)
    in
    claim [] [] ordered
;;

let finish ~base_path (receipt : terminal_receipt) =
  let identity = receipt.identity in
  let* () = ensure_store_dirs ~base_path ~keeper_name:identity.keeper_name in
  let path = receipt_path_for_identity ~base_path identity in
  let operation =
    operation_stage_path
      ~base_path
      ~keeper_name:identity.keeper_name
      ~operation_id:identity.id
  in
  let awaiting =
    path_for_id
      (awaiting_dir ~base_path ~keeper_name:identity.keeper_name)
      identity.id
  in
  let pending =
    path_for_id
      (pending_dir ~base_path ~keeper_name:identity.keeper_name)
      identity.id
  in
  let inflight =
    path_for_id
      (inflight_dir ~base_path ~keeper_name:identity.keeper_name)
      identity.id
  in
  let* exists = file_exists path in
  let* () =
    if exists
    then
      let* current = read_receipt path in
      if receipt_identity_equal current.identity identity
         && current.outcome = receipt.outcome
         && Float.equal current.started_at receipt.started_at
         && Float.equal current.ended_at receipt.ended_at
         && String.equal
              (payload_sha256 current.detail)
              (payload_sha256 receipt.detail)
      then Ok ()
      else Error (Identity_conflict { job_id = identity.id; path })
    else
      let* inflight_exists = file_exists inflight in
      if not inflight_exists
      then Error (Missing_inflight_lease { job_id = identity.id; path = inflight })
      else
        let* envelope = read_envelope inflight in
        let* () =
          ensure_queue_coordinates
            ~expected_keeper_name:identity.keeper_name
            ~path:inflight
            envelope
        in
        let* () = ensure_expected_state ~expected:Expect_inflight ~path:inflight envelope in
        if not (receipt_identity_matches_job identity envelope.job)
        then Error (Identity_conflict { job_id = identity.id; path = inflight })
        else
          (match envelope.state with
           | Awaiting_turn_commit | Pending ->
             Error
               (Missing_inflight_lease
                  { job_id = identity.id
                  ; path = inflight
                  })
           | Inflight { started_at } ->
             if not (Float.equal started_at receipt.started_at)
             then
               Error
                 (Inflight_lease_conflict
                    { job_id = identity.id
                    ; path = inflight
                    ; expected_started_at = receipt.started_at
                    ; actual_started_at = started_at
                    })
             else save_json path (receipt_to_json receipt))
  in
  let cleanup_errors = cleanup_paths [ operation; awaiting; pending; inflight ] in
  Ok { cleanup_errors }
;;

let backlog_count ~base_path ~keeper_name =
  if not (keeper_name_is_valid keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    let* ancestors_exist =
      validate_keeper_ancestors_if_present ~base_path ~keeper_name
    in
    if not ancestors_exist
    then Ok 0
    else
      let* awaiting = list_json_paths (awaiting_dir ~base_path ~keeper_name) in
      let* pending = list_json_paths (pending_dir ~base_path ~keeper_name) in
      let* inflight = list_json_paths (inflight_dir ~base_path ~keeper_name) in
      let* awaiting_envelopes =
        load_envelopes
          ~expected_keeper_name:keeper_name
          ~expected_state:Expect_awaiting
          awaiting
      in
      let* pending_envelopes =
        load_envelopes
          ~expected_keeper_name:keeper_name
          ~expected_state:Expect_pending
          pending
      in
      let* inflight_envelopes =
        load_envelopes
          ~expected_keeper_name:keeper_name
          ~expected_state:Expect_inflight
          inflight
      in
      Ok
        (List.length awaiting_envelopes
         + List.length pending_envelopes
         + List.length inflight_envelopes)
;;

let directory_exists path =
  let* exists = file_exists path in
  if not exists
  then Ok false
  else
    let* is_directory =
      protect_io Inspect path (fun () ->
        (Unix.lstat path).Unix.st_kind = Unix.S_DIR)
    in
    if is_directory
    then Ok true
    else
      Error
        (Io_error
           { operation = Inspect
           ; path
           ; detail = "expected a directory but found a non-directory entry"
           })
;;

let discover_keeper_names ~base_path =
  let root = Common.keepers_runtime_dir_of_base ~base_path in
  let* root_exists = validate_managed_root_if_present ~base_path in
  if not root_exists
  then Ok ([], [])
  else
    let* entries =
      protect_io List_directory root (fun () -> Sys.readdir root |> Array.to_list)
    in
    let rec loop keepers errors = function
      | [] ->
        Ok
          ( List.sort_uniq String.compare keepers
          , List.rev errors )
      | keeper_name :: rest ->
        if not (keeper_name_is_valid keeper_name)
        then loop keepers (Invalid_keeper_name keeper_name :: errors) rest
        else
          let keeper_dir = Filename.concat root keeper_name in
          let jobs_dir = keeper_jobs_dir ~base_path ~keeper_name in
          (match directory_exists keeper_dir with
           | Error error -> loop keepers (error :: errors) rest
           | Ok false -> loop keepers errors rest
           | Ok true ->
             (match directory_exists jobs_dir with
              | Error error -> loop keepers (error :: errors) rest
              | Ok false -> loop keepers errors rest
              | Ok true ->
                (match backlog_count ~base_path ~keeper_name with
                 | Error error -> loop keepers (error :: errors) rest
                 | Ok count ->
                   loop
                     (if count > 0 then keeper_name :: keepers else keepers)
                     errors
                     rest)))
    in
    loop [] [] entries
;;

module For_testing = struct
  let awaiting_dir = awaiting_dir
  let pending_dir = pending_dir
  let inflight_dir = inflight_dir
  let receipts_dir = receipts_dir
  let receipt_path = receipt_path
end
