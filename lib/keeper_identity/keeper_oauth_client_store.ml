(** See keeper_oauth_client_store.mli. *)

module App = struct
  type t = {
    client_id : string;
    client_secret : string option;
    scopes : string list;
  }
end

module Registered = struct
  type t = {
    client_id : string;
    client_secret : string option;
    secret_expires_at : float option;
  }
end

type login_client =
  | Operator_app of App.t
  | Registered of Registered.t

let login_client_id = function
  | Operator_app app -> app.App.client_id
  | Registered registered -> registered.Registered.client_id
;;

let login_client_secret = function
  | Operator_app app -> app.App.client_secret
  | Registered registered -> registered.Registered.client_secret
;;

type binding =
  | Bound_to_app of { client_id : string }
  | Bound_to_registered of Registered.t

let binding_of_login_client = function
  | Operator_app app -> Bound_to_app { client_id = app.App.client_id }
  | Registered registered -> Bound_to_registered registered
;;

open Result.Syntax

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

let guard_io f =
  try f () with
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "%s: %s %s" (Unix.error_message err) fn arg)
  | Sys_error message -> Error message
;;

let write_whole path contents =
  guard_io (fun () ->
    let temp = path ^ ".tmp" in
    ensure_dir (Filename.dirname path);
    Out_channel.with_open_bin temp (fun oc -> Out_channel.output_string oc contents);
    Unix.chmod temp 0o600;
    Unix.rename temp path;
    Ok ())
;;

let read_json path =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ when not (Sys.file_exists path) -> Ok None
  | exception Sys_error message -> Error message
  | contents ->
    (match Yojson.Safe.from_string contents with
     | exception Yojson.Json_error detail -> Error (Printf.sprintf "%s: %s" path detail)
     | `Assoc fields -> Ok (Some fields)
     | _ -> Error (Printf.sprintf "%s: not an object" path))
;;

(* Strict field readers. An absent optional field is [None]; a present field
   of the wrong type is a refusal, because reading it as absent would turn a
   confidential client into a public one, or an expiring secret into one that
   never lapses. *)
let required_string ~path fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok (String.trim value)
  | Some _ | None -> Error (Printf.sprintf "%s: %s must be a non-empty string" path key)
;;

let optional_string ~path fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some (String.trim value))
  | Some _ -> Error (Printf.sprintf "%s: %s must be a non-empty string when present" path key)
;;

let optional_float ~path fields key =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (float_of_int value))
  | Some _ -> Error (Printf.sprintf "%s: %s must be a number when present" path key)
;;

let string_list ~path fields key =
  match List.assoc_opt key fields with
  | None -> Ok []
  | Some (`List items) ->
    List.fold_right
      (fun item acc ->
        let* acc = acc in
        match item with
        | `String value when String.trim value <> "" -> Ok (String.trim value :: acc)
        | _ -> Error (Printf.sprintf "%s: %s must list non-empty strings" path key))
      items (Ok [])
  | Some _ -> Error (Printf.sprintf "%s: %s must be a list" path key)
;;

let optional_member name = function
  | None -> []
  | Some value -> [ name, value ]
;;

(* ── operator apps ──────────────────────────────────────────────────── *)

let app_path ~identity_dir ~(provider : Keeper_oauth_provider.t) =
  Filename.concat
    (Filename.concat identity_dir "apps")
    (provider.Keeper_oauth_provider.client_group ^ ".json")
;;

let load_app ~identity_dir ~provider =
  let path = app_path ~identity_dir ~provider in
  let* fields = read_json path in
  match fields with
  | None -> Ok None
  | Some fields ->
    let* client_id = required_string ~path fields "client_id" in
    let* client_secret = optional_string ~path fields "client_secret" in
    let* scopes = string_list ~path fields "scopes" in
    Ok (Some { App.client_id; client_secret; scopes })
;;

let save_app ~identity_dir ~provider (app : App.t) =
  write_whole
    (app_path ~identity_dir ~provider)
    (Yojson.Safe.to_string
       (`Assoc
         ([ "client_id", `String app.App.client_id ]
          @ optional_member "client_secret"
              (Option.map (fun secret -> `String secret) app.App.client_secret)
          @ [ "scopes", `List (List.map (fun scope -> `String scope) app.App.scopes) ])))
