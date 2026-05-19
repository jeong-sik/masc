(** See [auth_config_store.mli] for the contract. *)

open Masc_domain

module Storage = Auth_storage

let persist_auth_config config (auth_cfg : auth_config) =
  Storage.ensure_auth_dirs config;
  let file = Storage.auth_config_file config in
  let json = auth_config_to_yojson auth_cfg in
  Storage.save_private_text_file file (Yojson.Safe.pretty_to_string json)
;;

let load_auth_config config : auth_config =
  let file = Storage.auth_config_file config in
  if Storage.file_exists file
  then (
    try
      let content = Storage.read_text_file file in
      let json = Yojson.Safe.from_string content in
      match auth_config_of_yojson json with
      | Ok cfg -> cfg
      | Error msg ->
        Log.Auth.warn "[load_auth_config] parse error for %s: %s" file msg;
        default_auth_config
    with
    | Sys_error _ | Yojson.Json_error _ -> default_auth_config)
  else default_auth_config
;;

let save_auth_config config (auth_cfg : auth_config) =
  persist_auth_config config auth_cfg
;;
