(** Keeper_context_core — shared keeper context utilities.

    Accessors, JSON codecs, save/load extracted to
    [Keeper_context_core_accessors] (godfile decomp). *)

open Printf
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_context_core_accessors

type 'persistence_error checkpoint_write_error =
  | Tool_history_invalid of Keeper_compaction_unit.structural_error
  | Persistence_error of 'persistence_error

let checkpoint_write_error_to_string ~persistence_error_to_string = function
  | Tool_history_invalid error ->
    "tool history invalid: " ^ Keeper_compaction_unit.show_structural_error error
  | Persistence_error error -> persistence_error_to_string error
;;

let resume_checkpoint_of_context (ctx : working_context) : Agent_sdk.Checkpoint.t =
  let checkpoint_context = Agent_sdk.Context.copy ~eio:true (oas_context_of_context ctx) in
  {
    ctx.checkpoint with
    version = Agent_sdk.Checkpoint.checkpoint_version;
    system_prompt = Some (system_prompt_of_context ctx);
    messages = messages_of_context ctx;
    context = checkpoint_context;
  }

let context_of_oas_checkpoint (cp : Agent_sdk.Checkpoint.t) : working_context =
  let system_prompt = Option.value ~default:"" cp.system_prompt in
  let messages = cp.messages in
  let context = Agent_sdk.Context.copy ~eio:true cp.context in
  let checkpoint =
    { cp with system_prompt = Some system_prompt; messages; context }
  in
  sync_oas_context { checkpoint }