;;

(* ── the client a login used ───────────────────────────────────────── *)

(* The wire names of the two binding kinds. Decoded into the variant at this
   boundary and nowhere else; an unknown kind is a refusal. *)
let kind_app = "operator_app"
let kind_registered = "registered"

let binding_to_json = function
  | Bound_to_app { client_id } ->
    `Assoc [ "kind", `String kind_app; "client_id", `String client_id ]
  | Bound_to_registered registered ->
    `Assoc
      ([ "kind", `String kind_registered
       ; "client_id", `String registered.Registered.client_id
       ]
       @ optional_member "client_secret"
           (Option.map (fun secret -> `String secret) registered.Registered.client_secret)
       @ optional_member "secret_expires_at"
           (Option.map (fun seconds -> `Float seconds)
              registered.Registered.secret_expires_at))
;;

let load_binding ~path =
  let* fields = read_json path in
  match fields with
  | None -> Ok None
  | Some fields ->
    let* client_id = required_string ~path fields "client_id" in
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) when String.equal kind kind_app ->
       Ok (Some (Bound_to_app { client_id }))
     | Some (`String kind) when String.equal kind kind_registered ->
       let* client_secret = optional_string ~path fields "client_secret" in
       let* secret_expires_at = optional_float ~path fields "secret_expires_at" in
       Ok (Some (Bound_to_registered { Registered.client_id; client_secret; secret_expires_at }))
     | Some _ | None ->
       Error
         (Printf.sprintf "%s: kind must be %S or %S" path kind_app kind_registered))
;;

let save_binding ~path binding =
  write_whole path (Yojson.Safe.to_string (binding_to_json binding))
;;

let delete_binding ~path =
  guard_io (fun () ->
    (try Sys.remove path with
     | Sys_error _ when not (Sys.file_exists path) -> ());
    Ok ())
;;

let secret_expired (registered : Registered.t) ~now =
  match registered.Registered.client_secret with
  | None -> false
  | Some _ ->
    (match registered.Registered.secret_expires_at with
     | None -> true
     | Some seconds when Float.equal seconds 0. -> false
     | Some seconds -> seconds <= now)
;;

type redeem_error =
  | Not_bound
  | Binding_unreadable of string
  | App_unreadable of string
  | App_gone of { client_id : string }
  | App_replaced of { bound : string; current : string }
  | Registration_lapsed of { client_id : string }

let redeem_error_to_string = function
  | Not_bound ->
    "this keeper has no record of the client its login used; attach it to the \
     provider again"
  | Binding_unreadable problem ->
    Printf.sprintf "the record of the client this keeper's login used cannot be read: %s"
      problem
  | App_unreadable problem ->
    Printf.sprintf "the app on file for this provider cannot be read: %s" problem
  | App_gone { client_id } ->
    Printf.sprintf
      "this keeper logged in with app %s, which is no longer on file; attach it \
       to the provider again"
      client_id
  | App_replaced { bound; current } ->
    Printf.sprintf
      "this keeper logged in with app %s, and the app on file is now %s; attach \
       it to the provider again"
      bound current
  | Registration_lapsed { client_id } ->
    Printf.sprintf
      "the client %s this keeper's login registered has an expired secret; \
       attach it to the provider again"
      client_id
;;

let redeeming_client ~identity_dir ~provider ~binding ~now =
  match binding with
  | Bound_to_registered registered ->
    if secret_expired registered ~now
    then Error (Registration_lapsed { client_id = registered.Registered.client_id })
    else Ok (registered.Registered.client_id, registered.Registered.client_secret)
  | Bound_to_app { client_id = bound } ->
    (match load_app ~identity_dir ~provider with
     | Error problem -> Error (App_unreadable problem)
     | Ok None -> Error (App_gone { client_id = bound })
     | Ok (Some app) when String.equal app.App.client_id bound ->
       Ok (app.App.client_id, app.App.client_secret)
     | Ok (Some app) -> Error (App_replaced { bound; current = app.App.client_id }))
;;
