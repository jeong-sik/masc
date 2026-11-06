module Async = Keeper_msg_async
module Dependency = Keeper_composition_dependency
open Result.Syntax
open Keeper_tool_execution_journal_types
open Keeper_tool_execution_journal_model
open Keeper_tool_execution_journal_store
open Keeper_tool_execution_journal_resolution
open Keeper_tool_execution_journal_continuation
open Keeper_tool_execution_journal_completion

type discovery_scope = All_pending | Result_notifications of result_notification list

module Result_keys = Stdlib.Set.Make (struct
  type t = string * string * Dependency.t
  (* These closed immutable dependency values contain only original identities,
     including exact Skill revisions. This ordering never drives marker order. *)
  let compare = Stdlib.compare
end)

type pending_continuations =
  { inspected : int; ready : continuation list; waiting : int; unselected : int; retired : int
  ; failures : (string * error) list }
type discovery = Ready of continuation | Still_waiting | Unselected | Retired | Lock_infrastructure

let continuation_data_name name =
  let suffix = ".json" in
  String.length name = 64 + String.length suffix && String.ends_with ~suffix name
  && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) (String.sub name 0 64)

let continuation_lock_data_name name =
  let suffix = ".lock" in
  if not (String.ends_with ~suffix name) then None else
  let data_name = String.sub name 0 (String.length name - String.length suffix) in
  if continuation_data_name data_name then Some data_name else None

