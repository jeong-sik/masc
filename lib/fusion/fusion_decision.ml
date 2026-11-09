(** Keeper decisions are task-history events, distinct from Fusion judge advice. *)
open Result.Syntax

module Event = Fusion_decision_event

type disposition = Event.disposition = Adopted | Rejected | Modified

type error = Rejected of string | Storage_failure of string
let error_to_string = function Rejected detail | Storage_failure detail -> detail
let failure_class = function
  | Rejected _ -> Tool_result.Workflow_rejection
  | Storage_failure _ -> Tool_result.Runtime_failure

type recorded = { event : Yojson.Safe.t; cleanup_warning : string option }

type proposal = Event.proposal
let parse = Event.parse

let validate_source ~run_id (post : Board.post) =
  match post.origin with
  | Some {source=Some "fusion"; fusion_run_id=Some actual; fusion_producer=Some producer; _}
    when actual=run_id && String.trim producer <> "" -> Ok post
  | _ -> Error (Rejected "source is not exact Fusion evidence")

let source_in_workspace ~run_id =
  match Board_dispatch.find_post_by_run_id_unchecked ~run_id with
  | Some post -> validate_source ~run_id post
  | None -> Error (Rejected "Fusion run has no durable deliberation evidence")

let source_owned_by ~keeper (post : Board.post) =
  match post.origin with
  | Some {fusion_producer=Some producer; _} -> String.equal producer keeper
  | Some {fusion_producer=None; _} | None -> false

