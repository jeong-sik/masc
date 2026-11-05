(* HIGH-RISK-UNREVIEWED: see the interface. *)

module A = Authz_activation
module T = Server_startup_takeover

let ( let* ) = Result.bind
let invitation_path = "/accounts/invite#"
let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

let with_lease ~base_path f =
  match Unix.realpath base_path with
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "the base path %s is not reachable: %s" base_path (Unix.error_message error))
  | base_path ->
    (match T.acquire_base_path_lock ~run_dir:(Host_config.host ()).base_path_lease_dir base_path with
     | T.Base_path_already_owned { owner; lock_path } ->
       Error (T.base_path_contention_message ~base_path ~lock_path owner)
     | T.Base_path_rejected rejection -> Error (T.base_path_lock_rejection_to_string rejection)
     | T.Base_path_acquired lease ->
       Fun.protect ~finally:(fun () -> T.release_base_path_lease lease) (fun () -> f base_path))
;;

(* What a server started from this environment would read. *)
let anonymous_mutations () =
  Result.map
    Server_auth_config.allow_anonymous_mutations
    (Result.map_error
       Server_auth_config.resolve_error_to_string
       (Server_auth_config.resolve (Server_auth_config.read_env ())))
;;

let activate ~external_store base_path =
  let* base_url = Env_config_core.masc_http_base_url_result () in
  let* anonymous_mutations = anonymous_mutations () in
  let* activated =
    Result.map_error
      A.error_to_string
      (Eio_main.run (fun _env ->
         A.activate
           ~base_path
           ~config_dir:(Env_config_core.masc_config_dir_opt ())
           ~external_store
           ~anonymous_mutations
           ~now_ms))
  in
  Ok (base_url, activated)
;;

let bootstrap ~base_path ~external_store =
  match with_lease ~base_path (activate ~external_store) with
  | Error reason ->
    Printf.eprintf "masc auth bootstrap: %s\n" reason;
    1
  | Ok (base_url, { A.workspace_id; invitation }) ->
    Printf.printf
      "The installation is activated for multi-account use, workspace %s.\n\
       The first Admin signs in once with this link before %s. It is not shown again:\n\
       %s%s%s\n"
      (Authz_types.Workspace_id.to_string workspace_id)
      (Time_codec.rfc3339_of_unix (float_of_int invitation.A.expires_at_ms /. 1000.))
      base_url
      invitation_path
      invitation.A.token;
    0
;;
