(** Keeper_context_core — shared keeper context utilities.

    Accessors, JSON codecs, save/load extracted to
    [Keeper_context_core_accessors] (godfile decomp). *)

open Printf
open Keeper_types

include Keeper_context_core_accessors
include Keeper_context_core_sanitize

let capped_checkpoint_messages_of_context
      ~(max_checkpoint_messages : int)
      (ctx : working_context)
  : Agent_sdk.Types.message list
  =
  (* Shared by checkpoint persistence and pre-dispatch resume: both paths
     must honor the load-time message cap plus content-size guards. *)
  let original_messages = messages_of_context ctx in
  let capped_messages =
    trim_messages_preserving_pairs original_messages
      ~max_count:max_checkpoint_messages
  in
  let capped_messages_were_truncated =
    List.length capped_messages < List.length original_messages
  in
  let capped_messages =
    Agent_sdk.Context_reducer.reduce
      (Agent_sdk.Context_reducer.stub_tool_results ~keep_recent:1)
      capped_messages
  in
  let capped_messages, sanitize_stats =
    sanitize_checkpoint_messages capped_messages
  in
  if capped_messages_were_truncated || checkpoint_sanitize_changed sanitize_stats
  then repair_broken_tool_call_pairs capped_messages
  else capped_messages

let resume_checkpoint_of_context
      ~(max_checkpoint_messages : int)
      (ctx : working_context) : Agent_sdk.Checkpoint.t
  =
  let checkpoint_context = Agent_sdk.Context.copy (oas_context_of_context ctx) in
  {
    ctx.checkpoint with
    version = Agent_sdk.Checkpoint.checkpoint_version;
    system_prompt = Some (system_prompt_of_context ctx);
    messages = capped_checkpoint_messages_of_context ~max_checkpoint_messages ctx;
    max_total_tokens = Some (max_tokens_of_context ctx);
    context = checkpoint_context;
  }

