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
val cache_resolved_base_path : string -> unit
val resolve_masc_base_path : string -> string
val resolve_server_default_base_path : string -> string
val is_temp_scratch_dir : string -> bool
(** [is_temp_scratch_dir p] is true when [p] is (or is under) a scratch/temp
    directory such as the OS temp dir, [/tmp], [/var/tmp] or [/dev/shm]. *)
val resolved_base_escapes_temp_request : string -> string -> bool
(** [resolved_base_escapes_temp_request requested resolved] is true when
    [requested] is a scratch/temp directory but [resolved] is not — i.e. a
    temp-dir base request resolved outside temp. task-351 guard: such a
    resolution must never be honoured, or a test harness can rewrite a live
    workspace (2026-08-25 04:38:30Z incident). *)
val env_opt : string -> string option
val sanitize_namespace_segment : string -> string
(** A bounded filesystem path segment for a logical name.

    A name that is already a safe, short, lowercase segment maps to itself. Any
    other name carries the first 64 bits of its SHA-256 digest. This separates
    the known folding collisions such as ["a.b"], ["a/b"] and ["a b"] and
    makes accidental collisions unlikely; it is not a mathematical injectivity
    guarantee. Length is at most {!namespace_segment_max_length} + 17
    (#24342, #24343). *)

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
