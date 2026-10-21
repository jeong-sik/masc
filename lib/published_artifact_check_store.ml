module Check = Published_artifact_check
module Artifacts = Published_artifact_store

type error =
  | Invalid of string
  | Artifact_error of Artifacts.error
  | Conflict of Check.t option
  | Unavailable of string
  | Commit_uncertain of Check.t
type listing = { checks : Check.t list; diagnostics : (string * string) list }

let ( let* ) = Result.bind
let error_message = function
  | Invalid message | Unavailable message -> message
  | Artifact_error error -> Artifacts.error_message error
  | Conflict _ -> "artifact check changed; refresh before changing it"
  | Commit_uncertain _ -> "artifact check may have been saved; reread before retrying"

let root ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "published_artifact_checks"
let filename (target : Check.target) =
  target.id ^ "-r" ^ string_of_int target.revision ^ ".json"
let path ~base_path target = Filename.concat (root ~base_path) (filename target)

let protect f = try f () with
  | Sys_error message -> Error (Unavailable message)
  | Unix.Unix_error (error, operation, _) ->
    Error (Unavailable (operation ^ ": " ^ Unix.error_message error))

let directory_entries ~base_path =
  match Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path (root ~base_path) with
  | Ok entries -> Ok entries
  | Error error -> Error (Unavailable (Fs_compat.owned_regular_file_read_error_to_string error))

let read_snapshot ~base_path name =
  let file = Filename.concat (root ~base_path) name in
  (* Validate the owned parent and data leaf before entering the shared stable
     transaction protocol. Its lock is created exclusively and an existing
     leaf is bound to its regular descriptor before any marker write. *)
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path file with
  | Error _ -> Error (Unavailable "artifact check could not be read")
  | Ok (None | Some _) ->
    let* _ = Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
      ~ownership_root:base_path (Fs_compat.private_jsonl_lock_path file)
      |> Result.map_error (fun _ -> Unavailable "artifact check lock is not an owned regular file") in
    Fs_compat.read_private_jsonl_durable_locked_result file ~after:None
    |> Result.map_error (fun error -> Unavailable
      (Fs_compat.private_jsonl_transaction_error_to_string error))

let decode_snapshot name (snapshot : Fs_compat.private_jsonl_snapshot) =
  if Fs_compat.Private_jsonl_cursor.is_missing snapshot.cursor then Ok None
  else
    let content = snapshot.bytes in
    if not (String.is_valid_utf_8 content) then Error (Unavailable "artifact check is not valid UTF-8")
    else match Yojson.Safe.from_string content with
      | json ->
        (match Check.of_json json with
         | Error message -> Error (Unavailable ("invalid artifact check: " ^ message))
         | Ok check ->
           if String.equal name (filename check.target) then Ok (Some check)
           else Error (Unavailable "artifact check filename identity mismatch"))
      | exception Yojson.Json_error _ -> Error (Unavailable "invalid artifact check JSON")

let load_file ~base_path name =
  let* snapshot = read_snapshot ~base_path name in
  decode_snapshot name snapshot

let list ~base_path = protect (fun () ->
  let* entries = directory_entries ~base_path in
  let checks, diagnostics = List.fold_left (fun (checks, diagnostics) name ->
    if not (Filename.check_suffix name ".json") then checks, diagnostics
    else match load_file ~base_path name with
      | Ok (Some check) -> check :: checks, diagnostics
      | Ok None -> checks, (name, "artifact check disappeared during listing; refresh") :: diagnostics
      | Error error -> checks, (name, error_message error) :: diagnostics)
    ([],[]) (Option.value ~default:[] entries) in
  Ok {checks=List.rev checks;diagnostics=List.rev diagnostics})

let set_with_rewrite ~rewrite ~base_path ~actor (request : Check.request) = protect (fun () ->
  let* (_, revision, _) =
    Artifacts.read ~base_path ~id:request.target.id ~revision:(Some request.target.revision)
    |> Result.map_error (fun error -> Artifact_error error) in
  let* () = if String.equal revision.body.sha256 request.target.body_sha256 then Ok ()
    else Error (Invalid "artifact revision digest mismatch") in
  let dir = root ~base_path in
  let* _ = directory_entries ~base_path in
  let* () = match Keeper_fs_durable_directory.ensure
    ~before_prepare:(fun () -> ()) ~before_directory_fsync:(fun _ -> ())
    ~ownership_root:base_path dir with
    | Ok _ -> Ok ()
    | Error _ -> Error (Unavailable "artifact check directory could not be prepared") in
  let* _ = directory_entries ~base_path in
  let file = path ~base_path request.target in
  let name = filename request.target in
  let* snapshot = read_snapshot ~base_path name in
  let* previous = decode_snapshot name snapshot in
  let* () = match previous with
    | Some check when not (Check.same_target check.target request.target) ->
      Error (Unavailable "stored check revision digest mismatch")
    | None | Some _ -> Ok () in
  let previous_change = Option.map (fun (check : Check.t) -> check.change_id) previous in
  if previous_change <> request.expected_change_id then Error (Conflict previous)
  else
    let change_id = Random_id.prefixed ~prefix:"check-" ~bytes:16 in
    let* () = if Some change_id = previous_change then Error (Unavailable "check identity collision")
      else Ok () in
    let* check = Check.create ~actor ~at:(Types_core.now_iso ()) ~change_id request
      |> Result.map_error (fun message -> Invalid message) in
    let rec failed = function
      | Fs_compat.Cursor_mismatch _ ->
        let* current = load_file ~base_path name in Error (Conflict current)
      | Rewrite_published_durability_unknown _ -> Error (Commit_uncertain check)
      | Transaction_settlement_failed {primary=Transaction_succeeded (Cursor_succeeded _);_} ->
        Error (Commit_uncertain check)
      | Transaction_settlement_failed
          {primary=Transaction_succeeded (Snapshot_succeeded _ | Cursor_precondition_succeeded _);_} as error ->
        Error (Unavailable (Fs_compat.private_jsonl_transaction_error_to_string error))
      | Transaction_settlement_failed {primary=Transaction_failed error;_} -> failed error
      | (Stable_lock_contended _ | Unexpected_stable_lock_permissions _
        | Invalid_stable_lock_state _ | Unexpected_transaction_file_kind _
        | Ambiguous_transaction_file_identity _ | Transaction_path_binding_changed _
        | Transaction_content_changed _ | Incomplete_transaction_tail _
        | Invalid_transaction_suffix | Private_jsonl_operation_failed _
        | Rewrite_stage_failed _ | Transaction_append_failed _) as error ->
        Error (Unavailable (Fs_compat.private_jsonl_transaction_error_to_string error)) in
    match rewrite file ~expected:snapshot.cursor (Yojson.Safe.to_string (Check.to_json check) ^ "\n") with
    | Ok _ -> Ok check
    | Error error -> failed error)

let set ~base_path ~actor request =
  set_with_rewrite ~rewrite:Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
    ~base_path ~actor request

module For_testing = struct
  let set_with_rewrite_io ~io ~base_path ~actor request =
    set_with_rewrite
      ~rewrite:(Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_with_io_for_testing ~io)
      ~base_path ~actor request
end
