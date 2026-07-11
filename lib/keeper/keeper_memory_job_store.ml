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

module Anchored = Fs_compat.Anchored_dir

type anchored_directory =
  { handle : Anchored.t
  ; path : string
  }

type store_directories =
  { jobs : anchored_directory
  ; awaiting : anchored_directory
  ; pending : anchored_directory
  ; inflight : anchored_directory
  ; receipts : anchored_directory
  ; operations : anchored_directory
  }

type artifact =
  { directory : anchored_directory
  ; name : Anchored.Segment.t
  ; path : string
  }

let child_name ~parent path =
  if String.equal (Filename.dirname path) parent
  then
    let raw = Filename.basename path in
    (match Anchored.Segment.of_string raw with
     | Ok segment -> Ok segment
     | Error error ->
       Error
         (Io_error
            { operation = Inspect
            ; path
            ; detail = Anchored.Segment.error_to_string error
            }))
  else
    Error
      (Io_error
         { operation = Inspect
         ; path
         ; detail =
             Printf.sprintf
               "memory job path is not a direct child of its SSOT parent %s"
               parent
         })
;;

let with_directory ~owned parent path f =
  let* name = child_name ~parent:parent.path path in
  let permission = if owned then private_directory_mode else 0o755 in
  try
    Anchored.with_ensure_dir
      parent.handle
      ~name
      ~perm:permission
      ~enforce_perm:owned
      (fun handle -> f { handle; path })
  with
  | Unix.Unix_error ((Unix.ELOOP | Unix.ENOTDIR), _, _) as exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path
         ; detail = Printexc.to_string exn
         })
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Io_error
         { operation = Ensure_directory
         ; path
         ; detail = Printexc.to_string exn
         })
;;

let with_ensured_store ~base_path ~keeper_name f =
  let masc_path = Common.masc_dir_from_base_path ~base_path in
  let keepers_path = Common.keepers_runtime_dir_of_base ~base_path in
  let keeper_path = Filename.concat keepers_path keeper_name in
  let jobs_path = keeper_jobs_dir ~base_path ~keeper_name in
  let awaiting_path = awaiting_dir ~base_path ~keeper_name in
  let pending_path = pending_dir ~base_path ~keeper_name in
  let inflight_path = inflight_dir ~base_path ~keeper_name in
  let receipts_path = receipts_dir ~base_path ~keeper_name in
  let operations_path = operations_dir ~base_path ~keeper_name in
  let* masc_name = child_name ~parent:base_path masc_path in
  let* keepers_name = child_name ~parent:masc_path keepers_path in
  let* keeper_name_segment = child_name ~parent:keepers_path keeper_path in
  let* jobs_name = child_name ~parent:keeper_path jobs_path in
  let steps : Anchored.ensure_step list =
    [ { name = masc_name; perm = 0o755; enforce_perm = false }
    ; { name = keepers_name; perm = 0o755; enforce_perm = false }
    ; { name = keeper_name_segment; perm = 0o755; enforce_perm = false }
    ; { name = jobs_name
      ; perm = private_directory_mode
      ; enforce_perm = true
      }
    ]
  in
  try
    Anchored.with_ensure_path ~root:base_path steps @@ fun handle ->
    let jobs = { handle; path = jobs_path } in
    with_directory ~owned:true jobs awaiting_path @@ fun awaiting ->
    with_directory ~owned:true jobs pending_path @@ fun pending ->
    with_directory ~owned:true jobs inflight_path @@ fun inflight ->
    with_directory ~owned:true jobs receipts_path @@ fun receipts ->
    with_directory ~owned:true jobs operations_path @@ fun operations ->
    f { jobs; awaiting; pending; inflight; receipts; operations }
  with
  | Unix.Unix_error ((Unix.ELOOP | Unix.ENOTDIR), _, _) as exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path = jobs_path
         ; detail = Printexc.to_string exn
         })
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Io_error
         { operation = Ensure_directory
         ; path = jobs_path
         ; detail = Printexc.to_string exn
         })
;;

type 'a presence =
  | Missing
  | Present of 'a

type existing_jobs = { jobs : anchored_directory }

