(* RFC-0057 Phase 2 — spec types extracted into a standalone library.

   It was standalone to keep the generator executable off masc_tool_schemas,
   which consumed the file that executable produced: exe -> lib -> generated
   file -> exe. The generator, its dune rule and the generated file are gone
   (see tool_schemas_operator_surface.ml), so that cycle no longer exists.
   The types stay here because Tool_schemas_misc, Dashboard and
   test_operator_surface_toml_parity read them. *)

(* The dashboard tool's [scope] argument. It is spelled in two places that
   cannot see each other: the JSON Schema enum the tool TOML declares, and the
   runtime parser in [Dashboard] that rejects anything outside it. Adding a
   scope to one and not the other either hides it from the model or advertises
   one the runtime refuses, and nothing failed when they drifted (#27069).

   It lives in this library because the generator already links it and nothing
   here depends on the consumers, so [Dashboard] can take it too without the
   cycle the generator exists to avoid. *)
type dashboard_scope =
  | Dashboard_scope_all
  | Dashboard_scope_current

let dashboard_scope_to_string = function
  | Dashboard_scope_all -> "all"
  | Dashboard_scope_current -> "current"
;;

let dashboard_scope_of_string_opt = function
  | "all" -> Some Dashboard_scope_all
  | "current" -> Some Dashboard_scope_current
  | _ -> None
;;

(* Order is the enum order in the emitted schema. *)
let all_dashboard_scopes = [ Dashboard_scope_all; Dashboard_scope_current ]

let dashboard_scope_strings =
  List.map dashboard_scope_to_string all_dashboard_scopes
;;


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

   tool_name_ref rationale: 본 lib은 tool-name catalog sublib에 의존 불가
   (역방향 cycle). boundary alias로 string 유지, 검증은 codegen/descriptor
   registry 측에서 수행 (JSON serialization과 동일 정신).

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

(** Issue #15257 Phase 1: Canonical SSOT for config category enum strings.
    Shared between gen_tool_descriptors.ml and tool_schemas_misc.ml without
    introducing circular dune dependencies. Mirrors the producer-side
    [Env_config_snapshot.valid_config_category_strings]; the drift guard
    in [test/test_operator_surface_toml_parity.ml ::
    config_category_enum_matches_its_owner] asserts
    they stay identical. *)
let config_category_enum_strings =
  [ "server"
  ; "auth"
  ; "transport"
  ; "storage"
  ; "runtime"
  ; "rate_limiting"
  ; "inference"
  ; "keeper"
  ; "keeper_execution"
  ; "autonomy"
  ; "dashboard"
  ; "operations"
  ; "channel"
  ; "process"
  ; "worker"
  ; "web_search"
  ; "session"
  ]
