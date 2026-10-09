(** Workspace policy independent of emulator implementation. *)
val holder_left :
  transaction:Auth.credential_transaction -> config:Workspace.config ->
  now:float -> string -> Machine_controller_contract.holder_departure option
(** [None] retains the holder, including when its status cannot be established.
    Hold [transaction] through the resulting controller effect. *)

type call_refusal =
  | Refused of string
  | Seats_unknown of string

val pass_refusal :
  transaction:Auth.credential_transaction -> config:Workspace.config ->
  target:(string option, string) result -> call_refusal option
(** Check the parsed handoff target while credential publication is excluded.
    [Ok None] is a release with no recipient. [None] permits the handoff;
    it does not authenticate the caller or mutate the machine. *)
