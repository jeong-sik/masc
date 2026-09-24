(** Write and Edit for a tree the endpoint owns ([Endpoint_owned]): the bytes
    travel through [masc-exec-shim] over the remote lane instead of a host
    filesystem capability. Same path jail, modes, patch and evidence as the
    host handler, and no publication-recovery journal (the replace is
    [mktemp] + [mv] on the endpoint).

    A name in the keeper's own tree is an internal write and takes no Gate
    decision. A path the tree refuses may be under one of the endpoint's
    declared roots ([allowed_paths], #38593); the caller says through
    {!declared_root_writes} whether such a path is written and, if so, which
    Gate decides it. *)

type patch_request =
  { old_string : string
  ; new_string : string
  ; replace_all : bool
  }

type authorize_declared_root =
  endpoint:Exec_ssh_endpoint.t
  -> requested_target:string
  -> mode:Keeper_tool_write_mode.t
  -> content_source:Keeper_write_content.t
  -> content:string
  -> patch:patch_request option
  -> Keeper_gate.decision

type declared_root_writes =
  | Refuse_declared_roots
      (** A path outside the keeper's tree is refused, declared or not. *)
  | Authorize_declared_roots of authorize_declared_root
      (** A path under a declared root is written only when this decision
          allows it. It is asked right before the write, with the bytes that
          would be written ([content]; for a patch, the patched file), the
          endpoint path as [requested_target], and the configuration of the
          OpenSSH endpoint the write runs on -- the same one whose
          [allowed_paths] declared the root. [Deferred] answers with the
          deferred receipt and writes nothing. Only an OpenSSH endpoint
          declares roots; a guest endpoint's refused path stays refused. *)

val handle :
  declared_root_writes:declared_root_writes ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Resolve the keeper's endpoint through {!Keeper_sandbox_remote_lane} and
    run {!handle_with_endpoint}. An unreachable endpoint is a
    [Dependency_unavailable] failure. *)

val handle_with_endpoint :
  declared_root_writes:declared_root_writes ->
  endpoint:Keeper_sandbox_remote.t ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

type content_mode =
  | Replace_whole
  | Append_tail

val write_argv : mode:content_mode -> remote_path:string -> string list
(** The [sh -c] payload that writes stdin to [remote_path]: an atomic
    replace beside the target, or an append. *)

val declared_root_write_argv :
  mode:content_mode -> endpoint_path:string -> roots:string list -> string list
(** The payload for a path under the endpoint's declared [roots]. On the
    endpoint it resolves the directory it writes in and exits
    {!declared_root_escape_exit}, writing nothing, unless that directory is
    physically under one of [roots] and the target is not a symbolic link.
    The Gate approved a lexical path; this makes the bytes land at that path
    or nowhere. *)

val declared_root_escape_exit : int

val read_source_argv : remote_path:string -> string list
(** The payload that prints a regular file, or exits
    {!patch_source_missing_exit} when there is none to patch. *)

val patch_source_missing_exit : int
