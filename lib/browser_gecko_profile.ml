let ( let* ) = Result.bind
module Requirement = Resource_requirement
module Profile = Private_browser_profile

let lock_name = ".parentlock"
let label = "Gecko profile"
let root_label = "Gecko profile root"
let instance_label = "Gecko instance profiles"

let root ~lane_addon_root = Filename.concat lane_addon_root "gecko-profiles"

let protect ~label path run =
  try run () with Unix.Unix_error (error, call, _) ->
    Error (Printf.sprintf "%s %s: %s failed: %s" label path call (Unix.error_message error))

let ensure_directory path = try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let checked ~label path =
  let* _ = Requirement.lstat ~label Requirement.private_directory path in
  Requirement.canonical ~label path

let is_masc_name text = match Uuidm.of_string text with
  | Some uuid -> String.equal (Uuidm.to_string uuid) text
  | None -> false

let prepare_instance ~root ~instance_id =
  if not (is_masc_name instance_id) then
    Error (Printf.sprintf "%s require a canonical instance UUID; it is %S" instance_label instance_id)
  else protect ~label:root_label root (fun () ->
    ensure_directory root;
    (* Resolve the parent only: a symlinked root is refused, not followed. *)
    let root = Filename.concat (Unix.realpath (Filename.dirname root)) (Filename.basename root) in
    let* () = checked ~label:root_label root in
    let instance = Filename.concat root instance_id in
    ensure_directory instance;
    let* () = checked ~label:instance_label instance in
    Ok instance)

let check_instance instance = protect ~label:instance_label instance (fun () -> checked ~label:instance_label instance)

let create ~instance =
  let path = Filename.concat instance Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  protect ~label path (fun () -> Unix.mkdir path 0o700; Ok path)

type removal =
  | Removed
  | In_use

let remove_if_free path =
  let* lock_file = Profile.open_lock ~profile:path ~name:lock_name in
  Fun.protect ~finally:(fun () -> Profile.close_lock lock_file) (fun () ->
    match Profile.inspect lock_file with
    | Profile.Held_by holder -> Profile.release holder; Ok In_use
    | Profile.Changing -> Ok In_use
    | Profile.Unreadable detail -> Error detail
    | Profile.Unlocked ->
      let* taken = Profile.lock lock_file in
      match taken with
      | Profile.Held_elsewhere -> Ok In_use
      | Profile.Locked ->
        let* () = Profile.remove ~label ~last:lock_name path in
        Ok Removed)
