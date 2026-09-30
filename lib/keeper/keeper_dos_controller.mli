(** Frees the DOS controller of a holder who can no longer move, before a
    call that needs the controller. *)

val holder_left :
  transaction:Auth.credential_transaction -> config:Workspace.config ->
  now:float -> string -> Tool_misc_dos_lane.holder_departure option
(** Why [holder] can no longer act, or [None] while it still can.
    [Keeper_stopped]: a Keeper that is paused or stopped, including one whose
    stop finished and left the registry but kept its meta. [Credential_expired]:
    a name whose persisted credential ran out before [now], by the rule
    its bearer is checked by ({!Play_invite.expired}), only where every request
    must carry a credential. This includes a Worker that took a free controller
    through a direct move, even though Workers are not handoff targets.
    [No_credential]: a name
    that is not a Keeper and has no credential file, only where every request
    must carry a credential (auth enabled, [require_token]). A credential file
    that cannot be read, and a missing one where a request needs no token,
    keep the controller. [transaction] must be the current admission for
    [config]'s workspace; keep it through the resulting controller effect. *)

val before_move :
  config:Workspace.config -> who:string -> (unit, Masc_domain.masc_error) result
(** Lets a departed holder's controller go so that [who] can take it, and
    posts the board announcement after releasing the credential transaction.
    Credential publication and the departure read/release cannot interleave.
    A failed credential-lock admission returns [Error] without releasing or
    moving the machine. Keeper phase changes are governed by the Keeper registry. *)

val release_retired : keeper_name:string -> by:string -> (unit, string) result
(** Lets go of the controller [keeper_name] holds when its Keeper is removed
    for good, and tells the board as {!before_move} would for a stopped
    Keeper. {!holder_left} cannot see this departure: with the meta gone, the
    Keeper's own credential has no expiry and reads like an agent that is
    coming back. [Ok ()] also when it holds nothing or no machine is loaded;
    [Error] names a machine that could not be read. *)

(** Why a call was stopped before it reached the machine. *)
type call_refusal =
  | Refused of string  (** the call cannot run as asked; the caller can fix it *)
  | Seats_unknown of string  (** who sits at the machine could not be read *)

val before_call :
  config:Workspace.config -> who:string -> name:string -> args:Yojson.Safe.t ->
  (unit, call_refusal) result
(** What every caller of a misc tool runs first (a Keeper's turn, the play
    page's DOS routes, an MCP client). A call that moves the machine lets a
    departed holder go ({!before_move}). Where every request must carry a
    credential, a pass goes only to a name in [Play_seat.hand_to] and any
    other target is an [Error]; nothing has happened then. Where a name may be
    self-declared there is no list, and a pass goes through as before. Other
    calls pass through. *)

val refusal_result : tool_name:string -> call_refusal -> Tool_result.result
(** The tool answer for a refusal: a [Workflow_rejection] for [Refused], a
    [Runtime_failure] for [Seats_unknown]. *)