let with_existing_directory parent path f =
  let* name = child_name ~parent:parent.path path in
  try
    match
      Anchored.with_open_dir_opt parent.handle name (fun handle ->
        f { handle; path })
    with
    | None -> Ok Missing
    | Some result -> result
  with
  | Unix.Unix_error ((Unix.ELOOP | Unix.ENOTDIR), _, _) as exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path
         ; detail = Printexc.to_string exn
         })
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path
         ; detail = Printexc.to_string exn
         })
;;

let with_optional_directory parent path f =
  let* presence =
    with_existing_directory parent path (fun directory ->
      let* value = f directory in
      Ok (Present value))
  in
  match presence with
  | Missing -> Ok None
  | Present value -> Ok (Some value)
;;

let with_existing_jobs ~base_path ~keeper_name f =
  let masc_path = Common.masc_dir_from_base_path ~base_path in
  let keepers_path = Common.keepers_runtime_dir_of_base ~base_path in
  let keeper_path = Filename.concat keepers_path keeper_name in
  let jobs_path = keeper_jobs_dir ~base_path ~keeper_name in
  let* masc_name = child_name ~parent:base_path masc_path in
  let* keepers_name = child_name ~parent:masc_path keepers_path in
  let* keeper_name_segment = child_name ~parent:keepers_path keeper_path in
  let* jobs_name = child_name ~parent:keeper_path jobs_path in
  try
    match
      Anchored.with_open_path_opt
        ~root:base_path
        [ masc_name; keepers_name; keeper_name_segment; jobs_name ]
        (fun handle ->
           let* value = f { jobs = { handle; path = jobs_path } } in
           Ok (Present value))
    with
    | None -> Ok Missing
    | Some result -> result
  with
  | Unix.Unix_error ((Unix.ELOOP | Unix.ENOTDIR), _, _) as exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path = jobs_path
         ; detail = Printexc.to_string exn
         })
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Io_error
         { operation = Inspect
         ; path = jobs_path
         ; detail = Printexc.to_string exn
         })
;;

let artifact_from_segment directory name =
  let raw_name = Anchored.Segment.to_string name in
  { directory
  ; name
  ; path = Filename.concat directory.path raw_name
  }
;;

let artifact directory raw_name =
  let name =
    match Anchored.Segment.of_string raw_name with
    | Ok segment -> segment
    | Error error ->
      invalid_arg
        (Printf.sprintf
           "invalid memory job artifact name %S: %s"
           raw_name
           (Anchored.Segment.error_to_string error))
  in
  artifact_from_segment directory name
;;

let artifact_for_id directory id = artifact directory (id ^ json_suffix)

let awaiting_artifact store (job : job) =
  artifact_for_id store.awaiting job.id
;;

let pending_artifact store (job : job) =
  artifact_for_id store.pending job.id
;;

let inflight_artifact store (job : job) =
  artifact_for_id store.inflight job.id
;;

let receipt_artifact store (job : job) =
  artifact_for_id store.receipts job.id
;;

let receipt_artifact_for_identity store (identity : receipt_identity) =
  artifact_for_id store.receipts identity.id
;;

let operation_artifact store operation_id =
  artifact_for_id store.operations operation_id
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

let make_terminal_receipt (lease : lease) ~ended_at ~outcome ~detail =
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

let inspect_artifact item =
  protect_io Inspect item.path (fun () ->
    Anchored.stat item.directory.handle item.name)
;;

let read_json_opt item =
  let content =
    try Ok (Anchored.read_file_opt item.directory.handle item.name) with
    | Unix.Unix_error ((Unix.ELOOP | Unix.EISDIR), _, _) as exn ->
      Error
        (Io_error
           { operation = Inspect
           ; path = item.path
           ; detail = Printexc.to_string exn
           })
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Io_error
           { operation = Read
           ; path = item.path
           ; detail = Printexc.to_string exn
           })
  in
  let* content = content in
  match content with
  | None -> Ok None
  | Some content ->
    (match Safe_ops.parse_json_safe ~context:item.path content with
     | Ok json -> Ok (Some json)
     | Error detail ->
       Error (Io_error { operation = Read; path = item.path; detail }))
