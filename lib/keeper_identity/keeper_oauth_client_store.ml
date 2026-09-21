(** See keeper_oauth_client_store.mli. *)

type credentials = {
  client_id : string;
  client_secret : string option;
  secret_expires_at : float option;
  scopes : string list;
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

let secret_expires_path ~dir ~provider =
  entry_path ~dir ~provider "client_secret_expires_at"
;;

let scopes_path ~dir ~provider = entry_path ~dir ~provider "scopes"
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

let ( let* ) = Result.bind

(* Space separated on disk, as it goes on the wire. A file that is not there
   is no override, which is a different thing from a file holding nothing --
   and [read_trimmed] already refuses the latter. *)
let scopes_of_stored = function
  | None -> []
  | Some text ->
    List.filter (fun scope -> not (String.equal scope "")) (String.split_on_char ' ' text)
;;

(* Unix seconds, as the server dated the secret beside it. A file that will
   not parse is a refusal rather than a shrug: reading it as absent would
   silently promote an expiring secret to one that never expires, which is
   the state this file exists to keep out. *)
let expiry_of_stored path = function
  | None -> Ok None
  | Some text ->
    (match float_of_string_opt text with
     | Some seconds -> Ok (Some seconds)
     | None ->
       Error (Printf.sprintf "not a number: %s holds %S" path text))
;;

let load ~dir ~provider =
  let* client_id = read_trimmed (file_path ~dir ~provider) in
  match client_id with
  | None -> Ok None
  | Some client_id ->
    (* The id is written last, so an id on disk means everything beside it is
       already there. A missing secret file is therefore a public client
       rather than a half-written pair, and a missing expiry file beside a
       secret is a registration this store wrote before it read the field. *)
    let* client_secret = read_trimmed (secret_path ~dir ~provider) in
    let expiry_path = secret_expires_path ~dir ~provider in
    let* stored_expiry = read_trimmed expiry_path in
    let* secret_expires_at = expiry_of_stored expiry_path stored_expiry in
    let* stored_scopes = read_trimmed (scopes_path ~dir ~provider) in
    Ok
      (Some
         { client_id
         ; client_secret
         ; secret_expires_at
         ; scopes = scopes_of_stored stored_scopes
         })
;;

let secret_expired { client_secret; secret_expires_at; _ } ~now =
  match client_secret with
  (* A public client has no secret, so nothing about it lapses. This is why
     an install that registered one keeps working indefinitely. *)
  | None -> false
  | Some _ ->
    (match secret_expires_at with
     (* RFC 7591 section 3.2.1: the field is REQUIRED when a secret is
        issued, and 0 means the secret will not expire. So a confidential
        client with nothing recorded is not one that never expires -- it is
        one registered before this store read the field, whose real deadline
        is unknown and may already be behind us. Saying "expired" costs one
        registration; saying "valid" is how a client reaches the token
        endpoint long after the server forgot it. *)
     | None -> true
     | Some seconds when Float.equal seconds 0. -> false
     | Some seconds -> seconds <= now)
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

let remove_if_present path =
  try Sys.remove path with
  | Sys_error _ when not (Sys.file_exists path) -> ()
;;

let save ~dir ~provider { client_id; client_secret; secret_expires_at; scopes } =
  try
    (* Secret first, id second. The id is what {!load} keys on, so writing it
       last means a reader never finds a confidential client wearing the face
       of a public one -- which would fail at the token endpoint with the
       server's word for "who are you" and nothing here saying why. The
       expiry goes in the same half for the same reason: an id on disk
       promises that whatever dates the secret is already beside it. *)
    (match scopes with
     | [] -> remove_if_present (scopes_path ~dir ~provider)
     | scopes -> write_whole (scopes_path ~dir ~provider) (String.concat " " scopes));
    (match client_secret with
     | None -> remove_if_present (secret_path ~dir ~provider)
     | Some secret -> write_whole (secret_path ~dir ~provider) secret);
    (match secret_expires_at with
     | None -> remove_if_present (secret_expires_path ~dir ~provider)
     | Some seconds ->
       write_whole (secret_expires_path ~dir ~provider) (Printf.sprintf "%.0f" seconds));
    write_whole (file_path ~dir ~provider) client_id;
    Ok ()
  with
  | Unix.Unix_error (err, fn, arg) -> Error (describe err fn arg)
  | Sys_error message -> Error message
;;
