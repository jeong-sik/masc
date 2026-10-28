module Draft = Artifact_draft
module Engine = Artifact_document_engine
module Artifacts = Published_artifact_store
module Discussion = Artifact_discussion
type error =
  | Invalid of string
  | Missing
  | Generation_conflict of Draft.target
  | Discussion_conflict of string
  | Artifact_error of Artifacts.error
  | Transform_error of Engine.error
  | Unavailable of string
  | Commit_uncertain of Draft.t
type view = { draft : Draft.t; content : string; selection : (Draft.selection * int * int) option }
open Result.Syntax
let error_message = function
  | Invalid message | Unavailable message | Discussion_conflict message -> message
  | Missing -> "shared draft not found"
  | Generation_conflict _ -> "shared draft generation changed; reopen the document"
  | Artifact_error error -> Artifacts.error_message error
  | Transform_error error -> Engine.error_message error
  | Commit_uncertain _ -> "draft may have been saved; reread before retrying"
let view_to_json view = Draft.document_to_json ~draft:view.draft ~content:view.content ~selection:view.selection
let root ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "artifact_drafts"
let path ~base_path artifact_id = Filename.concat (root ~base_path) (artifact_id ^ ".json")
let protect f = try f () with
  | Sys_error message -> Error (Unavailable message)
  | Unix.Unix_error (error, operation, _) -> Error (Unavailable (operation ^ ": " ^ Unix.error_message error))
