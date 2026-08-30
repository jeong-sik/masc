(** SSH remote execution endpoint registry entry (Phase 1 SSH lane).

    One [t] per [\[exec.ssh.endpoints.<name>\]] table in runtime.toml
    (docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md §4.2
    "Config surface"). The registry is parsed by {!Runtime_toml} into
    {!Runtime_schema.config.exec_ssh_endpoints}; keeper dispatch (Phase 1
    task 6) resolves a keeper TOML [remote_endpoint] name against it and an
    unknown name is a config-load error. *)

val known_capabilities : string list
(** Capability strings the registry recognizes (Phase 2 reservations).
    Unknown values are warned about and ignored at parse time, per the
    spec table. *)

val default_identity_file : name:string -> string
(** [.masc/ssh/<name>.key] — relative to the workspace base path.
    [Runtime_toml] is base-agnostic, so the default is stored in this
    base-relative form; consumers join it onto the workspace base. *)

val default_known_hosts_file : name:string -> string
(** [.masc/ssh/known_hosts.d/<name>] — relative to the workspace base path,
    same convention as {!default_identity_file}. *)

val default_port : int
(** [22]. *)

val default_connect_timeout_sec : int
(** [10] — maps to ssh [ConnectTimeout]. *)

val default_max_concurrent_sessions : int
(** [8] — sessions multiplex onto one ControlMaster connection; sshd
    [MaxSessions] defaults to 10, so the ceiling is explicit. *)

val validate_destination : host:string -> user:string -> (unit, string) result
(** Reject values that OpenSSH could parse as an option instead of the single
    [user@host] destination argument, plus whitespace/control bytes and extra
    [@] separators. This validation is repeated at dispatch as defense in
    depth for callers that construct {!t} directly. *)

(* Path convention: the defaults above are stored relative to the workspace
   base path, and an operator-written explicit RELATIVE [identity_file] or
   [known_hosts_file] resolves the same way — consumers join either form onto
   the workspace base (Phase 1 tasks 6/9 contract). *)

type t =
  { name : string  (** Registry key — the [<name>] in the table header. *)
  ; host : string  (** Remote host (required). *)
  ; user : string  (** Remote unix user (required). *)
  ; port : int  (** ssh port. Default {!default_port}. *)
  ; identity_file : string
    (** Dedicated key — a path *reference*; key material lives at 0600 under
        [<base>/.masc/ssh/] per [config/identity/] conventions. Default
        [<base>/.masc/ssh/<name>.key], stored base-relative. *)
  ; known_hosts_file : string
    (** Pinned host keys (public; may be committed). Default
        [<base>/.masc/ssh/known_hosts.d/<name>], stored base-relative. *)
  ; remote_root : string  (** Remote playground root (required). *)
  ; connect_timeout_sec : int
    (** Maps to ssh [ConnectTimeout]. Default {!default_connect_timeout_sec}. *)
  ; max_concurrent_sessions : int
    (** Sessions multiplex onto one ControlMaster connection; sshd
        [MaxSessions] defaults to 10, so the ceiling is explicit. Default
        {!default_max_concurrent_sessions}. *)
  ; env_allowlist : string list
    (** Request env names allowed to cross the wire. Default [[]]. *)
  ; capabilities : string list
    (** Reserved Phase 2 markers ({!known_capabilities}); unknown values are
        warned about and ignored at parse time. Default [[]]. *)
  }
[@@deriving show, eq]

val toml_of_endpoint : t -> Otoml.t
(** R00 serialization contract: derive the fixture/roundtrip TOML form from
    [t] itself instead of hand-writing it per test. [Runtime_toml]'s decoder
    is the consumer SSOT; this encoder is its type-derived mirror. Emits only
    the endpoint table (no [exec.ssh.endpoints] wrapper) so several endpoints
    can be composed into one runtime.toml. *)

val to_toml : t -> string
(** Serialize one endpoint as the standard TOML text of its
    [exec.ssh.endpoints.<name>] table, ready to be a section of runtime.toml. *)