let source ~keeper ~run_id =
  match Board_dispatch.find_post_by_run_id_unchecked ~run_id with
  | Some post when source_owned_by ~keeper post ->
    validate_source ~run_id post
  (* A run owned by another Keeper and a run that does not exist answer with the
     same sentence. Two sentences let a Keeper walk run ids and learn which ones
     exist under someone else; neither case is this caller's evidence, so
     neither needs a word of its own. The mismatch inside the owned branch above
     keeps its own message -- that post is the caller's already. *)
  | Some _ | None -> Error (Rejected "Fusion run has no durable deliberation evidence")

let evidence_sha256 (post : Board.post) =
  Agent_core_sha256.(digest_string (Yojson.Safe.to_string
    (`Assoc ["body", `String post.body; "meta", (match post.meta_json with Some json -> json | None -> `Null)])) |> to_hex)

let events_location config =
  Dated_jsonl.Store.at
    (Workspace.dated_store_root config)
    Dated_jsonl.Store.Root.Events
let events_root config = Dated_jsonl.Store.dir (events_location config)
let protect f = try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _ | Eio.Io _ | Yojson.Json_error _) as exn -> Error (Storage_failure (Printexc.to_string exn))

(* Read the existing task event journal without an arbitrary history cap. A
   malformed row prevents a new write from guessing whether its identity exists. *)
let read_events ~config ~run_id = protect (fun () ->
  let root = events_root config in
  let rows = ref [] in
  if Sys.file_exists root then (
    let months = Sys.readdir root in
    Array.sort String.compare months;
    Array.iter (fun month ->
      let directory = Filename.concat root month in
      if Sys.is_directory directory then (
        let files = Sys.readdir directory in
        Array.sort Dated_jsonl.Layout.compare_day_files files;
        Array.iter (fun name ->
          if Filename.check_suffix name ".jsonl" then
            Fs_compat.load_file (Filename.concat directory name)
            |> String.split_on_char '\n'
            |> List.iter (fun line -> if String.trim line <> "" then
              let json = Yojson.Safe.from_string line in
              match Event.select_for_run ~run_id json with
              | Ok None -> ()
              | Ok (Some event) -> rows := event :: !rows
              | Error detail -> raise (Yojson.Json_error detail))) files)) months);
  Ok (List.stable_sort (fun a b -> String.compare (Event.timestamp a) (Event.timestamp b)) (List.rev !rows)))

let read ~config ~run_id =
  Result.map (List.map Event.to_yojson) (read_events ~config ~run_id)

(* The Task a decision on this run may name: the one the request was captured
   for, read from the evidence post's source_context. Checking only that the
   named Task exists and is assigned to the caller let a decision on an
   unscoped or Goal-only run -- or a run requested for another Task -- bind its
   evidence hash to whatever Task the Keeper held. A decision lives in a Task's
   history; a run with no Task has none to write into. *)
let run_task ~run_id (post : Board.post) =
  let context = match post.meta_json with
    | Some (`Assoc fields) -> List.assoc_opt "source_context" fields
    | Some _ | None -> None in
  match context with
  | None | Some `Null -> Ok None
  | Some json ->
    (match Fusion_request_context.of_yojson json with
     | Ok context -> Ok (Fusion_request_context.task_id context)
     | Error detail ->
       Error (Storage_failure (Printf.sprintf
         "Fusion run %s evidence carries an unreadable source_context: %s" run_id detail)))

let record ~config ~keeper ~turn_ref (proposal : proposal) = protect (fun () ->
  let* post = source ~keeper ~run_id:proposal.run_id in
  let* () = match run_task ~run_id:proposal.run_id post with
    | Error _ as error -> error
    | Ok None ->
      Error (Rejected (Printf.sprintf
        "Fusion run %s was not requested for a Task, so there is no Task decision to record"
        proposal.run_id))
    | Ok (Some task_id) when String.equal task_id proposal.task_id -> Ok ()
    | Ok (Some task_id) ->
      Error (Rejected (Printf.sprintf
        "decision task %s is not the Task Fusion run %s was requested for (%s)"
        proposal.task_id proposal.run_id task_id)) in
  Workspace_utils.with_file_lock config (Workspace_backlog.backlog_lock_path config) (fun () ->
  let* backlog = Workspace_backlog.read_backlog_r config |> Result.map_error (fun detail -> Storage_failure detail) in
  let* task = match List.find_opt (fun (task : Masc_domain.task) -> task.id = proposal.task_id) backlog.tasks with
    | Some task -> Ok task | None -> Error (Rejected "task does not exist") in
  let* () = if Masc_domain.task_assignee_of_status task.task_status = Some keeper then Ok ()
    else Error (Rejected "decision task is not assigned to this Keeper") in
  let* links = Workspace_goal_index.read_goal_task_links_authoritative_r config |> Result.map_error (fun detail -> Storage_failure detail) in
  let goal_ids = List.filter_map (fun (goal_id, tasks) -> if List.mem proposal.task_id tasks then Some goal_id else None) links
    |> List.sort_uniq String.compare in
  let identity = `Assoc ["fusion_run_id", `String proposal.run_id; "task", `String proposal.task_id;
    "agent", `String keeper; "turn_ref", Ids.Turn_ref.to_yojson turn_ref] in
  let decision_id = Agent_core_sha256.(digest_string (Yojson.Safe.to_string identity) |> to_hex) in
  let evidence_sha256 = evidence_sha256 post in
  let payload = Event.prepare ~decision_id ~evidence_sha256
      ~post_id:(Board.Post_id.to_string post.id) ~goal_ids ~agent:keeper ~turn_ref proposal in
  Workspace_utils.with_file_lock config (Filename.concat (events_root config) "fusion-decision.lock") (fun () ->
    let* existing = read_events ~config ~run_id:proposal.run_id in
    match List.find_opt (fun event -> String.equal (Event.decision_id event) decision_id) existing with
    | Some event ->
      if Event.matches_payload event payload then Ok {event=Event.to_yojson event; cleanup_warning=None}
      else Error (Rejected "this turn already recorded a different decision for this run and task")
    | None ->
      let event = Event.encode payload ~timestamp:(Masc_domain.now_iso ()) in
      let dated = Dated_jsonl.Store.dated_path_now (events_location config) in
      (match Fs_compat.append_private_jsonl_durable_locked_result dated.path (Yojson.Safe.to_string event ^ "\n") with
       | Fs_compat.Private_file_succeeded () -> Ok {event; cleanup_warning=None}
       | Fs_compat.Private_file_succeeded_with_cleanup_failure {cleanup_failure; _} ->
         Ok {event; cleanup_warning=Some (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)}
       | Fs_compat.Private_file_failed error ->
         Error (Storage_failure (Fs_compat.private_jsonl_append_error_to_string error))
       | Fs_compat.Private_file_failed_with_cleanup_failure {error; cleanup_failure} ->
         Error (Storage_failure (Fs_compat.private_jsonl_append_error_to_string error ^ "; cleanup: "
           ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))))))

let read_for_keeper ~config ~keeper ~run_id =
  let* _ = source ~keeper ~run_id in
  let* rows = read_events ~config ~run_id in
  Ok (List.filter (fun event -> String.equal (Event.agent event) keeper) rows
      |> List.map Event.to_yojson)

let read_to_yojson = function
  | Ok records -> `Assoc ["state", `String "available"; "records", `List records]
  | Error error -> `Assoc ["state", `String "unavailable"; "detail", `String (error_to_string error)]