let pending_continuations_with ~scope ~before_retire ~on_ready ~read_composition_result ~base_path =
  let* base_path = filesystem (fun () -> Ok (Fs_compat.realpath base_path)) in
  let root = Common.masc_dir_from_base_path ~base_path in
  let directory = continuation_directory ~base_path in
  let* names = filesystem (fun () ->
    let* inspection = Fs_compat.inspect_owned_directory_chain ~ownership_root:root directory
      |> Result.map_error (fun error -> Persistence_failed
          (Fs_compat.owned_directory_chain_rejection_to_string error)) in
    match inspection with
      | Fs_compat.Owned_directory_missing -> Ok []
      | Owned_directory _ -> Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
          ~ownership_root:root directory
          |> Result.map_error (fun error -> Persistence_failed
              (Fs_compat.owned_regular_file_read_error_to_string error))) in
  let result_keys = match scope with
    | All_pending -> None
    | Result_notifications notifications ->
      Some (List.fold_left (fun keys (notification : result_notification) ->
        Result_keys.add (notification.base_path,notification.keeper_name,notification.dependency) keys)
        Result_keys.empty notifications) in
  let selected (continuation : continuation) =
    match result_keys with
    | None -> true
    | Some keys ->
      (* Empty Lost waits need original recovery without a result binding.
         The immutable per-pass index matches sealed typed dependencies only;
         result readiness and intake authority are still read afresh. *)
      continuation.dependencies = [] || List.exists (fun dependency ->
        Result_keys.mem (continuation.journal.base_path,
          continuation.journal.immutable_source.keeper_name,dependency) keys)
        continuation.dependencies in
  let inspect name = filesystem (fun () ->
    let path = Filename.concat directory name in
    match continuation_lock_data_name name with
    | Some data_name ->
      (* Retirement unlinks only the marker data file, leaving this lock
         sibling behind. An existence-only check skips those orphaned locks
         without acquiring or validating them, so each pass stays
         proportional to live markers, not to every historical request. *)
      let data_path = Filename.concat directory data_name in
      if Fs_compat.file_exists data_path then
        let* _ = continuation_snapshot ~root data_path in
        Ok Lock_infrastructure
      else Ok Lock_infrastructure
    | None when not (continuation_data_name name) ->
      Error (Invalid_continuation_marker "unexpected pending partition filename")
    | None ->
      let* snapshot = continuation_snapshot ~root path in
      if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok Retired
      else
        let* marker = decode_continuation_marker snapshot.bytes in
        if name <> continuation_filename marker.request_id
        then Error (Invalid_continuation_marker "marker filename does not bind its request") else
        let* journal = load_authority ~base_path ~keeper_name:marker.keeper_name
            ~composition_run_id:marker.composition_run_id in
        let* state = strict_read ~root journal.path in
        let* () = check_source journal state in
        let* () = match state.resolution with
          | Some _ -> Ok ()
          | None -> validate_artifacts ~base_path journal.immutable_source in
        match Async.load_canonical_durable_terminal ~base_path ~caller:marker.keeper_name marker.request_id with
        | Error (Async.Canonical_terminal_runtime_active _ | Canonical_terminal_nonterminal _) -> Ok Still_waiting
        | Error (Async.Canonical_terminal_absent | Async.Canonical_terminal_unreadable _
            | Async.Canonical_terminal_access_rejected _
            | Async.Canonical_terminal_publication_ambiguous _
            | Async.Canonical_terminal_noncanonical_location _ as error) ->
          Error (Prior_owner_not_terminal
            {request_id=marker.request_id;reason=Async.canonical_terminal_error_to_string error})
        | Ok proof ->
          let entry = Async.durable_terminal_entry proof in
          let* () = entry_matches_source journal.immutable_source entry
            |> Result.map_error (fun reason -> Invalid_continuation_marker reason) in
          let retire () =
            before_retire path;
            let* () = validate_owned_path ~root ~path ~create:true in
            let* receipt = Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_result path
                ~expected:snapshot
              |> Fs_compat.private_jsonl_cursor_success_receipt
              |> Result.map_error (fun error -> Persistence_failed
                  (Fs_compat.private_jsonl_transaction_error_to_string error)) in
            ignore (continuation_receipt path receipt); Ok Retired in
          match state.resolution with
          | Some resolution ->
            if not (String.equal resolution.owner.request_id marker.request_id)
            then Error (Invalid_continuation_marker "resolved owner differs from pending marker") else
            let () = before_retire path in
            let* () = retire_resolution_marker ~root ~path ~snapshot resolution in
            Ok Retired
          | None -> match state.owner with
          | None -> Error (Invalid_continuation_marker "request has no bound journal owner")
          | Some current when current.request_id <> marker.request_id -> retire ()
          | Some _ ->
            match entry.status with
            | Async.Waiting_for_dependencies _ | Lost _ ->
              let* candidate = waiting_continuation journal in
              (match candidate with
               | None when (match entry.status with
                   | Async.Lost _ -> true
                   | Queued | Running | Cancelling _ | Cancelled _ | Persistence_failed _
                   | Waiting_for_dependencies _ | Done _ -> false) -> retire ()
               | None -> Error Ownership_changed
               | Some continuation when continuation_request_id continuation <> marker.request_id -> Error Ownership_changed
               | Some continuation when not (selected continuation) -> Ok Unselected
               | Some continuation ->
                 let* readiness = continuation_readiness ~read_composition_result continuation in
                 match readiness with
                 | Waiting_for_results -> Ok Still_waiting
                 | Results_ready -> Ok (Ready continuation))
            | Cancelled _ | Persistence_failed _ | Done _ -> retire ()
            | Queued | Running | Cancelling _ -> Error (Invalid_continuation_marker "terminal proof has an active status")) in
  let empty = {inspected=0;ready=[];waiting=0;unselected=0;retired=0;failures=[]} in
  let report = List.fold_left (fun report name ->
    match inspect name with
    | Ok Lock_infrastructure -> report
    | Ok (Ready continuation) ->
      (* The original reads have returned and released their authority scopes.
         Scheduling exceptions are not journal/filesystem failures. *)
      on_ready continuation;
      let report = {report with inspected=report.inspected+1} in
      {report with ready=continuation :: report.ready}
    | Ok Still_waiting ->
      let report = {report with inspected=report.inspected+1} in
      {report with waiting=report.waiting+1}
    | Ok Unselected ->
      {report with inspected=report.inspected+1;unselected=report.unselected+1}
    | Ok Retired ->
      let report = {report with inspected=report.inspected+1} in
      {report with retired=report.retired+1}
    (* Permanent Invalid_result retains its marker unless an explicit, durable
       owner-bound resolution seals this run and its exact marker snapshot.
       Missing authority never becomes retirement or replacement dispatch. *)
    | Error error ->
      let report = {report with inspected=report.inspected+1} in
      {report with failures=(name,error) :: report.failures}) empty names in
  Ok {report with ready=List.rev report.ready;failures=List.rev report.failures}

let discover_pending_continuations ~scope ~on_ready ~read_composition_result ~base_path =
  pending_continuations_with ~scope ~before_retire:(fun _ -> ()) ~on_ready ~read_composition_result ~base_path

let pending_continuations ~read_composition_result ~base_path =
  discover_pending_continuations ~scope:All_pending ~on_ready:ignore ~read_composition_result ~base_path

module For_testing = struct
  let pending_continuations ~before_retire ~read_composition_result ~base_path =
    pending_continuations_with ~scope:All_pending ~before_retire ~on_ready:ignore ~read_composition_result ~base_path
end
