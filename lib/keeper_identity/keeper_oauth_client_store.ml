(** See keeper_oauth_client_store.mli. *)

(* The provider's id is one path component -- checked when the declaration
   is read, and the record is private -- so this joins without checking
   again. *)
let file_path ~dir ~(provider : Keeper_oauth_provider.t) =
  Filename.concat (Filename.concat dir provider.Keeper_oauth_provider.id) "client_id"
;;

let rec ensure_dir path =
  if String.equal path "" || String.equal path "." || String.equal path "/"
     || Sys.file_exists path
  then ()
  else (
    let parent = Filename.dirname path in
    if not (String.equal parent path) then ensure_dir parent;
    try Unix.mkdir path 0o700 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
;;

let describe err fn arg =
  Printf.sprintf "%s: %s %s" (Unix.error_message err) fn arg
;;

let load ~dir ~provider =
  let path = file_path ~dir ~provider in
  match In_channel.with_open_bin path In_channel.input_all with
  | contents ->
    let trimmed = String.trim contents in
    (* An empty file is a write that did not finish, not an id. Saying so
       lets a caller stop rather than register a second client over it. *)
    if String.equal trimmed ""
    then Error (Printf.sprintf "client id file is empty: %s" path)
    else Ok (Some trimmed)
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok None
  | exception Sys_error message -> Error message
;;

let save ~dir ~provider ~client_id =
  let path = file_path ~dir ~provider in
  let temp = path ^ ".tmp" in
  try
    ensure_dir (Filename.dirname path);
    (* Written whole and then moved, so a reader either finds the previous
       id or this one, never half of one. *)
    Out_channel.with_open_bin temp (fun oc -> Out_channel.output_string oc client_id);
    Unix.chmod temp 0o600;
    Unix.rename temp path;
    Ok ()
  with
  | Unix.Unix_error (err, fn, arg) -> Error (describe err fn arg)
  | Sys_error message -> Error message
;;