let checkpoint_for_persistence
    ~(multimodal_policy : Keeper_types_profile.multimodal_policy)
    ~(keeper_name : string)
    ~(session : session_context)
    ~(agent_name : string)
    ~(ctx : working_context)
    ~(generation : int)
  : (Agent_sdk.Checkpoint.t, Keeper_compaction_unit.structural_error) result =
  let checkpoint_context = Agent_sdk.Context.copy ~eio:true (oas_context_of_context ctx) in
  Agent_sdk.Context.set_scoped checkpoint_context Agent_sdk.Context.Session
    Keeper_checkpoint_store.keeper_generation_context_key (`Int generation);
  let checkpoint_messages = messages_of_context ctx in
  (* RFC vision-delegation §2.3 site 2 (checkpoint write boundary). For a
     Delegate keeper, evict any inline image to a handle-only placeholder BEFORE
     it is persisted, so a reloaded checkpoint can never re-materialise an
     [Image] and re-trigger the RFC-0265 reroute. Store-only here — checkpoint
     writes must not block the turn fiber on a vision provider call (eager
     extraction is site 1's job). Also the migration path for images persisted
     by pre-existing checkpoints. No-op for Inherit/Reroute (safe-by-default).
     [multimodal_policy]/[keeper_name] are required so every checkpoint write
     path is compiler-forced to declare its policy (N-of-M closure). *)
  let checkpoint_messages =
    List.map
      (Keeper_vision_ingest.evict_message
         ~mode:Keeper_vision_ingest.Store_only
         ~policy:multimodal_policy
         ~keeper_name)
      checkpoint_messages
  in
  match Keeper_compaction_unit.validate checkpoint_messages with
  | Error _ as error -> error
  | Ok () ->
    Ok
      {
        ctx.checkpoint with
        version = Agent_sdk.Checkpoint.checkpoint_version;
        session_id = session.session_id;
        agent_name;
        model = Boundary_redaction.to_string Boundary_redaction.runtime_model_label;
        system_prompt = Some (system_prompt_of_context ctx);
        messages = checkpoint_messages;
        created_at = Time_compat.now ();
        context = checkpoint_context;
      }

let save_oas_checkpoint_classified
    ~multimodal_policy
    ~keeper_name
    ~session
    ~agent_name
    ~ctx
    ~generation
  =
  match
    checkpoint_for_persistence
      ~multimodal_policy
      ~keeper_name
      ~session
      ~agent_name
      ~ctx
      ~generation
  with
  | Error error -> Error (Tool_history_invalid error)
  | Ok checkpoint ->
    (match
       Keeper_checkpoint_store.save_oas_classified
         ~session_dir:session.session_dir
         checkpoint
     with
     | Ok outcome -> Ok (checkpoint, outcome)
     | Error error -> Error (Persistence_error error))

let save_oas_checkpoint_if_source
    ~multimodal_policy
    ~keeper_name
    ~session
    ~agent_name
    ~ctx
    ~generation
    ~expected_source_ref
  =
  match
    checkpoint_for_persistence
      ~multimodal_policy
      ~keeper_name
      ~session
      ~agent_name
      ~ctx
      ~generation
  with
  | Error error -> Error (Tool_history_invalid error)
  | Ok checkpoint ->
    (match
       Keeper_checkpoint_store.save_oas_if_source
         ~generation_fallback:generation
         ~session_dir:session.session_dir
         ~expected_source_ref
         checkpoint
     with
     | Error error -> Error (Persistence_error error)
     | Ok installed_ref ->
       Keeper_checkpoint_store.save_oas_history
         ~session_dir:session.session_dir
         checkpoint;
       Ok (checkpoint, installed_ref))

let save_oas_checkpoint
    ~multimodal_policy
    ~keeper_name
    ~session
    ~agent_name
    ~ctx
    ~generation
  =
  match
    save_oas_checkpoint_classified
      ~multimodal_policy
      ~keeper_name
      ~session
      ~agent_name
      ~ctx
      ~generation
  with
  | Ok (checkpoint, Keeper_checkpoint_store.Saved _)
  | Ok (checkpoint, Keeper_checkpoint_store.Stale_noop _) -> Ok checkpoint
  | Error e -> Error e

let checkpoint_generation (cp : Agent_sdk.Checkpoint.t) ~(fallback : int) : int =
  match
    Agent_sdk.Context.get_scoped cp.context Agent_sdk.Context.Session
      Keeper_checkpoint_store.keeper_generation_context_key
  with
  | Some (`Int value) -> value
  | Some (`Intlit raw) -> Option.value ~default:fallback (int_of_string_opt raw)
  | _ -> fallback

(* ================================================================ *)
(* Checkpoint Loading                                                *)
(* ================================================================ *)

let load_context_from_checkpoint ~trace_id ~base_dir =
  let session = create_session ~session_id:trace_id ~base_dir in
  let oas_result =
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:trace_id
  in
  (match oas_result with
   | Error (Parse_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_parse))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint parse error: %s" trace_id detail
   | Error (Store_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_store))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint store error: %s" trace_id detail
   | Error (Io_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_io))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint I/O error: %s" trace_id detail
   | Error (Sdk_other_error detail) ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string CheckpointFailures)
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_sdk))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint SDK error: %s" trace_id detail
   | Error Not_found ->
       Log.Keeper.debug "keeper:%s OAS checkpoint not found" trace_id
   | Ok _ -> ());
  let oas_checkpoint =
    (match oas_result with
     | Ok v -> Some v
     | Error Not_found -> None
     | Error _ ->
       Log.Keeper.warn
         "keeper:%s OAS checkpoint unavailable after explicit load diagnostics"
         trace_id;
       None)
  in
  match oas_checkpoint with
  | Some checkpoint ->
      let ctx = context_of_oas_checkpoint checkpoint in
      (session, Some ctx)
  | None ->
      (* No canonical OAS checkpoint is available. Non-trivial OAS errors
         were already logged above at error level. *)
      (session, None)

(** Patch an OAS checkpoint: unify session_id and normalize the last assistant
    message's visible text. OAS-owned internal replay blocks (reasoning/tool blocks) stay
    typed content blocks; MASC only edits the visible text projection. New
    writes keep the checkpoint [working_context] empty. *)
let patch_checkpoint_last_assistant
    (cp : Agent_sdk.Checkpoint.t) ~session_id ~response_text
  : Agent_sdk.Checkpoint.t =
  let visible_response_text = response_text in
  let patch_assistant_message (msg : Agent_sdk.Types.message) =
    let visible_is_blank = String.trim visible_response_text = "" in
    let rec patch_content replaced acc = function
      | [] ->
          if replaced || visible_is_blank then List.rev acc
          else List.rev (Agent_sdk.Types.Text visible_response_text :: acc)
      | Agent_sdk.Types.Text _ :: rest when not replaced ->
          let acc =
            if visible_is_blank then acc
            else Agent_sdk.Types.Text visible_response_text :: acc
          in
          patch_content true acc rest
      | Agent_sdk.Types.Text _ :: rest -> patch_content replaced acc rest
      | block :: rest -> patch_content replaced (block :: acc) rest
    in
    Agent_sdk.Types.make_message
      ~role:Agent_sdk.Types.Assistant
      (patch_content false [] msg.Agent_sdk.Types.content)
  in
  let rec patch_last_assistant suffix_rev = function
    | [] -> cp.messages
    | msg :: older_rev when msg.Agent_sdk.Types.role = Agent_sdk.Types.Assistant ->
        List.rev_append older_rev (patch_assistant_message msg :: suffix_rev)
    | msg :: older_rev -> patch_last_assistant (msg :: suffix_rev) older_rev
  in
  let messages =
    patch_last_assistant [] (List.rev cp.messages)
  in
  { cp with Agent_sdk.Checkpoint.session_id;
            messages;
            working_context = None }
