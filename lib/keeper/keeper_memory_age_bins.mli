(** Memory fact age ladder based on first_seen timestamps (RFC-0515 §2.4.5,
    E17, E28).

    The server counts a Keeper's ordinary facts into {!bin_count} bins by the
    time since each fact was first seen. Bin 0 is under an hour. Each of the
    four {!edge}s (1h, 1d, 7d, 30d) starts a bin exactly. Between two edges
    the bins start on equal steps of a log axis: 8 bins from an hour to a
    day, 8 from a day to seven days, 6 from seven days to 30 days. The last
    bin is 30 days or older.

    The edges are declared here once. The screens read their ticks, colours
    and words from {!edge_span} and {!edge_bin}, never from numbers of their
    own.

    A first_seen ahead of [now] has age 0. Pure: no clock of its own. *)

val bin_count : int
(** 24. *)

type bin
(** One of the {!bin_count} bins. *)

val bins : bin list
(** Every bin once, the newest (under an hour) first. *)

val index : bin -> int
(** The bin's place in {!bins} and in the wire array: 0 for under an hour,
    23 for 30 days or older. *)

(** {1 The exact edges} *)

type edge =
  | Hour
  | Day
  | Week
  | Month

val edges : edge list
(** The four edges, the youngest (one hour) first. *)

(** An age in the unit a person reads it in. *)
type span =
  | Hours of int
  | Days of int

val edge_span : edge -> span
(** One hour, one day, seven days, 30 days. *)

val edge_bin : edge -> bin
(** The bin the edge starts: bins 1, 9, 17 and 23. An age exactly on the
    edge is in this bin, one second younger in the bin before it. *)

(** {1 Counts} *)

type t
(** {!bin_count} counts, none below zero. *)

val zero : t

val classify : now:float -> float -> bin

val of_first_seen : now:float -> float list -> t

val count : t -> bin -> int

val total : t -> int

val add : t -> t -> t

val to_json : t -> Yojson.Safe.t
(** A JSON array of the {!bin_count} counts, bin 0 first. *)

val of_json : Yojson.Safe.t -> (t, string) result
(** Takes exactly an array of {!bin_count} non-negative integers. Anything
    else, an object included, is an [Error]. *)
