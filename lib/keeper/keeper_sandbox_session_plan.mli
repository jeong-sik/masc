(** RFC-0070 Phase 3e (e) — Pure construction of a docker session
    (long-lived container) plan.

    Sibling of {!Keeper_sandbox_oneshot_plan}: that one models a single
    [docker run --rm <cmd>] invocation; this one models *one
    container's lifetime* — a [docker run -d --rm <idle-loop>] spawn
    plus subsequent [docker exec] commands and a final [docker rm].
    Covers [keeper_turn_sandbox_runtime]'s persistent-session container
    (the Phase 4.1 cutover target).

    Reference: docs/rfc/RFC-0070-keeper-sandbox-pure-edge-separation.md
    §3.1.2 (incl. the v2.3 pure/edge correction).

    Determinism contract: same request inputs ⇒ identical {!t}. No
    wall-clock, no PID read, no Random, no daemon I/O — those are the
    *edge* ({!Sandbox_session_executor} / {!Docker_client.S.run_detached},
    which spawns the container, writes {!identity_files}, resolves the
    seccomp choice, and appends the spawn-time [owner_pid] /
    [started_at] labels). [of_request] does read
    [Env_config_keeper.KeeperSandbox.*] for the resource limits and
    rootfs/tmpfs flags — those are stable per run, not the
    non-determinism the split targets.

    This module depends on {!Keeper_sandbox_runtime} for the
    label-key constants + [base_path_hash] / [sanitize_label_value]
    helpers, so the label set stays byte-identical to what
    [keeper_turn_sandbox_runtime.start_container] emits today — a
    later refactor may move those into a shared module, but
    re-defining them here would risk drift. *)

(** {1 Types} *)

(** A docker [--ulimit] entry. Docker's syntax is [name=soft:hard]; the
    shipped default is [{ name = "nofile"; soft = N; hard = N }] (the
    current [docker_nofile_args] behaviour), but [soft <> hard] is now
    representable. *)
type ulimit =
  { name : string
  ; soft : int
  ; hard : int
  }

(** Seccomp profile choice. Currently always {!Seccomp_default} —
    [keeper_turn_sandbox_runtime] does not pick a per-keeper profile;
    it uses whatever [ensure_keeper_sandbox_runtime] returns at spawn
    time. The variant exists so a future per-keeper choice is
    representable without changing the plan shape. The *resolution*
    ([Seccomp_default] → [--security-opt seccomp=<path>] or none) is an
    edge concern. *)
type seccomp_choice =
  | Seccomp_default
  | Seccomp_unconfined
  | Seccomp_profile_file of string

(** {1 Errors} *)

(** Closed sum — no catch-all. [string] payload = the offending input
    value, not a human-readable message (display strings are
    caller-formatted from the variant + payload, keeping payload
    semantics stable and grep-able). *)
type plan_error =
  | Invalid_meta_name of string  (** payload = the offending [meta_name] (often [""]) *)
  | Invalid_container_root of string  (** payload = the offending [container_root] (often [""]) *)
  | Invalid_host_root of string  (** payload = the offending [host_root] (often [""]) *)

(** {1 Plan} *)

(** Abstract session-execution plan. Opaque outside
    {!Sandbox_session_executor}; accessors below expose what the edge
    needs to assemble the [docker run -d] argv. *)
type t

(** {1 Constructor} *)

(** [of_request ~turn_id ~attempt ~meta_name ~container_root ~base_path
    ~container_kind ~network_mode ~host_root ~uid ~gid ?ttl_sec
    ?extra_env ()] derives a session plan from its declared inputs
    alone. Pure (modulo the [Env_config_keeper.KeeperSandbox.*] reads
    noted in the module doc).

    Validation: [meta_name], [container_root], [host_root] must be
    non-empty (the offending value is the payload).

    Populated as the v2.3 pure/edge table specifies:
    - [container_name = Keeper_container_name.derive ~algo:SHA_256
      ~turn_id ~attempt ~suffix:meta_name]
    - [labels] — the 7 deterministic labels only (component /
      base_path_hash / keeper / kind / network / turn_id /
      ttl_sec-if-given); the edge adds [owner_pid] + [started_at].
    - [mounts] — the workspace volume ([host_root:container_root:rw])
      followed by the two identity mounts
      ([<host_root>/.docker-identity/passwd:/etc/passwd:ro], [.../group:/etc/group:ro]).
    - [identity_files] — the [(passwd_path, passwd_content);
      (group_path, group_content)] pairs the edge must write before
      the identity mounts are valid. Content is deterministic in
      [uid]/[gid].
    - [env_overrides] — [("HOME","/tmp"); ("USER","keeper");
      ("LOGNAME","keeper"); ("SHELL","/bin/sh")] then [extra_env].
    - [ulimits] — [[{ name = "nofile"; soft = n; hard = n }]] where
      [n = Env_config_keeper.KeeperSandbox.nofile_limit ()].
    - [pids_limit], [memory_limit], [tmpfs], [read_only_rootfs] —
      from [Env_config_keeper.KeeperSandbox.*].
    - [startup_command] — the trap-and-sleep idle loop
      ([trap : TERM INT; while :; do sleep 3600; done]).
    - [seccomp_profile = Seccomp_default], [cap_drop_all = true],
      [no_new_privileges = true], [user = Some (uid, gid)],
      [image] / [container_root] / [network_mode] / [workdir = Some container_root]
      from the args. *)
val of_request
  :  turn_id:int
  -> attempt:int
  -> meta_name:string
  -> image:string
  -> container_root:string
  -> base_path:string
  -> container_kind:string
  -> network_mode:Keeper_types.network_mode
  -> host_root:string
  -> uid:int
  -> gid:int
  -> ?ttl_sec:float
  -> ?extra_env:(string * string) list
  -> unit
  -> (t, plan_error) result

(** {1 Accessors} *)

val container_name : t -> Keeper_container_name.t
val image : t -> string
val container_root : t -> string

(** Each mount is a docker [-v] spec string ([src:dst:mode]). *)
val mounts : t -> string list

(** [(path, content)] pairs the edge must write (mkdir_p + atomic
    write) before the identity [-v] mounts in {!mounts} are valid. *)
val identity_files : t -> (string * string) list

(** [(name, value)] pairs, emitted as [--env name=value]. *)
val env_overrides : t -> (string * string) list

val network_mode : t -> Keeper_types.network_mode
val user : t -> (int * int) option
val ulimits : t -> ulimit list
val read_only_rootfs : t -> bool
val tmpfs_mount : t -> string
val workdir : t -> string option
val startup_command : t -> string

(** The 7 deterministic [(key, value)] label pairs. The edge appends
    [owner_pid] + [started_at] at spawn time. *)
val labels : t -> (string * string) list

val cap_drop_all : t -> bool
val no_new_privileges : t -> bool
val seccomp_profile : t -> seccomp_choice
val pids_limit : t -> int
val memory_limit : t -> string

(** {1 Equality / pretty-print for tests} *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
