type failure =
  | Worker_failed of string
  | Source_access_unavailable of string
  | Proposal_invalid of string
[@@deriving yojson]

type owner = { instance_id : string; claim_id : string } [@@deriving yojson]
type refusal = { runtime_id : string; message : string; limit_tokens : int option }
[@@deriving yojson]
type source_record = { trace_id : string; turn_count : int; sha256 : string; bytes : int }
[@@deriving yojson]
type projection =
  { artifact_sha256 : string
  ; bytes : int
  ; source_sha256 : string
  ; claimed_required_refs : string list
  ; claimed_stimulus_ids : string list
  }
[@@deriving yojson]
type state =
  | Queued
  | Claimed of owner
  | Proposed of owner * projection
  | Work_failed of owner * failure
  | Work_cancelled of owner * string
[@@deriving yojson]
type t =
  { work_id : string
  ; keeper_name : string
  ; admission_id : string
  ; source_record : source_record
  ; refusals : refusal list
  ; pending_stimuli : string list
  ; required_refs : string list
  ; watermark : string
  ; offset : int
  ; state : state
  }
[@@deriving yojson]
type status = Pending | Running of owner | Proposal_recorded of projection
  | Failed of failure | Cancelled of string

type error =
  | Invalid_input of string | Invalid_record of string | Not_found
  | Identity_conflict | Stale_revision | Stale_owner | Source_changed | Terminal_state
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Artifact_read_failed of Tool_blob_store.fetch_error | Artifact_missing of string
  | Artifact_write_failed of string | Directory_prepare_failed of string
  | Lock_failed of File_lock_eio.durable_lock_error
  | Write_failed of Keeper_fs.durable_write_error

type 'a mutation = { value : 'a; lock_release_error : File_lock_eio.durable_lock_error option }
let ( let* ) = Result.bind
let digest bytes = Digestif.SHA256.(to_hex (digest_string bytes))
let id t = t.work_id
let revision t = digest (Yojson.Safe.to_string (to_yojson t))
let status t = match t.state with
  | Queued -> Pending | Claimed owner -> Running owner | Proposed (_, p) -> Proposal_recorded p
  | Work_failed (_, f) -> Failed f | Work_cancelled (_, reason) -> Cancelled reason
let source_artifact_sha256 t = t.source_record.sha256
let pending_stimulus_ids t = t.pending_stimuli
let required_source_refs t = t.required_refs
let source_watermark t = t.watermark
let cursor t = t.offset
let projection_artifact_sha256 p = p.artifact_sha256
let owner_instance_id owner = owner.instance_id
let owner_claim_id owner = owner.claim_id
let last_owner t = match t.state with
  | Queued -> None
  | Claimed owner | Proposed (owner, _) | Work_failed (owner, _)
  | Work_cancelled (owner, _) -> Some owner

let error_to_string = function
  | Invalid_input s -> "invalid recovery input: " ^ s
  | Invalid_record s -> "invalid recovery record: " ^ s
  | Not_found -> "recovery work not found"
  | Identity_conflict -> "recovery admission identity conflicts"
  | Stale_revision -> "recovery revision changed"
  | Stale_owner -> "recovery owner changed"
  | Source_changed -> "recovery source changed"
  | Terminal_state -> "recovery work is terminal"
  | Read_failed e -> Fs_compat.owned_regular_file_read_error_to_string e
  | Artifact_read_failed e -> Tool_blob_store.fetch_error_to_string e
  | Artifact_missing sha -> "recovery artifact missing: " ^ sha
  | Artifact_write_failed s -> "recovery artifact write failed: " ^ s
  | Directory_prepare_failed s -> "recovery directory preparation failed: " ^ s
  | Lock_failed e -> File_lock_eio.durable_lock_error_to_string e
  | Write_failed e -> Keeper_fs.durable_write_error_to_string e

let nonblank name s =
  if String.trim s = "" then Error (Invalid_input (name ^ " is empty")) else Ok ()
let valid_digest name s =
  match Tool_output.validate_sha256 s with
  | Ok () -> Ok ()
  | Error _ -> Error (Invalid_input (name ^ " is not a canonical SHA-256"))
