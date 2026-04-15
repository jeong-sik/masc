(** Keeper_social_model — stable facade over social-model types and dispatch.

    Callers continue to use this module; the actual implementation lives in
    the split social-model submodules. *)

type speech_act = Keeper_social_model_types.speech_act =
  | Stay_silent
  | Inform
  | Request_help
  | Claim_task
  | Comment_board
  | Post_board
  | Broadcast
  | Defer

type delivery_surface = Keeper_social_model_types.delivery_surface =
  | Silent
  | Visible_reply
  | Board_post
  | Board_comment
  | Task_claim_surface
  | Broadcast_surface

type model_id = Keeper_social_model_types.model_id =
  | Bdi_speech_v1
  | Magentic_ledger_v1

type transition_reason = Keeper_social_model_types.transition_reason =
  | Tool_only_stay_silent
  | Tool_only_comment_board
  | Tool_only_post_board
  | Tool_only_broadcast
  | Tool_only_claim_task
  | Tool_only_visible_reply
  | Tool_only_progress_ledger
  | Explicit_social_headers
  | Missing_headers_fallback_visible_reply
  | Invalid_headers_fallback_visible_reply
  | Inferred_visible_reply
  | Protocol_violation_missing_social_headers
  | Protocol_violation_invalid_social_headers
  | Protocol_violation_no_tools_no_social_headers
  | Failure_run_error

type social_state = Keeper_social_model_types.social_state = {
  social_model : string;
  belief_summary : string;
  active_desire : string option;
  current_intention : string option;
  blocker : string option;
  need : string option;
  speech_act : speech_act;
  delivery_surface : delivery_surface;
}

type accountability_claim = {
  subject : string;
  task_id : string option;
  evidence_refs : string list;
}

let speech_act_to_string = Keeper_social_model_types.speech_act_to_string
let delivery_surface_to_string =
  Keeper_social_model_types.delivery_surface_to_string

let model_id_to_string = Keeper_social_model_types.model_id_to_string
let model_id_of_string = Keeper_social_model_types.model_id_of_string
let is_known_social_model = Keeper_social_model_types.is_known_social_model
let fallback_social_model = Keeper_social_model_types.fallback_social_model
let normalize_social_model = Keeper_social_model_types.normalize_social_model
let transition_reason_to_string =
  Keeper_social_model_types.transition_reason_to_string

let nonempty_opt value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed

let previous_state_of_meta (meta : Keeper_types.keeper_meta) =
  let runtime = meta.runtime in
  let speech_act =
    match model_id_of_string meta.social_model with
    | None -> None
    | Some _ -> (
        match Keeper_social_model_types.speech_act_of_string runtime.last_speech_act with
        | Some speech_act -> Some speech_act
        | None -> None)
  in
  let active_desire = nonempty_opt runtime.last_active_desire in
  let current_intention = nonempty_opt runtime.last_current_intention in
  let blocker = nonempty_opt runtime.last_blocker in
  let need = nonempty_opt runtime.last_need in
  match speech_act, active_desire, current_intention, blocker, need with
  | None, None, None, None, None -> None
  | _ ->
      let speech_act = Option.value ~default:Inform speech_act in
      Some
        {
          social_model = normalize_social_model meta.social_model;
          belief_summary = "runtime_carry";
          active_desire;
          current_intention;
          blocker;
          need;
          speech_act;
          delivery_surface =
            Keeper_social_model_types.default_delivery_surface_of_speech_act
              speech_act;
        }

let extract_accountability_claim (result : Keeper_agent_run.run_result) =
  let headers, _ =
    Keeper_social_model_protocol.parse_header_block result.response_text
  in
  match
    Keeper_social_model_protocol.nonempty_header_opt headers "CLAIM_KIND",
    Keeper_social_model_protocol.nonempty_header_opt headers "CLAIM_SUBJECT"
  with
  | Some kind, Some subject
    when String.equal (String.lowercase_ascii (String.trim kind))
           "completion_claim" ->
      Some
        {
          subject = String.trim subject;
          task_id =
            Keeper_social_model_protocol.nonempty_header_opt headers
              "CLAIM_TASK_ID";
          evidence_refs =
            Keeper_social_model_protocol.comma_list_header_opt headers
              "EVIDENCE_REFS";
        }
  | _ -> None

let apply_to_result = Keeper_social_model_registry.apply_to_result
let derive_failure_state = Keeper_social_model_registry.derive_failure_state
