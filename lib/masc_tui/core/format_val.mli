(** Typed compact numeric and observation formatting.

    Strictly separates present numeric values from [Unreported], [Absent],
    [Loading], and [Failed] — and explicitly distinguishes subscription zero
    (["$0 Sub"]) from exhausted credits (["$0 Exhausted"]) and unreported
    accounts (["? Unreported"]). *)

type unit_kind =
  | Count
  | Rate_per_sec
  | Percent
  | Milliseconds
  | Bytes
  | Tokens
  | Usd
  | Candles

type cost_state =
  | Amount of float
  | Subscription_zero
  | Exhausted_zero
  | Unreported

val format_value : unit_kind -> float -> string
(** Format a finite value compactly for the given unit (e.g. ["38.7k"],
    ["1.4k/s"], ["95.7%"], ["14.2ms"], ["3.9 GiB"], ["18.8B tok"], ["$40.95"],
    ["12.400 C"]). Non-finite floats format as ["?"]. *)

val format_observed : unit_kind -> float Observed.t -> lang:Say.lang -> string
(** Format an observed float without ever collapsing [Unreported], [Absent],
    [Loading], or [Failed] into ["0"]. *)

val format_cost : cost_state -> lang:Say.lang -> string
(** Format cost/credit state with explicit ["$0 Sub"] / ["$0 Exhausted"] /
    ["? Unreported"] spelling. *)

val format_delta_pct : float -> string
(** Format a percentage delta with width-1 geometric arrow (e.g. ["▲+1.2%"],
    ["▼-3.4%"], ["─0.0%"]). *)

val format_duration_s : float -> string
(** Compact human duration (e.g. ["42s"], ["1h58m"], ["3d4h"]). *)

val format_age_short : now_unix:float -> float -> string
(** Compact relative age from [ts_unix] to [now_unix]: ["now"] under 5s,
    otherwise {!format_duration_s}, or {!Glyph.Missing_absent} when invalid. *)

val format_hhmm_opt : ?tz_offset_sec:int -> float -> string option
(** Format Unix seconds as ["HH:MM"] in the given UTC offset (default [0]),
    returning [None] for non-finite or non-positive timestamps. *)