let refs name xs =
  let* () = List.fold_left (fun acc s -> let* () = acc in nonblank name s) (Ok ()) xs in
  if List.length (List.sort_uniq String.compare xs) <> List.length xs
  then Error (Invalid_input (name ^ " contains duplicate identities")) else Ok ()
let same_set a b = List.sort String.compare a = List.sort String.compare b
let source_ref r =
  let* trace_id = Keeper_id.Trace_id.of_string r.trace_id |> Result.map_error (fun e -> Invalid_input e) in
  Keeper_checkpoint_ref.of_persisted ~trace_id ~turn_count:r.turn_count ~sha256:r.sha256
  |> Result.map_error (fun _ -> Invalid_input "invalid checkpoint reference")
let source t =
  (* Every constructor and persisted decode validates this invariant. *)
  match source_ref t.source_record with Ok ref -> ref | Error _ -> assert false
let work_identity ~keeper_name ~admission_id ~trace_id =
  digest (Yojson.Safe.to_string (`List (List.map (fun s -> `String s)
    [keeper_name; trace_id; admission_id])))
let valid_owner owner =
  let* () = nonblank "owner instance" owner.instance_id in nonblank "owner claim" owner.claim_id
let validate t =
  let* _ = Keeper_id.Keeper_name.of_string t.keeper_name |> Result.map_error (fun e -> Invalid_input e) in
  let* () = nonblank "admission" t.admission_id in
  let* _ = source_ref t.source_record in
  let* () = nonblank "source watermark" t.watermark in
  let* () = refs "pending stimulus" t.pending_stimuli in
  let* () = refs "required source" t.required_refs in
  let* () = if t.refusals = [] then Error (Invalid_input "no context refusal") else Ok () in
  let* () = List.fold_left (fun acc refusal ->
    let* () = acc in
    let* () = nonblank "runtime" refusal.runtime_id in
    match refusal.limit_tokens with
    | Some n when n <= 0 -> Error (Invalid_input "nonpositive observed token limit")
    | None | Some _ -> Ok ()) (Ok ()) t.refusals in
  let* () = if t.source_record.bytes < 0 || t.offset < 0 || t.offset > t.source_record.bytes
    then Error (Invalid_input "cursor is outside the exact source bytes") else Ok () in
  let* () = if t.work_id <> work_identity ~keeper_name:t.keeper_name ~admission_id:t.admission_id
      ~trace_id:t.source_record.trace_id then Error Identity_conflict else Ok () in
  match t.state with
  | Queued -> Ok ()
  | Claimed owner -> valid_owner owner
  | Proposed (owner, p) ->
    let* () = valid_owner owner in
    let* () = valid_digest "proposal artifact" p.artifact_sha256 in
    let* () = if p.bytes <= 0 then Error (Invalid_input "empty proposal") else Ok () in
    let* () = refs "claimed required source" p.claimed_required_refs in
    let* () = refs "claimed stimulus" p.claimed_stimulus_ids in
    if p.source_sha256 <> t.source_record.sha256
       || not (same_set p.claimed_required_refs t.required_refs)
       || not (same_set p.claimed_stimulus_ids t.pending_stimuli)
    then Error (Invalid_input "proposal envelope differs from owner source/requirements")
    else Ok ()
  | Work_failed (owner, (Worker_failed s | Source_access_unavailable s | Proposal_invalid s))
  | Work_cancelled (owner, s) ->
    let* () = valid_owner owner in nonblank "terminal detail" s

let store_dir config = Filename.concat (Workspace.masc_root_dir config) "keeper-recovery-work"
let path config id = Filename.concat (store_dir config) (id ^ ".json")
let fetch_verified config ~sha256 ~bytes =
  let* content = Tool_blob_store.fetch (Tool_blob_store.create ~base_path:config.Workspace.base_path)
    ~sha256 |> Result.map_error (fun e -> Artifact_read_failed e) in
  match content with
  | None -> Error (Artifact_missing sha256)
  | Some content when String.length content = bytes -> Ok content
  | Some _ -> Error (Invalid_record "artifact bytes disagree with recorded identity")
