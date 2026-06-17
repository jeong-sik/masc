(* Fusion — 패널+심판 gate의 타입드 계약 (구현).
   계약/문서: fusion_types.mli, docs/rfc/RFC-0255-fusion-panel-judge-deliberation.md *)

type usage =
  { input_tokens : int
  ; output_tokens : int
  }
[@@deriving yojson, show, eq]

let zero_usage = { input_tokens = 0; output_tokens = 0 }

let add_usage a b =
  { input_tokens = a.input_tokens + b.input_tokens
  ; output_tokens = a.output_tokens + b.output_tokens
  }

module Fusion_depth = struct
  type t =
    | Top
    | Nested
  [@@deriving yojson, show, eq]
end

type panel_failure =
  | Timeout
  | Provider_error of string
  | Empty_response
[@@deriving yojson, show, eq]

type panel_answer =
  { model : string
  ; answer : string
  ; confidence : float option
  ; usage : usage
  }
[@@deriving yojson, show, eq]

type panel_error =
  { failed_model : string
  ; reason : panel_failure
  }
[@@deriving yojson, show, eq]

type panel_outcome =
  | Answered of panel_answer
  | Failed of panel_error
[@@deriving yojson, show, eq]

let answered_of outcomes =
  List.filter_map
    (function Answered a -> Some a | Failed _ -> None)
    outcomes

type claim =
  { text : string
  ; supporting_models : string list
  }
[@@deriving yojson, show, eq]

type contradiction =
  { topic : string
  ; positions : (string * string) list
  ; evidence : string list
  }
[@@deriving yojson, show, eq]

type coverage_gap =
  { gap_topic : string
  ; addressed_by : string list
  ; missing : string option  (** 무엇이 빠졌는지. 미상이면 None (""로 압축하지 않음). *)
  }
[@@deriving yojson, show, eq]

type insight =
  { insight_text : string
  ; from_model : string
  }
[@@deriving yojson, show, eq]

type recommendation =
  { action : string
  ; rationale : string
  }
[@@deriving yojson, show, eq]

type insufficiency = { missing_for_decision : string list }
[@@deriving yojson, show, eq]

type judge_decision =
  | Answer of string
  | Recommend of recommendation
  | Insufficient of insufficiency
[@@deriving yojson, show, eq]

type judge_synthesis =
  { consensus : claim list
  ; contradictions : contradiction list
  ; partial_coverage : coverage_gap list
  ; unique_insights : insight list
  ; blind_spots : string list
  ; resolved_answer : string
  ; decision : judge_decision
  ; dropped_malformed : int
      (** 파서가 걸러낸 비정상 하위요소 개수. 0이면 LLM 출력이 스키마를 완전히 준수한 것. *)
  }
[@@deriving yojson, show, eq]

type judge_error =
  | Judge_build_failed of panel_failure
  | Judge_run_failed of string
  | Judge_empty
  | Judge_provider_error of string
  | Judge_parse_failed of string
[@@deriving yojson, show, eq]

type low_confidence =
  { score : float
  ; threshold : float
  }
[@@deriving yojson, show, eq]

type fusion_trigger =
  | Explicit_tool_call
  | Low_confidence of low_confidence
  | High_stakes of string
  | Contested_board of string
  | Operator_requested
  | Harness_eval
[@@deriving yojson, show, eq]

let trigger_label = function
  | Explicit_tool_call -> "explicit_tool_call"
  | Low_confidence _ -> "low_confidence"
  | High_stakes _ -> "high_stakes"
  | Contested_board _ -> "contested_board"
  | Operator_requested -> "operator_requested"
  | Harness_eval -> "harness_eval"

type fusion_request =
  { run_id : string
  ; keeper : string
  ; prompt : string
  ; preset : string
  ; depth : Fusion_depth.t
  ; trigger : fusion_trigger
  }
[@@deriving yojson, show, eq]

type deny_reason =
  | Disabled
  | Preset_unknown of string
  | Depth_exceeded
  | Over_hourly_budget
  | Not_warranted
[@@deriving yojson, show, eq]

let deny_reason_label = function
  | Disabled -> "disabled"
  | Preset_unknown _ -> "preset_unknown"
  | Depth_exceeded -> "depth_exceeded"
  | Over_hourly_budget -> "over_hourly_budget"
  | Not_warranted -> "not_warranted"

type gate_decision =
  | Allow of fusion_request
  | Deny of deny_reason
[@@deriving yojson, show, eq]
