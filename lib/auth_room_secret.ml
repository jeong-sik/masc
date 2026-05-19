(** See [auth_room_secret.mli] for the contract. *)

open Masc_domain

module Storage = Auth_storage
module Config_store = Auth_config_store

(** Initialize room secret *)
let init_room_secret config : string =
  Storage.ensure_auth_dirs config;
  let secret = Storage.generate_token () in
  let hash = Storage.sha256_hash secret in
  Storage.save_private_text_file (Storage.room_secret_file config) hash;
  let cfg = Config_store.load_auth_config config in
  Config_store.save_auth_config config { cfg with room_secret_hash = Some hash };
  secret
;;

(** Verify room secret *)
let verify_room_secret config secret : bool =
  let hash = Storage.sha256_hash secret in
  let file = Storage.room_secret_file config in
  if Storage.file_exists file
  then (
    let stored_hash = String.trim (Storage.read_text_file file) in
    hash = stored_hash)
  else false
;;

(** Enable authentication for a room.
    Creates a bootstrap admin token for the enabling agent to prevent
    circular permission deadlock (BUG-025). *)
let enable_auth ~create_token config ~require_token ~agent_name
  : string * string option
  =
  let secret = init_room_secret config in
  let cfg = Config_store.load_auth_config config in
  Config_store.save_auth_config config { cfg with enabled = true; require_token };
  let bootstrap_token =
    if agent_name <> ""
    then (
      Storage.write_initial_admin config agent_name;
      match create_token config ~agent_name ~role:Admin with
      | Ok (token, _cred) -> Some token
      | Error e ->
        Log.Auth.warn
          "[enable_auth] bootstrap token creation failed for %s: %s"
          agent_name
          (Masc_domain.show_masc_error e);
        None)
    else None
  in
  secret, bootstrap_token
;;

(** Disable authentication *)
let disable_auth config =
  let cfg = Config_store.load_auth_config config in
  Config_store.save_auth_config config { cfg with enabled = false };
  let file = Storage.initial_admin_file config in
  if Storage.file_exists file then Storage.remove_file file
;;

(** Check if auth is enabled *)
let is_auth_enabled config : bool =
  let cfg = Config_store.load_auth_config config in
  cfg.enabled
;;
