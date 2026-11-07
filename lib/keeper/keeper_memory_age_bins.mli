(** Memory fact age ladder bins based on first_seen timestamps (RFC-0511 §2.6 W1).

    Categorizes facts by age since first seen into four discrete bins:
    - [Under_hour]: age < 1 hour
    - [Under_day]: 1 hour <= age < 24 hours
    - [Under_week]: 24 hours <= age < 7 days
    - [Older]: age >= 7 days

    Future timestamps are treated as age 0 ([Under_hour]). *)

type bin =
  | Under_hour
  | Under_day
  | Under_week
  | Older

type t =
  { under_hour : int
  ; under_day : int
  ; under_week : int
  ; older : int
  }

val zero : t

val classify : now:float -> float -> bin

val of_first_seen : now:float -> float list -> t

val total : t -> int

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
