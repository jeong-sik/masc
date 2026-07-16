(* Fusion — 결정론적 발동 게이트 (구현).
   계약/문서: fusion_policy.mli, docs/rfc/RFC-0252 §6 *)

(* 한 패널 그룹 — 공통 system_prompt/web_tools/timeout으로 실행되는
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
  ; max_output_tokens : int option  (** 그룹 모델당 출력 토큰 예산 override *)
  ; timeout_s : float  (** 그룹 패널 호출 구조적 타임아웃 (초) *)
  }
[@@deriving show, eq]

(* JOJ(judge-of-judges, RFC-0283)의 1차 심판 한 명. panel_group과 동형이되 model이
   복수가 아니라 단수다 (심판은 한 모델이 한 종합을 낸다). [label]로 같은 model을 다른
   lens(system_prompt)로 여러 1차 심판에 둘 수 있다 (judge_id로 정체성 derive). *)
type judge_spec =
  { jmodel : string  (** provider.model id *)
  ; jlabel : string  (** 정체성 라벨 ([panelist_id]와 동형). ""면 정체성=jmodel *)
  ; jsystem_prompt : string  (** 이 1차 심판의 lens (config 필수) *)
  ; jweb_tools : bool  (** web_search/web_fetch 주입 여부 *)
  ; jmax_output_tokens : int option  (** 출력 토큰 예산 override *)
  ; jtimeout_s : float  (** 호출 구조적 타임아웃 (초) *)
  }
[@@deriving show, eq]

type preset =
  { name : string
  ; panels : panel_group list
  ; judge : string
      (** simple/refine/conditional 심판이자 JOJ의 meta-judge(reducer). (RFC-0283) *)
  ; judge_system_prompt : string
  ; judge_timeout_s : float
  ; judge_max_output_tokens : int option
  ; meta_timeout_s : float
      (** meta/stage-meta/final-meta 호출 구조적 타임아웃 (초). *)
  ; judges : judge_spec list
      (** JOJ 1차 심판들 (RFC-0283). 기본 []; simple/refine/conditional은 무시한다.
          JOJ 위상은 런타임에 >= 2 를 요구한다. *)
  ; fallback_judge_model : string option
      (** 전원 타임아웃/예산 실패 시 단일 fallback 심판 모델. *)
  }
[@@deriving show, eq]

let min_staged_judge_group_size = 2
let default_staged_judge_group_size = 3

let valid_max_output_tokens = function
  | None -> true
  | Some n -> n > 0

(* 패널/심판 호출 구조적 타임아웃 기본값 (preset이 명시 안 할 때). 운영 노브 —
   행동 휴리스틱이 아니므로 named SSOT 상수로 둔다 (Magic Number 회피). *)
let default_timeout_s = 300.0

(* 모든 그룹의 모델을 평탄화 — 그룹순 × 그룹내 모델순 보존 (패널 fan-out 순서와 동일). *)
let preset_models (p : preset) =
  List.concat_map (fun (g : panel_group) -> g.models) p.panels

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

(* JOJ 1차 심판들의 정체성 (RFC-0283). 정체성 포맷은 [panelist_id]를 그대로 쓴다
   (label+model → 식별 문자열, SSOT 한 곳). 입력순 보존 = meta 프롬프트 attribution 순서. *)
let preset_judge_ids (p : preset) =
  List.map
    (fun (j : judge_spec) -> panelist_id ~label:j.jlabel ~model:j.jmodel)
    p.judges

(* 두 1차 심판이 같은 정체성([judge_id])을 가지면 그 id를 반환. meta 프롬프트가 정체성
   문자열로 각 종합을 attribute하므로 중복은 모호성(어느 1차 심판인지 구분 불가)을 부른다.
   [preset_duplicate_panelist]와 동형 — fail-closed. judges=[]면 항상 None. *)
let preset_duplicate_judge (p : preset) =
  let rec find_dup seen = function
    | [] -> None
    | id :: rest -> if List.mem id seen then Some id else find_dup (id :: seen) rest
  in
  find_dup [] (preset_judge_ids p)

(* 모든 1차 심판의 system prompt(lens)가 비어있지 않은가. 1차 심판의 lens는 행동을
   정의하므로 코드 default로 채우지 않는다. judges=[]면 vacuously true(simple/refine/
   conditional은 judges를 안 쓰므로 검증 무관). *)
