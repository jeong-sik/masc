(** Keeper decisions are task-history events, distinct from Fusion judge advice. *)
let ( let* ) = Result.bind

type disposition = Adopted | Rejected | Modified
let disposition_to_string = function Adopted -> "adopted" | Rejected -> "rejected" | Modified -> "modified"
let disposition_of_string = function
  | "adopted" -> Ok Adopted | "rejected" -> Ok Rejected | "modified" -> Ok Modified
  | _ -> Error "decision must be adopted, rejected or modified"

type error = Rejected of string | Storage_failure of string
let error_to_string = function Rejected detail | Storage_failure detail -> detail
let failure_class = function
  | Rejected _ -> Tool_result.Workflow_rejection
  | Storage_failure _ -> Tool_result.Runtime_failure

type recorded = { event : Yojson.Safe.t; cleanup_warning : string option }

type proposal = { run_id:string; task_id:string; disposition:disposition; choice:string; reason:string }
let parse json =
  let* fields = match json with `Assoc fields -> Ok fields | _ -> Error "decision must be an object" in
  let names = List.map fst fields in
  if List.exists (fun name -> not (List.mem name ["run_id"; "task_id"; "decision"; "choice"; "reason"])) names
     || List.length names <> List.length (List.sort_uniq String.compare names)
  then Error "unknown or duplicate decision fields"
  else
    let string name = match List.assoc_opt name fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | _ -> Error (name ^ " must be nonblank") in
    let* run_id = string "run_id" in
    let* task_id = string "task_id" in
    let* decision = string "decision" in
    let* disposition = disposition_of_string decision in
    let* choice = string "choice" in
    let* reason = string "reason" in
    Ok {run_id; task_id; disposition; choice; reason}

let source ~keeper ~run_id =
  match Board_dispatch.find_post_by_run_id ~run_id with
  | Some post when Board.Agent_id.to_string post.author = keeper ->
    (match post.origin with
     | Some {source=Some "fusion"; fusion_run_id=Some actual; _} when actual=run_id -> Ok post
     | _ -> Error (Rejected "source is not exact Fusion evidence"))
  (* A run owned by another Keeper and a run that does not exist answer with the
     same sentence. Two sentences let a Keeper walk run ids and learn which ones
     exist under someone else; neither case is this caller's evidence, so
     neither needs a word of its own. The mismatch inside the owned branch above
     keeps its own message -- that post is the caller's already. *)
  | Some _ | None -> Error (Rejected "Fusion run has no durable deliberation evidence")

let evidence_sha256 (post : Board.post) =
  Digestif.SHA256.(digest_string (Yojson.Safe.to_string
    (`Assoc ["body", `String post.body; "meta", (match post.meta_json with Some json -> json | None -> `Null)])) |> to_hex)

