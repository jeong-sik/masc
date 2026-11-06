module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
open Result.Syntax
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_json
open Keeper_tool_execution_journal_model
open Keeper_tool_execution_journal_state_decode
open Keeper_tool_execution_journal_store

type continuation_marker =
  { request_id : string; keeper_name : string
  ; composition_run_id : Plan.Composition_run_id.t }

let continuation_directory ~base_path =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path)
    "keeper_msg_requests") "prepared_continuations"
let continuation_filename request_id = sha request_id ^ ".json"
let continuation_marker_json (marker : continuation_marker) =
  `Assoc ["schema", `String "keeper.prepared_continuation.v1";
    "request_id", `String marker.request_id; "keeper_name", `String marker.keeper_name;
    "composition_run_id", `String (Plan.Composition_run_id.to_string marker.composition_run_id)]
let decode_continuation_marker bytes =
  Result.map_error (fun detail -> Invalid_continuation_marker detail) (decode (fun () ->
    let fields = object_fields ["schema";"request_id";"keeper_name";"composition_run_id"]
        (Yojson.Safe.from_string bytes) in
    require (field "schema" fields = `String "keeper.prepared_continuation.v1") "unknown continuation marker schema";
    let request_id = string (field "request_id" fields)
    and keeper_name = string (field "keeper_name" fields) in
    require (exact_name request_id && exact_name keeper_name) "invalid continuation marker owner";
    let composition_run_id = match Plan.Composition_run_id.of_string
        (string (field "composition_run_id" fields)) with
      | Ok identity -> identity
      | Error (Plan.Composition_run_id.Invalid_uuid_v7 detail) -> refuse detail in
    {request_id;keeper_name;composition_run_id}))

