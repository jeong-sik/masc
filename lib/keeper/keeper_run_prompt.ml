(** Keeper_run_prompt — build turn prompt context (Steps 5-6).

    Takes the run context from [Keeper_run_context], calls the
    [build_turn_prompt] callback to get the final system prompt and
    dynamic context, then renders memory/temporal context, builds prompt
    metrics, and appends the user message.

    @since 0.120.0 *)

type turn_prompt_context =
  { turn_system : Keeper_turn_system.t
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

let this_turn_opening = function
  | Record_user_turn -> Keeper_turn_driver_try_provider.Opened_before_its_input
  | Skip_already_checkpointed_user_turn -> Keeper_turn_driver_try_provider.Opened_after_its_input
;;

type extra_system_context_assembly = Keeper_context_assembly.t

let sanitize_user_message = Inference_utils.sanitize_text_utf8

let assemble_extra_system_context = Keeper_context_assembly.assemble

(* The Completion Authority layer is world state that comes and goes between
   turns, so it is a context block, not a System observation.
   The Goal snapshot is a System suffix. The admitted operation source is one
   for an official client only. Agent Core leaves it in the end context, which
   rides the turn's first request alone, so a turn that serves an admitted
   request sends the System a turn that does not would: a System that changed
   with the turn kind made the provider read the whole history again. A later
   round carries this turn's authority block again because the post-tool
   assembly drops the [Dynamic_context] it came from (#45853). Proof state
   remains visible too, but Agent Core keeps this recurring state out of the
   post-tool User tail by carrying it in the issued System. Official clients
   retain their turn-scoped delivery of it, because their System outlives
   this turn. The complete current norms ride the Agent Core System for the
   same reason; an official client still receives them as the
   [Constitution_amendments] block. *)
let assemble_request_context ~checkpoint_owner ~(system : Keeper_turn_system.t) ~post_tool_round ~previous_assembly
    ~dynamic_context_partition ~existing_extra_system_context ~blocks =
  let observations, blocks, dynamic_context_partition, proof_state, admitted_source =
    if post_tool_round then
      match previous_assembly with
      | None -> [], blocks, dynamic_context_partition, None, None
      | Some (previous : Keeper_context_assembly.t) ->
        let observations = match previous.system_prompt with
          | None -> [] | Some issued -> issued.observations in
        (* Proof state, the current norms and the admitted source are issued
           again below, from the carried proof state and source and from
           [system], for the owner of this request. A copy the previous
           round's System held is dropped. *)
        let observations = List.filter (function
            | Keeper_context_assembly.Current_norms _
            | Keeper_context_assembly.Direct_input_source _ -> false
            | Keeper_context_assembly.Goals_awaiting_proof _ ->
              Option.is_none previous.proof_state
            | Keeper_context_assembly.Active_goals _ -> true) observations in
        let carried = List.filter (fun (id, _) ->
            Prompt_block_id.equal id Prompt_block_id.Completion_authority
            || (Option.is_none previous.proof_state
                && Prompt_block_id.equal id Prompt_block_id.Goals_awaiting_proof)) previous.blocks in
        ( observations, carried @ blocks, dynamic_context_partition, previous.proof_state
        , previous.admitted_source )
    else
      match dynamic_context_partition,
        List.filter (fun (id, _) -> Prompt_block_id.equal id Prompt_block_id.Dynamic_context) blocks with
      | Some partition, [(_, dynamic)] when String.equal dynamic (Keeper_context_layers.text partition) ->
        let sections = Keeper_context_layers.sections partition in
        let unique layer = List.length (List.filter (fun (section : Keeper_context_layers.section) ->
          section.section_source = Keeper_context_layers.Layer layer) sections) <= 1 in
        if not (unique Active_goals && unique Direct_input_source
                && unique Goals_awaiting_proof && unique Completion_authority)
        then [], blocks, dynamic_context_partition, None, None
        else
          let observation make layer = match Keeper_context_layers.text layer with
            | "" -> [] | text -> [make (Inference_utils.sanitize_text_utf8 text)] in
          let goals, remaining = Keeper_context_layers.partition_layer Active_goals partition in
          let source, without_source =
            Keeper_context_layers.partition_layer Direct_input_source remaining in
          (* Agent Core keeps the source in the end context; an official client
             reads it in System (below), so its end context drops it. *)
          let remaining = match checkpoint_owner with
            | Runtime_execution.Official_client -> without_source
            | Runtime_execution.Masc_agent_core -> remaining in
          let awaiting, remaining = Keeper_context_layers.partition_layer Goals_awaiting_proof remaining in
          let authority, remaining = Keeper_context_layers.partition_layer Completion_authority remaining in
          let observations =
            observation (fun text -> Keeper_context_assembly.Active_goals text) goals in
          let block id layer = match Keeper_context_layers.text layer with
            | "" -> [] | text -> [id, Inference_utils.sanitize_text_utf8 text] in
          let proof_state = Keeper_context_assembly.issue_proof_state awaiting in
          let split = block Prompt_block_id.Completion_authority authority in
          observations, split @ List.map (fun (id, text) ->
            if Prompt_block_id.equal id Prompt_block_id.Dynamic_context
            then id, Keeper_context_layers.text remaining else id, text) blocks, Some remaining, proof_state
          , Keeper_context_assembly.issue_admitted_source source
      | Some _, _ | None, _ -> [], blocks, dynamic_context_partition, None, None
  in
  (* Only a matching renderer partition or the prior issued assembly supplies
     [admitted_source], and only an official client reads it in System, right
     behind the Goal snapshot. *)
  let observations =
    match checkpoint_owner, admitted_source with
    | Runtime_execution.Official_client, Some (source : Keeper_context_assembly.admitted_source) ->
      let goals, rest = List.partition (function
          | Keeper_context_assembly.Active_goals _ -> true
          | Keeper_context_assembly.Current_norms _
          | Keeper_context_assembly.Direct_input_source _
          | Keeper_context_assembly.Goals_awaiting_proof _ -> false) observations in
      goals @ [ Keeper_context_assembly.Direct_input_source source.source_text ] @ rest
    | Runtime_execution.Official_client, None
    | Runtime_execution.Masc_agent_core, (Some _ | None) -> observations
  in
  (* Only a matching renderer partition or the prior issued assembly supplies
     [proof_state]. A raw caller block must not acquire System authority. *)
  let observations, blocks =
    match proof_state with
    | Some (proof : Keeper_context_assembly.proof_state) ->
      let text = proof.proof_text in
      (match checkpoint_owner with
       | Runtime_execution.Masc_agent_core ->
         observations @ [Keeper_context_assembly.Goals_awaiting_proof text], blocks
       | Runtime_execution.Official_client ->
         observations, (Prompt_block_id.Goals_awaiting_proof, text) :: blocks)
    | None -> observations, blocks
  in
  (* The complete current norms are the same text on every request of the
     turn. Agent Core carries them in the issued System, in front of the
     observations that change more often, so a request that follows tool
     results still ends with those results. On a turn that has them, an
     article write therefore changes the System a request sends, although
     [system.text] stays equal. An official client keeps the block: its
     projection sends a block the session holds again only when
     the bytes change ([Prompt_block_id.resent_when_held]). A turn without
     the complete list carries its delta as the end-context block for both
     owners. A System whose [<norms>] already are the complete set
     ([Keeper_turn_system.In_text]) carries neither. *)
  let constitution sections =
    Inference_utils.sanitize_text_utf8 (String.concat "\n" sections) in
  let beside = match system.current_norms with
    | Keeper_turn_system.Beside_text norms -> [ norms ]
    | Keeper_turn_system.Not_carried | Keeper_turn_system.In_text _ -> [] in
  let observations, amendments =
    match checkpoint_owner, system.current_norms with
    | Runtime_execution.Masc_agent_core, Keeper_turn_system.Beside_text norms ->
      (* [Keeper_turn_system.with_current_norms] leaves no delta beside the
         complete list. One that is there rides with it, in the order the
         block joins the two. *)
      ( Keeper_context_assembly.Current_norms
          (constitution (Option.to_list system.amendments @ [ norms ]))
        :: observations
      , [] )
    | Runtime_execution.Masc_agent_core, (Keeper_turn_system.Not_carried | Keeper_turn_system.In_text _)
    | Runtime_execution.Official_client,
      (Keeper_turn_system.Not_carried | Keeper_turn_system.In_text _ | Keeper_turn_system.Beside_text _) ->
      (match Option.to_list system.amendments @ beside with
       | [] -> observations, []
       | sections ->
         observations, [ Prompt_block_id.Constitution_amendments, constitution sections ])
  in
  let blocks = amendments @ blocks
    |> List.filter (fun (id, _) -> not post_tool_round || Prompt_block_id.injected_on_post_tool_round id)
    |> List.stable_sort (fun (left, _) (right, _) ->
         Int.compare (Prompt_block_id.cache_rank left) (Prompt_block_id.cache_rank right)) in
  assemble_extra_system_context ~dynamic_context_partition ~existing_extra_system_context ~blocks
  |> Keeper_context_assembly.with_system_observations
       ~base_text:(Inference_utils.sanitize_text_utf8 system.text) ~observations
  |> Keeper_context_assembly.with_proof_state proof_state
  |> Keeper_context_assembly.with_admitted_source admitted_source

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
      ~(history_user_source : Keeper_types_support.history_source)
      ~(user_turn_record : user_turn_record)
      ~(start_turn_count : int)
  : turn_prompt_context
  =
  let ctx_work = ctx.Keeper_run_context.ctx_work in
  let session = ctx.Keeper_run_context.session in
  let shared_context = ctx.Keeper_run_context.shared_context in
  (* 5. The turn sends the run context's System, direct or autonomous; the
     caller's callback supplies only the dynamic context (#38354). *)
  let turn_system = ctx.Keeper_run_context.system in
  let turn_system_prompt = turn_system.Keeper_turn_system.text in
  let { Keeper_agent_prompt_metrics.dynamic_context
      ; dynamic_context_for_tools
      } =
    build_turn_prompt
      ~base_system_prompt:turn_system_prompt
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
  (* The same speaker entry AGENT_CORE stamps on its own copy of this input,
     so no copy of the turn's input exists without it. *)
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
  { turn_system
  ; dynamic_context
  ; dynamic_context_for_tools
  ; temporal_context
  ; prompt_metrics
  ; history_messages
  ; ctx_work
  }
