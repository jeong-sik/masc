(** See keeper_oauth_client_store.mli. *)

type credentials = {
  client_id : string;
  client_secret : string option;
}

(* Keyed by the provider's client group rather than its id: a client belongs
   to an authorization server, and the eight Google Workspace resources sit
   behind one. The group is one path component -- checked when the
   declaration is read, and the record is private -- so this joins without
   checking again. *)
let entry_path ~dir ~(provider : Keeper_oauth_provider.t) name =
  Filename.concat
    (Filename.concat dir provider.Keeper_oauth_provider.client_group)
    name
;;

let file_path ~dir ~provider = entry_path ~dir ~provider "client_id"
let secret_path ~dir ~provider = entry_path ~dir ~provider "client_secret"
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

let read_trimmed path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents ->
    let trimmed = String.trim contents in
    (* An empty file is a write that did not finish, not a value. Saying so
       lets a caller stop rather than register a second client over it. *)
    if String.equal trimmed ""
    then Error (Printf.sprintf "file is empty: %s" path)
    else Ok (Some trimmed)
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok None
  | exception Sys_error message -> Error message
;;

let load ~dir ~provider =
  match read_trimmed (file_path ~dir ~provider) with
  | Error message -> Error message
  | Ok None -> Ok None
  | Ok (Some client_id) ->
    (* The id is written last, so an id on disk means the secret beside it
       is already there. A missing secret file is therefore a public client
       rather than a half-written pair. *)
    (match read_trimmed (secret_path ~dir ~provider) with
     | Error message -> Error message
     | Ok client_secret -> Ok (Some { client_id; client_secret }))
;;

let write_whole path value =
  let temp = path ^ ".tmp" in
  ensure_dir (Filename.dirname path);
  (* Written whole and then moved, so a reader either finds the previous
     value or this one, never half of one. *)
  Out_channel.with_open_bin temp (fun oc -> Out_channel.output_string oc value);
  Unix.chmod temp 0o600;
  Unix.rename temp path
;;

let save ~dir ~provider { client_id; client_secret } =
  try
    (* Secret first, id second. The id is what {!load} keys on, so writing it
       last means a reader never finds a confidential client wearing the face
       of a public one -- which would fail at the token endpoint with the
       server's word for "who are you" and nothing here saying why. *)
    (match client_secret with
     | None -> ()
     | Some secret -> write_whole (secret_path ~dir ~provider) secret);
    write_whole (file_path ~dir ~provider) client_id;
    Ok ()
  with
  | Unix.Unix_error (err, fn, arg) -> Error (describe err fn arg)
  | Sys_error message -> Error message
;;
