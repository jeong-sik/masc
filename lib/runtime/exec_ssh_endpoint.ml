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

let validate_destination ~host ~user =
  let validate kind value =
    if value = ""
    then Error (Printf.sprintf "remote_ssh_endpoint_invalid: %s must not be empty" kind)
    else if value.[0] = '-'
    then
      Error
        (Printf.sprintf
           "remote_ssh_endpoint_invalid: %s must not begin with '-' (OpenSSH option injection)"
           kind)
    else if String.contains value '@'
    then
      Error
        (Printf.sprintf
           "remote_ssh_endpoint_invalid: %s must not contain '@'"
           kind)
    else if
      String.exists
        (fun c ->
          let code = Char.code c in
          code <= 0x20 || code = 0x7f)
        value
    then
      Error
        (Printf.sprintf
           "remote_ssh_endpoint_invalid: %s must not contain whitespace or control bytes"
           kind)
    else Ok ()
  in
  match validate "host" host with
  | Error _ as error -> error
  | Ok () -> validate "user" user
;;

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
  ; private_home : bool
    (** The operator's declaration that this account's home is the keeper's
        alone (RFC-0422 §3.4). Default [false]. *)
  }
[@@deriving show, eq]
let string_array values = Otoml.TomlArray (List.map (fun s -> Otoml.TomlString s) values)

(** R00 serialization contract: derive the fixture/roundtrip TOML form from
    [t] itself instead of hand-writing it per test. [Runtime_toml]'s decoder
    is the consumer SSOT; this encoder is its type-derived mirror, so a field
    rename or a new knob cannot drift between what tests write and what the
    loader reads. The table body carries ONLY the keys the strict decoder
    accepts — the endpoint name is the table header key, not a field, and a
    stray [name] entry would fail the whole load. *)
let toml_of_endpoint (endpoint : t) : Otoml.t =
  Otoml.TomlTable
    [ ("host", Otoml.string endpoint.host)
    ; ("user", Otoml.string endpoint.user)
    ; ("port", Otoml.integer endpoint.port)
    ; ("identity_file", Otoml.string endpoint.identity_file)
    ; ("known_hosts_file", Otoml.string endpoint.known_hosts_file)
    ; ("remote_root", Otoml.string endpoint.remote_root)
    ; ("connect_timeout_sec", Otoml.integer endpoint.connect_timeout_sec)
    ; ("max_concurrent_sessions", Otoml.integer endpoint.max_concurrent_sessions)
    ; ("env_allowlist", string_array endpoint.env_allowlist)
    ; ("capabilities", string_array endpoint.capabilities)
    ; ("private_home", Otoml.boolean endpoint.private_home)
    ]

(** Serialize one endpoint as the standard TOML text of its
    [exec.ssh.endpoints.<name>] table, ready to be a section of runtime.toml.
    The path is built as nested tables — a dotted literal key would make the
    printer emit one quoted header key instead of the section path. *)
let to_toml (endpoint : t) : string =
  Otoml.Printer.to_string
    (Otoml.TomlTable
       [ ( "exec"
         , Otoml.TomlTable
             [ ( "ssh"
               , Otoml.TomlTable
                   [ ( "endpoints"
                     , Otoml.TomlTable [ (endpoint.name, toml_of_endpoint endpoint) ] )
                   ] )
             ] )
       ])