;;

let read_json item =
  let* json = read_json_opt item in
  match json with
  | Some json -> Ok json
  | None ->
    Error
      (Io_error
         { operation = Read
         ; path = item.path
         ; detail = "memory job artifact does not exist"
         })
;;

let read_envelope item =
  let* json = read_json item in
  envelope_of_json json
  |> Result.map_error (fun detail -> Decode_error { path = item.path; detail })
;;

let read_envelope_opt item =
  let* json = read_json_opt item in
  match json with
  | None -> Ok None
  | Some json ->
    envelope_of_json json
    |> Result.map Option.some
    |> Result.map_error (fun detail ->
      Decode_error { path = item.path; detail })
;;

let read_receipt item =
  let* json = read_json item in
  receipt_of_json json
  |> Result.map_error (fun detail -> Decode_error { path = item.path; detail })
;;

let read_receipt_opt item =
  let* json = read_json_opt item in
  match json with
  | None -> Ok None
  | Some json ->
    receipt_of_json json
    |> Result.map Option.some
    |> Result.map_error (fun detail ->
      Decode_error { path = item.path; detail })
;;

let save_json item json =
  match
    Anchored.atomic_replace
      item.directory.handle
      ~name:item.name
      ~perm:private_file_mode
      (Yojson.Safe.pretty_to_string json)
  with
  | Ok () -> Ok ()
  | Error error ->
    Error
      (Io_error
         { operation = Write
         ; path = item.path
         ; detail = Anchored.mutation_error_to_string error
         })
;;

let remove_if_exists item =
  match Anchored.unlink_if_exists item.directory.handle item.name with
  | Ok (`Missing | `Removed) -> Ok ()
  | Error error ->
    Error
      (Io_error
         { operation = Remove
         ; path = item.path
         ; detail = Anchored.mutation_error_to_string error
         })
;;

let remove_required item =
  match Anchored.unlink_if_exists item.directory.handle item.name with
  | Ok `Removed -> Ok ()
  | Ok `Missing ->
    Error
      (Io_error
         { operation = Remove
         ; path = item.path
         ; detail = "required memory job artifact disappeared before unlink"
         })
  | Error error ->
    Error
      (Io_error
         { operation = Remove
         ; path = item.path
         ; detail = Anchored.mutation_error_to_string error
         })
;;

let cleanup_artifacts items =
  List.fold_left
    (fun errors item ->
       match remove_if_exists item with
       | Ok () -> errors
       | Error error -> error :: errors)
    []
    items
  |> List.rev
;;

let require_same_regular_identity ~source ~destination expected = function
  | Some ({ Anchored.kind = Regular_file; _ } as actual)
    when Anchored.same_identity expected actual -> Ok ()
  | Some _ ->
    Error
      (Io_error
         { operation = Inspect
         ; path = destination
         ; detail =
             Printf.sprintf
               "atomic orphan destination conflicts with source %s"
               source
         })
  | None ->
    Error
      (Io_error
         { operation = Inspect
         ; path = destination
         ; detail = "atomic orphan destination disappeared"
         })
;;

