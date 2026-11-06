module Plan = Keeper_tool_plan
module Async = Keeper_msg_async
open Result.Syntax
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_json
open Keeper_tool_execution_journal_model
open Keeper_tool_execution_journal_state_decode

let source journal = journal.immutable_source
let source_observation journal = journal.immutable_observation
let worker_source (worker : worker) = worker.journal.immutable_source
let worker_source_observation (worker : worker) = worker.journal.immutable_observation
let path_for ~base_path ~keeper_name ~composition_run_id =
  let root = Common.masc_dir_from_base_path ~base_path in
  let directory = Filename.concat (Filename.concat (Filename.concat root "keeper_msg_requests") "execution_journals") (sha keeper_name) in
  root, Filename.concat directory (Plan.Composition_run_id.to_string composition_run_id ^ ".jsonl")

let validate_owned_path_blocking ~root ~path ~create =
  match Fs_compat.owned_directory_paths ~ownership_root:root (Filename.dirname path) with
  | Error rejection -> Error (Unreadable_journal (Fs_compat.owned_directory_chain_rejection_to_string rejection))
  | Ok paths ->
    let inspect expected_kind location =
      match Unix.lstat location with
      | stats ->
        Result.map_error (fun detail -> Unreadable_journal detail) (decode (fun () ->
          require (stats.st_kind = expected_kind && stats.st_uid = Unix.getuid () && stats.st_perm land 0o022 = 0)
            ("unowned filesystem entry " ^ location);
          if expected_kind = Unix.S_REG then require (stats.st_nlink = 1) "non-unique journal file"))
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> if create then Ok () else Error Missing_journal in
    let* () = List.fold_left (fun prior directory -> let* () = prior in inspect Unix.S_DIR directory) (Ok ()) (root :: paths) in
    inspect Unix.S_REG path

let validate_owned_path ~root ~path ~create =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> validate_owned_path_blocking ~root ~path ~create
  | Fs_compat.Eio_fiber ->
    Eio_unix.run_in_systhread ~label:"composition-journal-owned-path"
      (fun () -> validate_owned_path_blocking ~root ~path ~create)

let filesystem f = try f () with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Unix.Unix_error (code, operation, path) -> Error (Persistence_failed (Printf.sprintf "%s(%s): %s" operation path (Unix.error_message code)))
  | Sys_error detail -> Error (Persistence_failed detail)

let read_manifest ~base_path (reference : Tool_output.artifact_ref) =
  let* bytes = Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256
    |> Result.map_error (fun error -> Draft_unavailable (Tool_blob_store.fetch_error_to_string error)) in
  let* bytes = match bytes with Some bytes -> Ok bytes | None -> Error (Draft_unavailable "original artifact absent") in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () ->
    require (reference.mime = Tool_output.artifact_manifest_mime && String.length bytes = reference.bytes)
      "original artifact media type or byte identity mismatch";
    let json = Yojson.Safe.from_string bytes in valid_json json;
    match Tool_output.artifact_manifest_of_json json with
    | Tool_output.Decoded_artifact_manifest {structured_content; _} -> structured_content
    | Tool_output.Invalid_artifact_manifest {detail} -> refuse detail
    | Tool_output.Not_artifact_manifest -> refuse "expected canonical prepared artifact manifest"))

let frozen_draft ~base_path immutable_source =
  let* draft = read_manifest ~base_path immutable_source.draft_reference in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () ->
    let fields = object_fields ["keeper"; "execution"; "recipe"; "plan"; "nested_calls"; "contracts"; "skill"] draft in
    require (field "keeper" fields = `String immutable_source.keeper_name) "draft keeper identity mismatch";
    require (field "execution" fields = `String "async") "journal requires a prepared async draft";
    fields))

let frozen_plan ~base_path immutable_source =
  let* fields = frozen_draft ~base_path immutable_source in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () -> field "plan" fields))

