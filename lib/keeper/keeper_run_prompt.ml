(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, and appends the user message.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; memory_context : string
  ; temporal_context : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; history_messages : Agent_sdk.Types.message list
  ; ctx_work : Keeper_context_runtime.working_context
  }

(* RFC-0351 section 5 / #25462: an autonomous wake whose user turn is only the
   [autonomous_wake_marker] constant carries nothing forward — the observation
   frame it stands for rides [dynamic_context], rebuilt fresh every turn and
   never persisted. Recording it anyway appends a byte-identical message per
   wake, which is pure transcript duplication (analyst: the same 147B message
   x359, part of a 25.7% exact-dup share). The distinction is typed here rather
   than inferred from the message text. *)
type user_turn_record =
  | Record_user_turn
      (** The user turn carries content later turns need: an operator message,
          a HITL resolution, or chat-lane input. *)
  | Skip_uninformative_wake
      (** Autonomous wake marker alone. Neither appended to the working context
          nor persisted to session history. *)

(* The unified lane's user turn is the wake marker constant unless a HITL
   resolution was appended to it, so the presence of that resolution is the
   whole signal. Extracted from the lane call site to keep the mapping
   unit-testable and to keep the decision out of the message text. *)
let user_turn_record_of_hitl_resolution : _ option -> user_turn_record
  = function
  | None -> Skip_uninformative_wake
  | Some _ -> Record_user_turn
;;

let user_turn_record_for_prompt_build
      ~hitl_resolution_present
      ~user_turn_record
  =
  if hitl_resolution_present
  then Skip_uninformative_wake
  else user_turn_record
;;

type turn_effect_record =
  | Meaningful_turn
  | Inert_autonomous_turn

(* One typed decision owns both replay persistence and librarian extraction.
   A model response is not itself an external effect: scheduled idle prose has
   no consumer, yet previously accumulated in the checkpoint and then became
   librarian input. Existing execution facts are sufficient:

   - operator/HITL input is durable input,
   - any Keeper tool call may have changed or observed state needed later,
   - a routed continuation has an external consumer.

   No response-text classifier or duplicate field comparison is involved. *)
let turn_effect_record_of_turn
      ~(user_turn_record : user_turn_record)
      ~(tool_calls_made : bool)
      ~(external_delivery_routed : bool)
  : turn_effect_record
  =
  match user_turn_record with
  | Skip_uninformative_wake
    when not tool_calls_made && not external_delivery_routed ->
    Inert_autonomous_turn
  | Skip_uninformative_wake | Record_user_turn -> Meaningful_turn
;;

type extra_system_context_assembly =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  }

let normalize_memory_fragment = Inference_utils.sanitize_text_utf8
let sanitize_user_message = Inference_utils.sanitize_text_utf8

let append_extra_system_context ctx text =
  match ctx with
  | None -> Some text
  | Some existing -> Some (existing ^ "\n\n" ^ text)

let assembled_extra_system_context
      ~(existing_extra_system_context : string option)
      ~(included_blocks : (Prompt_block_id.t * string) list) =
  List.fold_left
    (fun ctx (_, text) -> append_extra_system_context ctx text)
    existing_extra_system_context
    included_blocks

let assemble_extra_system_context
      ~(existing_extra_system_context : string option)
      ~(blocks : (Prompt_block_id.t * string) list)
  : extra_system_context_assembly =
  { extra_system_context =
      assembled_extra_system_context
        ~existing_extra_system_context
        ~included_blocks:blocks
  ; blocks
  }

let build_turn_context
      ~(ctx : Keeper_run_context.run_context)
      ~(build_turn_prompt :
           base_system_prompt:string
        -> messages:Agent_sdk.Types.message list
        -> Keeper_agent_prompt_metrics.turn_prompt)
      ~(user_message : string)
      ~config:(_ : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(history_user_source : string)
      ~(user_turn_record : user_turn_record)
      ~(is_retry : bool)
      ~(start_turn_count : int)
  : turn_prompt_context
  =
  let base_system_prompt = ctx.Keeper_run_context.base_system_prompt in
  let ctx_work = ctx.Keeper_run_context.ctx_work in
  let session = ctx.Keeper_run_context.session in
  let shared_context = ctx.Keeper_run_context.shared_context in
  (* 5. Build final turn system prompt via caller callback. *)
  let { Keeper_agent_prompt_metrics.system_prompt = turn_system_prompt
      ; dynamic_context
      } =
    build_turn_prompt
      ~base_system_prompt
      ~messages:(Keeper_context_runtime.messages_of_context ctx_work)
  in
  let memory_context = "" in
  let temporal_context =
    Masc_context_injector.render_temporal_summary shared_context
    |> Option.value ~default:""
  in
  let prompt_metrics =
    Keeper_agent_prompt_metrics.build_prompt_metrics
      ~system_prompt:turn_system_prompt
      ~dynamic_context
      ~user_message
  in
  (* [substrate:system_prompt] observability *)
  (let segment = prompt_metrics.Keeper_agent_prompt_metrics.system_prompt_segment in
   let hash16 =
     match segment.Keeper_agent_prompt_metrics.fingerprint with
     | Some hex when String.length hex >= 16 -> String.sub hex 0 16
     | Some hex -> hex
     | None -> "empty"
   in
   Log.Keeper.routine
     "[substrate:system_prompt] agent=%s turn=%d length=%d hash=%s"
     meta.agent_name (start_turn_count + 1) segment.Keeper_agent_prompt_metrics.bytes hash16);
  (* [substrate:task_assignment] observability *)
  (let user_seg = prompt_metrics.Keeper_agent_prompt_metrics.user_message_segment in
   let dyn_seg = prompt_metrics.Keeper_agent_prompt_metrics.dynamic_context_segment in
   let pick_hash16 (segment : Keeper_agent_prompt_metrics.prompt_segment_metrics) =
     match segment.Keeper_agent_prompt_metrics.fingerprint with
     | Some hex when String.length hex >= 16 -> String.sub hex 0 16
     | Some hex -> hex
     | None -> "empty"
   in
   Log.Keeper.routine
     "[substrate:task_assignment] agent=%s turn=%d user_length=%d \
      user_hash=%s dyn_length=%d dyn_hash=%s"
     meta.agent_name (start_turn_count + 1) user_seg.Keeper_agent_prompt_metrics.bytes
     (pick_hash16 user_seg) dyn_seg.Keeper_agent_prompt_metrics.bytes (pick_hash16 dyn_seg));
  (* 6. Append user message and persist. *)
  let user_msg = Agent_sdk.Types.user_msg user_message in
  let history_messages =
    Keeper_context_runtime.messages_of_context ctx_work
  in
  let ctx_work =
    match user_turn_record with
    | Record_user_turn -> Keeper_context_runtime.append ctx_work user_msg
    | Skip_uninformative_wake -> ctx_work
  in
  (match user_turn_record, is_retry with
   | Record_user_turn, false ->
     Keeper_context_runtime.persist_message
       ~source:history_user_source
       session
       user_msg
   | Record_user_turn, true | Skip_uninformative_wake, _ -> ());
  { turn_system_prompt
  ; dynamic_context
  ; memory_context
  ; temporal_context
  ; prompt_metrics
  ; history_messages
  ; ctx_work
  }
