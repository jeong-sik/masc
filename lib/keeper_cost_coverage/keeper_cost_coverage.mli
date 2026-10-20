(** Reported cost and the evidence covering its sum. This is observation only;
    no value here authorizes or limits a Keeper turn. Callers supply each
    resolved spend reading once, after the existing usage resolver has handled
    repeated conversation counters. *)
type observation =
  | Priced of float
  | Price_not_reported
  | Usage_unresolved
  | Attempt_unobserved
      (** A started attempt with no spend reading. It is not proof of free
          invocation. No started attempt contributes no observation at all. *)

type history = Complete | Unobserved

type t = private
  { known_cost_usd : float
  ; priced_readings : int
  ; unpriced_readings : int
  ; unresolved_readings : int
  ; unobserved_attempts : int
  ; history : history
  }

type knowledge =
  | No_observations
  | Fully_priced
  | No_reported_prices
  | Partly_priced
  | Unresolved
      (** Coverage is not established: unresolved usage, unobserved attempts,
          or an unobserved historical baseline. Read the counts for detail. *)

type error =
  | Invalid_cost
  | Cost_overflow
  | Count_overflow
  | Evidence_regressed
  | History_rewritten

val empty : t
val unobserved_history : known_cost_usd:float -> (t, error) result
(** Explicitly retain a reported sum whose historical pricing coverage is
    unavailable. This does not infer coverage from that amount, even at zero,
    and does not read, migrate or reset persisted metadata. *)
val observe : t -> observation -> (t, error) result
val add : t -> t -> (t, error) result
val difference : before:t -> after:t -> (t, error) result
(** The additive change between snapshots, suitable for applying to a newer
    owner snapshot. Reject regressed amounts/counts and erased unknown history.
    This is not an event deduplicator or a replacement for owner identity/CAS. *)
val knowledge : t -> knowledge