let validate_artifacts ~base_path immutable_source =
  let* draft = frozen_draft ~base_path immutable_source in
  let* run = read_manifest ~base_path immutable_source.run_reference in
  Result.map_error (fun detail -> Draft_unavailable detail) (decode (fun () ->
    let fields = object_fields ["draft"; "nested_calls"; "nested_activation"; "composition_run_id"; "tool_use_id"; "source_turn"] run in
    require (canonical_equal (field "draft" fields) (Tool_output.normalized_artifact_ref_to_json immutable_source.draft_reference))
      "run artifact draft identity mismatch";
    require (canonical_equal (field "nested_calls" fields) (field "nested_calls" draft))
      "run artifact frozen child mapping mismatch";
    (match field "nested_calls" fields,field "nested_activation" fields with
     | `List [],`Null -> ()
     | `List (_::_),binding ->
       (match Keeper_skill_activation_recorder.bound_context_of_yojson binding with
        | Ok _ -> () | Error error -> refuse (Keeper_skill_activation_recorder.error_to_string error))
     | _ -> refuse "run artifact original child activation binding mismatch");
    require (field "composition_run_id" fields = `String (Plan.Composition_run_id.to_string immutable_source.composition_run_id)
      && field "tool_use_id" fields = `String immutable_source.parent_tool_use_id
      && field "source_turn" fields = `Int immutable_source.source_turn) "run artifact original invocation mismatch"))

let strict_read ~root path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ()) ~ownership_root:root path with
  | Error error -> Error (Unreadable_journal (Fs_compat.owned_regular_file_read_error_to_string error))
  | Ok None -> Error Missing_journal
  | Ok (Some contents) -> Result.map_error (fun detail -> Corrupt_journal detail) (decode_state contents.content)

let check_source (journal : t) (state : state) =
  if source_json journal.immutable_source = source_json state.source && journal.source_sha = state.source_sha
     && same_source_observation journal.immutable_observation state.source_observation
  then Ok () else Error Source_conflict

let cleanup_warning path failure =
  (* Logging cannot turn the transaction's known primary outcome into a write
     failure. Cancellation still propagates; ordinary sink I/O is observational. *)
  try
    Log.Keeper.warn "composition journal primary transaction outcome preserved; descriptor cleanup failed for %s: %s"
      path (Fs_compat.private_jsonl_operation_failure_to_string failure)
  with
  | Eio.Cancel.Cancelled _ as cancellation -> raise cancellation
  | Sys_error _ | Unix.Unix_error _ -> ()

(* The async request detail reads this journal (run, owner, generation,
   resolution), so a write the journal decided to make is announced as a
   change of the Keeper's async requests, whatever its outcome. A write that
   did not land costs a reader one read of an unchanged journal. *)
let announce_written ~wrote (source : source) =
  if wrote then Keeper_msg_async_broadcast.requests_changed ~keeper_name:source.keeper_name

(* Runs a journal file transaction and then announces [source]'s Keeper if
   the transaction decided to write, also when it raised after deciding:
   the bytes may have landed before the raise. *)
let announcing ~wrote (source : source) transaction =
  match transaction () with
  | outcome -> announce_written ~wrote:!wrote source; outcome
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    announce_written ~wrote:!wrote source;
    Printexc.raise_with_backtrace exn backtrace

