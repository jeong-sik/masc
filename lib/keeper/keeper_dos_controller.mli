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
    [Participant_departed]: the current credential generation explicitly left
    through the play-session endpoint. Its bearer stays valid for reconnect.
    [No_credential]: a name
    that is not a Keeper and has no credential file, only where every request
    must carry a credential (auth enabled, [require_token]). A credential file
    that cannot be read, and a missing one where a request needs no token,
    keep the controller. [transaction] must be the current admission for
    [config]'s workspace; keep it through the resulting controller effect. *)

type participation_error = Credential_changed | Participation_unavailable of string
val set_participation : config:Workspace.config -> who:string -> token:string ->
  Play_participation.t -> (unit, participation_error) result
(** Revalidate the exact current credential and expiry under Auth admission.
    Departure persists ineligibility and releases this holder while retaining
    the same admission used by incoming handoffs. Reconnection restores
    eligibility without taking control. Board publication occurs after release
    of Auth. The bearer remains valid for explicit reconnect. *)

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

val with_move_admission :
  config:Workspace.config -> who:string -> run:(unit -> 'a) ->
  ('a, call_refusal) result
(** Admit [who] and hold the credential transaction through [run]. This is the
    atomic boundary for a DOS operation that can acquire the shared
    controller: a concurrent play-session departure either waits until the
    operation completes or is committed first and prevents the operation. *)

val execute :
  config:Workspace.config -> who:string -> name:string -> args:Yojson.Safe.t ->
  run:(?dos_admission:((unit -> Tool_result.result) -> Tool_result.result) ->
    unit -> Tool_result.result option) ->
  (Tool_result.result option, call_refusal) result
(** Execute an already authorized misc tool request. Handoff target discovery,
    departed-holder recovery and the actual DOS pass share one Auth admission,
    excluding credential publication and revocation until the effect completes.
    Handoff uses the same DOS implementation as the misc dispatcher; its Board
    announcements are flushed after Auth release. For a controller-taking
    operation, [run] is invoked while credential admission remains held through
    the DOS lane effect. Load and restore instead receive [dos_admission],
    which the dispatcher must apply only to the prepared lane commit; their
    inventory and checkpoint preparation run outside the credential transaction. [None] means no dispatcher handled that other tool.
    The HTTP body must already have been read.
    This does not authenticate [who] or cancel requests authorized earlier. *)

val refusal_result : tool_name:string -> call_refusal -> Tool_result.result
(** The tool answer for a refusal: a [Workflow_rejection] for [Refused], a
    [Runtime_failure] for [Seats_unknown]. *)
