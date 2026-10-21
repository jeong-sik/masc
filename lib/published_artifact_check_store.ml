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

let load_file ~base_path name =
  match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.geteuid ())
    ~ownership_root:base_path (Filename.concat (root ~base_path) name) with
  | Error _ -> Error (Unavailable "artifact check could not be read")
  | Ok None -> Ok None
  | Ok (Some {content;_}) ->
    if not (String.is_valid_utf_8 content) then Error (Unavailable "artifact check is not valid UTF-8")
    else match Yojson.Safe.from_string content with
      | json ->
        (match Check.of_json json with
         | Error message -> Error (Unavailable ("invalid artifact check: " ^ message))
         | Ok check ->
           if String.equal name (filename check.target) then Ok (Some check)
           else Error (Unavailable "artifact check filename identity mismatch"))
      | exception Yojson.Json_error _ -> Error (Unavailable "invalid artifact check JSON")

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

let set ~base_path ~actor (request : Check.request) = protect (fun () ->
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
  match File_lock_eio.with_durable_lock_observed
    ~lock_path:(path ~base_path request.target ^ ".lock") (fun () ->
      let* previous = load_file ~base_path (filename request.target) in
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
        match Keeper_fs.save_json_durable_atomic ~ownership_root:base_path
          (path ~base_path request.target) (Check.to_json check) with
        | Ok () -> Ok check
        | Error error ->
          if error.renamed then Error (Commit_uncertain check)
          else Error (Unavailable (Keeper_fs.durable_write_error_to_string error))) with
  | File_lock_eio.Lock_not_acquired error ->
    Error (Unavailable (File_lock_eio.durable_lock_error_to_string error))
  | File_lock_eio.Body_completed {value;release_error=None} -> value
  | File_lock_eio.Body_completed {value;release_error=Some error} ->
    Log.Misc.error "artifact check lock release: %s"
      (File_lock_eio.durable_lock_error_to_string error);
    value)