let update_existing_with_bytes journal decide = filesystem (fun () ->
  let* () = validate_owned_path ~root:journal.root ~path:journal.path ~create:false in
  let wrote = ref false in
  let callback bytes =
    match validate_owned_path ~root:journal.root ~path:journal.path ~create:false with
    | Error error -> None, Error error
    | Ok () ->
      match Result.map_error (fun detail -> Corrupt_journal detail) (decode_state bytes) with
      | Error error -> None, Error error
      | Ok state ->
        match check_source journal state with
        | Error error -> None, Error error
        | Ok () ->
          let (next, _) as decided = decide bytes state in
          wrote := Option.is_some next;
          decided in
  let unpack = function None -> Error Missing_journal | Some result -> result in
  match announcing ~wrote journal.immutable_source (fun () ->
      Fs_compat.update_existing_private_file_durable_locked_result journal.path callback) with
  | Fs_compat.Private_file_succeeded value -> unpack value
  | Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} ->
    cleanup_warning journal.path cleanup_failure; unpack value
  | Private_file_failed error -> Error (Persistence_failed (Fs_compat.private_jsonl_transaction_error_to_string error))
  | Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
    Error (Persistence_failed (Fs_compat.private_jsonl_transaction_error_to_string error ^ "; cleanup=" ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let update_existing journal decide = update_existing_with_bytes journal (fun _ state -> decide state)

let prepare ?observation ~base_path immutable_source = filesystem (fun () ->
  let* () = Result.map_error (fun detail -> Invalid_source detail) (decode (fun () -> validate_source immutable_source)) in
  let base_path = Fs_compat.realpath base_path in
  let* () = validate_artifacts ~base_path immutable_source in
  let root, path = path_for ~base_path ~keeper_name:immutable_source.keeper_name ~composition_run_id:immutable_source.composition_run_id in
  let journal = {base_path; root; path; immutable_source; source_sha = json_sha (source_json immutable_source);
                 immutable_observation=observation} in
  let* () = validate_owned_path ~root ~path ~create:true in
  Fs_compat.mkdir_p (Filename.dirname path);
  let* () = validate_owned_path ~root ~path ~create:true in
  let existing = strict_read ~root path in
  let* absent = match existing with
    | Error Missing_journal -> Ok true
    | Error (Invalid_source _ | Unreadable_journal _ | Corrupt_journal _ | Source_conflict
        | Queued_request_rejected _ | Prior_owner_not_terminal _ | Ownership_changed
        | Node_identity_conflict _ | Replay_not_proven _ | Attempt_conflict _ | Plan_identity_conflict
        | Draft_unavailable _ | Invalid_result _ | Invalid_continuation_marker _
        | Persistence_failed _ as error) -> Error error
    | Ok state ->
        let* () = check_source {journal with immutable_observation=state.source_observation} state in
        Ok false in
  let wrote = ref false in
  let callback bytes =
    match validate_owned_path ~root ~path ~create:false with
    | Error error -> None, Error error
    | Ok () ->
      if bytes = "" && absent then
        (match decode (fun () -> Option.map (fun observation ->
            source_observation_of_json (source_observation_json observation)) observation) with
         | Error detail -> None, Error (Invalid_source detail)
         | Ok observation ->
             let bytes = row (source_event immutable_source)
               ^ (match observation with None -> "" | Some observation ->
                   row (source_observation_event journal.source_sha observation)) in
             wrote := true;
             Some bytes, Ok {journal with immutable_observation=observation})
      else match Result.map_error (fun detail -> Corrupt_journal detail) (decode_state bytes) with
        | Error error -> None, Error error
        | Ok state ->
            let journal = {journal with immutable_observation=state.source_observation} in
            None, Result.map (fun () -> journal) (check_source journal state) in
  match announcing ~wrote immutable_source (fun () ->
      Fs_compat.update_private_file_durable_locked_result path callback) with
  | Fs_compat.Private_file_succeeded value -> value
  | Private_file_succeeded_with_cleanup_failure {value; cleanup_failure} -> cleanup_warning path cleanup_failure; value
  | Private_file_failed error -> Error (Persistence_failed (Fs_compat.durable_append_error_to_string error))
  | Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
    Error (Persistence_failed (Fs_compat.durable_append_error_to_string error ^ "; cleanup=" ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let load_authority_state ~base_path ~keeper_name ~composition_run_id = filesystem (fun () ->
  if not (exact_name keeper_name) then Error (Invalid_source "invalid keeper name") else
  let base_path = Fs_compat.realpath base_path in
  let root, path = path_for ~base_path ~keeper_name ~composition_run_id in
  let* state = strict_read ~root path in
  if not (String.equal state.source.keeper_name keeper_name && Plan.Composition_run_id.equal state.source.composition_run_id composition_run_id)
  then Error Source_conflict else
  Ok ({base_path; root; path; immutable_source = state.source; source_sha = state.source_sha;
       immutable_observation=state.source_observation},state))

let load_authority ~base_path ~keeper_name ~composition_run_id =
  load_authority_state ~base_path ~keeper_name ~composition_run_id |> Result.map fst

let load ~base_path ~keeper_name ~composition_run_id =
  let* journal = load_authority ~base_path ~keeper_name ~composition_run_id in
  let* () = filesystem (fun () -> validate_artifacts ~base_path:journal.base_path journal.immutable_source) in
  Ok journal

let entry_matches_source source (entry : Async.entry) = decode (fun () ->
  require (String.equal entry.keeper_name source.keeper_name && String.equal entry.submitted_by source.keeper_name) "request caller/keeper mismatch";
  let fields = match entry.request_context with Some fields -> fields | None -> refuse "missing prepared request context" in
  valid_json (`Assoc fields);
  let unique name = match List.filter_map (fun (key, value) -> if String.equal key name then Some value else None) fields with
    | [value] -> value | _ -> refuse ("missing or duplicate context " ^ name) in
  require (unique "composition_run_id" = `String (Plan.Composition_run_id.to_string source.composition_run_id)) "request run identity mismatch";
  let reference name expected = match Tool_output.normalized_artifact_ref_of_json (unique name) with
    | Tool_output.Decoded_normalized_artifact_ref found ->
      require (Tool_output.normalized_artifact_ref_to_json found = Tool_output.normalized_artifact_ref_to_json expected) ("request " ^ name ^ " mismatch")
    | Tool_output.Invalid_normalized_artifact_ref {detail} -> refuse detail
    | Tool_output.Not_normalized_artifact_ref -> refuse ("invalid context reference " ^ name) in
  reference "draft_reference" source.draft_reference; reference "run_artifact" source.run_reference;
  (match source.producer with
   | Prepared -> require (unique "composition_tool" = `String Keeper_tool_composition_catalog.run_tool_name)
       "prepared producer tool mismatch"
   | Named {tool_name;skill_reference;activation=_;origin=_} ->
     require (unique "composition_tool" = `String tool_name
       && canonical_equal (unique "skill_reference") (Skill_reference.to_yojson skill_reference))
       "named producer identity mismatch");
  require (unique "parent_tool_use_id" = `String source.parent_tool_use_id && unique "source_turn" = `Int source.source_turn) "original invocation mismatch";
  let task_fields = List.filter_map (fun (name, value) -> if name = "source_task_id" then Some value else None) fields in
  require (task_fields = (match source.source_task_id with None -> [] | Some task -> [`String task])) "source task identity mismatch")

let validate_request journal (entry : Async.entry) = filesystem (fun () ->
  if not (String.equal (Fs_compat.realpath entry.base_path) journal.base_path)
  then Error Source_conflict
  else
    let* () = entry_matches_source journal.immutable_source entry
      |> Result.map_error (fun detail -> Invalid_source detail) in
    let* state = strict_read ~root:journal.root journal.path in
    let* () = check_source journal state in
    let belongs (binding : binding) = String.equal binding.request_id entry.request_id in
    if Option.exists belongs state.owner
       || List.exists (fun (binding,_) -> belongs binding) state.prior_owners
    then Ok () else Error (Invalid_source "canonical request was not admitted to this prepared run"))

let canonical_queued journal request_id =
  let* proof = Async.load_canonical_durable_queued ~base_path:journal.base_path
      ~caller:journal.immutable_source.keeper_name request_id
    |> Result.map_error (fun error -> Queued_request_rejected (Async.canonical_queued_error_to_string error)) in
  Result.map_error (fun detail -> Queued_request_rejected detail)
    (entry_matches_source journal.immutable_source (Async.durable_queued_entry proof))
