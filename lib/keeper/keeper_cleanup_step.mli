(** The storage cleanup steps the server runs for a Keeper's sandbox.

    One closed list. Where a step applies and how it shares the Keeper with
    its turns are answered here through exhaustive matches, so a step added
    to the list cannot be skipped silently by the code that selects and runs
    steps. The order of [all] is the order steps run for one Keeper.

    Design: [docs/rfc/RFC-storage-cleanup-steps-come-from-one-list-and-leave-a-result.md]. *)

type t =
  | Guest_builds
  (** Idle Dune [_build] output inside a running Apple microVM guest. *)
  | Remote_workspace
  (** Idle entries under a Remote_ssh Keeper's workspace root on its endpoint. *)
[@@deriving enumerate]

val equal : t -> t -> bool

val to_string : t -> string
(** The step's wire name. *)

val of_string : string -> t option
(** The step with that wire name. [None] for any other text. *)

(** How a step shares the Keeper with its turns. *)
type admission =
  | Idle_owner
  (** Runs only while the Keeper is idle, holding the Owner's Maintenance
      slot. The Keeper's turns and the payload share what the step cleans. *)
  | Beside_turns
  (** Runs beside the Keeper's turns. The payload itself leaves alone what a
      live process uses and what was touched within the retention. *)

val admission : t -> admission

val applies_to :
  t ->
  sandbox_profile:Keeper_types_profile.sandbox_profile ->
  microvm_backend:Keeper_microvm_backend.t option ->
  bool
(** Whether a Keeper declared with this profile and backend has what the step
    cleans. The caller passes the TOML-resolved declaration: a stored or
    projected meta carries the JSON decoder's placeholder profile. *)
