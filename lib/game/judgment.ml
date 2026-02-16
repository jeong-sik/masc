(** Judgment Engine - Pure LLM-driven logic for MASC Game Engine *)

(** LLM에게 전달할 순수 데이터 팩 *)
type judgment_request = {
  agent_id: string;
  intent: string;      (* "철창문을 뜯어내고 싶어" *)
  world_state: string; (* "어두운 지하 감옥" *)
  skill_sheet: string; (* JSON string of agent's abilities *)
  suggested_roll: int; (* 공정성을 위한 엔진의 난수 *)
}

type t = {
  success: bool;
  ability_used: string; (* LLM이 선택한 능력치 (예: "STR") *)
  difficulty_set: string; (* LLM이 설정한 난이도 *)
  narrative_result: string;
  impact_score: int;
}

let roll_dice sides = 1 + Random.int sides

(** 판단을 위한 최소한의 데이터만 묶어줌 *)
let request_judgment ~agent_id ~intent ~world_state ~skill_sheet =
  {
    agent_id;
    intent;
    world_state;
    skill_sheet;
    suggested_roll = roll_dice 20;
  }
