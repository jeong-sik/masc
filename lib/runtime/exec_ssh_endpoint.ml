(** SSH remote execution endpoint registry entry (Phase 1 SSH lane).

    One [t] per [\[exec.ssh.endpoints.<name>\]] table in runtime.toml
    (docs/superpowers/specs/2026-08-27-openssh-microvm-exec-design.md §4.2
    "Config surface"). The registry is parsed by {!Runtime_toml} into
    {!Runtime_schema.config.exec_ssh_endpoints}; keeper dispatch (Phase 1
    task 6) resolves a keeper TOML [remote_endpoint] name against it and an
    unknown name is a config-load error. *)

(** Capability strings the registry recognizes (Phase 2 reservations).
    Unknown values are warned about and ignored at parse time, per the
    spec table. *)
let known_capabilities = [ "kvm"; "firecracker" ]

(* The two file defaults are resolved at parse time (where the endpoint name
   is in scope) as paths RELATIVE to the workspace base path, with the name
   substituted. [Runtime_toml] is deliberately base-agnostic — credential
   [file] paths are likewise carried verbatim — so the registry stores the
   same relative form rather than resolving against [Config_dir_resolver]
   here. Consumers join them onto the workspace base (or
   [Config_dir_resolver.masc_root]). *)
let default_identity_file ~name = Printf.sprintf ".masc/ssh/%s.key" name

let default_known_hosts_file ~name =
  Printf.sprintf ".masc/ssh/known_hosts.d/%s" name
;;

let default_port = 22
let default_connect_timeout_sec = 10
let default_max_concurrent_sessions = 8

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
