(** A pool of language servers, one per [(lang_id, workspace_root)] pair.
    See [lsp_workspace_pool.mli] for why the root is in the key. *)

type key = Lsp_process_manager.language * string (* language, workspace_root *)

type error =
  | Server_unavailable of
      { lang_id : string
      ; command : string
      }
  | Server_failed of
      { lang_id : string
      ; reason : string
      }

let pp_error fmt = function
  | Server_unavailable { lang_id; command } ->
    Fmt.pf fmt "language server for %s is not installed: %s not on PATH" lang_id command
  | Server_failed { lang_id; reason } -> Fmt.pf fmt "language server %s: %s" lang_id reason
;;

(* [initialize] is the one request whose timeout this pool owns — the same 10s
   [Server_ide_lsp_proxy]'s [Lsp_proxy_limits] gives it. *)
let initialize_timeout_sec = 10.0

(* A Keeper's question blocks its turn, so this pool bounds the wait. The proxy
   does not: there, the dashboard client owns the request timeout. Above the
   10s a cold [initialize] gets, below any Keeper turn budget. *)
let request_timeout_sec = 30.0

(* [Lsp_message_router] correlates answers by JSON-RPC id; [client_id] only tags
   the pending entry for fan-out to a WebSocket client, which this pool has
   none of. *)
let pool_client_id = -1

type t =
  { sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t
  ; router : Lsp_message_router.t
  ; table_mutex : Eio.Mutex.t (* guards [servers] and [spawn_locks] *)
  ; servers : (key, Lsp_process_manager.lsp_process) Hashtbl.t
  ; spawn_locks : (key, Eio.Mutex.t) Hashtbl.t
  ; commands : Lsp_process_manager.servers (* which command starts each language *)
  }

let create ~sw ~clock ~proc_mgr ~servers =
  { sw
  ; clock
  ; proc_mgr
  ; commands = servers
  ; router = Lsp_message_router.create ()
  ; table_mutex = Eio.Mutex.create ()
  ; servers = Hashtbl.create 8
  ; spawn_locks = Hashtbl.create 8
  }
;;

(* Table reads and writes are short and must not be abandoned half-done, so
   they hold the mutex with [~protect:true]. Spawning does not — see
   [spawn_locked]. *)
let with_table t f = Eio.Mutex.use_rw ~protect:true t.table_mutex f
let find t key = with_table t (fun () -> Hashtbl.find_opt t.servers key)
let install t key proc = with_table t (fun () -> Hashtbl.replace t.servers key proc)

(* The response reader calls this when the server's stdout ends. Without it a
   dead server stays in the table and every later question waits out
   [request_timeout_sec] against a process that will never answer. *)
let forget t ((language, workspace_root) as key) ~reason =
  with_table t (fun () -> Hashtbl.remove t.servers key);
  Log.Server.info
    "LSP pool dropped %s for %s: %s"
    (Lsp_process_manager.lang_id_of_language language)
    workspace_root
    reason
;;

let spawn_lock_for t key =
  with_table t (fun () ->
    match Hashtbl.find_opt t.spawn_locks key with
    | Some lock -> lock
    | None ->
      let lock = Eio.Mutex.create () in
      Hashtbl.replace t.spawn_locks key lock;
      lock)
;;

let await_answer t ~timeout ~what promise =
  match Eio.Time.with_timeout_exn t.clock timeout (fun () -> Eio.Promise.await promise) with
  | Ok json -> Ok json
  | Error msg -> Error msg
  | exception Eio.Time.Timeout -> Error (Printf.sprintf "%s timed out after %.0fs" what timeout)
;;

let initialize_params ~workspace_root =
  `Assoc
    [ "rootUri", `String ("file://" ^ workspace_root)
    ; "rootPath", `String workspace_root
      (* NDT-OK: the pid is what it is for — LSP has the server watch this
         process and exit when it goes, which is the only teardown left if
         masc dies before [close] or the switch runs. Nothing branches on the
         value; it leaves for the server and never comes back. *)
    ; "processId", `Int (Unix.getpid ())
    ; "capabilities", `Assoc []
    ]
;;

(* Any exit that is not a successful install — an error, a timeout, or a Keeper
   turn cancelled mid-[initialize] — tears the process down here.
   [Lsp_process_manager.spawn] binds it to the pool's switch, which lives as
   long as the server, so nothing else reclaims it (#21546). The teardown
   handles its own exceptions so it cannot replace the exception on its way
   out. *)
let discard_unless_installed proc installed =
  if not !installed
  then (
    try Lsp_process_manager.shutdown proc with
    | exn ->
      Log.Server.debug
        "LSP pool teardown for %s raised: %s"
        proc.Lsp_process_manager.lang_id
        (Printexc.to_string exn))
;;

let start_locked t ~key ~language ~workspace_root =
  let lang_id = Lsp_process_manager.lang_id_of_language language in
  match
    Lsp_process_manager.spawn ~sw:t.sw ~servers:t.commands ~lang_id ~workspace_root t.proc_mgr
  with
  | Error err ->
    Error
      (Server_failed
         { lang_id; reason = Format.asprintf "%a" Lsp_process_manager.pp_spawn_error err })
  | Ok proc ->
    let installed = ref false in
    Fun.protect
      ~finally:(fun () -> discard_unless_installed proc installed)
      (fun () ->
        Lsp_message_router.start_response_reader
          ~sw:t.sw
          t.router
          proc
          ~on_exit:(Some (fun ~reason -> forget t key ~reason))
          ~on_notification:(fun ~client_id:_ ~method_ _params ->
            (* Diagnostics and progress belong to an editor; a question and its
               answer are all this pool carries. *)
            Log.Server.debug "LSP pool dropped %s from %s" method_ lang_id);
        let promise =
          Lsp_message_router.send_request
            t.router
            proc
            ~method_:"initialize"
            ~params:(initialize_params ~workspace_root)
            ~client_id:pool_client_id
        in
        match
          await_answer t ~timeout:initialize_timeout_sec ~what:"initialize" promise
        with
        | Error reason -> Error (Server_failed { lang_id; reason })
        | Ok _capabilities ->
          Lsp_message_router.send_notification
            t.router
            proc
            ~method_:"initialized"
            ~params:(`Assoc []);
          install t key proc;
          installed := true;
          Log.Server.info "LSP pool started %s for %s" lang_id workspace_root;
          Ok proc)
