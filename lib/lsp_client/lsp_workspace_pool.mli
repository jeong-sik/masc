(** A pool of language servers, one per [(lang_id, workspace_root)] pair.

    [Server_ide_lsp_proxy] keeps its own cache inside each WebSocket
    connection, and every request on that connection carries that connection's
    root, so keying on [lang_id] alone is correct there. This pool is
    server-scoped instead: Keepers ask concurrently from different sandbox
    roots, so the root is part of the key. #28773 removed a gRPC rpc that kept
    a server-scoped table keyed on [lang_id] alone while spawning with the
    first caller's root, which handed later callers a language server rooted in
    someone else's workspace.

    [workspace_root] goes into the key verbatim. Two spellings of one directory
    ([/a/b] and [/a/b/]) are two keys and start two servers; callers pass the
    sandbox root they already hold rather than a path a Keeper typed. *)

type t

(** A language with no mapped server is not one of these: {!ensure} takes a
    [Lsp_process_manager.language], so "no such language" is settled by the
    caller resolving the file's extension and cannot reach the pool.
    [Lsp_process_manager.spawn] does collapse the two — it answers
    [Command_not_found] both for an unmapped language and for a missing
    command — which is why the pool checks [PATH] itself instead of reading
    that constructor. *)

type error =
  | Server_unavailable of
      { lang_id : string
      ; command : string
      }
      (** The language's command is not on [PATH]. Three of the five commands
          [Lsp_process_manager] maps are absent on the host this was measured
          on, so this is an ordinary answer, not an incident. *)
  | Server_failed of
      { lang_id : string
      ; reason : string
      }
      (** The server started and then failed to initialize, to answer, or to
          stay alive. *)

val pp_error : Format.formatter -> error -> unit

(** [with_pool ~clock ~proc_mgr f] runs [f] with a pool and shuts every
    language server down before returning.

    A pool is only handed out this way because the teardown cannot be left to
    the switch. [Lsp_process_manager.spawn] forks a stderr drain and a response
    reader onto the switch, and both block on a read that ends only when the
    pipes close — while the pipes close in [Eio.Switch.on_release], which runs
    after the switch has waited for those fibers. A pool torn down by its
    switch alone hangs there; measured, with two [ocamllsp] processes still
    resident five minutes on. *)
val with_pool
  :  clock:float Eio.Time.clock_ty Eio.Resource.t
  -> proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> servers:Lsp_process_manager.servers
  -> (t -> 'a)
  -> 'a

(** The language server for [(lang_id, workspace_root)], started and
    initialized on first use. Two calls with the same pair get the same
    process; a call with a different root gets a different one.

    Concurrent callers racing on one key are serialized: the loser of the race
    receives the process the winner installed rather than starting a second. *)
val ensure
  :  t
  -> language:Lsp_process_manager.language
  -> workspace_root:string
  -> (Lsp_process_manager.lsp_process, error) result

(** One JSON-RPC request to the server for [(lang_id, workspace_root)], with
    the server started if needed. A request that outlives
    [request_timeout_sec] answers [Server_failed] and leaves the server in the
    pool — that timeout describes this question, not the server's health. *)
val ask
  :  t
  -> language:Lsp_process_manager.language
  -> workspace_root:string
  -> method_:string
  -> params:Yojson.Safe.t
  -> (Yojson.Safe.t, error) result

(** One JSON-RPC notification to the server for [(language, workspace_root)],
    with the server started if needed. A notification has no answer, so the
    [unit] says it was written, not that the server acted on it. *)
val notify
  :  t
  -> language:Lsp_process_manager.language
  -> workspace_root:string
  -> method_:string
  -> params:Yojson.Safe.t
  -> (unit, error) result
