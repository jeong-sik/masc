(** Operator_digest_review_types — review item type and shared helpers.

    Separated from Operator_digest_types to avoid record field collision:
    both [attention_item] and [review_item] have fields named [kind],
    [severity], [target_type], [target_id]. Modules that include
    Operator_digest_types would see ambiguous field resolution. *)

open Operator_pending_confirm
open Operator_digest_types

(* Local alias — not leaked when this module is included/re-exported. *)
module U_ = Yojson.Safe.Util

type review_item = {
  id : string;
  kind : string;
  target_type : string;
  target_id : string option;
  severity : operator_severity;
  urgency : string;
  summary : string;
  why_now : string;
  source : string;
  authoritative : bool;
  fingerprint : string;
  stale_sec : int option;
  confirm_required : bool;
  recommended_action : recommended_action option;
  truth_ref : Yojson.Safe.t;
  friction : Yojson.Safe.t;
  advice : Yojson.Safe.t;
}

let review_empty_advice_json =
  `Assoc
    [
      ("active_summary", `Null);
      ("active_guidance_layer", `Null);
      ("authoritative_judgment_available", `Bool false);
    ]

let review_truth_ref_json ~target_type ~target_id =
  `Assoc
    [
      ("target_type", `String target_type);
      ("target_id", string_option_to_json target_id);
    ]

let json_string_opt json key =
  json |> U_.member key |> U_.to_string_option

let json_float_opt json key =
  match json |> U_.member key with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | `Intlit raw -> (try Some (float_of_string raw) with Failure _ -> None)
  | _ -> None

let json_bool_opt json key =
  match json |> U_.member key with
  | `Bool value -> Some value
  | _ -> None

let review_fingerprint parts =
  let payload = String.concat "|" parts in
  Digestif.SHA256.(digest_string payload |> to_hex)

let stale_sec_of_iso ~now iso =
  Option.bind iso (fun value ->
      try Some (max 0 (int_of_float (now -. Types.parse_iso8601 value)))
      with Failure _ -> None)

let review_action_copy = function
  | "broadcast" -> "전체 공지"
  | "namespace_pause" -> "프로젝트 일시정지"
  | "room_pause" -> "프로젝트 일시정지"
  | "namespace_resume" -> "프로젝트 재개"
  | "room_resume" -> "프로젝트 재개"
  | "team_note" -> "세션 메모"
  | "team_broadcast" -> "세션 공지"
  | "team_task_inject" -> "세션 작업 주입"
  | "team_worker_spawn_batch" -> "세션 작업자 교체"
  | "team_stop" -> "세션 중지"
  | "keeper_message" -> "키퍼 메시지"
  | "keeper_probe" -> "키퍼 점검"
  | "keeper_recover" -> "키퍼 복구"
  | "review_resolve" -> "검토 해결"
  | "review_defer" -> "검토 보류"
  | other -> other
