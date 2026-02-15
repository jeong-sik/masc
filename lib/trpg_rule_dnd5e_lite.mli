type roll_tier =
  | Critical_fail
  | Fail
  | Partial
  | Success
  | Great
  | Miracle

type roll_classification = {
  tier : roll_tier;
  label : string;
  passed : bool;
}

val stat_bonus : int -> int
val classify_roll : raw_d20:int -> total:int -> roll_classification
val roll_tier_to_string : roll_tier -> string

include Trpg_rule.S