let checkpoint_max_tokens (cp : Agent_sdk.Checkpoint.t) ~(fallback : int) : int =
  let open Yojson.Safe.Util in
  match cp.max_total_tokens with
  | Some value -> value
  | None -> (
      match cp.working_context with
      | Some (`Assoc _ as sidecar) ->
          sidecar |> member "max_tokens" |> to_int_option
      |> Option.value ~default:fallback
      | _ -> fallback)

let context_of_oas_checkpoint
    ?(repair_orphans = true)
    ~(max_checkpoint_messages : int)
    (cp : Agent_sdk.Checkpoint.t)
    ~(primary_model_max_tokens : int) : working_context =
  let cp, _ = sanitize_oas_checkpoint ~repair_orphans cp in
  let system_prompt = Option.value ~default:"" cp.system_prompt in
  let max_tokens =
    checkpoint_max_tokens cp ~fallback:primary_model_max_tokens
  in
  let messages =
    let messages =
      trim_messages_preserving_pairs cp.messages
        ~max_count:max_checkpoint_messages
    in
    if repair_orphans then repair_broken_tool_call_pairs messages
    else messages
  in
  let context = Agent_sdk.Context.copy cp.context in
  let checkpoint =
    { cp with system_prompt = Some system_prompt; messages; context }
  in
  sync_oas_context
    { checkpoint; max_tokens }

let checkpoint_model_of_meta (meta : keeper_meta) =
  let candidates =
    meta.runtime.usage.last_model_used
    :: Keeper_model_labels.configured_model_labels_of_meta meta
  in
  match List.find_opt (fun value -> String.trim value <> "") candidates with
  | Some value -> value
  | None -> Cascade_runtime_candidate.default_local_runtime_label ()

let save_oas_checkpoint
    ~(max_checkpoint_messages : int)
    ~(session : session_context)
    ~(agent_name : string)
    ~(model : string)
    ~(ctx : working_context)
    ~(generation : int)
  : (Agent_sdk.Checkpoint.t, string) result =
  let checkpoint_context = Agent_sdk.Context.copy (oas_context_of_context ctx) in
  Agent_sdk.Context.set_scoped checkpoint_context Agent_sdk.Context.Session
    checkpoint_generation_key (`Int generation);
  let checkpoint =
    {
      ctx.checkpoint with
      version = Agent_sdk.Checkpoint.checkpoint_version;
      session_id = session.session_id;
      agent_name;
      model;
      system_prompt = Some (system_prompt_of_context ctx);
      messages = capped_checkpoint_messages_of_context ~max_checkpoint_messages ctx;
      created_at = Time_compat.now ();
      max_total_tokens = Some (max_tokens_of_context ctx);
      context = checkpoint_context;
    }
  in
  match Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir checkpoint with
  | Ok () -> Ok checkpoint
  | Error e -> Error e

let checkpoint_generation (cp : Agent_sdk.Checkpoint.t) ~(fallback : int) : int =
  let open Yojson.Safe.Util in
  match
    Agent_sdk.Context.get_scoped cp.context Agent_sdk.Context.Session
      checkpoint_generation_key
  with
  | Some (`Int value) -> value
  | Some (`Intlit raw) -> Option.value ~default:fallback (int_of_string_opt raw)
  | _ -> (
      match cp.working_context with
      | Some (`Assoc _ as sidecar) ->
          sidecar |> member "generation" |> to_int_option
          |> Option.value ~default:fallback
      | _ -> fallback)

(* ================================================================ *)
(* Checkpoint Loading                                                *)
(* ================================================================ *)

let load_context_from_checkpoint ~max_checkpoint_messages ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = create_session ~session_id:trace_id ~base_dir in
  let oas_result =
    Keeper_checkpoint_store.load_oas ~session_dir:session.session_dir
      ~session_id:trace_id
  in
  (match oas_result with
   | Error (Parse_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_parse))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint parse error: %s" trace_id detail
   | Error (Store_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_store))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint store error: %s" trace_id detail
   | Error (Io_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
         ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_io))]
         ();
       Log.Keeper.error "keeper:%s OAS checkpoint I/O error: %s" trace_id detail
   | Error (Sdk_other_error detail) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_checkpoint_failures
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
       Log.Keeper.warn "keeper:%s OAS checkpoint error discarded at sanitize to_option" trace_id;
       None)
    |> Option.map (fun checkpoint ->
      let sanitized, stats = sanitize_oas_checkpoint checkpoint in
      if checkpoint_sanitize_changed stats then begin
        Log.Keeper.info
          "keeper:%s OAS checkpoint sanitized messages: dropped_blocks=%d dropped_messages=%d dropped_chars=%d truncated_blocks=%d truncated_chars=%d"
          trace_id
          stats.dropped_blocks
          stats.dropped_messages
          stats.dropped_chars
          stats.truncated_blocks
          stats.truncated_chars;
        (match Keeper_checkpoint_store.save_oas ~session_dir:session.session_dir sanitized with
         | Ok () -> ()
         | Error detail ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_checkpoint_failures
               ~labels:[("operation", Keeper_checkpoint_failure_operation.(to_label Oas_sanitize_save))]
               ();
             Log.Keeper.error
               "keeper:%s OAS checkpoint sanitize save failed: %s"
               trace_id detail)
      end;
      sanitized)
  in
  match oas_checkpoint with
  | Some checkpoint ->
      let ctx =
        context_of_oas_checkpoint ~max_checkpoint_messages checkpoint ~primary_model_max_tokens
      in
      let ctx =
        if primary_model_max_tokens <= 0 then ctx
        else sync_oas_context { ctx with max_tokens = primary_model_max_tokens }
      in
      (session, Some ctx)
  | None ->
      (* No canonical OAS checkpoint is available. Non-trivial OAS errors
         were already logged above at error level. *)
      (session, None)

(** Patch an OAS checkpoint: unify session_id and replace the last
    assistant message's text content with [response_text] and attach the
    structured replay snapshot in message metadata. New writes keep the
    checkpoint [working_context] empty. *)
let patch_checkpoint_last_assistant
    ?snapshot
    (cp : Agent_sdk.Checkpoint.t) ~session_id ~response_text
  : Agent_sdk.Checkpoint.t =
  let snapshot =
    match snapshot with
    | Some snapshot -> Some snapshot
    | None -> Keeper_memory_policy.parse_state_snapshot_from_reply response_text
  in
  let visible_response_text =
    match snapshot with
    | Some _ -> Keeper_text_processing.strip_state_blocks_text response_text
    | None -> response_text
  in
  (* Find index of last assistant message. *)
  let last_asst_idx = ref (-1) in
  List.iteri
    (fun i (msg : Agent_sdk.Types.message) ->
      if msg.role = Agent_sdk.Types.Assistant then last_asst_idx := i)
    cp.messages;
  let messages =
    if !last_asst_idx < 0 then cp.messages
    else
      List.mapi
        (fun i msg ->
          if i = !last_asst_idx then
            let metadata =
              match snapshot with
              | Some snapshot ->
                  [
                    ( Keeper_memory_policy.replay_metadata_key,
                      Keeper_memory_policy.replay_metadata_of_snapshot
                        snapshot );
                  ]
              | None -> []
            in
            Agent_sdk.Types.make_message
              ~role:Agent_sdk.Types.Assistant
              ~metadata
              [ Agent_sdk.Types.Text visible_response_text ]
          else msg)
        cp.messages
  in
  let sanitized_messages, _ = sanitize_checkpoint_messages messages in
  { cp with Agent_sdk.Checkpoint.session_id;
            messages = sanitized_messages;
            working_context = None }
