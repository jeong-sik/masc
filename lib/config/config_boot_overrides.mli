(** Process-local typed boot configuration store.

    Holds startup-loaded typed configuration decoded directly from
    [runtime.toml] without round-tripping through fake environment strings.

    Precedence used by {!source} and standard readers:
    real process env > typed boot store > hardcoded default. A file-owned
    name (see {!declare_file_owned}) skips the process env: typed boot store
    > hardcoded default. *)

(** Typed scalar value decoded directly from [runtime.toml]. *)
type typed_value =
  | Bool of bool
  | Int of int
  | Float of float
  | String of string

val typed_value_to_string : typed_value -> string
(** Format a typed value for operator display projections. *)

(** Typed immutable namespace records decoded directly from [runtime.toml]. *)
type memory_config =
  { category_cap : int option
  ; facts_per_category_cap : int option
  ; recall_enabled : bool option
  ; librarian_enabled : bool option
  ; facts_max_bytes : int option
  ; pending_max_bytes : int option
  }

type wiki_contents_config =
  { enabled : bool option
  }

type maintenance_config =
  { jsonl_retention_days : int option
  }

type transport_config =
  { h2_max_concurrent_streams : int option
  ; h2_max_pending_response_bytes : int option
  ; h2_initial_window_size : int option
  ; https_port : int option
  ; tls_cert_file : string option
  ; tls_key_file : string option
  ; grpc_enabled : bool option
  ; ws_enabled : bool option
  ; serving_domain_enabled : bool option
  ; startup_watchdog_sec : float option
  }

type typed_namespaces =
  { memory : memory_config
  ; wiki_contents : wiki_contents_config
  ; maintenance : maintenance_config
  ; transport : transport_config
  }

val empty_typed_namespaces : typed_namespaces

val typed_namespaces : unit -> typed_namespaces
(** Current immutable snapshot of decoded [runtime.toml] namespace records. *)

val set_typed_namespaces : typed_namespaces -> unit
(** Atomically publish decoded [runtime.toml] namespace records. *)

val get_typed_opt : string -> typed_value option
(** Read the typed boot value for [name]. [None] if no boot value is set. *)

val set_typed : string -> typed_value -> unit
(** Store one typed boot value. CAS-based; safe under contention. *)

val set_typed_batch : (string * typed_value) list -> unit
(** Atomically apply a batch of typed boot values. *)

val get_opt : string -> string option
(** Operator/display string projection of the boot value for [name].
    Typed config readers should prefer {!get_typed_opt}. *)

val set : string -> string -> unit
(** Store a raw string boot override (for tests and string-typed settings). *)

val clear : string -> unit
(** Drop the boot override for [name]. CAS-based. *)

val declare_file_owned : string list -> unit
(** Declare the names whose only input is the runtime file; replaces any earlier
    declaration. The loader calls it at boot with the registry's file-owned
    names, before it reads or applies anything, and with [[]] when the file
    does not load. *)

val is_file_owned : string -> bool
(** Whether [name] was declared file-owned. *)

val reset_for_tests : unit -> unit
(** Test-only: reset the entire store, typed namespaces, and file-owned
    declaration to empty. *)

(** The layer that would supply a setting: the process environment, the
    boot-time value the runtime file applied, or neither. *)
type source =
  | Env
  | Boot_override
  | Default

val source : string -> source
(** The layer that would supply [name]. *)
