(** Static observation classification for the external-effect Gate.

    [Needs_observation] does not reject a call: the existing boxed execution
    may answer it without a Judge. Unsupported syntax and runtime profiles
    retain their ordinary Gate path. No command is executed by this module. *)

type git_command = Diff | Log | Show | Grep | Reflog | Whatchanged | Blame | Annotate

type observation_reason =
  | Git_configuration_override
  | Git_command_requires_execution of git_command
  | Unproven_request

type classification =
  | Static_observation
  | Needs_observation of observation_reason

val classification_to_yojson : classification -> Yojson.Safe.t
(** Canonical classification and reason tags for the execution record.
    Includes a closed Git command name when known, never raw arguments. *)

val classify_request
  :  operation:string
  -> sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile option
  -> input:Yojson.Safe.t
  -> classification
(** Classify a [tool_execute] envelope or a [network_read] capability.
    Commands are decoded from argv, script, or an argv shell costume using
    the dispatcher's Shell IR parser. Reasons survive each layer of that
    projection. A static command still requires a disposable-guest profile
    before the whole request is statically observational; envelope sandbox
    labels remain display data only.

    The established [web_search]/[web_fetch] policy is retained. Their
    executors own network destination validation; this function performs no
    DNS lookup or output-location inference. *)

val classify_script : string -> classification
(** Classifies every pipeline/sequence stage through the dispatcher's parser.
    The first stage without a static observation proof supplies the reason.
    A dynamic or unsupported shell construct remains [Unproven_request]. *)

val classify_argv : string list -> classification
(** Git global configuration overrides and commands whose effects depend on
    repository configuration, helper programs or output options need actual
    execution evidence. Other command handling retains the existing policy;
    this is not a complete effect proof for every Git/Unix option. *)

val observation_network_capabilities : string list
val observation_commands : string list
val git_read_subcommands : string list
(** Existing static command inventories, exposed for coverage of that policy. *)
