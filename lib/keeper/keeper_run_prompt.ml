(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, and appends the user message.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; temporal_context : string
  ; prompt_metrics : Keeper_agent_prompt_metrics.prompt_metrics
  ; history_messages : Agent_core.Types.message list
  ; ctx_work : Keeper_context_runtime.working_context
  }

(* Ordinary user turns, including the tiny autonomous [Continue.] cue, are
   durable conversation messages. A resumed HITL checkpoint can already own
   the exact current input; that exceptional replay path skips only the second
   append, never because the content is judged uninformative. *)
type user_turn_record =
  | Record_user_turn
      (** The user turn carries content later turns need: an operator message,
          a HITL resolution, chat-lane input, or the autonomous continuation
          cue. *)
  | Skip_already_checkpointed_user_turn
      (** The resumed AGENT_CORE checkpoint already owns this exact user turn. Do not
          append or persist a second copy before replay. *)

type extra_system_context_assembly =
  { extra_system_context : string option
  ; blocks : (Prompt_block_id.t * string) list
  }

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

(* See the mli: a position question about the last message, deliberately not
   [Hooks.last_tool_results], which answers containment over the whole
   history. *)
let ends_with_tool_results (messages : Agent_core.Types.message list) =
  let rec last = function
    | [] -> None
    | [ message ] -> Some message
    | _ :: rest -> last rest
  in
  match last messages with
  | Some { Agent_core.Types.role = Agent_core.Types.Tool; _ } -> true
  | Some
      { Agent_core.Types.role =
          Agent_core.Types.User | Agent_core.Types.System
          | Agent_core.Types.Assistant
      ; _
      }
  | None -> false

(* Whether this dispatch is a later round of a turn already under way, which is
   what the per-round block filter is actually asking. The message shape alone
   cannot say it: a keeper whose previous turn ended on a tool result — the
   ordinary way a turn ends — replays exactly that shape into the first round
   of its next turn, so the filter fired on turns that had injected nothing
   yet (39 of 108 turns on 2026-08-25). [injected_this_turn] is the half the
   history does not carry. *)
let is_later_round_of_this_turn ~injected_this_turn messages =
  injected_this_turn && ends_with_tool_results messages
;;


let build_turn_context
      ~(ctx : Keeper_run_context.run_context)
      ~(build_turn_prompt :
           base_system_prompt:string
        -> messages:Agent_core.Types.message list
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
  let temporal_context =
    Masc_context_injector.render_temporal_summary shared_context
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
     meta.name (start_turn_count + 1) segment.Keeper_agent_prompt_metrics.bytes hash16);
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
     meta.name (start_turn_count + 1) user_seg.Keeper_agent_prompt_metrics.bytes
     (pick_hash16 user_seg) dyn_seg.Keeper_agent_prompt_metrics.bytes (pick_hash16 dyn_seg));
  (* 6. Append user message and persist. *)
  let user_msg = Agent_core.Types.user_msg user_message in
  let history_messages =
    Keeper_context_runtime.messages_of_context ctx_work
  in
  let ctx_work =
    match user_turn_record with
    | Record_user_turn -> Keeper_context_runtime.append ctx_work user_msg
    | Skip_already_checkpointed_user_turn -> ctx_work
  in
  (match user_turn_record, is_retry with
   | Record_user_turn, false ->
     Keeper_context_runtime.persist_message
       ~source:history_user_source
       session
       user_msg
   | Record_user_turn, true | Skip_already_checkpointed_user_turn, _ -> ());
  { turn_system_prompt
  ; dynamic_context
  ; temporal_context
  ; prompt_metrics
  ; history_messages
  ; ctx_work
  }
