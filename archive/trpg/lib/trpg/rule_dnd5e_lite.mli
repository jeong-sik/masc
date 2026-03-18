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
val roll_with_modifier : raw_d20:int -> stat:int -> modifier:int -> roll_classification
val roll_with_advantage : d20_1:int -> d20_2:int -> stat:int -> modifier:int -> roll_classification
val roll_with_disadvantage : d20_1:int -> d20_2:int -> stat:int -> modifier:int -> roll_classification
val damage_multiplier_of_tier : roll_tier -> float
val defense_mitigation_of_tier : roll_tier -> float

include Rule.S
