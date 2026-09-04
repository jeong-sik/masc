(** Keeper_turn_up_args — parse and bundle tool arguments for keeper_up.

    Extracts all argument parsing from [handle_keeper_up] into a
    single record so that create / update branches receive
    structured data instead of 60+ local bindings. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** Parsed [keeper_up] tool arguments. Optional fields are [None] when the
    JSON arg was absent or [`Null], except [max_context_override_opt], whose
    paired [max_context_override_present] distinguishes explicit clear from
    omission on update. Non-optional fields default to [""], [[]], or the
    profile-default. *)
type parsed_args =
  { name : string
  ; runtime_id_opt : string option
  ; autoboot_enabled_opt : bool option
  ; mention_targets_opt : string list option
  ; max_context_override_opt : int option
  ; max_context_override_present : bool
  ; proactive_enabled_opt : bool option
  ; sandbox_profile_opt : string option
  ; remote_endpoint_opt : string option
  ; remote_endpoint_present : bool
  ; network_mode_opt : string option
  ; skill_names_opt : string list option
  ; skill_names_present : bool
  ; native_tool_posture_opt : Runtime_native_tools.posture option
  ; native_tool_posture_present : bool
  ; instructions_arg : string option
  ; profile_defaults : keeper_profile_defaults
  ; declarative_manifest_snapshot : declarative_manifest_snapshot
  ; instructions_opt : string option
  }

(** Project an [`Assoc] member at [key]; [None] for non-objects or
    missing keys. *)
(** Parse the explicit context override. Missing is [(false, None)]; null or
    zero explicitly clears it; positive integers are preserved exactly. *)
val parse_max_context_override :
  Yojson.Safe.t -> (bool * int option, string) result

(** Top-level parser: project the [keeper_up] tool args JSON to a
    [parsed_args] record, or return a [tool_result] error envelope.

    A stated profile has to be dispatchable, not just well-formed: a
    [remote_ssh] profile runs the endpoint preflight, and a [docker] profile
    runs [docker_preflight] (daemon, image, hardening) and is refused under
    {!Keeper_sandbox_runtime.docker_preflight_failed_label} when it fails.
    [docker_preflight] defaults to {!Keeper_sandbox_runtime.docker_preflight}
    with the [Io] shell-timeout bucket; [None] from it means the preflight
    master switch is off and admission proceeds. Both preflights run on
    every call, creation and update alike: a redeclared keeper whose sandbox
    is unreachable is refused the same way a new one is. The test suite has
    no daemon and passes its own probe. *)
val parse :
  ?docker_preflight:(timeout_sec:float -> Keeper_sandbox_runtime.docker_preflight option) ->
  _ context ->
  Yojson.Safe.t ->
  (parsed_args, tool_result) result

(** Every top-level key [parse] consumes — the contract the unknown-key gate
    is derived from, not documentation of it. A consumed-but-unlisted key
    makes [parse] reject valid traffic; a listed-but-dead key certifies the
    silent drop the gate exists to kill. Keep exactly in sync with [parse]. *)
val creation_stem : string
(** A declaration [parse] accepts, rendered for a human to fill in.

    Lives beside [parse] because which fields a creation cannot omit is
    [parse]'s business. Stating them anywhere else drifts: the TUI form
    carried a two-field stem across the whole time [sandbox_profile] was
    required, so every keeper made through it came back rejected. A test runs
    this through [parse], which puts a new requirement's cost here rather than
    in an operator's editor. *)

val known_turn_up_args : string list

(** Typed rejection (R09 [turn_up_arg_unknown]) naming every unrecognised
    key the caller sent. *)
val turn_up_arg_unknown : string list -> tool_result

(** Resolve mention targets with dedupe + blank filter. [None] falls through to
    [fallback_targets] → [[name]]; [Some []] is an explicit clear. *)
val resolve_mention_targets :
  mention_targets_opt:string list option ->
  fallback_targets:string list ->
  name:string ->
  string list

val resolve_sandbox_profile :
  ?requested:string ->
  fallback:sandbox_profile option ->
  unit ->
  sandbox_profile option
(** An explicit [requested] profile wins over the TOML [fallback]; [None] means
    neither source named one.

    Omission is not a profile, so it does not collapse into [Local].  It used
    to: keeper-up then refused the substituted value with "local is disabled",
    naming a profile the caller never chose, and the message sent operators
    looking for a playground switch instead of the missing field.  Callers
    turn [None] into
    [Keeper_meta_contract.missing_required_sandbox_profile_error], which names
    the field and the allowed values.

    [requested] is the caller's raw string; an unparseable one is treated as absent,
    since the gate rejects those first. *)

val resolve_requested_network_mode :
  requested:string option ->
  sandbox_profile:sandbox_profile ->
  fallback:network_mode option ->
  (network_mode, string) result
(** The network mode a keeper lands on. [requested] is the caller's raw
    [network_mode] argument; an unparseable one is an [Error] naming every
    accepted spelling, and [None] takes the keeper TOML's [fallback] first,
    then the profile's own default.

    A mode the profile cannot hold is an [Error] as well, from
    {!Keeper_types_profile_sandbox.network_mode_rejection}. Without it,
    [remote_ssh] with [none] was written to a keeper TOML and reported as
    created, and the config loader — which held the same rule — refused that
    file on its next read.

    Create and update both call this. They did not: create resolved from
    [fallback] alone and never read the caller's argument, so a caller who
    asked for [inherit] on a new keeper got [none] written to its TOML with
    nothing said, while the same argument on an existing keeper was honoured.
    A keeper created to search the web reached the operator unable to.

    [fallback] is the keeper TOML's declaration, never a live meta's
    [network_mode]: the meta decoder pins that field, so reading it back would
    flip a declared [none] to [inherit] on any field-only update. *)
