(** Worker runtime configuration — resolves [worker-runtime.json] plus
    env overrides into a cached, effective config consulted by
    [worker_runtime_*] modules at spawn time.

    Config resolution order (first wins per field):

    + [MASC_WORKER_RUNTIME_BACKEND]
    + [MASC_WORKER_RUNTIME_DOCKER_IMAGE]
    + [MASC_WORKER_RUNTIME_HOST_MCP_BASE_URL]
    + [<config_root>/worker-runtime.json]
    + Built-in defaults ([Local] backend, ["masc-worker-runtime:dev"] image). *)

(** {1 Types} *)

type docker_config = {
  image : string;
  host_mcp_base_url : string option;
}

type worker_spawn = {
  backend : Worker_execution_backend.t;
  docker : docker_config;
}

type t = {
  worker_spawn : worker_spawn;
}

(** {1 Public API} *)

(** Effective worker runtime backend after file + env resolution. *)
val backend : unit -> Worker_execution_backend.t

(** Effective docker image, after file + env resolution. *)
val docker_image : unit -> string

(** Effective host MCP base URL override (if any). *)
val host_mcp_base_url_opt : unit -> string option

(** Invalidate the cached resolved config; next call re-reads disk
    and env. Used by tests and by explicit reload paths. *)
val reset : unit -> unit
