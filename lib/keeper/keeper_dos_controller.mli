(** Frees the DOS controller of a holder who can no longer move, before a
    call that needs the controller. *)

val holder_left : config:Workspace.config -> now:float -> string -> Tool_misc_dos_lane.holder_departure option
(** Why [holder] can no longer act, or [None] while it still can.
    [Keeper_stopped]: a Keeper that is paused or stopped, including one whose
    stop finished and left the registry but kept its meta. [Player_expired]:
    a name whose Player credential ran out before [now], by the rule its
    bearer is checked by ({!Play_invite.expired}). [No_credential]: a name
    that is not a Keeper and has no credential file, only where every request
    must carry a credential (auth enabled, [require_token]). A credential file
    that cannot be read, and a missing one where a request needs no token,
    keep the controller. *)

val before_move :
  config:Workspace.config -> who:string -> (unit, Masc_domain.masc_error) result
(** Lets a departed holder's controller go so that [who] can take it, and
    posts the board announcement after releasing the credential transaction.
    Credential publication and the departure read/release cannot interleave.
    A failed credential-lock admission returns [Error] without releasing or
    moving the machine. Keeper phase changes are governed by the Keeper registry. *)

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