let reconcile_atomic_orphan ~jobs directory name =
  let source = artifact_from_segment directory name in
  let* inspected = inspect_artifact source in
  match inspected with
  | None ->
    Error
      (Io_error
         { operation = Inspect
         ; path = source.path
         ; detail = "atomic orphan disappeared during reconciliation"
         })
  | Some { Anchored.kind = Regular_file; size = 0L; _ } ->
    let* () = remove_required source in
    Log.Keeper.warn
      "memory job queue removed zero-length atomic orphan path=%s"
      source.path;
    Ok ()
  | Some ({ Anchored.kind = Regular_file; _ } as source_identity) ->
    let* synced_identity =
      protect_io Sync source.path (fun () ->
        Anchored.fsync_file directory.handle name)
    in
    let* () =
      if Anchored.same_identity source_identity synced_identity
      then Ok ()
      else
        Error
          (Io_error
             { operation = Inspect
             ; path = source.path
             ; detail = "atomic orphan changed while it was being synced"
             })
    in
    let bucket_name = Filename.basename directory.path in
    let recovered_path =
      Filename.concat jobs.path recovered_atomic_writes_dirname
    in
    with_directory ~owned:true jobs recovered_path @@ fun recovered ->
    let bucket_path = Filename.concat recovered.path bucket_name in
    with_directory ~owned:true recovered bucket_path @@ fun bucket ->
    let destination = artifact_from_segment bucket name in
    let* destination_before = inspect_artifact destination in
    let* () =
      match destination_before with
      | Some _ ->
        require_same_regular_identity
          ~source:source.path
          ~destination:destination.path
          synced_identity
          destination_before
      | None ->
        let link_result =
          match
            Anchored.link_no_replace
              ~src_dir:directory.handle
              ~src:name
              ~dst_dir:bucket.handle
              ~dst:name
          with
          | Ok () -> Ok ()
          | Error
              (Anchored.Not_committed
                 { cause = Unix.Unix_error (Unix.EEXIST, _, _)
                 ; cleanup_error = None
                 }) -> Ok ()
          | Error error ->
            Error
              (Io_error
                 { operation = Write
                 ; path = destination.path
                 ; detail = Anchored.mutation_error_to_string error
                 })
        in
        let* () = link_result in
        let* destination_after = inspect_artifact destination in
        require_same_regular_identity
          ~source:source.path
          ~destination:destination.path
          synced_identity
          destination_after
    in
    let* source_before_unlink = inspect_artifact source in
    let* () =
      require_same_regular_identity
        ~source:source.path
        ~destination:source.path
        synced_identity
        source_before_unlink
    in
    let* () = remove_required source in
    let* () =
      protect_io Set_permissions destination.path (fun () ->
        Anchored.chmod_file bucket.handle name private_file_mode)
    in
    Log.Keeper.error
      "memory job queue preserved non-empty atomic orphan source=%s destination=%s"
      source.path
      destination.path;
    Ok ()
  | Some _ ->
    Error
      (Io_error
         { operation = Inspect
         ; path = source.path
         ; detail = "atomic orphan is not a regular file"
         })
;;

let list_json_artifacts ~jobs directory =
  let* entries =
    protect_io List_directory directory.path (fun () ->
      Anchored.read_dir directory.handle)
  in
  let rec validate acc = function
    | [] -> Ok (List.rev acc)
    | name :: rest ->
      let raw_name = Anchored.Segment.to_string name in
      let item = artifact_from_segment directory name in
      if Filename.check_suffix raw_name json_suffix
      then validate (item :: acc) rest
      else if Fs_compat.is_atomic_orphan_name raw_name
      then
        let* () = reconcile_atomic_orphan ~jobs directory name in
        validate acc rest
      else Error (Unexpected_queue_entry item.path)
  in
  validate [] entries
;;

let reconcile_atomic_orphans_in_dir ~jobs directory =
  let* entries =
    protect_io List_directory directory.path (fun () ->
      Anchored.read_dir directory.handle)
  in
  let rec loop = function
    | [] -> Ok ()
    | name :: rest ->
      if
        Fs_compat.is_atomic_orphan_name
          (Anchored.Segment.to_string name)
      then
        let* () = reconcile_atomic_orphan ~jobs directory name in
        loop rest
      else loop rest
  in
  loop entries
;;

let job_equal (left : job) (right : job) =
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

let classify_existing_envelope ~expected_job ~expected_state ~item outcome =
  let* envelope = read_envelope_opt item in
  match envelope with
  | None -> Ok None
  | Some envelope ->
    let* () =
      ensure_queue_coordinates
        ~expected_keeper_name:expected_job.keeper_name
        ~path:item.path
        envelope
    in
    let* () = ensure_same_job ~expected:expected_job ~path:item.path envelope in
    let* () =
      ensure_expected_state ~expected:expected_state ~path:item.path envelope
    in
    Ok (Some outcome)
;;

