(** A resolved deadline opened at one instant, which every stage of one call
    spends from.

    A call that measures its request before sending it has two stages under
    one caller budget: the count-tokens round trip and the completion or
    stream after it. Opening the window once and handing the same window to
    both stages gives them one [deadline_at]; each stage that re-read the
    clock and added the budget again would close its own window a little
    later than the caller's.

    Only {!open_} makes a window, so [deadline_at] is always the instant it
    was opened plus [timeout_s]. *)

type 'clock t = private
  | Unbounded
  | Bounded of
      { clock : 'clock
      ; timeout_s : float  (** the budget as declared, for messages *)
      ; deadline_at : float  (** on [clock] *)
      }

(** Opens the window now on the deadline's clock. *)
val open_ : (_ Eio.Time.clock as 'clock) Http_client.explicit_deadline -> 'clock t

(** What the window has left now, in seconds. A window with nothing left is
    [`Spent], so no stage is handed a bound that is not greater than zero;
    [`Spent] carries the budget as declared, and the caller names the phase
    it ends as. *)
val remaining
  :  _ Eio.Time.clock t
  -> [ `Unbounded | `Remaining of float | `Spent of float ]
