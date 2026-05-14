(* RFC-0057 Phase 2 — spec types extracted into a standalone library.

   Why standalone? The generator executable (bin/gen_tool_descriptors.ml)
   must not depend on masc_tool_schemas (the consumer of the generated
   file), otherwise dune sees a cycle: exe -> lib -> generated file -> exe.

   Keeping these types in a tiny sibling library breaks the cycle:
   exe depends on tool_schemas_specs (types only), and masc_tool_schemas
   depends on nothing new — it just receives the generated ml. *)

type param_type =
  | T_string of
      { enum : string list option
      ; default : string option
      }
  | T_int of
      { min : int option
      ; max : int option
      ; default : int option
      }
  | T_bool of { default : bool option }
  | T_string_array of { default : Yojson.Safe.t option }
  | T_object of { default : Yojson.Safe.t option }

type param =
  { p_name : string
  ; p_type : param_type
  ; p_description : string
  ; p_required : bool
  }

(* Behavior contract — Issue #15257 C축 (description 표준 부재 해소).
   Tool descriptor에 행동 규칙을 typed로 박아 작성자 직관 의존 제거.
   Closed sum + non-option list로 모든 spec 작성자에게 명시적 표명 강제.

   tool_name_ref rationale: 본 lib은 Tool_name sublib에 의존 불가
   (역방향 cycle). boundary alias로 string 유지, 검증은 codegen 측의
   Tool_name.of_string에서 수행 (JSON serialization과 동일 정신).

   PoC는 2 variant (Precede_with, Hint)로 시작 — minimum + audit 원칙.
   future variants (Avoid_after, Mutually_exclusive_with, ...)는 사용처
   증거가 누적된 시점에 추가. *)

type tool_name_ref = string

type usage_hint =
  | Mention_specific_agent
  | Update_status
  | Help_request

type behavior_rule =
  | Precede_with of tool_name_ref list
  | Hint of usage_hint

type tool_spec =
  { name : string
  ; description : string
  ; parameters : param list
  ; additional_properties : bool
  ; behavior_contract : behavior_rule list
  }
