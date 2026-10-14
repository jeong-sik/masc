(** [candle.toml] (RFC-goal-candle-ledger 3.9): is the Candle reward currency
    on?

    The answer is read from the file on every call. There is no default value
    and no cache: a file that cannot be read, is not TOML, or holds a key this
    build does not know turns Candle off with a reason, and the server carries
    on. An operator adds keys only after the build that reads them is
    deployed, because an older build refuses the key it does not know. *)

type payout_policy = private {
  grades : (Candle_grade.t * int * string) list;
  distribution : Candle_math.distribution;
  weight_max : int; deduction_rate : int; deduction_floor : int;
}

val grade_amount_milli : payout_policy -> Candle_grade.t -> int option

type pricing_policy =
  | Fixed
  | Supply_scaled of
      { target_per_keeper_milli : int
      ; min_permille : int
      ; max_permille : int
      ; rounding : Candle_math.rounding
      }

type policy = private
  { payout : payout_policy
  ; prices : (Keeper_portrait_item.t * int) list
  ; pricing : pricing_policy
  ; half_life : Candle_decay.half_life
  }

val pricing : policy -> pricing_policy

val max_permille_limit : int
(** Upper bound ([10_000], i.e. 10x base price) accepted for [max_permille] in
    [shop.pricing]. *)

val min_active_balance_milli : pricing_policy -> int
(** Minimum positive wallet balance (in milli-Candles) for a keeper to count
    toward [active_keepers] under [pricing_policy]: [1] under [Fixed], and
    [max 1 (target_per_keeper_milli / 10)] under [Supply_scaled]. *)

type price = Unpriced | Priced of int
val price : policy -> Keeper_portrait_item.t -> price
(** The explicit configured base milli-Candle price. A missing entry is
    [Unpriced], including when the optional [shop] table is absent. *)

val scale_price
  :  pricing:pricing_policy
  -> total_supply_milli:Z.t
  -> active_keepers:int
  -> base_price_milli:int
  -> int
(** Exact Zarith supply-scaled price calculation. Under [Fixed] or when
    [active_keepers <= 0], returns [base_price_milli]. Under [Supply_scaled],
    scales [base_price_milli] by the clamped permille ratio of
    [total_supply_milli] to [active_keepers * target_per_keeper_milli]. An
    explicit zero base price stays zero; a positive base price scales to at
    least [1] milli-Candle. *)

val effective_price
  :  policy
  -> total_supply_milli:Z.t
  -> active_keepers:int
  -> Keeper_portrait_item.t
  -> price
(** Effective milli-Candle price for [item] under [policy.pricing] at the given
    circulating supply and active keeper count. *)

type t =
  | Off  (** There is no [candle.toml]. Nothing is recorded, paid or sold. *)
  | Enabled of policy
  | Disabled of { reason : string }
      (** The file is there and does not read. Nothing is recorded, paid or
          sold, and the reason is for the operator to see. *)

val of_toml_string : string -> t
(** [half_life] must be explicitly ["off"] or a positive integer number of
    hours. Missing, unknown or malformed values disable Candle; no default.
    All payout fields, a nonempty grade amount table, matching nonblank grade
    criteria and explicit distribution policies are required. The optional
    [shop.prices_milli] table accepts only canonical catalog ids and
    nonnegative integers. Grade amounts accept [0..max_int], independent of
    the weight range: payout intermediates are exact, while each allocation
    remains bounded by its configured total. Cumulative wallet overflow is
    checked at settlement. No default prices or payout values. *)

val load_file : path:string -> t
(** [Off] when [path] does not exist. Anything else that stops it from being
    examined or read as a file is [Disabled]: a directory in its place, a
    symlink that loops, a directory that cannot be searched. *)

val load : base_path:string -> t
(** {!load_file} on {!Config_dir_resolver.candle_toml_path_for_base_path}. *)

val to_string : t -> string
(** A short line for a log or the operator's screen. *)
