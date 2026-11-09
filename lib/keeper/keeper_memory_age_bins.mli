(** Memory fact age ladder based on first_seen timestamps (RFC-0515 §2.4.5,
    E17).

    The server counts a Keeper's ordinary facts into {!bin_count} bins by the
    time since each fact was first seen. Bin 0 is under an hour. Bins 1 – 22
    split one hour to 30 days into equal steps on a log axis, and bin 23 is
    30 days or older: bin [k] (1 ≤ k ≤ 23) starts at
    [1h × 720 ^ ((k − 1) ÷ 22)]. This is the mock's [ladderBins] with n = 24,
    [r = ln 720 ÷ 22].

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

val lower_edge : bin -> float
(** The youngest age, in seconds, the bin counts: 0 for bin 0, one hour for
    bin 1, 30 days for bin 23. {!classify} puts an age exactly on an edge in
    the bin the edge starts. *)

val nearest_edge : float -> bin
(** The bin whose lower edge lies nearest [age] seconds on the log axis,
    [round (ln (age ÷ 1h) ÷ r) + 1] held to bins 1 – 23: the mock's
    [ladderTicks]. An age of one hour or less is bin 1. *)

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
