(** The server's storage cleanup loop for Keeper sandboxes. It schedules each
    Keeper's steps, keeps what they returned and publishes it.

    What a step cleans and how it runs are [Keeper_cleanup_step] and
    [Keeper_cleanup_attempt]. The published value is [Keeper_cleanup_status].
    Operator guide: [docs/guides/KEEPER-VM-BUILD-CLEANUP.md]. *)

type running
(** The Keepers whose attempt has not returned. *)

val create_running : unit -> running

val schedule :
  sw:Eio.Switch.t -> running:running -> keeper_name:string -> (unit -> unit) -> bool
(** Forks the callback for the Keeper and answers [true], unless an earlier
    attempt of that Keeper has not returned: then nothing is forked and the
    answer is [false]. The Keeper is free again when the callback returns or
    unwinds. *)

val attempt_steps :
  config:Workspace.config ->
  keeper_name:string ->
  Keeper_cleanup_step.t list ->
  unit ->
  unit
(** Runs the Keeper's steps in the given order. Each attempt is logged and
    recorded; a step does not wait on the one before it. *)

val current : unit -> Keeper_cleanup_status.t
(** The latest pass and, for every Keeper and step, the latest attempt. Empty
    after a start until the first pass. *)

val envelope_json : unit -> Yojson.Safe.t
(** [current] as the dashboard tools envelope carries it. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Forks the loop under [sw]. *)
