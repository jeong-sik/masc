(** Pure immutable state for sticky runtime-lane preferences. *)

type t

type preference =
  { candidate : string
  ; noted_at : float
  }

type observation =
  | No_preference
  | Expired_preference
  | Active_preference of preference
(** The result of resolving one lane at one supplied instant. Expiry is kept
    distinct from absence so the transition and its pruning are testable. *)

val empty : t

val remember :
  lane_id:string -> candidate:string -> noted_at:float -> t -> t
(** Remember the latest success by event time. A delayed commit carrying an
    older [noted_at] cannot overwrite a newer success for the same lane. *)

val observe :
  now:float -> ttl_s:float -> lane_id:string -> t -> t * observation
(** Resolve and, when necessary, prune the preference for [lane_id]. Time and
    TTL policy are values supplied by the outer runtime shell. A non-positive
    [ttl_s] always expires the entry, including when [noted_at] is newer than
    [now] because the two effects raced before commit. *)

val reorder : observation -> string list -> string list
(** Move an active preferred candidate to the head while retaining the
    declared relative order of all other candidates. *)

val preferred : observation -> (string * float) option
(** Project the public diagnostics view. Both absence and an expiry observed
    by this call intentionally become [None] at that boundary. *)