let stage_awaiting_turn_commit ~base_path job =
  with_ensured_store ~base_path ~keeper_name:job.keeper_name @@ fun store ->
  let receipt_item = receipt_artifact store job in
  let* existing_receipt = read_receipt_opt receipt_item in
  match existing_receipt with
  | Some receipt ->
    if receipt_identity_matches_retry receipt.identity job
    then
      let cleanup_errors =
        cleanup_artifacts
          [ awaiting_artifact store job
          ; pending_artifact store job
          ; inflight_artifact store job
          ; operation_artifact store job.id
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
    else
      Error
        (Identity_conflict { job_id = job.id; path = receipt_item.path })
  | None ->
    let awaiting_item = awaiting_artifact store job in
    let pending_item = pending_artifact store job in
    let inflight_item = inflight_artifact store job in
    let* awaiting =
      classify_existing_envelope
        ~expected_job:job
        ~expected_state:Expect_awaiting
        ~item:awaiting_item
        Already_awaiting
    in
    match awaiting with
    | Some outcome -> Ok outcome
    | None ->
    let* pending =
      classify_existing_envelope
        ~expected_job:job
        ~expected_state:Expect_pending
        ~item:pending_item
        Already_pending
    in
    match pending with
    | Some outcome -> Ok outcome
    | None ->
      let* inflight =
        classify_existing_envelope
          ~expected_job:job
          ~expected_state:Expect_inflight
          ~item:inflight_item
          Already_inflight
      in
      (match inflight with
       | Some outcome -> Ok outcome
       | None ->
         let envelope = { job; state = Awaiting_turn_commit } in
         let* () = save_json awaiting_item (envelope_to_json envelope) in
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

let load_envelopes ~expected_keeper_name ~expected_state items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* envelope = read_envelope item in
      let* () =
        ensure_queue_coordinates
          ~expected_keeper_name
          ~path:item.path
          envelope
      in
      let* () =
        ensure_expected_state
          ~expected:expected_state
          ~path:item.path
          envelope
      in
      loop ((item, envelope) :: acc) rest
  in
  loop [] items
;;

let list_awaiting ~base_path ~keeper_name =
  if not (keeper_name_is_valid keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    with_ensured_store ~base_path ~keeper_name @@ fun store ->
    let* items = list_json_artifacts ~jobs:store.jobs store.awaiting in
    let* envelopes =
      load_envelopes
        ~expected_keeper_name:keeper_name
        ~expected_state:Expect_awaiting
        items
    in
    Ok (List.map (fun (_, envelope) -> envelope.job) envelopes)
;;

let activate ~base_path (job : job) =
  with_ensured_store ~base_path ~keeper_name:job.keeper_name @@ fun store ->
  let awaiting = awaiting_artifact store job in
  let pending = pending_artifact store job in
  let inflight = inflight_artifact store job in
  let receipt = receipt_artifact store job in
  let operation = operation_artifact store job.id in
  let* terminal = read_receipt_opt receipt in
  match terminal with
  | Some terminal ->
    if not (receipt_identity_matches_retry terminal.identity job)
    then Error (Identity_conflict { job_id = job.id; path = receipt.path })
    else
      let cleanup_errors =
        cleanup_artifacts [ awaiting; pending; inflight; operation ]
      in
      Ok (Activation_already_completed, { cleanup_errors })
  | None ->
    let* pending_state =
      classify_existing_envelope
        ~expected_job:job
        ~expected_state:Expect_pending
        ~item:pending
        Activation_already_pending
    in
    (match pending_state with
     | Some activation ->
       let cleanup_errors = cleanup_artifacts [ awaiting ] in
       Ok (activation, { cleanup_errors })
     | None ->
       let* inflight_state =
         classify_existing_envelope
           ~expected_job:job
           ~expected_state:Expect_inflight
           ~item:inflight
           Activation_already_inflight
       in
       (match inflight_state with
        | Some activation ->
          let cleanup_errors = cleanup_artifacts [ awaiting ] in
          Ok (activation, { cleanup_errors })
        | None ->
          let* awaiting_envelope = read_envelope_opt awaiting in
          (match awaiting_envelope with
           | None ->
            Error
              (Decode_error
                 { path = awaiting.path
                 ; detail =
                     "cannot activate a memory job without its awaiting-turn-commit envelope"
                 })
           | Some envelope ->
            let* () =
              ensure_queue_coordinates
                ~expected_keeper_name:job.keeper_name
                ~path:awaiting.path
                envelope
            in
            let* () =
              ensure_same_job ~expected:job ~path:awaiting.path envelope
            in
            let* () =
              ensure_expected_state
                ~expected:Expect_awaiting
                ~path:awaiting.path
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
            let cleanup_errors = cleanup_artifacts [ awaiting ] in
            Ok (Activated, { cleanup_errors }))))
;;

let abort_awaiting ~base_path (job : job) =
  with_ensured_store ~base_path ~keeper_name:job.keeper_name @@ fun store ->
  let item = awaiting_artifact store job in
  let* envelope = read_envelope_opt item in
  match envelope with
  | None -> Ok ()
  | Some envelope ->
    let* () =
      ensure_queue_coordinates
        ~expected_keeper_name:job.keeper_name
        ~path:item.path
        envelope
    in
    let* () = ensure_same_job ~expected:job ~path:item.path envelope in
    let* () =
      ensure_expected_state ~expected:Expect_awaiting ~path:item.path envelope
    in
    remove_if_exists item
;;

let recover_one store (inflight_item, envelope) =
  match envelope.state with
  | Awaiting_turn_commit | Pending ->
    Error
      (Decode_error
         { path = inflight_item.path
         ; detail = "inflight directory contains a pending envelope"
         })
  | Inflight { started_at } ->
    let job = envelope.job in
    let receipt_item = receipt_artifact store job in
    let* receipt = read_receipt_opt receipt_item in
    (match receipt with
     | Some receipt ->
      if not (receipt_identity_matches_job receipt.identity job)
      then
        Error
          (Identity_conflict { job_id = job.id; path = receipt_item.path })
      else if not (Float.equal receipt.started_at started_at)
      then
        Error
          (Inflight_lease_conflict
             { job_id = job.id
             ; path = inflight_item.path
             ; expected_started_at = receipt.started_at
             ; actual_started_at = started_at
             })
      else
        let cleanup_errors =
          cleanup_artifacts
            [ operation_artifact store job.id
            ; awaiting_artifact store job
            ; pending_artifact store job
            ; inflight_item
            ]
        in
        Ok (false, cleanup_errors)
     | None ->
      let pending_item = pending_artifact store job in
      let* pending = read_envelope_opt pending_item in
      let* () =
        match pending with
        | Some pending ->
          let* () =
            ensure_same_job ~expected:job ~path:pending_item.path pending
          in
          ensure_expected_state
            ~expected:Expect_pending
            ~path:pending_item.path
            pending
        | None -> save_json pending_item (envelope_to_json { job; state = Pending })
      in
      let cleanup_errors = cleanup_artifacts [ inflight_item ] in
      Ok (true, cleanup_errors))
;;

let recover_inflight ~base_path ~keeper_name =
  if not (keeper_name_is_valid keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    with_ensured_store ~base_path ~keeper_name @@ fun store ->
    let* () =
      reconcile_atomic_orphans_in_dir ~jobs:store.jobs store.receipts
    in
    let* () =
      reconcile_atomic_orphans_in_dir ~jobs:store.jobs store.operations
    in
    let* items = list_json_artifacts ~jobs:store.jobs store.inflight in
    let* envelopes =
      load_envelopes
        ~expected_keeper_name:keeper_name
        ~expected_state:Expect_inflight
        items
    in
    let rec loop replayed cleanup_errors = function
      | [] -> Ok { replayed; cleanup_errors = List.rev cleanup_errors }
      | item :: rest ->
        let* did_recover, item_cleanup_errors = recover_one store item in
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
    with_ensured_store ~base_path ~keeper_name @@ fun store ->
    let* items = list_json_artifacts ~jobs:store.jobs store.pending in
    let* envelopes =
      load_envelopes
        ~expected_keeper_name:keeper_name
        ~expected_state:Expect_pending
        items
    in
    let ordered =
      envelopes
      |> List.map (fun (item, envelope) -> item, envelope.job)
      |> List.sort (fun (_, left) (_, right) -> compare_job_order left right)
    in
    let process_item item job =
      let receipt_item = receipt_artifact store job in
      let* receipt = read_receipt_opt receipt_item in
      match receipt with
      | Some receipt ->
        if not (receipt_identity_matches_job receipt.identity job)
        then
          Error
            (Identity_conflict { job_id = job.id; path = receipt_item.path })
        else
          Ok
            (`Skipped
              (cleanup_artifacts
                 [ item
                 ; awaiting_artifact store job
                 ; inflight_artifact store job
                 ; operation_artifact store job.id
                 ]))
      | None ->
        let lease = { job; started_at = now } in
        let destination = inflight_artifact store job in
        let* inflight = read_envelope_opt destination in
        (match inflight with
         | Some inflight ->
          let* () =
            ensure_queue_coordinates
              ~expected_keeper_name:keeper_name
              ~path:destination.path
              inflight
          in
          let* () =
            ensure_same_job ~expected:job ~path:destination.path inflight
          in
          let* () =
            ensure_expected_state
              ~expected:Expect_inflight
              ~path:destination.path
              inflight
          in
          Error
            (Pending_already_inflight
               { job_id = job.id
               ; pending_path = item.path
               ; inflight_path = destination.path
               })
         | None ->
          let* () =
            save_json
              destination
              (envelope_to_json
                 { job
                 ; state = Inflight { started_at = lease.started_at }
                 })
          in
          Ok (`Claimed (lease, cleanup_artifacts [ item ])))
    in
    let rec claim leases cleanup_errors = function
      | [] ->
        Ok
          { leases = List.rev leases
          ; cleanup_errors = List.rev cleanup_errors
          ; blocked = None
          }
      | (item, job) :: rest ->
        (match process_item item job with
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
  with_ensured_store ~base_path ~keeper_name:identity.keeper_name @@ fun store ->
  let receipt_item = receipt_artifact_for_identity store identity in
  let operation = operation_artifact store identity.id in
  let awaiting = artifact_for_id store.awaiting identity.id in
  let pending = artifact_for_id store.pending identity.id in
  let inflight = artifact_for_id store.inflight identity.id in
  let* existing_receipt = read_receipt_opt receipt_item in
  let* () =
    match existing_receipt with
    | Some current ->
      if receipt_identity_equal current.identity identity
         && current.outcome = receipt.outcome
         && Float.equal current.started_at receipt.started_at
         && Float.equal current.ended_at receipt.ended_at
         && String.equal
              (payload_sha256 current.detail)
              (payload_sha256 receipt.detail)
      then Ok ()
      else
        Error
          (Identity_conflict { job_id = identity.id; path = receipt_item.path })
    | None ->
      let* inflight_envelope = read_envelope_opt inflight in
      (match inflight_envelope with
       | None ->
        Error
          (Missing_inflight_lease
             { job_id = identity.id; path = inflight.path })
       | Some envelope ->
        let* () =
          ensure_queue_coordinates
            ~expected_keeper_name:identity.keeper_name
            ~path:inflight.path
            envelope
        in
        let* () =
          ensure_expected_state
            ~expected:Expect_inflight
            ~path:inflight.path
            envelope
        in
        if not (receipt_identity_matches_job identity envelope.job)
        then
          Error
            (Identity_conflict { job_id = identity.id; path = inflight.path })
        else
          (match envelope.state with
           | Awaiting_turn_commit | Pending ->
             Error
               (Missing_inflight_lease
                  { job_id = identity.id
                  ; path = inflight.path
                  })
           | Inflight { started_at } ->
             if not (Float.equal started_at receipt.started_at)
             then
               Error
                 (Inflight_lease_conflict
                    { job_id = identity.id
                    ; path = inflight.path
                    ; expected_started_at = receipt.started_at
                    ; actual_started_at = started_at
                    })
             else save_json receipt_item (receipt_to_json receipt)))
  in
  let cleanup_errors =
    cleanup_artifacts [ operation; awaiting; pending; inflight ]
  in
  Ok { cleanup_errors }
;;

let count_queue_in_jobs ~keeper_name ~jobs ~path ~expected_state =
  let* count =
    with_optional_directory jobs path (fun directory ->
      let* items = list_json_artifacts ~jobs directory in
      let* envelopes =
        load_envelopes
          ~expected_keeper_name:keeper_name
          ~expected_state
          items
      in
      Ok (List.length envelopes))
  in
  Ok (Option.value count ~default:0)
;;

let count_backlog_in_jobs ~base_path ~keeper_name jobs =
  let* awaiting =
    count_queue_in_jobs
      ~keeper_name
      ~jobs
      ~path:(awaiting_dir ~base_path ~keeper_name)
      ~expected_state:Expect_awaiting
  in
  let* pending =
    count_queue_in_jobs
      ~keeper_name
      ~jobs
      ~path:(pending_dir ~base_path ~keeper_name)
      ~expected_state:Expect_pending
  in
  let* inflight =
    count_queue_in_jobs
      ~keeper_name
      ~jobs
      ~path:(inflight_dir ~base_path ~keeper_name)
      ~expected_state:Expect_inflight
  in
  Ok (awaiting + pending + inflight)
;;

let backlog_count ~base_path ~keeper_name =
  if not (keeper_name_is_valid keeper_name)
  then Error (Invalid_keeper_name keeper_name)
  else
    let* presence =
      with_existing_jobs ~base_path ~keeper_name @@ fun store ->
      count_backlog_in_jobs ~base_path ~keeper_name store.jobs
    in
    (match presence with
     | Missing -> Ok 0
     | Present count -> Ok count)
;;

let discover_keeper_names ~base_path =
  let masc_path = Common.masc_dir_from_base_path ~base_path in
  let keepers_path = Common.keepers_runtime_dir_of_base ~base_path in
  let* masc_name = child_name ~parent:base_path masc_path in
  let* keepers_name = child_name ~parent:masc_path keepers_path in
  let* presence =
    try
      match
        Anchored.with_open_path_opt
          ~root:base_path
          [ masc_name; keepers_name ]
          (fun handle ->
             let keepers_directory = { handle; path = keepers_path } in
             let* entries =
               protect_io List_directory keepers_path (fun () ->
                 Anchored.read_dir keepers_directory.handle)
             in
             let rec loop keepers errors = function
               | [] ->
                 Ok
                   (Present
                      ( List.sort_uniq String.compare keepers
                      , List.rev errors ))
               | keeper_segment :: rest ->
                 let keeper_name =
                   Anchored.Segment.to_string keeper_segment
                 in
                 if not (keeper_name_is_valid keeper_name)
                 then
                   loop
                     keepers
                     (Invalid_keeper_name keeper_name :: errors)
                     rest
                 else
                   let keeper_path =
                     Filename.concat keepers_path keeper_name
                   in
                   let jobs_path = keeper_jobs_dir ~base_path ~keeper_name in
                   let count_result =
                     with_optional_directory
                       keepers_directory
                       keeper_path
                       (fun keeper_directory ->
                          let* jobs_presence =
                            with_optional_directory
                              keeper_directory
                              jobs_path
                              (count_backlog_in_jobs
                                 ~base_path
                                 ~keeper_name)
                          in
                          Ok (Option.value jobs_presence ~default:0))
                   in
                   (match count_result with
                    | Error error ->
                      loop keepers (error :: errors) rest
                    | Ok None -> loop keepers errors rest
                    | Ok (Some count) ->
                      loop
                        (if count > 0
                         then keeper_name :: keepers
                         else keepers)
                        errors
                        rest)
             in
             loop [] [] entries)
      with
      | None -> Ok Missing
      | Some result -> result
    with
    | Unix.Unix_error ((Unix.ELOOP | Unix.ENOTDIR), _, _) as exn ->
      Error
        (Io_error
           { operation = Inspect
           ; path = keepers_path
           ; detail = Printexc.to_string exn
           })
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Io_error
           { operation = Inspect
           ; path = keepers_path
           ; detail = Printexc.to_string exn
           })
  in
  match presence with
  | Missing -> Ok ([], [])
  | Present result -> Ok result
;;

module For_testing = struct
  let awaiting_dir = awaiting_dir
  let pending_dir = pending_dir
  let inflight_dir = inflight_dir
  let receipts_dir = receipts_dir
  let receipt_path = receipt_path
end
