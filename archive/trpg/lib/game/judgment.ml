
(** Judgment Engine - Rule-based decision logic for MASC Game Engine *)

type ability = STR | DEX | CON | INT | WIS | CHA | LUK

type judgment_result = {
  success: bool;
  roll: int;
  modifier: int;
  threshold: int;
  message: string;
}

let roll_dice sides = 1 + Random.int sides

(** 능력치 보정치 계산 (D&D 스타일: (score - 10) / 2) *)
let get_modifier score = (score - 10) / 2

(** 판정 로직: d20 + modifier >= threshold *)
let judge ~ability_score ~threshold ~action_desc =
  Random.self_init ();
  let roll = roll_dice 20 in
  let modifier = get_modifier ability_score in
  let total = roll + modifier in
  let success = total >= threshold in
  {
    success;
    roll;
    modifier;
    threshold;
    message = Printf.sprintf "%s: %s (Roll: %d + Mod: %d = %d vs Threshold: %d)"
      action_desc (if success then "SUCCESS" else "FAILURE") roll modifier total threshold
  }
