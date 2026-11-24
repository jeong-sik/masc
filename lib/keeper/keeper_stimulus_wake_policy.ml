type sender_kind =
  | Human_sender
  | Connector_sender
  | Keeper_sender
  | Own_async_sender
  | System_sender

type input_kind =
  | Direct_message
  | Board_mention_or_reply
  | Board_broadcast
  | Board_reaction_or_vote
  | Board_attention_ambient
  | Delegate_completion
  | Own_async_completion
  | Task_cancelled_or_rejected
  | Task_outcome_approved
  | Scheduled_wake
  | Workspace_broadcast

type stimulus_wake_policy =
  | Now
  | At_tick
  | Carry

(* Total exhaustive wake policy over (input_kind, sender_kind) (#54342):
   human/connector direct attention and own-async completions wake Now;
   keeper-authored peer communication coalesces At_tick on a staggered grid;
   ambient reactions, votes, discoverable attention, and approved outcomes Carry. *)
let stimulus_wake_policy_of ~input_kind ~sender_kind =
  match input_kind, sender_kind with
  | (Own_async_completion | Scheduled_wake),
    (Human_sender | Connector_sender | Keeper_sender | Own_async_sender | System_sender) ->
    Now
  | Direct_message, (Human_sender | Connector_sender | Own_async_sender | System_sender) ->
    Now
  | Direct_message, Keeper_sender -> At_tick
  | Board_mention_or_reply, (Human_sender | Connector_sender) -> Now
  | Board_mention_or_reply, (Keeper_sender | Own_async_sender | System_sender) -> At_tick
  | Board_broadcast, (Human_sender | Connector_sender) -> Now
  | Board_broadcast, (Keeper_sender | Own_async_sender | System_sender) -> At_tick
  | Workspace_broadcast, (Human_sender | Connector_sender) -> Now
  | Workspace_broadcast, (Keeper_sender | Own_async_sender | System_sender) -> At_tick
  | Delegate_completion, (Human_sender | Connector_sender | Own_async_sender) -> Now
  | Delegate_completion, (Keeper_sender | System_sender) -> At_tick
  | Task_cancelled_or_rejected, (Human_sender | Connector_sender) -> Now
  | Task_cancelled_or_rejected, (Keeper_sender | Own_async_sender | System_sender) -> At_tick
  | (Board_reaction_or_vote | Board_attention_ambient | Task_outcome_approved),
    (Human_sender | Connector_sender | Keeper_sender | Own_async_sender | System_sender) ->
    Carry
;;

let task_verdict_wake_policy ~input_kind authority =
  let sender_kind =
    match authority with
    | Masc_domain.Human_operator _ -> Human_sender
    | Masc_domain.System_llm_agent _ -> System_sender
  in
  stimulus_wake_policy_of ~input_kind ~sender_kind
;;

let urgency_of_stimulus_wake_policy = function
  | Now -> Keeper_event_queue.Immediate
  | At_tick -> Keeper_event_queue.Normal
  | Carry -> Keeper_event_queue.Low
;;

let effective_urgency (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Task_outcome outcome ->
    task_verdict_wake_policy ~input_kind:Task_outcome_approved outcome.to_authority
    |> urgency_of_stimulus_wake_policy
  | Completion_authority_rejected rejection ->
    task_verdict_wake_policy ~input_kind:Task_cancelled_or_rejected rejection.car_authority
    |> urgency_of_stimulus_wake_policy
  | _ -> stimulus.urgency
;;