let preset_judge_prompts_present (p : preset) =
  List.for_all
    (fun (j : judge_spec) -> String.length (String.trim j.jsystem_prompt) > 0)
    p.judges

type staged_judge_group_error =
  | Staged_group_size_below_min of int
  | Staged_too_few_judges of
      { group_size : int
      ; judges : int
      }
  | Staged_ragged_judges of
      { group_size : int
      ; judges : int
      }
[@@deriving show, eq]

let staged_judge_group_error_message = function
  | Staged_group_size_below_min group_size ->
    Printf.sprintf "staged_judge_group_size must be >= %d, got %d"
      min_staged_judge_group_size
      group_size
  | Staged_too_few_judges { group_size; judges } ->
    Printf.sprintf
      "staged_judge_of_judges requires at least two full groups: group_size=%d \
       requires >= %d judges, got %d"
      group_size
      (group_size * 2)
      judges
  | Staged_ragged_judges { group_size; judges } ->
    Printf.sprintf
      "staged_judge_of_judges requires judge count divisible by \
       staged_judge_group_size: group_size=%d, judges=%d"
      group_size
      judges

let staged_judge_groups ~group_size judges =
  let judge_count = List.length judges in
  if group_size < min_staged_judge_group_size
  then Error (Staged_group_size_below_min group_size)
  else if judge_count < group_size * 2
  then Error (Staged_too_few_judges { group_size; judges = judge_count })
  else if judge_count mod group_size <> 0
  then Error (Staged_ragged_judges { group_size; judges = judge_count })
  else
    let rec take n acc rest =
      if n = 0
      then (List.rev acc, rest)
      else
        match rest with
        | [] -> (List.rev acc, [])
        | x :: xs -> take (n - 1) (x :: acc) xs
    in
    let rec loop acc rest =
      match rest with
      | [] -> Ok (List.rev acc)
      | _ ->
        let group, rest = take group_size [] rest in
        loop (group :: acc) rest
    in
    loop [] judges

(* 외곽 run_safe 타임아웃. 하나의 Async_agent.all은 하나의 외곽 타임아웃만
   가지므로(RFC-0252-A §4.3) 그룹별 정밀 timeout은 build_agent에 반영하고 외곽은
   입력 전체가 한 wave로 실행되는 현재 구조에 맞춰 그룹 timeout 중 max로 둔다. *)
let panel_outer_timeout_of (groups : panel_group list) =
  List.fold_left (fun acc (g : panel_group) -> Float.max acc g.timeout_s) 0.0 groups

(* 심판은 preset당 1개이므로 그룹들에서 web_tools를 derive한다: req 또는 어느 그룹이든
   web_tools면 심판도 web tool. 단일 그룹이면 req || group.web_tools = 오늘의
   req.web_tools || preset.web_tools (byte-identity). *)
let judge_web_tools_of ~req_web_tools (groups : panel_group list) =
  req_web_tools || List.exists (fun (g : panel_group) -> g.web_tools) groups

