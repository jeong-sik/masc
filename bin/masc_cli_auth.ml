(* HIGH-RISK-UNREVIEWED: see the interface. *)

module A = Authz_activation
module T = Server_startup_takeover

let ( let* ) = Result.bind
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

(* The person opens the link from wherever they are, so its base is the public
   address the operator states, as for a Play invite. MASC_HOST and
   MASC_HTTP_PORT of this shell need not be where the server listens. *)
let public_base_url () =
  let key = Env_config_core.http_base_url_env_key in
  match Env_config_core.masc_http_base_url_opt () with
  | None ->
    Error
      (key
       ^ " is not set, so the link has no address; set it to the http(s) address the \
          person opens")
  | Some base ->
    if Masc.Play_invite.is_http_public_base_url base
    then Ok base
    else
      (* The value is not echoed: a refused URL can carry a password. *)
      Error
        (key
         ^ " is not an http(s) origin with no user, path, query or fragment, so it cannot \
            carry the link")
;;

(* What a server started from this shell would read. A server started from
   another environment reads its own. *)
let anonymous_mutations () =
  Result.map
    Server_auth_config.allow_anonymous_mutations
    (Result.map_error
       Server_auth_config.resolve_error_to_string
       (Server_auth_config.resolve (Server_auth_config.read_env ())))
;;

(* Both are read before anything is written, so a link that could not be
   printed, or a setting a server would refuse, writes nothing. *)
let activate ~external_store base_path =
  let* base_url = public_base_url () in
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
       This build does not serve multi-account yet, so a server stops at boot on this \
       workspace. No command undoes the activation.\n\
       The first Admin signs in once with this link before %s. It is not shown again:\n\
       %s\n"
      (Authz_types.Workspace_id.to_string workspace_id)
      (Time_codec.rfc3339_of_unix (float_of_int (A.expires_at_ms invitation) /. 1000.))
      (A.link ~base_url invitation);
    (* The invitation is committed by now. A link that did not reach the output
       is reported, so the exit code does not claim it was printed. *)
    (match flush stdout with
     | () -> 0
     | exception Sys_error detail ->
       Printf.eprintf
         "masc auth bootstrap: the installation is activated, and its link did not reach \
          the standard output: %s\n"
         detail;
       1)
;;
