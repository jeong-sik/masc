(** Keeper_execution — keeper tool execution loop, prompting,
    compaction, proactive/explicit room behavior, and keepalive runtime.

    This module re-exports sub-modules for backward compatibility:
    - Keeper_exec_context:   shared utilities, checkpoint, compaction, prompts, text processing
    - Keeper_exec_autonomy:  autonomous execution engine (gate config, plan execution)
    - Keeper_exec_proactive: proactive generation, deliberation, maybe_emit_proactive
    - Keeper_exec_room:      explicit room replies, social board events, learned policy *)

open Keeper_types
open Keeper_alerting

include Keeper_exec_context
include Keeper_exec_autonomy
include Keeper_exec_proactive
include Keeper_exec_room

(* Self-model drift is defined here rather than in a sub-module because it
   depends on append_trait_clause (from context) and is only called from
   keeper_turn.ml which opens Keeper_execution. *)
let apply_self_model_drift
    ~(meta : keeper_meta)
    ~(user_message : string)
    ~(work_kind : string) : keeper_meta * bool * string option =
  if not meta.drift_enabled then
    (meta, false, None)
  else if String.trim user_message = "" then
    (meta, false, None)
  else if work_kind <> "general_chat" && work_kind <> "memory_recall" then
    (meta, false, None)
  else
    let turn_gap = meta.total_turns - meta.last_drift_turn in
    if turn_gap < meta.drift_min_turn_gap then
      (meta, false, None)
    else
      let msg = String.lowercase_ascii user_message in
      let has_any keywords = List.exists (fun kw -> contains_ci msg kw) keywords in
      let relationship_flag =
        has_any
          [ "연애"; "관계"; "감정"; "사람"; "호감"; "불호"; "신뢰"; "친밀"; "친구";
            "relationship"; "emotion"; "trust"; "liking"; "dislike" ]
      in
      let safety_flag =
        has_any
          [ "위험"; "리스크"; "장애"; "실패"; "사고"; "롤백"; "incident"; "risk";
            "failure"; "rollback"; "outage" ]
      in
      let delivery_flag =
        has_any
          [ "실행"; "마감"; "배포"; "완료"; "일정"; "ship"; "deliver"; "deadline";
            "execute" ]
      in
      let memory_flag =
        has_any
          [ "기억"; "메모"; "승계"; "핸드오프"; "컴팩팅"; "memory"; "handoff";
            "compaction"; "context" ]
      in
      let conflict_flag =
        has_any
          [ "갈등"; "충돌"; "싸움"; "비난"; "불편"; "conflict"; "fight"; "blame" ]
      in
      if not (relationship_flag || safety_flag || delivery_flag || memory_flag || conflict_flag)
      then
        (meta, false, None)
      else
        let will' =
          meta.will
          |> (fun v ->
               if safety_flag then
                 append_trait_clause ~base:v
                   ~clause:"불확실성이 커지면 즉시 보수 모드로 전환한다."
               else v)
          |> (fun v ->
               if conflict_flag then
                 append_trait_clause ~base:v
                   ~clause:"갈등 상황에서는 해석보다 사실 확인과 경계선 선언을 먼저 수행한다."
               else v)
          |> compact_self_model_text
        in
        let needs' =
          meta.needs
          |> (fun v ->
               if relationship_flag then
                 append_trait_clause ~base:v
                   ~clause:"관계의 비대칭, 감정 신호, 실제 사실을 분리 기록한다."
               else v)
          |> (fun v ->
               if memory_flag then
                 append_trait_clause ~base:v
                   ~clause:"기억 항목은 사실/해석/결정을 분리해 보존한다."
               else v)
          |> compact_self_model_text
        in
        let desires' =
          meta.desires
          |> (fun v ->
               if delivery_flag then
                 append_trait_clause ~base:v
                   ~clause:"다음 행동을 책임/기한/검증 기준과 함께 즉시 고정한다."
               else v)
          |> (fun v ->
               if relationship_flag then
                 append_trait_clause ~base:v
                   ~clause:"관계를 해치지 않으면서도 핵심을 말하는 문장을 우선 선택한다."
               else v)
          |> compact_self_model_text
        in
        if will' = meta.will && needs' = meta.needs && desires' = meta.desires
        then
          (meta, false, None)
        else
          let tags =
            []
            |> (fun xs -> if relationship_flag then "relationship" :: xs else xs)
            |> (fun xs -> if safety_flag then "safety" :: xs else xs)
            |> (fun xs -> if delivery_flag then "delivery" :: xs else xs)
            |> (fun xs -> if memory_flag then "memory" :: xs else xs)
            |> (fun xs -> if conflict_flag then "conflict" :: xs else xs)
            |> List.rev
          in
          let reason =
            Printf.sprintf "auto-drift(turn=%d,gap=%d,tags=%s)" meta.total_turns
              turn_gap (String.concat "," tags)
          in
          ( {
              meta with
              will = will';
              needs = needs';
              desires = desires';
              drift_count_total = meta.drift_count_total + 1;
              last_drift_turn = meta.total_turns;
              last_drift_reason = reason;
              updated_at = now_iso ();
            },
            true,
            Some reason )