(* RFC-0280: 검증된 preset을 타입으로 증명한다 (Parse, don't validate).
   [Validated_preset.t = private preset]이라 외부는 필드를 읽되([preset]/coercion)
   검증 없이 생성할 수 없다 → invalid preset이 게이트·orchestrator로 흐를 수 없다.
   검증 SSOT는 [of_preset] 한 곳 — 호출처(게이트)가 재검증하지 않는다. *)
module Validated_preset = struct
  type t = preset

  (* 검증 실패 사유 — 닫힌 합. config 계층이 이를 자기 [config_error]로 매핑한다
     (의존 방향: config → policy). *)
  type invalid =
    | Empty_panel_models  (** 패널 그룹 전체에 실행할 모델이 없음 *)
    | Missing_prompt  (** 패널 또는 심판 system prompt 비어있음 *)
    | Missing_judge_model  (** 심판 model id 비어있음 *)
    | Duplicate_panelist of string  (** 두 패널이 같은 정체성(panelist_id) *)
    | Bad_max_output_tokens of int
        (** 그룹/심판 출력 토큰 예산 override가 양수가 아님 *)
    | Judge_panel_prompt_missing  (** JOJ 1차 심판 system prompt 비어있음 (RFC-0283) *)
    | Duplicate_judge of string  (** 두 JOJ 1차 심판이 같은 정체성(judge_id) (RFC-0283) *)
    | Bad_meta_timeout of float
        (** [meta_timeout_s]가 양수 유한수가 아님. *)

  (* 검증 순서는 config 로드 시점과 동일: non-empty models → 패널 prompt →
     judge model → 패널 정체성 중복 → 패널 max_output_tokens 범위 → (RFC-0283)
     1차 심판 prompt → 1차 심판 정체성 중복 → 심판 max_output_tokens 범위.
     judges=[]면 1차 심판 관련 셋은 통과(simple/refine/conditional preset은 기존과 동일
     결과 = byte-identity). *)
  let of_preset (p : preset) : (t, invalid) result =
    if p.panels = [] || preset_models p = [] then Error Empty_panel_models
    else if not (preset_prompts_present p) then Error Missing_prompt
    else if not (preset_judge_present p) then Error Missing_judge_model
    else
      match preset_duplicate_panelist p with
      | Some id -> Error (Duplicate_panelist id)
      | None ->
        (match
           List.find_map
             (fun (g : panel_group) ->
               match g.max_output_tokens with
               | Some n when not (valid_max_output_tokens (Some n)) -> Some n
               | _ -> None)
             p.panels
         with
         | Some n -> Error (Bad_max_output_tokens n)
         | None ->
           if not (preset_judge_prompts_present p) then Error Judge_panel_prompt_missing
           else (
             match preset_duplicate_judge p with
             | Some id -> Error (Duplicate_judge id)
             | None ->
               (match
                  p.judge_max_output_tokens
                  :: List.map (fun (j : judge_spec) -> j.jmax_output_tokens) p.judges
                  |> List.find_opt (fun v -> not (valid_max_output_tokens v))
                with
                | Some (Some n) -> Error (Bad_max_output_tokens n)
                | Some None | None ->
                  if
                    not (p.meta_timeout_s > 0.0 && Float.is_finite p.meta_timeout_s)
                  then Error (Bad_meta_timeout p.meta_timeout_s)
                  else Ok p)))

  let preset (t : t) : preset = t

  (* private 타입 deriving 의존을 피해 underlying [preset]에 위임 (Fusion_policy.t가
     derive할 때 Validated_preset.pp/equal을 참조한다). *)
  let pp fmt (t : t) = pp_preset fmt t
  let show (t : t) = show_preset t
  let equal (a : t) (b : t) = equal_preset a b
end

type t =
  { enabled : bool
  ; default_preset : string
  ; staged_judge_group_size : int
  ; presets : Validated_preset.t list
  }
[@@deriving show, eq]

let find_preset (policy : t) name =
  List.find_opt
    (fun (vp : Validated_preset.t) ->
      String.equal (Validated_preset.preset vp).name name)
    policy.presets

(* decide는 enabled/preset/depth의 구조적 판정만 담당한다 — "이 턴이 심의할 가치가
   있나"는 게이트가 score 비교나 문자열 매칭으로 판정하지 않고, 키퍼(이미 LLM)가
   판단해 masc_fusion을 호출하는 것으로 표현한다(RFC-0252 §6). 따라서 [req.trigger]는
   발동 이유 라벨일 뿐 적격성 판정에 쓰이지 않는다.
   모델 집합 재검증은 없다 — [find_preset]이 [Validated_preset.t]를 돌려주므로
   non-empty는 타입으로 증명됨 (RFC-0280, 기존 dead 재검증 제거). *)
let decide ~(policy : t)
    (req : Fusion_types.fusion_request) : Fusion_types.gate_decision =
  if not policy.enabled then Fusion_types.Deny Fusion_types.Disabled
  else
    match find_preset policy req.preset with
    | None -> Fusion_types.Deny (Fusion_types.Preset_unknown req.preset)
    | Some _vp ->
      (match req.depth with
       | Fusion_types.Fusion_depth.Nested ->
         Fusion_types.Deny Fusion_types.Depth_exceeded
       | Fusion_types.Fusion_depth.Top -> Fusion_types.Allow req)
