(** Keeper_context_core — shared keeper context utilities.

    Accessors, JSON codecs, save/load extracted to
    [Keeper_context_core_accessors] (godfile decomp). *)

open Printf
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_context_core_accessors

type 'persistence_error checkpoint_write_error =
  | Tool_history_invalid of Keeper_transcript_unit.structural_error
  | Persistence_error of 'persistence_error

let checkpoint_write_error_to_string ~persistence_error_to_string = function
  | Tool_history_invalid error ->
    "tool history invalid: " ^ Keeper_transcript_unit.show_structural_error error
  | Persistence_error error -> persistence_error_to_string error
;;

let resume_checkpoint_of_context (ctx : working_context) : Agent_core.Checkpoint.t =
  let checkpoint_context = Agent_core.Context.copy ~eio:true (agent_core_context_of_context ctx) in
  {
    ctx.checkpoint with
    version = Agent_core.Checkpoint.checkpoint_version;
    system_prompt = Some (system_prompt_of_context ctx);
    messages = messages_of_context ctx;
    context = checkpoint_context;
  }

let context_of_agent_core_checkpoint (cp : Agent_core.Checkpoint.t) : working_context =
  let system_prompt = Option.value ~default:"" cp.system_prompt in
  let messages = cp.messages in
  let context = Agent_core.Context.copy ~eio:true cp.context in
  let checkpoint =
    { cp with system_prompt = Some system_prompt; messages; context }
  in
  sync_agent_core_context { checkpoint }

let checkpoint_for_persistence
    ~(runtime_id : string)
    ~(keeper_name : string)
    ~(session : session_context)
    ~(agent_name : string)
    ~(ctx : working_context)
  : (Agent_core.Checkpoint.t, Keeper_transcript_unit.structural_error) result =
  let checkpoint_context = Agent_core.Context.copy ~eio:true (agent_core_context_of_context ctx) in
  let checkpoint_messages = messages_of_context ctx in
  (* RFC vision-delegation §2.3 site 2 (checkpoint write boundary). For a
     keeper whose runtime cannot take an image, evict any inline image to a handle-only placeholder BEFORE
     it is persisted, so a reloaded checkpoint can never re-materialise an
     [Image] and re-trigger the RFC-0265 reroute. Store-only here — checkpoint
     writes must not block the turn fiber on a vision provider call (eager
     extraction is site 1's job). Also the migration path for images persisted
     by pre-existing checkpoints. A runtime that takes the image itself keeps
     it. [runtime_id]/[keeper_name] are required so every checkpoint write path
     is compiler-forced to name the runtime it persists for (N-of-M closure). *)
  let checkpoint_messages =
    List.map
      (Keeper_vision_ingest.evict_message
         ~mode:Keeper_vision_ingest.Store_only
         ~delegate:(Keeper_vision_ingest.delegates_media ~runtime_id)
         ~keeper_name)
      checkpoint_messages
  in
  match Keeper_transcript_unit.validate checkpoint_messages with
  | Error _ as error -> error
  | Ok () ->
    Ok
      {
        ctx.checkpoint with
        version = Agent_core.Checkpoint.checkpoint_version;
        session_id = session.session_id;
        agent_name;
        model = Boundary_redaction.to_string Boundary_redaction.runtime_model_label;
        system_prompt = Some (system_prompt_of_context ctx);
        messages = checkpoint_messages;
        created_at = Time_compat.now ();
        context = checkpoint_context;
      }

let save_agent_core_checkpoint_classified
    ~runtime_id
    ~keeper_name
    ~session
    ~agent_name
    ~ctx
  =
  match
    checkpoint_for_persistence
      ~runtime_id
      ~keeper_name
      ~session
      ~agent_name
      ~ctx
  with
  | Error error -> Error (Tool_history_invalid error)
  | Ok checkpoint ->
    (match
       Keeper_checkpoint_store.save_agent_core_classified
         ~session_dir:session.session_dir
         checkpoint
     with
     | Ok outcome -> Ok (checkpoint, outcome)
     | Error error -> Error (Persistence_error error))

let save_agent_core_checkpoint_if_source_with
    ~save_agent_core_history
    ~runtime_id
    ~keeper_name
    ~session
    ~agent_name
    ~ctx
    ~expected_source_ref
  =
  match
    checkpoint_for_persistence
      ~runtime_id
      ~keeper_name
      ~session
      ~agent_name
      ~ctx
  with
  | Error error -> Error (Tool_history_invalid error)
  | Ok checkpoint ->
    (match
       Keeper_checkpoint_store.save_agent_core_if_source
         ~session_dir:session.session_dir
         ~expected_source_ref
         checkpoint
     with
     | Keeper_checkpoint_store.Not_installed _ as installation ->
       Ok (checkpoint, installation)
     | Keeper_checkpoint_store.Installed installed ->
       let installation =
         match
           save_agent_core_history
             ~session_dir:session.session_dir
             checkpoint
         with
         | () -> Keeper_checkpoint_store.Installed installed
         | exception exn ->
           let failure = exn, Printexc.get_raw_backtrace () in
           Keeper_checkpoint_store.Installed
             { installed with
               auxiliary =
                 installed.auxiliary
                 @ [ Keeper_checkpoint_store.History_write_failed failure ]
             }
       in
       Ok (checkpoint, installation))

module For_testing = struct
  let save_agent_core_checkpoint_if_source_with_history ~save_agent_core_history =
    save_agent_core_checkpoint_if_source_with ~save_agent_core_history
  ;;
end

let save_agent_core_checkpoint
    ~runtime_id
    ~keeper_name
    ~session
    ~agent_name
    ~ctx
  =
  match
    save_agent_core_checkpoint_classified
      ~runtime_id
      ~keeper_name
      ~session
      ~agent_name
      ~ctx
  with
  | Ok (checkpoint, Keeper_checkpoint_store.Saved _)
  | Ok (checkpoint, Keeper_checkpoint_store.Stale_noop _) -> Ok checkpoint
  | Error e -> Error e

(* ================================================================ *)
(* Checkpoint Loading                                                *)
(* ================================================================ *)

let load_context_from_checkpoint ~trace_id ~base_dir =
  let session = create_session ~session_id:trace_id ~base_dir in
  let agent_core_result =
    Keeper_checkpoint_store.load_agent_core ~session_dir:session.session_dir
      ~session_id:trace_id
  in
  (match agent_core_result with
   | Error (Parse_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Agent_core_parse))]
         ();
       Log.Keeper.error "keeper:%s AGENT_CORE checkpoint parse error: %s" trace_id detail
   | Error (Store_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Agent_core_store))]
         ();
       Log.Keeper.error "keeper:%s AGENT_CORE checkpoint store error: %s" trace_id detail
   | Error (Io_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Agent_core_io))]
         ();
       Log.Keeper.error "keeper:%s AGENT_CORE checkpoint I/O error: %s" trace_id detail
   | Error (Agent_core_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Agent_core_failure))]
         ();
       Log.Keeper.error "keeper:%s AGENT_CORE checkpoint agent-core error: %s" trace_id detail
   | Error Not_found ->
       Log.Keeper.debug "keeper:%s AGENT_CORE checkpoint not found" trace_id
   | Ok _ -> ());
  let agent_core_checkpoint =
    (match agent_core_result with
     | Ok v -> Some v
     | Error Not_found -> None
     | Error _ ->
       Log.Keeper.warn
         "keeper:%s AGENT_CORE checkpoint unavailable after explicit load diagnostics"
         trace_id;
       None)
  in
  match agent_core_checkpoint with
  | Some checkpoint ->
      let ctx = context_of_agent_core_checkpoint checkpoint in
      (session, Some ctx)
  | None ->
      (* No canonical AGENT_CORE checkpoint is available. Non-trivial AGENT_CORE errors
         were already logged above at error level. *)
      (session, None)

