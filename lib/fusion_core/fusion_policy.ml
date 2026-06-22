(* Fusion — 결정론적 발동 게이트 (구현).
   계약/문서: fusion_policy.mli, docs/rfc/RFC-0252 §6 *)

(* 한 패널 그룹 — 공통 system_prompt/web_tools/max_tool_calls/timeout으로 실행되는
   모델 묶음. 한 preset이 이종(heterogeneous) 그룹 여럿을 가질 수 있다(RFC-0252-A).
   닫힌 record (option-dual 없음); preset이 [panel_group list]를 deriving하므로
   nested deriving 필수. *)
type panel_group =
  { models : string list  (** provider.model ids *)
  ; label : string
      (** 패널 정체성 라벨 (RFC-0278). 같은 model을 다른 system_prompt로 여러 그룹에
          둘 때(persona ensemble) 패널을 구분한다. ""(기본)이면 정체성=model 그대로
          → legacy/단일-occurrence는 byte-identical. 정체성 derive는 [panelist_id]. *)
  ; system_prompt : string  (** 그룹 패널 모델 system prompt (config 필수) *)
  ; web_tools : bool  (** 그룹에 web_search/web_fetch 주입 여부 *)
  ; max_tool_calls : int  (** 그룹 모델당 최대 tool 호출 수 (0=무제한) *)
  ; timeout_s : float  (** 그룹 패널 호출 구조적 타임아웃 (초) *)
  }
[@@deriving show, eq]

type preset =
  { name : string
  ; panels : panel_group list
  ; judge : string
  ; judge_system_prompt : string
  ; judge_timeout_s : float
  }
[@@deriving show, eq]

let min_panel = 1
let max_panel = 8

(* 패널/심판 호출 구조적 타임아웃 기본값 (preset이 명시 안 할 때). 운영 노브 —
   행동 휴리스틱이 아니므로 named SSOT 상수로 둔다 (Magic Number 회피). *)
let default_timeout_s = 300.0

(* 모든 그룹의 모델을 평탄화 — 그룹순 × 그룹내 모델순 보존 (패널 fan-out 순서와 동일). *)
let preset_models (p : preset) =
  List.concat_map (fun (g : panel_group) -> g.models) p.panels

(* 패널 전체(그룹 합) 모델 수가 1..8 범위인가. 1..8은 OpenRouter Fusion의 총 모델
   상한이므로 그룹별이 아니라 평탄화 총합에 건다. panels=[]는 명시적 실패
   (Unknown→Permissive 회피 — 빈 그룹 리스트를 통과시키지 않는다). *)
let preset_size_ok (p : preset) =
  let total = List.length (preset_models p) in
  p.panels <> [] && total >= min_panel && total <= max_panel

(* 패널 정체성 (RFC-0278). label이 비면 model 그대로(legacy byte-identity), 있으면
   "label (model)". 이 문자열이 패널의 유일 식별자다: agent 카드명(Async_agent.all
   반환 키) · 심판이 보는 패널 태그 · panel_answer.model 값. label은 model을 압축하지
   않고 포함하므로 정보 손실이 없다 — provider 라우팅은 group.models의 원 model로
   build 시점에 따로 수행된다. 포맷은 SSOT로 여기 한 곳에서만 정의한다. *)
let panelist_id ~label ~model =
  if String.equal label "" then model else Printf.sprintf "%s (%s)" label model

(* 모든 그룹의 패널 정체성을 평탄화 (그룹순 × 그룹내 모델순 = fan-out 순서). *)
let preset_panelist_ids (p : preset) =
  List.concat_map
    (fun (g : panel_group) ->
      List.map (fun model -> panelist_id ~label:g.label ~model) g.models)
    p.panels

(* 두 패널이 같은 정체성([panelist_id])을 가지면 그 id를 반환. Async_agent.all이
   카드명(=정체성)으로 결과 리스트를 만들고, 심판/synthesis가 정체성 문자열로 패널을
   지칭하므로 중복 정체성은 모호성(어느 패널인지 구분 불가)을 부른다. 이 한 invariant가
   세 경우를 모두 흡수한다: (a) 한 그룹 내 같은 model (label 동일 → 같은 id),
   (b) 라벨 없는 두 그룹의 같은 model (둘 다 id=model), (c) 같은 라벨+같은 model.
   서로 다른 라벨이면 같은 model이라도 정체성이 달라 통과(same-model-different-prompt).
   (RFC-0278: parse-time 거부.)

   dedup은 (label, model) 튜플이 아니라 *렌더된 정체성 문자열*에 건다. 이게 옳은 이유:
   심판/sink/dashboard가 보는 namespace가 정확히 이 정체성 문자열이기 때문이다. panelist_id
   포맷("%s (%s)")은 단사(injective)가 아니라서 label=""+model="x (y)"와 label="x"+model="y"가
   같은 "x (y)"로 렌더될 수 있는데, 이 둘은 정체성 namespace에서 *실제로* 충돌한다(심판이
   동일 <panel model="x (y)"> 태그 둘을 받아 구분 불가). 따라서 같은 문자열이면 거부하는 게
   sound하다 — fail-closed. 튜플로 dedup하면 둘 다 통과시켜 그 모호성을 silent하게 흘린다(더
   나쁨). 단, provider.model id가 " (...)"를 포함하는 경우에만 이 충돌이 닿으므로(실제 id는
   "provider.model" opaque 문자열) 현실 config에선 latent하다. *)
