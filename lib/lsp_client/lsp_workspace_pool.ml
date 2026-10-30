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

(* Transport writes and answer/analysis observations use this request window.
   It bounds a stalled peer, not cumulative turn time or work. The proxy's
   dashboard client owns its own transport request policy. *)
let request_timeout_sec = 30.0

(* [Lsp_message_router] correlates answers by JSON-RPC id; [client_id] only tags
   the pending entry for fan-out to a WebSocket client, which this pool has
   none of. *)
let pool_client_id = -1

type document_readiness = Open_notification | Versioned_diagnostics
type analysis_waiter = {
  process : Lsp_process_manager.lsp_process;
  uri : string;
  version : int;
  promise : (unit, string) result Eio.Promise.t;
  resolver : (unit, string) result Eio.Promise.u;
}

type t =
  { sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t
  ; router : Lsp_message_router.t
  ; table_mutex : Eio.Mutex.t (* guards [servers] and [spawn_locks] *)
  ; servers : (key, Lsp_process_manager.lsp_process) Hashtbl.t
  ; spawn_locks : (key, Eio.Mutex.t) Hashtbl.t
  ; commands : Lsp_process_manager.servers (* which command starts each language *)
  ; document_versions : int Atomic.t
  ; document_locks : (key * string, Eio.Mutex.t) Hashtbl.t
  ; analysis_locks : (key, Eio.Mutex.t) Hashtbl.t
  ; mutable analysis_waiters : analysis_waiter list
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
  ; document_versions = Atomic.make 1
  ; document_locks = Hashtbl.create 8
  ; analysis_locks = Hashtbl.create 8
  ; analysis_waiters = []
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
let forget t ((language, workspace_root) as key) ~proc ~reason =
  with_table t (fun () ->
    (match Hashtbl.find_opt t.servers key with
     | Some current when current == proc -> Hashtbl.remove t.servers key
     | None | Some _ -> ());
    let failed,remaining=List.partition (fun waiter -> waiter.process == proc) t.analysis_waiters in
    t.analysis_waiters <- remaining;
    List.iter (fun waiter -> Eio.Promise.resolve waiter.resolver (Error reason)) failed);
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

let document_lock_for t key =
  with_table t (fun () ->
    match Hashtbl.find_opt t.document_locks key with
    | Some lock -> lock
    | None ->
      let lock=Eio.Mutex.create () in
      Hashtbl.add t.document_locks key lock;
      lock)
;;

let analysis_lock_for t key =
  with_table t (fun () ->
    match Hashtbl.find_opt t.analysis_locks key with
    | Some lock -> lock
    | None ->
      let lock=Eio.Mutex.create () in
      Hashtbl.add t.analysis_locks key lock;
      lock)
;;

let observe_analysis t proc ~method_ params =
  let field fields name = match List.filter (fun (key,_) -> String.equal key name) fields with
    | [_,value] -> Some value | [] | _ :: _ :: _ -> None in
  match method_,params with
  | "textDocument/publishDiagnostics", `Assoc fields ->
    (match field fields "uri",field fields "version",field fields "diagnostics" with
     | Some (`String uri),Some (`Int version),Some (`List _) ->
       with_table t (fun () ->
         let ready,remaining=List.partition (fun waiter ->
           waiter.process == proc && Lsp_uri.same_local_document waiter.uri uri
           && waiter.version=version)
           t.analysis_waiters in
         t.analysis_waiters <- remaining;
         List.iter (fun waiter -> Eio.Promise.resolve waiter.resolver (Ok ())) ready)
     | _ -> ())
  | _ -> ()
;;

(* An answer that arrived as the window closed is the answer; the window's
   verdict stands only when none had. *)
let await_answer ~clock ~timeout ~what promise =
  Watched_work.run
    ~watcher:(fun () ->
      Eio.Time.sleep clock timeout;
      Error (Printf.sprintf "%s timed out after %.0fs" what timeout))
    (fun () -> Eio.Promise.await promise)
;;

let transmit t ~timeout ~what f =
  try Ok (Eio.Time.with_timeout_exn t.clock timeout f) with
  | Eio.Time.Timeout -> Error (Printf.sprintf "%s write timed out after %.0fs" what timeout)
  | Eio.Io _ as exn -> Error (Printexc.to_string exn)
  | End_of_file -> Error "Language server closed its input"
  | Lsp_process_manager.Closed_transport -> Error "Language server transport is closed"
;;

