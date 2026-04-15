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
let normalize_social_model = Keeper_social_model_types.normalize_social_model

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
