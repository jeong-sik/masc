(** Filesystem runtime handlers for descriptor-backed Read/Edit/Write tools. *)

val valid_fs_write_mode_strings : string list
(** The canonical enum [Tool_shard_types_enum_mirrors.fs_write_mode_enum_strings]
    hand-copies. Exported so test_enum_mirror_sync can compare the copy against
    it; the mirror module names this value as the owner. *)
val resolve_write_attribution
  :  base_dir:string
  -> file_path:string
  -> Agent_observation.file_attribution
(** RFC-0378 §5.1. The system's only [Code_address] mint, used by
    the tool-event hook to decide where a keeper write belongs.
    Exposed for testing so the sandbox/working-tree join invariant
    can be verified directly.

    [Addressed] carries the parsed address when the file lives under a
    registered repository (sandbox playground parse or [local_path]
    prefix) whose [url] normalises via
    {!Agent_observation.canonical_url_of_remote}; the repo-relative
    path is lexically dot-collapsed before minting. A path inside a
    linked git worktree of the matched repository folds to the {e same}
    address as the main-tree path — decided by git itself
    ({!Repo_git.checkout_identity}: the file's [--git-common-dir]
    equals the matched root's [.git]), never by a path convention —
    with the measured checkout root carried as the [checkout]
    projection metadata (#28968, RFC-0378 §5.1/§9,
    RFC-keeper-workspace-root-only §3.2).
    [Unaddressed] carries the typed reason and the path exactly as the
    resolver saw it. Total — never raises. *)

val handle_read_file_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

val handle_owned_read_file_with_outcome :
  ownership_root:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** Read-only boundary for a Workspace producer that has no Keeper runtime
    metadata. Relative paths are rooted at [ownership_root], and the opened
    regular file plus every parent component is verified by [Fs_compat]. *)

(** Rebuild the write arguments from a recorded Gate input, including the
    mode the approval carried. [Error] when the recorded effect is one this
    module cannot reproduce exactly, so a caller replays nothing instead of
    downgrading the approved semantics. *)
val replay_args_of_gate_input : Yojson.Safe.t -> (Yojson.Safe.t, string) result

type approved_write =
  { target : string  (** the resolved path the approval names *)
  ; mode : Keeper_tool_write_mode.t
  ; carried : (string * Yojson.Safe.t) list
        (** the payload fields the approval carried, verbatim *)
  }
(** A recorded write approval, decoded. {!replay_args_of_gate_input} is this
    decode re-encoded for the write handler. *)

val approved_write_of_gate_input : Yojson.Safe.t -> (approved_write, string) result
(** Strict decode of a stored [filesystem_write] Gate input. An input with no
    string [requested_target] or with an effect this module cannot reproduce
    is an error, never a guess. *)

val write_call_summary : requested_target:string -> string option
(** The one line a write approval is about: the path it would write. This is
    the write tool's declared call summary; the submitting handler states it
    from the target it resolved, and the replay engine states it from
    {!approved_write_of_gate_input}. [None] when the target is blank. *)


val handle_file_write_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:
    Keeper_publication_recovery_availability.turn_context ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t
(** Local writes acquire the project-root anchor and selected allowed root with
    [Eio.Path.open_dir] before Gate evaluation, then keep those directory
    capabilities through Gate evaluation and the selected effect. Atomic
    replace/patch reads the live publication-recovery provider only after Gate
    authorization and keeps the resulting lane access through recovery record,
    temp-file, and rename work. Append and exclusive create are recovery-store
    independent and therefore never read that provider. No local write is
    performed through a validated native path string.

    The project root's parent is the operator-owned capability-acquisition
    boundary. An explicit allowed root outside the project likewise requires
    an operator-owned parent; Keeper-writable components must begin below the
    opened root capability.

    Writes whose selected confined root is exactly this Keeper's playground
    root proceed after the capability and root-identity checks without an
    approval Gate. Writes through every other allowed root retain the Gate. *)

val default_owned_target :
  ownership_root:string -> path:string -> string * string
(** The [(cwd_abs, target_path)] pair [handle_owned_read_file_with_outcome]
    uses when the tool call omits [cwd]. Falls back to
    [(ownership_root, path)] unless the root holds exactly one
    sub-directory at depth-1 — in that case the helper descends.
    The descent is monotone: a deeper level is taken only when the
    level above it is also uniquely named. With a unique
    [<ownership_root>/<a>/<b>/] layout, a bare repo-relative path
    (form A, e.g. ["lib/keeper/..."]) resolves under
    [<ownership_root>/<a>/<b>/], and a path that already names
    ["a/b/..."] has the leading two segments stripped so the
    subsequent [Filename.concat cwd_abs target_path] does not
    overshoot. With a unique [<ownership_root>/<a>/] layout and a
    path that names ["a/..."], the leading single segment is
    stripped. Zero, several, or non-matching sub-directories fall
    back to [(ownership_root, path)], so the helper never guesses.
    Exposed for testing so [test_owned_read_cwd] can pin the
    contract directly. *)

module For_testing : sig
  type created_directory_fault_stage =
    | Before_create_directory
    | Before_inspect_created_directory
    | Before_apply_directory_permissions

  type created_directory_fault

  val created_directory_fault
    :  stage:created_directory_fault_stage
    -> exception_:exn
    -> created_directory_fault

  val with_created_directory_fault
    :  created_directory_fault
    -> (unit -> 'a)
    -> 'a
end
