type acquire_result =
  | Acquired
  | Already_running of { pid : int }

type base_path_lease

type base_path_lock_rejection =
  | Base_path_canonicalization_failed of
      { base_path : string
      ; reason : string
      }
  | Base_path_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_canonicalization_failed of
      { run_dir : string
      ; reason : string
      }
  | Run_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Run_directory_untrusted_owner of
      { path : string
      ; effective_uid : int
      ; observed_uid : int
      }
  | Run_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_directory_not_directory of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_directory_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_directory_insecure_permissions of
      { path : string
      ; permissions : int
      }
  | Lease_directory_identity_changed of { path : string }
  | Runtime_directory_rejected of Fs_compat.owned_directory_chain_rejection
  | Runtime_directory_creation_failed of
      { path : string
      ; reason : string
      }
  | Lease_file_non_regular of
      { path : string
      ; kind : Unix.file_kind
      }
  | Lease_file_multiply_linked of
      { path : string
      ; links : int
      }
  | Lease_file_wrong_owner of
      { path : string
      ; expected_uid : int
      ; observed_uid : int
      }
  | Lease_identity_changed of { path : string }
  | Lease_io_failed of
      { operation : string
      ; path : string
      ; reason : string
      }

type base_path_acquire_result =
  | Base_path_acquired of base_path_lease
  | Base_path_already_owned of { pid : int option }
  | Base_path_rejected of base_path_lock_rejection

val base_path_lock_rejection_to_string : base_path_lock_rejection -> string

val pid_lock_path : int -> string

(** Deterministic external lease path for an already-canonical BasePath and
    host run root. The path is below the current effective UID's private lease
    directory; the full SHA-256 digest is a filesystem-safe index. Collisions
    fail closed by contending on the same lease file. This function derives a
    path only; [acquire_base_path_lock] establishes and validates the private
    directory. *)
val base_path_lock_path :
  run_dir:string ->
  canonical_base_path:string ->
  string

val status_line_is_healthy : string -> bool

val looks_like_server_command : string -> bool

val probe_liveness : ?timeout_sec:float -> ?path:string -> int -> bool

val wait_for_pid_exit :
  ?poll_interval_sec:float -> timeout_sec:float -> int -> bool

val acquire_pid_lock :
  ?lock_path:string ->
  ?probe_timeout_sec:float ->
  ?term_timeout_sec:float ->
  ?kill_wait_sec:float ->
  ?poll_interval_sec:float ->
  int ->
  acquire_result

(** Path of the takeover forensics breadcrumb derived from [lock_path]
    (the pid-lock file the takeover contends on). *)
val takeover_breadcrumb_path : lock_path:string -> string

(** Written by the killer immediately before signalling an unresponsive
    incumbent during [acquire_pid_lock], so the victim's SIGTERM path (or the
    next boot, after a SIGKILL escalation) can attribute the shutdown to this
    takeover instead of an unknown external sender. Best-effort: a write
    failure logs a warning and never blocks lock acquisition. *)
val write_takeover_breadcrumb :
  lock_path:string -> port:int -> target_pid:int -> signal_name:string -> unit

type takeover_breadcrumb =
  { breadcrumb_path : string
  ; age_sec : float
  ; killer_pid : int option
      (** Parsed from the payload for self-filtering at boot; [None] when the
          payload is not the expected JSON shape. The raw [payload] is always
          preserved for logging. *)
  ; payload : string
  }

type takeover_breadcrumb_read =
  | Breadcrumb_found of takeover_breadcrumb
  | Breadcrumb_stale of
      { breadcrumb_path : string
      ; age_sec : float
      }
  | Breadcrumb_absent
  | Breadcrumb_unreadable of
      { breadcrumb_path : string
      ; reason : string
      }

(** Reads the breadcrumb next to [lock_path]. [max_age_sec] (default 600 s,
    covering the supervisor restart cooldown plus a slow boot) bounds how old
    a breadcrumb may be to still explain the current signal; older files are
    reported as [Breadcrumb_stale] so a previous incident is never mistaken
    for the present one. *)
val read_takeover_breadcrumb :
  ?max_age_sec:float -> lock_path:string -> unit -> takeover_breadcrumb_read

(** Acquire the process-lifetime owner lease below a current-UID-owned [0700]
    private directory in the explicitly supplied host run root, then establish
    and validate [<base_path>/.masc]. A group- or world-writable [run_dir] is
    accepted only when its sticky bit prevents other UIDs from renaming the
    private directory. No fallback directory is selected.

    The effective UID is the host trust principal: the private directory blocks
    mutation by other UIDs, while processes already running as that UID are in
    the same host authority domain. Malicious same-UID rename, unlink, or chmod
    is outside the portable boundary because OCaml 5.4 exposes no
    [openat]/dirfd-relative no-follow API. Acquisition revalidates directory and
    file identities at every commit boundary and fails closed on an observed
    change; the residual lifetime race is tracked by #24344. *)
val acquire_base_path_lock :
  run_dir:string ->
  string ->
  base_path_acquire_result

val release_base_path_lease : base_path_lease -> unit

module For_testing : sig
  (** Immutable synchronization boundaries around the external lease open and
      the final identity checks. Production acquisition closes over no-op
      functions; no mutable test hook is reachable from production callers. *)
  val acquire_base_path_lock
    :  before_lease_open:(unit -> unit)
    -> before_commit_identity_check:(unit -> unit)
    -> before_runtime_identity_check:(unit -> unit)
    -> run_dir:string
    -> string
    -> base_path_acquire_result
end
