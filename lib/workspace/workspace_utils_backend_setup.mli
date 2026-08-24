type storage_backend =
  | Memory of Backend.Memory.t
  | FileSystem of Backend.FileSystem.t

type config = {
  base_path : string;
  workspace_path : string;
  lock_expiry_minutes : int;
  backend_config : Backend_types.config;
  backend : storage_backend;
}

val domain_local_pg_backend_diagnostics_json : unit -> Yojson.Safe.t
val parse_gitdir_to_main_root : string -> string option
val find_git_root : string -> string option
val normalize_base_path : string -> string
val running_under_test_executable : unit -> bool
val test_base_path_override_env : string
val cache_resolved_base_path : string -> unit
val resolve_masc_base_path : string -> string
val resolve_server_default_base_path : string -> string
val env_opt : string -> string option
val sanitize_namespace_segment : string -> string
(** A filesystem path segment for a logical name, injective and bounded.

    A name that is already a safe, short, lowercase segment maps to itself. Any
    other name carries a digest of the exact input, so two names never share a
    segment -- the previous folding mapped ["a.b"], ["a/b"] and ["a b"] onto
    one path, and let a name past the filesystem's component limit through
    (#24342, #24343). Distinct in, distinct out; length at most
    {!namespace_segment_max_length} + 17. *)

val namespace_segment_max_length : int
(** Longest canonical segment kept verbatim. Beyond it the segment is the
    truncated fold plus a digest, which stays inside a filesystem component. *)
val backend_config_for : string -> Backend_types.config
val memory_backend_fallback : Backend_types.config -> storage_backend
val create_backend : Backend_types.config -> (storage_backend, Backend_types.error) result
val reset_default_config_cache : unit -> unit
val default_config : string -> config
val default_config_uncached :
  ?on_backend_ready:(storage_backend -> unit) -> string -> config