let evidence_sha256 (post : Board.post) =
  Digestif.SHA256.(digest_string (Yojson.Safe.to_string
    (`Assoc ["body", `String post.body; "meta", (match post.meta_json with Some json -> json | None -> `Null)])) |> to_hex)

let validate_event json =
  let names = ["type"; "decision_id"; "fusion_run_id"; "fusion_post_id"; "fusion_evidence_sha256"; "task";
    "goal_ids"; "agent"; "actor_kind"; "turn_ref"; "decision"; "choice"; "reason"; "notes"; "ts"] in
  let* fields = match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields) = List.sort String.compare names -> Ok fields
    | _ -> Error "invalid Fusion decision event fields" in
  let value key = List.assoc key fields in
  let string key = match value key with `String text when String.trim text <> "" -> Ok text
    | _ -> Error ("invalid decision event " ^ key) in
  let* _ = List.fold_left (fun result key -> let* () = result in let* _ = string key in Ok ()) (Ok ())
    ["decision_id"; "fusion_run_id"; "fusion_post_id"; "fusion_evidence_sha256"; "task"; "agent"; "choice"; "reason"; "notes"; "ts"] in
  let* decision = string "decision" in
  let* _ = disposition_of_string decision in
  let* _ = Ids.Turn_ref.of_yojson (value "turn_ref") in
  let* () = match value "goal_ids" with
    | `List goals when List.for_all (function `String id -> String.trim id <> "" | _ -> false) goals -> Ok ()
    | _ -> Error "invalid decision Goal context" in
  if value "actor_kind" <> `String "keeper" then Error "invalid decision actor kind" else Ok json

let events_root config = Filename.concat (Workspace.masc_dir config) "events"
let protect f = try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _ | Eio.Io _ | Yojson.Json_error _) as exn -> Error (Storage_failure (Printexc.to_string exn))

(* Read the existing task event journal without an arbitrary history cap. A
   malformed row prevents a new write from guessing whether its identity exists. *)
let read ~config ~run_id = protect (fun () ->
  let root = events_root config in
  let rows = ref [] in
  if Sys.file_exists root then
    Array.iter (fun month ->
      let directory = Filename.concat root month in
      if Sys.is_directory directory then
        Array.iter (fun name ->
          if Filename.check_suffix name ".jsonl" then
            Fs_compat.load_file (Filename.concat directory name)
            |> String.split_on_char '\n'
            |> List.iter (fun line -> if String.trim line <> "" then
              let json = Yojson.Safe.from_string line in
              if Json_util.get_string json "type" = Some "fusion_decision"
                 && Json_util.get_string json "fusion_run_id" = Some run_id
              then (match validate_event json with
                | Ok event -> rows := event :: !rows
                | Error detail -> raise (Yojson.Json_error detail)))) (Sys.readdir directory)) (Sys.readdir root);
  Ok (List.sort (fun a b -> compare (Json_util.get_string a "ts") (Json_util.get_string b "ts")) !rows))

let record ~config ~keeper ~turn_ref proposal = protect (fun () ->
  let* post = source ~keeper ~run_id:proposal.run_id in
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
  let decision_id = Digestif.SHA256.(digest_string (Yojson.Safe.to_string identity) |> to_hex) in
  let evidence_sha256 = evidence_sha256 post in
  let fields = ["fusion_evidence_sha256", `String evidence_sha256; "type", `String "fusion_decision"; "decision_id", `String decision_id;
    "fusion_run_id", `String proposal.run_id; "fusion_post_id", `String (Board.Post_id.to_string post.id);
    "task", `String proposal.task_id; "goal_ids", `List (List.map (fun id -> `String id) goal_ids);
    "agent", `String keeper; "actor_kind", `String "keeper"; "turn_ref", Ids.Turn_ref.to_yojson turn_ref;
    "decision", `String (disposition_to_string proposal.disposition); "choice", `String proposal.choice;
    "reason", `String proposal.reason; "notes", `String ("Fusion " ^ disposition_to_string proposal.disposition ^ ": " ^ proposal.choice ^ " — " ^ proposal.reason)] in
  Workspace_utils.with_file_lock config (Filename.concat (events_root config) "fusion-decision.lock") (fun () ->
    let* existing = read ~config ~run_id:proposal.run_id in
    match List.find_opt (fun row -> Json_util.get_string row "decision_id" = Some decision_id) existing with
    | Some (`Assoc stored as row) ->
      if List.for_all (fun (key,value) -> List.assoc_opt key stored = Some value) fields then Ok {event=row; cleanup_warning=None}
      else Error (Rejected "this turn already recorded a different decision for this run and task")
    | Some _ -> Error (Storage_failure "invalid existing decision event")
    | None ->
      let event = `Assoc (fields @ ["ts", `String (Masc_domain.now_iso ())]) in
      let dated = Jsonl_writer.dated_path_now ~base_dir:(events_root config) in
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
  let* rows = read ~config ~run_id in
  Ok (List.filter (fun row -> Json_util.get_string row "agent" = Some keeper) rows)

let read_to_yojson = function
  | Ok records -> `Assoc ["state", `String "available"; "records", `List records]
  | Error error -> `Assoc ["state", `String "unavailable"; "detail", `String (error_to_string error)]