let initialize_params ~workspace_root =
  `Assoc
    [ "rootUri", `String (Lsp_uri.file_uri_of_path workspace_root)
    ; "rootPath", `String workspace_root
      (* NDT-OK: the pid is what it is for — LSP has the server watch this
         process and exit when it goes, which is the only teardown left if
         masc dies before [close] or the switch runs. Nothing branches on the
         value; it leaves for the server and never comes back. *)
    ; "processId", `Int (Unix.getpid ())
    ; "capabilities", `Assoc ["textDocument",`Assoc ["publishDiagnostics",`Assoc
        ["versionSupport",`Bool true]]]
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
    | exn -> (* cancel-guard-ok: this is the teardown for a cancelled install, and raising here abandons the process it exists to reclaim *)
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
          ~on_exit:(Some (fun ~reason -> forget t key ~proc ~reason))
          ~on_notification:(fun ~client_id:_ ~method_ params ->
            observe_analysis t proc ~method_ params);
        let sent = transmit t ~timeout:initialize_timeout_sec ~what:"initialize" (fun () ->
          Lsp_message_router.send_request
            t.router
            proc
            ~method_:"initialize"
            ~params:(initialize_params ~workspace_root)
            ~client_id:pool_client_id)
        in
        let initialized=Result.bind sent (fun promise ->
          await_answer ~clock:t.clock ~timeout:initialize_timeout_sec ~what:"initialize" promise) in
        match initialized
        with
        | Error reason -> Error (Server_failed { lang_id; reason })
        | Ok _capabilities ->
          let sent=transmit t ~timeout:initialize_timeout_sec ~what:"initialized" (fun () ->
            Lsp_message_router.send_notification
            t.router
            proc
            ~method_:"initialized"
            ~params:(`Assoc [])) in
          match sent with
          | Error reason -> Error (Server_failed {lang_id;reason})
          | Ok () ->
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
    let sent=transmit t ~timeout:request_timeout_sec ~what:method_ (fun () ->
      Lsp_message_router.send_request t.router proc ~method_ ~params ~client_id:pool_client_id)
    in
    let answered=Result.bind sent (fun promise ->
      await_answer ~clock:t.clock ~timeout:request_timeout_sec ~what:method_ promise) in
    (match answered with
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
    transmit t ~timeout:request_timeout_sec ~what:method_ (fun () ->
      Lsp_message_router.send_notification t.router proc ~method_ ~params)
    |> Result.map_error (fun reason -> Server_failed
      {lang_id=Lsp_process_manager.lang_id_of_language language;reason})
;;

let ask_document t ~language ~workspace_root ~uri ~text ~readiness ~method_ ~params =
  (* The scope below restores protocol ownership before unlocking even when
     cancelled, so a failed observation must not poison subsequent reads. *)
  let run () = Eio.Mutex.use_ro (document_lock_for t ((language,workspace_root),uri)) (fun () ->
    match ensure t ~language ~workspace_root with
    | Error _ as error -> error
    | Ok proc ->
      let lang_id=Lsp_process_manager.lang_id_of_language language in
      let failed reason=Error (Server_failed {lang_id;reason}) in
      let version=Atomic.fetch_and_add t.document_versions 1 in
      Eio.Switch.run (fun sw ->
        let waiter=match readiness with
          | Open_notification -> None
          | Versioned_diagnostics ->
            let promise,resolver=Eio.Promise.create () in
            let waiter={process=proc;uri;version;promise;resolver} in
            with_table t (fun () -> t.analysis_waiters <- waiter :: t.analysis_waiters);
            Some waiter in
        Eio.Switch.on_release sw (fun () ->
          with_table t (fun () -> t.analysis_waiters <-
            List.filter (fun current ->
              not (current.process == proc && current.version=version)) t.analysis_waiters);
          (* Close only the owned process. A blocked close uses the existing
             transport deadline, then retires that process rather than holding
             a cancelled scope or handing an open document to the next owner. *)
          try Eio.Time.with_timeout_exn t.clock request_timeout_sec (fun () ->
            Lsp_message_router.send_notification t.router proc
              ~method_:"textDocument/didClose" ~params:(`Assoc ["textDocument",`Assoc ["uri",`String uri]]))
          with exn -> (* cancel-guard-ok: release-only teardown; no work resumes *)
            forget t (language,workspace_root) ~proc ~reason:(Printexc.to_string exn);
            Lsp_process_manager.shutdown proc;
            Log.Server.debug "LSP document close for %s failed: %s" lang_id (Printexc.to_string exn));
        let opened=transmit t ~timeout:request_timeout_sec ~what:"textDocument/didOpen" (fun () ->
          Lsp_message_router.send_notification t.router proc ~method_:"textDocument/didOpen"
          ~params:(`Assoc ["textDocument",`Assoc ["uri",`String uri;"languageId",`String lang_id;
            "version",`Int version;"text",`String text]])) in
        let ready=Result.bind opened (fun () -> match waiter with
          | None -> Ok ()
          | Some waiter -> await_answer ~clock:t.clock ~timeout:request_timeout_sec
              ~what:"versioned document analysis" waiter.promise) in
        match ready with
        | Error reason -> failed reason
        | Ok () ->
          let sent=transmit t ~timeout:request_timeout_sec ~what:method_ (fun () ->
            Lsp_message_router.send_request t.router proc ~method_ ~params ~client_id:pool_client_id) in
          let answered=Result.bind sent (fun promise ->
            await_answer ~clock:t.clock ~timeout:request_timeout_sec ~what:method_ promise) in
          match answered with
          | Ok json -> Ok json
          | Error reason -> failed reason)) in
  match readiness with
  | Open_notification -> run ()
  | Versioned_diagnostics ->
    (* Pyright holds one active References cancellation source per process.
       Keep these reads serial so another URI cannot cancel the first one. *)
    Eio.Mutex.use_ro (analysis_lock_for t (language,workspace_root)) run
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
      Hashtbl.reset t.document_locks;
      Hashtbl.reset t.analysis_locks;
      let waiters=t.analysis_waiters in
      t.analysis_waiters <- [];
      List.iter (fun waiter -> Eio.Promise.resolve waiter.resolver (Error "Language server pool closed")) waiters;
      held)
  in
  List.iter
    (fun proc ->
      try Lsp_process_manager.shutdown proc with
      | exn -> (* cancel-guard-ok: the table is already reset, so raising on the first process abandons every one after it *)
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

module For_testing = struct
  let await_answer = await_answer
end