let preset_duplicate_panelist (p : preset) =
  let rec find_dup seen = function
    | [] -> None
    | id :: rest -> if List.mem id seen then Some id else find_dup (id :: seen) rest
  in
  find_dup [] (preset_panelist_ids p)

(* 모든 그룹의 패널 system prompt + 심판 system prompt가 비어있지 않은가. 프롬프트는
   행동을 정의하므로 코드 default로 채우지 않고 config에서 받는다 (없으면 fail-fast). *)
let preset_prompts_present (p : preset) =
  p.panels <> []
  && List.for_all
       (fun (g : panel_group) -> String.length (String.trim g.system_prompt) > 0)
       p.panels
  && String.length (String.trim p.judge_system_prompt) > 0

(* 심판 모델 id가 비어있지 않은가. judge는 종합을 수행하는 필수 모델이므로 빈
   문자열(config 누락 시 default)은 런타임에 빈 runtime_id로 agent 빌드를 깨뜨린다.
   load 단계에서 fail-fast (Unknown→Permissive 회피). *)
let preset_judge_present (p : preset) = String.length (String.trim p.judge) > 0

(* 외곽 run_safe 타임아웃 = 그룹 timeout 중 max. 하나의 Async_agent.all은 하나의
   외곽 타임아웃만 가지므로(RFC-0252-A §4.3), 그룹별 정밀 timeout은 build_agent에
   반영하고 외곽은 상한으로만 둔다. 단일 그룹(legacy desugar)이면 그 그룹 timeout =
   오늘의 panel_timeout_s (byte-identity). *)
let panel_outer_timeout_of (groups : panel_group list) =
  List.fold_left (fun acc (g : panel_group) -> Float.max acc g.timeout_s) 0.0 groups

(* 심판은 preset당 1개이므로 그룹들에서 web_tools를 derive한다: req 또는 어느 그룹이든
   web_tools면 심판도 web tool. 단일 그룹이면 req || group.web_tools = 오늘의
   req.web_tools || preset.web_tools (byte-identity). *)
let judge_web_tools_of ~req_web_tools (groups : panel_group list) =
  req_web_tools || List.exists (fun (g : panel_group) -> g.web_tools) groups

(* 심판 tool budget을 그룹들에서 derive. 0=무제한이 흡수자(어느 그룹이 무제한이면
   심판도 무제한), 그 외엔 그룹 max. 단일 그룹이면 그 값 = 오늘의
   max_tool_calls_per_panel (byte-identity). *)
let judge_tool_budget_of (groups : panel_group list) =
  if List.exists (fun (g : panel_group) -> g.max_tool_calls = 0) groups then 0
  else List.fold_left (fun acc (g : panel_group) -> max acc g.max_tool_calls) 0 groups

type t =
  { enabled : bool
  ; default_preset : string
  ; max_concurrent_panels : int
  ; presets : preset list
  }
[@@deriving show, eq]

let find_preset (policy : t) name =
  List.find_opt (fun (p : preset) -> String.equal p.name name) policy.presets

(* decide는 enabled/preset/depth의 구조적 판정만 담당한다 — "이 턴이 심의할 가치가
   있나"는 게이트가 score 비교나 문자열 매칭으로 판정하지 않고, 키퍼(이미 LLM)가
   판단해 masc_fusion을 호출하는 것으로 표현한다(RFC-0252 §6). 따라서 [req.trigger]는
   발동 이유 라벨일 뿐 적격성 판정에 쓰이지 않는다. *)
let decide ~(policy : t)
    (req : Fusion_types.fusion_request) : Fusion_types.gate_decision =
  if not policy.enabled then Fusion_types.Deny Fusion_types.Disabled
  else
    match find_preset policy req.preset with
    | None -> Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
    | Some preset when not (preset_size_ok preset) ->
      Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
    | Some _preset ->
      (match req.depth with
       | Fusion_types.Fusion_depth.Nested ->
         Fusion_types.Deny Fusion_types.Depth_exceeded
       | Fusion_types.Fusion_depth.Top -> Fusion_types.Allow req)