;;

let ensure t ~language ~workspace_root =
  (* [Lsp_process_manager.spawn] answers [Command_not_found] both when nothing
     is mapped and when the mapped command is missing, telling the two apart
     only by which string it carries. The pool cannot be asked the first
     question — [language] is a variant — and answers the second here, so a
     caller never has to read a string to learn which happened. *)
  let lang_id = Lsp_process_manager.lang_id_of_language language in
  let command, _argv = t.commands language in
  if not (Executable_path.path_has_executable command)
  then Error (Server_unavailable { lang_id; command })
  else (
    let key = language, workspace_root in
    match find t key with
    | Some proc -> Ok proc
    | None ->
      (* [~protect:false]: [initialize] can take seconds, and a Keeper whose
         turn is cancelled must not wait it out. The process is torn down on
         the way out either way. *)
      Eio.Mutex.use_rw ~protect:false (spawn_lock_for t key) (fun () ->
        match find t key with
        | Some proc -> Ok proc (* another caller won the race *)
        | None -> start_locked t ~key ~language ~workspace_root))
;;

let ask t ~language ~workspace_root ~method_ ~params =
  match ensure t ~language ~workspace_root with
  | Error _ as err -> err
  | Ok proc ->
    let promise =
      Lsp_message_router.send_request t.router proc ~method_ ~params ~client_id:pool_client_id
    in
    (match await_answer t ~timeout:request_timeout_sec ~what:method_ promise with
     | Error reason ->
       Error
         (Server_failed
            { lang_id = Lsp_process_manager.lang_id_of_language language; reason })
     | Ok json -> Ok json)
;;

let notify t ~language ~workspace_root ~method_ ~params =
  match ensure t ~language ~workspace_root with
  | Error _ as err -> err
  | Ok proc ->
    Lsp_message_router.send_notification t.router proc ~method_ ~params;
    Ok ()
;;

(* Shuts every held server down. Closing the pipes is what ends the stderr
   drain and the response reader; the switch cannot do it, because it releases
   after it has waited for exactly those fibers. *)
let close t =
  let held =
    Eio.Mutex.use_rw ~protect:true t.table_mutex (fun () ->
      let held = Hashtbl.fold (fun _key proc acc -> proc :: acc) t.servers [] in
      Hashtbl.reset t.servers;
      Hashtbl.reset t.spawn_locks;
      held)
  in
  List.iter
    (fun proc ->
      try Lsp_process_manager.shutdown proc with
      | exn ->
        Log.Server.debug
          "LSP pool close for %s raised: %s"
          proc.Lsp_process_manager.lang_id
          (Printexc.to_string exn))
    held
;;

let with_pool ~clock ~proc_mgr ~servers f =
  Eio.Switch.run (fun sw ->
    let t = create ~sw ~clock ~proc_mgr ~servers in
    Fun.protect ~finally:(fun () -> close t) (fun () -> f t))
;;