(** Patch an AGENT_CORE checkpoint: unify session_id and normalize the last assistant
    message's visible text. AGENT_CORE-owned internal replay blocks (reasoning/tool blocks) stay
    typed content blocks; MASC only edits the visible text projection. New
    writes keep the checkpoint [working_context] empty. *)
let patch_checkpoint_last_assistant
    (cp : Agent_core.Checkpoint.t) ~session_id ~response_text
  : Agent_core.Checkpoint.t =
  let visible_response_text = response_text in
  let patch_assistant_message (msg : Agent_core.Types.message) =
    let visible_is_blank = String.trim visible_response_text = "" in
    let rec patch_content replaced acc = function
      | [] ->
          if replaced || visible_is_blank then List.rev acc
          else List.rev (Agent_core.Types.Text visible_response_text :: acc)
      | Agent_core.Types.Text _ :: rest when not replaced ->
          let acc =
            if visible_is_blank then acc
            else Agent_core.Types.Text visible_response_text :: acc
          in
          patch_content true acc rest
      | Agent_core.Types.Text _ :: rest -> patch_content replaced acc rest
      | block :: rest -> patch_content replaced (block :: acc) rest
    in
    let content = patch_content false [] msg.Agent_core.Types.content in
    let rec content_unchanged left right =
      match left, right with
      | [], [] -> true
      | Agent_core.Types.Text left :: left_rest,
        Agent_core.Types.Text right :: right_rest
        when String.equal left right ->
        content_unchanged left_rest right_rest
      | left_block :: left_rest, right_block :: right_rest
        when left_block == right_block ->
        content_unchanged left_rest right_rest
      | _ -> false
    in
    if content_unchanged content msg.Agent_core.Types.content
       && Option.is_none msg.name
       && Option.is_none msg.tool_call_id
       && msg.metadata = []
    then msg
    else
      Agent_core.Types.make_message
        ~role:Agent_core.Types.Assistant
        content
  in
  let rec patch_last_assistant suffix_rev = function
    | [] -> cp.messages
    | msg :: older_rev when msg.Agent_core.Types.role = Agent_core.Types.Assistant ->
        let patched = patch_assistant_message msg in
        if patched == msg
        then cp.messages
        else List.rev_append older_rev (patched :: suffix_rev)
    | msg :: older_rev -> patch_last_assistant (msg :: suffix_rev) older_rev
  in
  let messages =
    patch_last_assistant [] (List.rev cp.messages)
  in
  { cp with Agent_core.Checkpoint.session_id;
            messages;
            working_context = None }