let verify_artifacts config t =
  let* bytes = fetch_verified config ~sha256:t.source_record.sha256 ~bytes:t.source_record.bytes in
  let* trace_id = Keeper_id.Trace_id.of_string t.source_record.trace_id
    |> Result.map_error (fun e -> Invalid_record e) in
  let* snapshot = Domain_pool_ref.submit_cpu_or_inline (fun () ->
    Keeper_checkpoint_store.exact_snapshot_of_canonical_bytes ~expected_session_id:trace_id bytes)
    |> Result.map_error (fun _ -> Invalid_record "source artifact is not the recorded checkpoint") in
  let* () = if Keeper_checkpoint_ref.equal (source t)
      (Keeper_checkpoint_store.exact_snapshot_reference snapshot) then Ok ()
    else Error (Invalid_record "source checkpoint reference mismatch") in
  match t.state with
  | Proposed (_, p) -> let* _ = fetch_verified config ~sha256:p.artifact_sha256 ~bytes:p.bytes in Ok ()
  | Queued | Claimed _ | Work_failed _ | Work_cancelled _ -> Ok ()
let load ~config ~id =
  let* () = valid_digest "work ID" id in
  let* raw = Fs_compat.load_owned_regular_file ~ownership_root:(Workspace.masc_root_dir config)
    (path config id) |> Result.map_error (fun e -> Read_failed e) in
  match raw with
  | None -> Ok None
  | Some raw ->
    let* json = try Ok (Yojson.Safe.from_string raw) with Yojson.Json_error e -> Error (Invalid_record e) in
    let* t = of_yojson json |> Result.map_error (fun e -> Invalid_record e) in
    let* () = validate t |> Result.map_error (fun e -> Invalid_record (error_to_string e)) in
    let* () = if t.work_id = id then Ok () else Error (Invalid_record "work ID differs from file") in
    Ok (Some t)
let prepare_directory config =
  Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
    ~before_directory_fsync:(fun _ -> ()) ~ownership_root:(Workspace.masc_root_dir config)
    (store_dir config)
  |> Result.map_error (function
    | Keeper_fs_durable_directory.Directory_chain_failed _ -> Directory_prepare_failed "directory ownership rejected"
    | Keeper_fs_durable_directory.Operation_failed ((Eio.Cancel.Cancelled _ as e), bt) ->
      Printexc.raise_with_backtrace e bt
    | Keeper_fs_durable_directory.Operation_failed (e, _) -> Directory_prepare_failed (Printexc.to_string e))
let transaction config id f =
  let* () = valid_digest "work ID" id in
  let* _ = prepare_directory config in
  match File_lock_eio.with_durable_lock_observed ~lock_path:(path config id ^ ".lock") f with
  | File_lock_eio.Lock_not_acquired e -> Error (Lock_failed e)
  | File_lock_eio.Body_completed { value = Error e; _ } -> Error e
  | File_lock_eio.Body_completed { value = Ok value; release_error } -> Ok {value; lock_release_error = release_error}
let write config t =
  let* () = validate t in
  Keeper_fs.save_json_durable_atomic ~ownership_root:(Workspace.masc_root_dir config)
    ~pretty:false (path config t.work_id) (to_yojson t)
  |> Result.map_error (fun e -> Write_failed e)
let put config bytes mime =
  try Ok (Tool_blob_store.put_durable (Tool_blob_store.create ~base_path:config.Workspace.base_path) ~bytes ~mime)
  with Sys_error e -> Error (Artifact_write_failed e)
