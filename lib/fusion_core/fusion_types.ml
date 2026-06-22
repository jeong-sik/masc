(* Fusion — 패널+심판 심의 루프의 타입드 계약 (구현).
   계약/문서: fusion_types.mli, docs/rfc/RFC-0252-fusion-panel-judge-deliberation.md *)

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
  }
[@@deriving yojson, show, eq]

type fusion_trigger =
  | Explicit_tool_call
  | Low_confidence
  | High_stakes of string
  | Contested_board of string
  | Operator_requested
  | Harness_eval
[@@deriving yojson, show, eq]

let trigger_label = function
  | Explicit_tool_call -> "explicit_tool_call"
  | Low_confidence -> "low_confidence"
  | High_stakes _ -> "high_stakes"
  | Contested_board _ -> "contested_board"
  | Operator_requested -> "operator_requested"
  | Harness_eval -> "harness_eval"

type fusion_request =
  { run_id : string
  ; keeper : string
  ; prompt : string
  ; preset : string
  ; web_tools : bool
  ; depth : Fusion_depth.t
  ; trigger : fusion_trigger
  }
[@@deriving yojson, show, eq]

type deny_reason =
  | Disabled
  | Preset_unknown of string
  | Depth_exceeded
[@@deriving yojson, show, eq]

let deny_reason_label = function
  | Disabled -> "disabled"
  | Preset_unknown _ -> "preset_unknown"
  | Depth_exceeded -> "depth_exceeded"

type gate_decision =
  | Allow of fusion_request
  | Deny of deny_reason
[@@deriving yojson, show, eq]

(* 심의 위상(topology) — 패널 답을 어떤 합성 구조로 reduce할지. 닫힌 합:
   keeper는 masc_fusion 도구에서 이름으로 고르고, 게이트는 보지 않으며, 오케스트레이터가
   이 변형으로 dispatch한다. 그래프 datatype이 아니라 named composition의 닫힌 집합
   (RFC-0252 §13 P2 확장; "Fusion as a Tool"의 합성-by-selection). 새 위상은 여기 추가하면
   orchestrator dispatch가 exhaustive-match 컴파일 에러로 누락을 강제한다. *)
type fusion_topology =
  | Simple  (** panel → judge → sink (현행, byte-identical) *)
  | Refine  (** panel → judge → judge'(1차 종합을 재검토) → sink *)
[@@deriving yojson, show, eq]

let fusion_topology_to_string = function
  | Simple -> "simple"
  | Refine -> "refine"

(* [to_string]의 역함수, 닫힌 합 밖은 [None]=fail-closed (Unknown→permissive 회피).
   keeper 입력 문자열을 typed 위상으로 parse한 뒤 exhaustive match하게 한다. round-trip은
   [test/fusion_core/test_fusion.ml :: fusion_topology_roundtrip]가 핀. *)
let fusion_topology_of_string = function
  | "simple" -> Some Simple
  | "refine" -> Some Refine
  | _ -> None

let all_fusion_topologies : fusion_topology list = [ Simple; Refine ]

let all_fusion_topology_strings : string list =
  List.map fusion_topology_to_string all_fusion_topologies

(* 1차 심판 종합을 refine 심판 프롬프트에 실어 보낼 lossless 텍스트 렌더. judge_synthesis의
   7필드 + 닫힌 합 decision을 모두 보존한다(CLAUDE.md 워크어라운드 #2 "두 개념을 한 string
   채널에 압축" 회피 — resolved_answer 한 줄로 collapse하지 않는다). 빈 리스트는 "(none)"으로
   렌더해 구조를 항상 노출(테스트 가능). decision은 닫힌 합 exhaustive match라 새 변형 추가 시
   컴파일 에러로 갱신을 강제한다. 순수 — 테스트 가능. *)
let render_prior_synthesis (s : judge_synthesis) : string =
  let bullets to_line = function
    | [] -> "(none)"
    | xs -> String.concat "\n" (List.map (fun x -> "- " ^ to_line x) xs)
  in
  let consensus =
    bullets
      (fun (c : claim) ->
        Printf.sprintf "%s (supported by: %s)" c.text
          (String.concat ", " c.supporting_models))
      s.consensus
  in
  let contradictions =
    bullets
      (fun (c : contradiction) ->
        let positions =
          c.positions
          |> List.map (fun (model, stance) ->
                 Printf.sprintf "%s says \"%s\"" model stance)
          |> String.concat "; "
        in
        Printf.sprintf "%s: %s [evidence: %s]" c.topic positions
          (String.concat "; " c.evidence))
      s.contradictions
  in
  let partial_coverage =
    bullets
      (fun (g : coverage_gap) ->
        Printf.sprintf "%s (addressed by: %s; missing: %s)" g.gap_topic
          (String.concat ", " g.addressed_by)
          (match g.missing with Some m -> m | None -> "unspecified"))
      s.partial_coverage
  in
  let unique_insights =
    bullets
      (fun (i : insight) ->
        Printf.sprintf "%s (from: %s)" i.insight_text i.from_model)
      s.unique_insights
  in
  let blind_spots = bullets (fun (b : string) -> b) s.blind_spots in
  let decision =
    match s.decision with
    | Answer text -> Printf.sprintf "Answer: %s" text
    | Recommend r -> Printf.sprintf "Recommend action \"%s\" — %s" r.action r.rationale
    | Insufficient i ->
      Printf.sprintf "Insufficient — missing: %s"
        (String.concat "; " i.missing_for_decision)
  in
  Printf.sprintf
    {|CONSENSUS:
%s
CONTRADICTIONS:
%s
PARTIAL COVERAGE:
%s
UNIQUE INSIGHTS:
%s
BLIND SPOTS:
%s
RESOLVED ANSWER:
%s
DECISION: %s|}
    consensus contradictions partial_coverage unique_insights blind_spots
    s.resolved_answer decision