let continuation_receipt path (receipt : 'a Fs_compat.private_jsonl_success_receipt) =
  (match receipt.settlement_error with
   | None -> ()
   | Some error ->
     (try Log.Keeper.warn "prepared continuation primary outcome preserved; settlement failed path=%s detail=%s"
        path (Fs_compat.private_jsonl_transaction_error_to_string error)
      with Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
        | Sys_error _ | Unix.Unix_error _ -> ()));
  receipt.value

let continuation_snapshot ~root path =
  let* () = validate_owned_path ~root ~path ~create:true in
  let* () = validate_owned_path ~root ~path:(Fs_compat.private_jsonl_lock_path path) ~create:true in
  let* receipt = Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
    |> Fs_compat.private_jsonl_snapshot_success_receipt
    |> Result.map_error (fun error -> Persistence_failed
        (Fs_compat.private_jsonl_transaction_error_to_string error)) in
  let* () = validate_owned_path ~root ~path ~create:true in
  let* () = validate_owned_path ~root ~path:(Fs_compat.private_jsonl_lock_path path) ~create:false in
  Ok (continuation_receipt path receipt)

let prepare_continuation_marker journal ~request_id = filesystem (fun () ->
  let source = journal.immutable_source in
  let marker = {request_id;keeper_name=source.keeper_name;composition_run_id=source.composition_run_id} in
  let path = Filename.concat (continuation_directory ~base_path:journal.base_path)
      (continuation_filename request_id) in
  let* () = validate_owned_path ~root:journal.root ~path ~create:true in
  Fs_compat.mkdir_p (Filename.dirname path);
  let* snapshot = continuation_snapshot ~root:journal.root path in
  if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then
    let* receipt = Fs_compat.append_private_jsonl_durable_locked_at_cursor_result path
        ~expected:snapshot.cursor (row (continuation_marker_json marker))
      |> Fs_compat.private_jsonl_cursor_success_receipt
      |> Result.map_error (fun error -> Persistence_failed
          (Fs_compat.private_jsonl_transaction_error_to_string error)) in
    ignore (continuation_receipt path receipt); Ok ()
  else
    let* found = decode_continuation_marker snapshot.bytes in
    if continuation_marker_json found = continuation_marker_json marker then Ok ()
    else Error (Invalid_continuation_marker "marker changed request/run/owner identity"))

let marker_version (snapshot : Fs_compat.private_jsonl_snapshot) =
  json_sha (`List [`String snapshot.bytes;
    `String (Fs_compat.Private_jsonl_cursor.fingerprint snapshot.cursor)])

let resolution_marker journal request_id =
  let path = Filename.concat (continuation_directory ~base_path:journal.base_path)
      (continuation_filename request_id) in
  let* snapshot = continuation_snapshot ~root:journal.root path in
  let* () = if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok () else
    let* marker = decode_continuation_marker snapshot.bytes in
    if String.equal marker.request_id request_id
        && String.equal marker.keeper_name journal.immutable_source.keeper_name
        && Plan.Composition_run_id.equal marker.composition_run_id journal.immutable_source.composition_run_id
    then Ok () else Error (Invalid_continuation_marker "resolution marker differs from the original source") in
  Ok (path,snapshot)

let retire_resolution_marker ~root ~path ~snapshot (resolution : resolution) =
  if Fs_compat.Private_jsonl_cursor.is_missing snapshot.Fs_compat.cursor then Ok ()
  else if not (String.equal (marker_version snapshot) resolution.marker_version)
  then Error (Invalid_continuation_marker "resolved marker was replaced; replacement retained")
  else
    let* () = validate_owned_path ~root ~path ~create:true in
    let* receipt = Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_result path
        ~expected:snapshot
      |> Fs_compat.private_jsonl_cursor_success_receipt
      |> Result.map_error (fun error -> Persistence_failed
          (Fs_compat.private_jsonl_transaction_error_to_string error)) in
    ignore (continuation_receipt path receipt);
    match receipt.settlement_error with
    | None -> Ok ()
    | Some error -> Error (Persistence_failed
        ("resolved marker primary retirement committed; settlement incomplete: " ^
          Fs_compat.private_jsonl_transaction_error_to_string error))

let with_resolution_terminal journal request_id f =
  match Async.with_canonical_durable_terminal ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id ~f:(fun proof ->
        let entry = Async.durable_terminal_entry proof in
        let* () = entry_matches_source journal.immutable_source entry
          |> Result.map_error (fun detail -> Invalid_source detail) in
        match entry.status with
        | Async.Waiting_for_dependencies _ | Lost _ -> f entry
        | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _ | Done _ ->
          Error (Invalid_result "explicit continuation resolution requires a waiting or lost physical owner")) with
  | Ok result -> result
  | Error error -> Error (Prior_owner_not_terminal
      {request_id;reason=Async.canonical_terminal_error_to_string error})

let resolution_version bytes snapshot entry =
  json_sha (`List [`String bytes; `String (marker_version snapshot); Async.entry_to_json entry])

let observe_resolution ~base_path ~keeper_name ~composition_run_id ~request_id = filesystem (fun () ->
  (* This loader can only observe or revoke future work. Missing dependency or
     artifact authority must not prevent an explicit revocation, and is never
     upgraded into replay permission. The journal and physical owner remain strict. *)
  let* journal = load_authority ~base_path ~keeper_name ~composition_run_id in
  with_resolution_terminal journal request_id (fun request ->
    let* _,snapshot = resolution_marker journal request_id in
    update_existing_with_bytes journal (fun bytes state -> None,
      let* () = match state.owner with
        | Some owner when String.equal owner.request_id request_id -> Ok ()
        | None | Some _ -> Error Ownership_changed in
      match state.resolution with
      | Some resolution -> Ok {request;version=resolution.expected_version;resolution=Some resolution}
      | None when Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor ->
        Error (Invalid_continuation_marker "unresolved owner has no pending marker")
      | None -> Ok {request;version=resolution_version bytes snapshot request;resolution=None})))

let resolve_continuation ~base_path ~keeper_name ~composition_run_id ~request_id
    ~expected_version ~decision ~requested_by ~reason ~now = filesystem (fun () ->
  let* () = if exact_name requested_by && nonblank reason && finite now && now >= 0.
    then Ok () else Error (Invalid_source "resolution requires an actor, reason and finite timestamp") in
  let* journal = load_authority ~base_path ~keeper_name ~composition_run_id in
  with_resolution_terminal journal request_id (fun request ->
    let* path,snapshot = resolution_marker journal request_id in
    let* resolution = update_existing_with_bytes journal (fun bytes state ->
      match state.owner with
      | None -> None, Error Ownership_changed
      | Some owner when not (String.equal owner.request_id request_id) -> None, Error Ownership_changed
      | Some owner ->
        match state.resolution with
        | Some resolution ->
          if String.equal resolution.expected_version expected_version
              && resolution.decision = decision && String.equal resolution.requested_by requested_by
              && String.equal resolution.reason reason
          then None, Ok resolution else None, Error Ownership_changed
        | None ->
          if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor
              || not (String.equal (resolution_version bytes snapshot request) expected_version)
          then None, Error Ownership_changed else
          let resolution = {owner;decision;requested_by;reason;resolved_at=now;
            expected_version;marker_version=marker_version snapshot} in
          Some (row (event "resolution" journal.source_sha
            ["resolution",resolution_to_json resolution])), Ok resolution) in
    (* The journal append has durably committed before marker retirement. Any
       interruption here leaves a terminal decision that a same-command retry
       or discovery can observe; it never reopens the original effect lane. *)
    let retirement_error = match retire_resolution_marker ~root:journal.root ~path ~snapshot resolution with
      | Ok () -> None | Error error -> Some error in
    Ok {resolution;marker_retired=Option.is_none retirement_error;retirement_error}))

let observe_request ~base_path ~composition_run_id (request_entry : Async.entry) = filesystem (fun () ->
  let* journal = load_authority ~base_path ~keeper_name:request_entry.keeper_name ~composition_run_id in
  let* () = if String.equal (Fs_compat.realpath request_entry.base_path) journal.base_path
    then Ok () else Error Source_conflict in
  let* () = entry_matches_source journal.immutable_source request_entry
    |> Result.map_error (fun detail -> Invalid_source detail) in
  let* observation = update_existing_with_bytes journal (fun bytes state -> None,
    let belongs (binding : binding) = String.equal binding.request_id request_entry.request_id in
    let* owner = match state.owner with
      | Some owner when belongs owner || List.exists (fun (prior,_) -> belongs prior) state.prior_owners -> Ok owner
      | None | Some _ -> Error Ownership_changed in
    Ok {journal;request_entry;observed_owner=owner;observed_resolution=state.resolution;
      journal_version=sha bytes;observed_at=Time_compat.now ()}) in
  let* () = match request_entry.status with
    | Async.Queued | Running | Cancelling _ ->
      (match Async.load_canonical_request ~base_path:journal.base_path
          ~caller:request_entry.keeper_name request_entry.request_id with
       | Found current when Async.same_entry_record current request_entry -> Ok ()
       | Found _ | Absent -> Error Ownership_changed
       | Unreadable detail -> Error (Invalid_result detail)
       | Rejected rejection -> Error (Invalid_result (Yojson.Safe.to_string (Async.access_rejection_to_json rejection))))
    | Done _ | Lost _ | Cancelled _ | Persistence_failed _ | Waiting_for_dependencies _ ->
      let* proof = Async.load_canonical_durable_terminal ~base_path:journal.base_path
          ~caller:request_entry.keeper_name request_entry.request_id
        |> Result.map_error (fun error -> Prior_owner_not_terminal
            {request_id=request_entry.request_id;reason=Async.canonical_terminal_error_to_string error}) in
      if Async.same_entry_record request_entry (Async.durable_terminal_entry proof)
      then Ok () else Error Ownership_changed in
  let* () = match observation.observed_resolution with
    | None -> Ok ()
    | Some resolution -> with_resolution_terminal journal resolution.owner.request_id (fun _ -> Ok ()) in
  Ok observation)