let create ~config ~keeper_name ~admission_id ~source:snapshot ~failures
    ~pending_stimulus_ids ~required_source_refs ~source_watermark =
  let source = Keeper_checkpoint_store.exact_snapshot_reference snapshot in
  let bytes = Keeper_checkpoint_store.exact_snapshot_canonical_bytes snapshot in
  let* refusals = List.fold_left (fun acc (runtime_id, failure) ->
    let* acc = acc in match failure with
    | Agent_core.Error.Api (Agent_core.Retry.ContextOverflow {message; limit}) ->
      Ok ({runtime_id; message; limit_tokens = limit} :: acc)
    | _ -> Error (Invalid_input "recovery requires typed provider context refusal")) (Ok []) failures in
  let keeper_name = Keeper_id.Keeper_name.to_string keeper_name in
  let trace_id = Keeper_id.Trace_id.to_string source.trace_id in
  let t = {work_id = work_identity ~keeper_name ~admission_id ~trace_id; keeper_name; admission_id;
    source_record = {trace_id; turn_count = source.turn_count; sha256 = source.sha256; bytes = String.length bytes};
    refusals = List.rev refusals; pending_stimuli = pending_stimulus_ids; required_refs = required_source_refs;
    watermark = source_watermark; offset = 0; state = Queued} in
  let* () = validate t in
  transaction config t.work_id (fun () ->
    let* existing = load ~config ~id:t.work_id in
    match existing with
    | Some old when {old with offset = 0; state = Queued} = t -> Ok old
    | Some _ -> Error Identity_conflict
    | None ->
      let* artifact = put config bytes "application/json" in
      let* () = if artifact.Tool_output.sha256 = source.sha256 then Ok ()
        else Error (Invalid_record "snapshot and artifact digest disagree") in
      let* () = write config t in Ok t)
let update ~config ~id ~expected_revision f =
  transaction config id (fun () ->
    let* current = load ~config ~id in
    let* current = Option.to_result ~none:Not_found current in
    let* () = if revision current = expected_revision then Ok () else Error Stale_revision in
    let* next, result = f current in
    let* () = write config next in Ok result)
let claim ~config ~id ~expected_revision ~instance_id =
  let* () = nonblank "owner instance" instance_id in
  update ~config ~id ~expected_revision (fun t -> match t.state with
    | Queued | Claimed _ ->
      let* () = verify_artifacts config t in
      let owner = {instance_id; claim_id = Random_id.uuid_v7 ()} in
      let next = {t with state = Claimed owner} in Ok (next, (next, owner))
    | Proposed _ | Work_failed _ | Work_cancelled _ -> Error Terminal_state)
let owned owner t = match t.state with
  | Claimed active when active = owner -> Ok ()
  | Claimed _ -> Error Stale_owner
  | Queued -> Error Stale_owner
  | Proposed _ | Work_failed _ | Work_cancelled _ -> Error Terminal_state
let record_progress ~config ~id ~owner ~expected_revision ~next_offset =
  update ~config ~id ~expected_revision (fun t ->
    let* () = owned owner t in
    let* () = if next_offset < t.offset || next_offset > t.source_record.bytes
      then Error (Invalid_input "source cursor regressed or exceeds EOF") else Ok () in
    let next = {t with offset = next_offset} in Ok (next, next))
let record_proposal ~config ~id ~owner ~expected_revision ~current_source
    ~claimed_required_refs ~claimed_stimulus_ids ~proposal_bytes =
  update ~config ~id ~expected_revision (fun t ->
    let* () = owned owner t in
    let* () = verify_artifacts config t in
    let* () = if Keeper_checkpoint_ref.equal (source t)
        (Keeper_checkpoint_store.exact_snapshot_reference current_source) then Ok () else Error Source_changed in
    let* () = refs "covered required source" claimed_required_refs in
    let* () = refs "covered stimulus" claimed_stimulus_ids in
    let* () = if same_set t.required_refs claimed_required_refs && same_set t.pending_stimuli claimed_stimulus_ids
      then Ok () else Error (Invalid_input "proposal changed owner-authored coverage") in
    let* () = nonblank "proposal" proposal_bytes in
    let* artifact = put config proposal_bytes "text/plain" in
    let next = {t with state = Proposed (owner,
      {artifact_sha256 = artifact.sha256; bytes = String.length proposal_bytes;
       source_sha256 = t.source_record.sha256; claimed_required_refs; claimed_stimulus_ids})} in
    Ok (next, next))
let finish ~config ~id ~owner ~expected_revision state =
  update ~config ~id ~expected_revision (fun t ->
    let* () = owned owner t in let next = {t with state} in Ok (next, next))
let fail ~config ~id ~owner ~expected_revision failure =
  finish ~config ~id ~owner ~expected_revision (Work_failed (owner, failure))
let cancel ~config ~id ~owner ~expected_revision ~reason =
  finish ~config ~id ~owner ~expected_revision (Work_cancelled (owner, reason))
