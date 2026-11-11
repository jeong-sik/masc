(** Chooses and runs the storage cleanup steps of one Keeper.

    Each step's switch, admission and payload are answered here, so the
    server's loop only schedules a Keeper and keeps what comes back.

    Design: [docs/rfc/RFC-storage-cleanup-steps-come-from-one-list-and-leave-a-result.md]. *)

val read_meta :
  config:Workspace.config ->
  keeper_name:string ->
  (Keeper_meta_contract.keeper_meta option, string) result
(** The Keeper's meta with its TOML declaration resolved. A stored or
    projected meta carries the JSON decoder's placeholder profile, so steps
    are never chosen from one. [Error] when the declaration cannot be read,
    or when the meta found under this name belongs to another Keeper. *)

val enabled : Keeper_cleanup_step.t -> bool
(** The step's switch in the runtime settings, read when called. *)

val select :
  config:Workspace.config ->
  enabled:(Keeper_cleanup_step.t -> bool) ->
  keeper_name:string ->
  (Keeper_cleanup_step.t list, Keeper_cleanup_status.exclusion) result
(** The steps that apply to the Keeper's declared sandbox and that [enabled]
    answers [true] for, in the order of the step list. Never [Ok []]. *)

val outcome_of_admission :
  ( [< `Ran of ('report option, string) result | `Busy of Keeper_owner.autonomous_block ]
    , Keeper_owner_registry.command_error )
    result ->
  'report Keeper_cleanup_status.outcome
(** How an idle-only step's admission reads as an outcome. A busy Owner is
    [Deferred] with its reason. A payload that found no running guest
    ([Ok None]) is [Not_running]. A refused command and a payload error are
    [Failed]. *)

val run :
  config:Workspace.config ->
  keeper_name:string ->
  Keeper_cleanup_step.t ->
  Keeper_cleanup_status.attempt
(** One attempt of one step. It reads the Keeper's meta again when the step
    is admitted, because an idle-only step can wait in the Owner's mailbox
    while the declaration changes. An exception is a [Failed] attempt; only
    cancellation is raised. *)
