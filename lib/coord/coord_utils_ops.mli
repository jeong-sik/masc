(** Coord helpers: input validators, JSON I/O (local + root-scoped),
    distributed/file locking with full-jitter backoff, and event
    logging. *)

open Types
open Coord_utils_backend_setup

val contains_substring : string -> string -> bool

(** {1 Validators (string-error)} *)

val validate_agent_name : string -> (string, string) result
val validate_task_id : string -> (string, string) result
val validate_room_id : string -> (string, string) result
val validate_file_path : string -> (string, string) result

(** {1 Sanitizers} *)

val sanitize_html : string -> string
val sanitize_agent_name : string -> string
val sanitize_message : string -> string

(** Map characters outside [a-z0-9._-] to [_HH] hex escapes;
    safe for filesystem path use. *)
val safe_filename : string -> string

(** {1 Validators (masc_error)} *)

val validate_agent_name_r : string -> (string, masc_error) result
val validate_task_id_r : string -> (string, masc_error) result
val validate_file_path_r : string -> (string, masc_error) result

(** {1 Initialization gates} *)

val ensure_initialized : config -> unit
val ensure_initialized_r : config -> (unit, masc_error) result

(** {1 Filesystem helpers} *)

val mkdir_p : string -> unit

(** {1 JSON I/O — local filesystem} *)

(** Read a JSON file from disk with permissive error handling:
    blank/empty files are returned as [`Assoc []]; parse / read
    failures log a WARN and return [`Assoc []]. *)
val read_json_local : string -> Yojson.Safe.t

(** Result-returning variant that surfaces the raw error message. *)
val read_json_local_result : string -> (Yojson.Safe.t, string) result

(** Atomic pretty-print write; creates parent dirs as needed. *)
val write_json_local :
  string -> Yojson.Safe.t -> (unit, string) result

(** {1 JSON I/O — root-scoped (cluster registry)} *)

val read_json_root : config -> string -> Yojson.Safe.t
val write_json_root : config -> string -> Yojson.Safe.t -> unit
val delete_path_root : config -> string -> unit
val path_exists_root : config -> string -> bool

(** {1 JSON I/O — backend-routed} *)

(** Read a JSON value via the active backend (or local FS when
    the backend has no key for this path). *)
val read_json : config -> string -> Yojson.Safe.t

(** Result-returning variant. *)
val read_json_result :
  config -> string -> (Yojson.Safe.t, string) result

(** Read a UTF-8 text file via the active backend; falls back to
    local FS when the backend has no key for this path. *)
val read_text : config -> string -> string

(** [true] iff the FileSystem backend should mirror writes to
    local disk (single-process configs only). *)
val should_dual_write_local : config -> bool

(** Backend-routed JSON write; respects [should_dual_write_local]. *)
val write_json : config -> string -> Yojson.Safe.t -> unit

val write_text_local : string -> string -> (unit, string) result
val write_text : config -> string -> string -> unit
val delete_path : config -> string -> unit
val path_exists : config -> string -> bool
val append_text : config -> string -> string -> unit

(** Read JSON if present; [None] for absent files (no WARN log). *)
val read_json_opt : config -> string -> Yojson.Safe.t option

(** {1 Agent JSON repair} *)

(** [true] iff the agent JSON has a numeric [last_seen] (legacy
    pre-canonical-form) and needs rewriting. *)
val agent_json_needs_repair : Yojson.Safe.t -> bool

(** Read an agent JSON and rewrite it in canonical form when the
    [last_seen] repair predicate fires. *)
val read_agent_with_repair :
  config -> string -> (agent, string) result

(** {1 Locking} *)

val sleep_lock_retry : ?clock:_ Eio.Time.clock -> float -> unit

(** Per-domain RNG key for backoff jitter. *)
val backoff_rng_key : Random.State.t Domain.DLS.key

(** Full-jitter backoff: returns a sleep duration uniformly
    distributed in [[0, delay]]. *)
val backoff_with_jitter : float -> float

(** Acquire a distributed lock via the backend, retrying with
    full-jitter backoff. Raises [Invalid_argument] when the
    50-attempt budget is exhausted; bumps the
    [Coord_hooks.distributed_lock_acquire_failed_fn] counter. *)
val with_distributed_lock :
  ?clock:_ Eio.Time.clock ->
  config ->
  string ->
  string ->
  (unit -> 'a) ->
  'a

(** Result-returning variant of [with_distributed_lock]. *)
val with_distributed_lock_r :
  ?clock:_ Eio.Time.clock ->
  config ->
  string ->
  string ->
  (unit -> 'a) ->
  ('a, masc_error) result

val with_file_lock_impl :
  ?clock:_ Eio.Time.clock ->
  config -> string -> (unit -> 'a) -> 'a

(** Cooperative file lock (Eio mutex for in-process, distributed
    lock for FileSystem backend); explicit clock argument. *)
val with_file_lock_eio :
  clock:_ Eio.Time.clock ->
  config -> string -> (unit -> 'a) -> 'a

(** Cooperative file lock; uses [Eio_context.get_clock_opt]. *)
val with_file_lock : config -> string -> (unit -> 'a) -> 'a

val with_file_lock_r_impl :
  ?clock:_ Eio.Time.clock ->
  config -> string -> (unit -> 'a) -> ('a, masc_error) result

val with_file_lock_r_eio :
  clock:_ Eio.Time.clock ->
  config -> string -> (unit -> 'a) -> ('a, masc_error) result

val with_file_lock_r :
  config -> string -> (unit -> 'a) -> ('a, masc_error) result

(** {1 Event logging} *)

(** Append [event_json], serialized via [Yojson.Safe.to_string], to the
    YYYY-MM/DD.jsonl event log under [.masc/events/]. PR #11507 migrated
    the implementation and every caller to typed JSON; the .mli must
    track. *)
val log_event : config -> Yojson.Safe.t -> unit
