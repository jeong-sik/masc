(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, and appends the user message.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system_prompt : string
  ; dynamic_context : string
  ; dynamic_context_for_tools : (Keeper_request_tool_access.t -> Keeper_context_layers.rendered) option
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

type extra_system_context_assembly = Keeper_context_assembly.t

let sanitize_user_message = Inference_utils.sanitize_text_utf8

let assemble_extra_system_context = Keeper_context_assembly.assemble

let assemble_request_context ~base_system_prompt ~post_tool_round ~previous_assembly
    ~dynamic_context_partition ~existing_extra_system_context ~blocks =
  let observations, blocks, dynamic_context_partition =
    if post_tool_round then
      let observations = match Option.bind previous_assembly (fun previous ->
          previous.Keeper_context_assembly.system_prompt) with
        | None -> [] | Some issued -> issued.observations in
      observations, blocks, dynamic_context_partition
    else
      match dynamic_context_partition,
        List.filter (fun (id, _) -> Prompt_block_id.equal id Prompt_block_id.Dynamic_context) blocks with
      | Some partition, [(_, dynamic)] when String.equal dynamic (Keeper_context_layers.text partition) ->
        let sections = Keeper_context_layers.sections partition in
        let unique layer = List.length (List.filter (fun (section : Keeper_context_layers.section) ->
          section.section_source = Keeper_context_layers.Layer layer) sections) <= 1 in
        if not (unique Active_goals && unique Completion_authority && unique Admitted_scheduled_input)
        then [], blocks, dynamic_context_partition
        else
          let goals, remaining = Keeper_context_layers.partition_layer Active_goals partition in
          let authority, remaining = Keeper_context_layers.partition_layer Completion_authority remaining in
          let admission, remaining = Keeper_context_layers.partition_layer Admitted_scheduled_input remaining in
          let observations =
            (match Keeper_context_layers.text goals with
             | "" -> [] | text -> [Keeper_context_assembly.Active_goals (Inference_utils.sanitize_text_utf8 text)])
            @ (match Keeper_context_layers.text authority with
               | "" -> [] | text -> [Keeper_context_assembly.Completion_authority (Inference_utils.sanitize_text_utf8 text)])
            @ (match Keeper_context_layers.text admission with
               | "" -> [] | text -> [Keeper_context_assembly.Admitted_scheduled_input (Inference_utils.sanitize_text_utf8 text)]) in
          observations, List.map (fun (id, text) ->
            if Prompt_block_id.equal id Prompt_block_id.Dynamic_context
            then id, Keeper_context_layers.text remaining else id, text) blocks, Some remaining
      | Some _, _ | None, _ -> [], blocks, dynamic_context_partition
  in
  let blocks = blocks
    |> List.filter (fun (id, _) -> not post_tool_round || Prompt_block_id.injected_on_post_tool_round id)
    |> List.stable_sort (fun (left, _) (right, _) ->
         Int.compare (Prompt_block_id.cache_rank left) (Prompt_block_id.cache_rank right)) in
  assemble_extra_system_context ~dynamic_context_partition ~existing_extra_system_context ~blocks
  |> Keeper_context_assembly.with_system_observations
       ~base_text:(Inference_utils.sanitize_text_utf8 base_system_prompt) ~observations

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
      ~(input_metadata : Agent_core.Types.metadata)
      ~config:(_ : Workspace.config)
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~(turn_ref : Ids.Turn_ref.t)
      ~(history_user_source : string)
      ~(user_turn_record : user_turn_record)
      ~(start_turn_count : int)
  : turn_prompt_context
  =
  let base_system_prompt = ctx.Keeper_run_context.base_system_prompt in
  let ctx_work = ctx.Keeper_run_context.ctx_work in
  let session = ctx.Keeper_run_context.session in
  let shared_context = ctx.Keeper_run_context.shared_context in
  (* 5. The turn sends the run context's base prompt, direct or autonomous;
     the caller's callback supplies only the dynamic context (#38354). *)
  let turn_system_prompt = base_system_prompt in
  let { Keeper_agent_prompt_metrics.dynamic_context
      ; dynamic_context_for_tools
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
  (* The same speaker entry AGENT_CORE stamps on its own copy of this input
     (RFC-0468 §3.2), so no copy of the turn's input exists without it. *)
  let user_msg =
    Agent_core.Types.make_message ~metadata:input_metadata ~role:Agent_core.Types.User
      [ Agent_core.Types.Text user_message ]
  in
  let history_messages =
    Keeper_context_runtime.messages_of_context ctx_work
  in
  let ctx_work =
    match user_turn_record with
    | Record_user_turn -> Keeper_context_runtime.append ctx_work user_msg
    | Skip_already_checkpointed_user_turn -> ctx_work
  in
  (match user_turn_record with
   | Record_user_turn ->
     Keeper_context_runtime.persist_message
       ~keeper_name:meta.name
       ~turn_ref
       ~source:history_user_source
       session
       user_msg
   | Skip_already_checkpointed_user_turn -> ());
  { turn_system_prompt
  ; dynamic_context
  ; dynamic_context_for_tools
  ; temporal_context
  ; prompt_metrics
  ; history_messages
  ; ctx_work
  }
