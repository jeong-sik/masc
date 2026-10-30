(** Fusion 설정 쓰기 — typed 연산 하나를 runtime.toml 에 적용한다.

    흐름 (RFC fusion-seat-routes §2.5):
    + 쓰기 전: preset 검증({!Fusion_policy.Validated_preset.of_preset})과 모든 자리의
      경로 풀기({!Runtime.resolve_assignment}). 못 풀면 쓰지 않는다.
    + 설정 잠금 안에서: 파일을 다시 읽어 revision 이 [expected_revision] 과 같은지
      본다. 다르면 다른 쓰기가 끼어든 것이라 거절한다. 같으면
      {!Fusion_config_writer} 로 고치고, 고친 파일 전체의 [\[fusion\]] 을
      {!Fusion_config.of_toml} 로 다시 읽어 본다.
    + 커밋은 {!Runtime.edit_config_text} 가 한다 — raw 저장과 같은 검증·원자 교체.

    lane 은 여기서 고치지 않는다. 자리 후보를 바꾸려면 기존 routing API 로 lane 을
    고친다. *)

type operation =
  | Set_settings of Fusion_config_writer.settings
  | Upsert_preset of Fusion_policy.preset
  | Delete_preset of string
  | Rename_preset of
      { from : string
      ; target : string
      }

val operation_of_yojson : Yojson.Safe.t -> (operation, string) result
(** [{"kind": "set_settings", "enabled", "default_preset",
    "staged_judge_group_size"}], [{"kind": "upsert_preset", "preset": {...}}]
    ({!Fusion_config_json.preset_of_yojson}), [{"kind": "delete_preset", "name"}],
    [{"kind": "rename_preset", "from", "to"}]. 모르는 kind 나 키는 거절한다. *)

val operation_label : operation -> string
(** 감사 기록용 한 줄. 예: ["upsert_preset trio"]. *)

type route_problem =
  | Route_missing  (** 로드된 lane 도 런타임도 아니다. *)
  | Route_catalog_missing of string
      (** 런타임의 카탈로그 행이 없다. payload 는 카탈로그 식별자 문장이다. *)

type error =
  | Configuration_unavailable of string
  | Configuration_changed
      (** 화면이 읽은 뒤 파일이 바뀌었다. 다시 읽고 다시 보내야 한다. *)
  | Preset_invalid of
      { preset : string
      ; invalid : Fusion_policy.Validated_preset.invalid
      }
  | Route_unresolved of
      { preset : string
      ; route : string
      ; problem : route_problem
      }
  | Name_invalid of string
      (** preset 이름이 비었거나 앞뒤 공백이 있다. *)
  | Default_preset_deleted of string
      (** [\[fusion\]] 이 켜져 있는데 기본 preset 을 지우려 했다. 기본을 먼저 바꾼다. *)
  | Edit_refused of Fusion_config_writer.error
  | Fusion_invalid of Fusion_config.config_error list
      (** 고친 파일의 [\[fusion\]] 이 로드되지 않는다. *)
  | Configuration_rejected of string
      (** 런타임 커밋 관문이 파일 전체를 거절했다. *)

val error_code : error -> string
val error_message : error -> string
val error_to_yojson : error -> Yojson.Safe.t

val apply
  :  runtime_config_path:string
  -> expected_revision:string
  -> operation
  -> (Runtime.config_commit_receipt, error) result
(** 연산 하나를 적용하고 커밋 영수증을 돌려준다. 영수증의 관측값이 쓴 파일과 그
    revision 이다. *)
