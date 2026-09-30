(** [candle.toml] (RFC-goal-candle-ledger 3.9): is the Candle reward currency
    on?

    The answer is read from the file on every call. There is no default value
    and no cache: a file that cannot be read, is not TOML, or holds a key this
    build does not know turns Candle off with a reason, and the server carries
    on. An operator adds keys only after the build that reads them is
    deployed, because an older build refuses the key it does not know. *)

type payout_policy = private {
  trivial_milli : int; small_milli : int; medium_milli : int;
  large_milli : int; epic_milli : int;
  weight_max : int; deduction_rate : int; deduction_floor : int;
}

val grade_amount_milli : payout_policy -> Candle_grade.t -> int

type policy = private
  { payout : payout_policy
  ; prices : (Keeper_portrait_item.t * int) list
  }

type price = Unpriced | Priced of int
val price : policy -> Keeper_portrait_item.t -> price
(** The explicit current milli-Candle price. A missing entry is [Unpriced],
    including when [shop] or its [prices_milli] table is absent. *)

type t =
  | Off  (** There is no [candle.toml]. Nothing is recorded, paid or sold. *)
  | Enabled of policy
  | Disabled of { reason : string }
      (** The file is there and does not read. Nothing is recorded, paid or
          sold, and the reason is for the operator to see. *)

val of_toml_string : string -> t
(** All payout fields and all five grade amounts are required. The optional
    [shop.prices_milli] table accepts only canonical catalog ids and
    nonnegative integers. No default prices or payout values. *)

val load_file : path:string -> t
(** [Off] when [path] does not exist. Anything else that stops it from being
    examined or read as a file is [Disabled]: a directory in its place, a
    symlink that loops, a directory that cannot be searched. *)

val load : base_path:string -> t
(** {!load_file} on {!Config_dir_resolver.candle_toml_path_for_base_path}. *)

val to_string : t -> string
(** A short line for a log or the operator's screen. *)
