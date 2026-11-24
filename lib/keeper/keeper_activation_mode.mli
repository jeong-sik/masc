(** Who starts a keeper, and whether it takes turns of its own.

    - [Manual]: the server never starts it. It is down until an operator
      starts it, and while it is down nothing runs: a person's chat message
      is refused as [keeper_not_started] and other queued work waits.
    - [On_demand]: the server starts it at boot. It takes no turn of its own:
      a turn opens when a chat message, a mention, a board event, a due
      schedule or another queued event arrives.
    - [Autonomous]: the server starts it at boot, and it also takes turns of
      its own.

    Once a keeper is up, requested work is eligible in every mode, subject to
    lifecycle pause and shutdown ownership. *)
type t = Manual | On_demand | Autonomous
val default : t
val restore_owner : t -> bool
val spontaneous : t -> bool
val to_string : t -> string
val of_string : string -> t option

val all : t list
(** Every mode, in declaration order. A caller that names the accepted
    values (an editor refusal, say) derives them from here with [to_string],
    so the list cannot drift from [of_string]. *)
val to_yojson : t -> Yojson.Safe.t