let directory ~base_path =
  Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ()) ~ownership_root:base_path (root ~base_path)
  |> Result.map_error (fun error -> Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
let prepare ~base_path =
  let* _ = directory ~base_path in
  let* _ = Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
    ~before_directory_fsync:(fun _ -> ()) ~ownership_root:base_path (root ~base_path)
    |> Result.map_error (fun _ -> Unavailable "shared draft directory could not be prepared") in
  let* _ = directory ~base_path in Ok ()
let load ~base_path artifact_id =
  let file = path ~base_path artifact_id in
  let check file = Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
      ~ownership_root:base_path file |> Result.map_error (fun _ -> Unavailable "shared draft path is not an owned regular file") in
  let* _ = check file in let* _ = check (Fs_compat.private_jsonl_lock_path file) in
  let* snapshot = Fs_compat.read_private_jsonl_durable_locked_result file ~after:None
    |> Result.map_error (fun error -> Unavailable (Fs_compat.private_jsonl_transaction_error_to_string error)) in
  let* draft = if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok None
    else if not (String.is_valid_utf_8 snapshot.bytes) then Error (Unavailable "draft metadata is not UTF-8")
    else match Yojson.Safe.from_string snapshot.bytes with
      | json ->
        let* draft = Draft.of_json json |> Result.map_error (fun message -> Unavailable message) in
        if String.equal draft.target.artifact_id artifact_id then Ok (Some draft)
        else Error (Unavailable "draft filename identity mismatch")
      | exception Yojson.Json_error _ -> Error (Unavailable "invalid shared draft JSON") in
  Ok (snapshot, draft)
let transformed result = Result.map_error (fun error -> Transform_error error) result
let source_limit (snapshot : Engine.snapshot) =
  if String.length snapshot.content > Tool_blob_store.max_served_bytes then Error (Invalid "draft exceeds artifact body limit")
  else Ok ()
let observe ?runner draft =
  let* snapshot = Engine.merge ?runner ~state:draft.Draft.state ~updates:[] () |> transformed in
  let* () = source_limit snapshot in Ok { draft; content = snapshot.content; selection = None }
let matching (target : Draft.target) (draft : Draft.t) =
  if target = draft.target then Ok () else Error (Generation_conflict draft.target)

(* A cursor mismatch proves this attempt did not commit. Merge/edit can be
   recomputed against the winner. An uncertain commit is never retried. *)
let rec write_error draft = function
  | Fs_compat.Cursor_mismatch _ -> Ok `Retry
  | Rewrite_published_durability_unknown _ -> Error (Commit_uncertain draft)
  | Transaction_settlement_failed { primary = Transaction_succeeded (Cursor_succeeded _); _ } -> Error (Commit_uncertain draft)
  | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> write_error draft error
  | (Transaction_settlement_failed { primary = Transaction_succeeded (Snapshot_succeeded _ | Cursor_precondition_succeeded _); _ }
    | Stable_lock_contended _ | Unexpected_stable_lock_permissions _ | Invalid_stable_lock_state _
    | Unexpected_transaction_file_kind _ | Ambiguous_transaction_file_identity _ | Transaction_path_binding_changed _
    | Transaction_content_changed _ | Incomplete_transaction_tail _ | Invalid_transaction_suffix
    | Private_jsonl_operation_failed _ | Rewrite_stage_failed _ | Transaction_append_failed _) as error ->
    Error (Unavailable (Fs_compat.private_jsonl_transaction_error_to_string error))
let commit ~base_path (snapshot : Fs_compat.private_jsonl_snapshot) draft =
  match Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
    (path ~base_path draft.Draft.target.artifact_id) ~expected:snapshot.cursor (Yojson.Safe.to_string (Draft.to_json draft) ^ "\n") with
  | Ok _ -> Ok `Saved
  | Error error -> write_error draft error
let read ?runner ~base_path ~artifact_id () = protect (fun () ->
  if not (Published_artifact.valid_id artifact_id) then Error (Invalid "invalid artifact id")
  else let* exists = directory ~base_path in
    match exists with None -> Error Missing | Some _ ->
      let* _, draft = load ~base_path artifact_id in
      match draft with None -> Error Missing | Some draft -> observe ?runner draft)
let open_draft ?runner ~base_path ~actor ~artifact_id ~revision () =
  let* _, base, content = Artifacts.read ~base_path ~id:artifact_id ~revision:(Some revision)
    |> Result.map_error (fun error -> Artifact_error error) in
  let* () = prepare ~base_path in
  let rec attempt () =
    let* snapshot, previous = load ~base_path artifact_id in
    match previous with
    | Some draft -> observe ?runner draft
    | None ->
      let* source = Engine.seed ?runner content |> transformed in let* () = source_limit source in
      let target = { Draft.artifact_id; generation = Random_id.uuid_v7 () } in
      let* draft = Draft.create ~target ~base_revision:base.revision ~base_sha256:base.body.sha256
        ~state:source.state ~actor ~at:(Types_core.now_iso ()) |> Result.map_error (fun message -> Invalid message) in
      let* committed = commit ~base_path snapshot draft in
      match committed with `Retry -> attempt () | `Saved -> Ok { draft; content = source.content; selection = None } in
  attempt ()
let mutate ?runner ~base_path ~actor (target : Draft.target) transform =
  if not (Published_artifact.valid_id target.artifact_id) then Error (Invalid "invalid artifact id")
  else let* exists = directory ~base_path in match exists with None -> Error Missing | Some _ ->
  let rec attempt () =
    let* snapshot, previous = load ~base_path target.artifact_id in
    let* previous = match previous with None -> Error Missing | Some draft -> Ok draft in
    let* () = matching target previous in
    let* source, selection, discussion = transform ?runner previous in let* () = source_limit source in
    if String.equal source.state previous.state && discussion = previous.discussion then Ok { draft = previous; content = source.content; selection }
    else
      let* draft = Draft.advance ~discussion previous ~state:source.state ~actor ~at:(Types_core.now_iso ())
        |> Result.map_error (fun message -> Invalid message) in
      let* committed = commit ~base_path snapshot draft in
      match committed with `Retry -> attempt () | `Saved -> Ok { draft; content = source.content; selection } in
  attempt ()
let execute_command ?runner ~base_path ~actor command = protect (fun () ->
  if String.trim actor = "" || not (String.is_valid_utf_8 actor) then Error (Invalid "actor must be nonblank UTF-8")
  else match command with
  | Draft.Open { artifact_id; revision } -> open_draft ?runner ~base_path ~actor ~artifact_id ~revision ()
  | Merge { target; updates } -> mutate ?runner ~base_path ~actor target (fun ?runner draft ->
      let* source = Engine.merge ?runner ~state:draft.Draft.state ~updates () |> transformed in Ok (source, None, draft.discussion))
  | Select { target; anchor; head } ->
    let* view = read ?runner ~base_path ~artifact_id:target.artifact_id () in let* () = matching target view.draft in
    let* selected = Engine.select ?runner ~state:view.draft.state ~anchor ~head () |> transformed in
    Ok { view with selection = Some ({ Draft.target; position = selected.selection }, selected.anchor, selected.head) }
  | Edit { selection; expected; replacement } ->
    mutate ?runner ~base_path ~actor selection.target (fun ?runner draft ->
      let* edited = Engine.edit ?runner ~state:draft.Draft.state ~selection:selection.position ~expected ~replacement () |> transformed in
      Ok (edited.snapshot, Some ({ Draft.target = selection.target; position = edited.selection }, edited.anchor, edited.head), draft.discussion))
  | Resolve selection ->
    let* view = read ?runner ~base_path ~artifact_id:selection.target.artifact_id () in
    let* () = matching selection.target view.draft in
    let* selected = Engine.resolve ?runner ~state:view.draft.state ~selection:selection.position () |> transformed in
    Ok { view with selection = Some (selection, selected.anchor, selected.head) }
  | Discuss { target; request } ->
    mutate ?runner ~base_path ~actor target (fun ?runner draft ->
      let* existing = Discussion.check draft.discussion ~actor request
        |> Result.map_error (fun message -> Discussion_conflict message) in
      let source () = Engine.merge ?runner ~state:draft.state ~updates:[] () |> transformed in
      match existing with
      | Some _ -> let* snapshot = source () in Ok (snapshot, None, draft.discussion)
      | None ->
        let* snapshot, selection, applied = match request.command with
          | Discussion.Comment { position; quote; _ } ->
            let* selected = Engine.resolve ?runner ~state:draft.state ~selection:position () |> transformed in
            let* actual = Engine.selected_text selected |> transformed in
            if actual <> quote then Error (Transform_error { Engine.kind = Changed_selection; message = "selected comment source changed; reread before commenting" })
            else Ok (selected.snapshot, Some ({ Draft.target; position }, selected.anchor, selected.head), None)
          | Accept thread_id ->
            (* [check] proved this thread exists and still has a pending proposal. *)
            let* threads = Discussion.threads draft.discussion |> Result.map_error (fun message -> Discussion_conflict message) in
            let thread = List.find (fun (thread : Discussion.thread) -> thread.id = thread_id) threads in
            let replacement = Option.get thread.proposal in
            let* edited = Engine.edit ?runner ~state:draft.state ~selection:thread.position ~expected:thread.quote ~replacement () |> transformed in
            Ok (edited.snapshot, Some ({ Draft.target; position = edited.selection }, edited.anchor, edited.head), Some edited.selection)
          | Reply _ | Resolve _ | Reopen _ | Reject _ -> let* snapshot = source () in Ok (snapshot, None, None) in
        let* discussion = Discussion.append draft.discussion ~actor ~at:(Types_core.now_iso ()) request ~applied
          |> Result.map_error (fun message -> Discussion_conflict message) in
        Ok (snapshot, selection, discussion)))

let execute ?runner ~base_path ~actor command =
  let result = execute_command ?runner ~base_path ~actor command in
  (match result with Error _ -> () | Ok view -> Artifact_draft_live.publish ~base_path ~draft:view.draft ~content:view.content);
  result
