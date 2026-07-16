(** Keeper_context_core — shared keeper context utilities.

    Accessors, JSON codecs, save/load extracted to
    [Keeper_context_core_accessors] (godfile decomp). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_context_core_accessors

module Canonical_tool = Agent_sdk.Canonical_tool

let add_checkpoint_sanitize_stats
    (a : checkpoint_sanitize_stats)
    (b : checkpoint_sanitize_stats) : checkpoint_sanitize_stats =
  {
    dropped_messages = a.dropped_messages + b.dropped_messages;
    dropped_blocks = a.dropped_blocks + b.dropped_blocks;
    dropped_chars = a.dropped_chars + b.dropped_chars;
    truncated_blocks = a.truncated_blocks + b.truncated_blocks;
    truncated_chars = a.truncated_chars + b.truncated_chars;
    tool_pair_repair =
      add_tool_pair_repair_stats a.tool_pair_repair b.tool_pair_repair;
  }

let checkpoint_stats_of_tool_pair_repair repair_stats =
  { empty_checkpoint_sanitize_stats with tool_pair_repair = repair_stats }

let tool_pair_repair_stats_to_json (stats : tool_pair_repair_stats) =
  let tool_use_samples =
    List.map
      (fun (tool_use_id, tool_name) ->
         `Assoc
           [ "tool_use_id", `String tool_use_id
           ; "tool_name", `String tool_name
           ])
      stats.dropped_tool_use_samples
  in
  let tool_result_ids =
    List.map (fun tool_use_id -> `String tool_use_id) stats.dropped_tool_result_ids
  in
  `Assoc
    [ "dropped_tool_uses", `Int stats.dropped_tool_uses
    ; "dropped_tool_results", `Int stats.dropped_tool_results
    ; "dropped_tool_use_samples", `List tool_use_samples
    ; "dropped_tool_result_ids", `List tool_result_ids
    ]

let truncate_checkpoint_text ~max_chars (text : string) : string * int =
  let len = String.length text in
  if len <= max_chars then (text, 0)
  else if max_chars <= 0 then ("", len)
  else
    let marker_len = String.length checkpoint_text_cap_marker in
    if max_chars <= marker_len then
      (String.sub checkpoint_text_cap_marker 0 max_chars, len)
    else
      let kept = max_chars - marker_len in
      ( String.sub text 0 kept ^ checkpoint_text_cap_marker,
        len - kept )

let reasoning_details_chars
    ~(reasoning_content : string option)
    ~(details : Agent_sdk.Types.reasoning_detail list) : int =
  Agent_sdk.Types.reasoning_details_text ~reasoning_content ~details
  |> String.length

let checkpoint_content_chars_of_block block =
  match Canonical_tool.tool_result_of_block block with
  | Some result -> String.length result.Canonical_tool.content
  | None -> (
      match block with
      | Agent_sdk.Types.Text text -> String.length text
      | Agent_sdk.Types.Thinking { content; _ } -> String.length content
      | Agent_sdk.Types.ReasoningDetails { reasoning_content; details } ->
          reasoning_details_chars ~reasoning_content ~details
      | Agent_sdk.Types.RedactedThinking text -> String.length text
      | Agent_sdk.Types.ToolResult _ ->
          invalid_arg
            "keeper_context_core: OAS canonical tool-result projection unavailable"
      | _ -> 0)

let checkpoint_content_chars_of_message (msg : Agent_sdk.Types.message) : int =
  List.fold_left
    (fun total block -> total + checkpoint_content_chars_of_block block)
    0
    msg.content

let cap_checkpoint_message_to_remaining_content
    ~(remaining : int)
    (msg : Agent_sdk.Types.message)
  : Agent_sdk.Types.message option * int * checkpoint_sanitize_stats =
  let message_chars = checkpoint_content_chars_of_message msg in
  if message_chars = 0 then (Some msg, 0, empty_checkpoint_sanitize_stats)
  else if remaining <= 0 then
    ( None,
      0,
      {
        empty_checkpoint_sanitize_stats with
        dropped_messages = 1;
        dropped_chars = message_chars;
      } )
  else if message_chars <= remaining then
    (Some msg, message_chars, empty_checkpoint_sanitize_stats)
  else
    let remaining_ref = ref remaining in
    let used_ref = ref 0 in
    let kept_rev, stats =
      List.fold_left
        (fun (kept_rev, stats) block ->
           let cap_content rebuild content =
             let len = String.length content in
             if len = 0 then
               (rebuild content :: kept_rev, stats)
             else if !remaining_ref <= 0 then
               ( kept_rev,
                 add_checkpoint_sanitize_stats stats
                   {
                     empty_checkpoint_sanitize_stats with
                     dropped_blocks = 1;
                     dropped_chars = len;
                   } )
             else if len <= !remaining_ref then (
               remaining_ref := !remaining_ref - len;
               used_ref := !used_ref + len;
               (rebuild content :: kept_rev, stats))
             else
               let capped, truncated_chars =
                 truncate_checkpoint_text ~max_chars:!remaining_ref content
               in
               let capped_len = String.length capped in
               remaining_ref := 0;
               used_ref := !used_ref + capped_len;
               ( rebuild capped :: kept_rev,
                 add_checkpoint_sanitize_stats stats
                   {
                     empty_checkpoint_sanitize_stats with
                     truncated_blocks = 1;
                     truncated_chars;
                   } )
           in
           match block with
           | Agent_sdk.Types.Text text ->
               cap_content (fun text -> Agent_sdk.Types.Text text) text
           | Agent_sdk.Types.ToolResult _ ->
               let result =
                 match Canonical_tool.tool_result_of_block block with
                 | Some result -> result
                 | None ->
                     invalid_arg
                       "keeper_context_core: OAS canonical tool-result projection unavailable"
               in
               cap_content
                 (fun content ->
                   Agent_sdk.Types.ToolResult
                     { tool_use_id = result.Canonical_tool.call_id
                     ; content
                     ; outcome = result.Canonical_tool.outcome
                     ; json = None
                     ; content_blocks = result.Canonical_tool.content_blocks
                     })
                 result.Canonical_tool.content
           | Agent_sdk.Types.Thinking t ->
               let len = String.length t.content in
               if len = 0 then
                 (Agent_sdk.Types.Thinking t :: kept_rev, stats)
               else if len <= !remaining_ref then (
                 remaining_ref := !remaining_ref - len;
                 used_ref := !used_ref + len;
                 (Agent_sdk.Types.Thinking t :: kept_rev, stats))
               else
                 ( kept_rev,
                   add_checkpoint_sanitize_stats stats
                     {
                       empty_checkpoint_sanitize_stats with
                       dropped_blocks = 1;
                       dropped_chars = len;
                     } )
           | Agent_sdk.Types.ReasoningDetails r ->
               let len =
                 reasoning_details_chars
                   ~reasoning_content:r.reasoning_content
                   ~details:r.details
               in
               if len = 0 then
                 (Agent_sdk.Types.ReasoningDetails r :: kept_rev, stats)
               else if len <= !remaining_ref then (
                 remaining_ref := !remaining_ref - len;
                 used_ref := !used_ref + len;
                 (Agent_sdk.Types.ReasoningDetails r :: kept_rev, stats))
               else
                 ( kept_rev,
                   add_checkpoint_sanitize_stats stats
                     {
                       empty_checkpoint_sanitize_stats with
                       dropped_blocks = 1;
                       dropped_chars = len;
                     } )
           | Agent_sdk.Types.RedactedThinking text ->
               let len = String.length text in
               if len = 0 then
                 (Agent_sdk.Types.RedactedThinking text :: kept_rev, stats)
               else if len <= !remaining_ref then (
                 remaining_ref := !remaining_ref - len;
                 used_ref := !used_ref + len;
                 (Agent_sdk.Types.RedactedThinking text :: kept_rev, stats))
               else
                 ( kept_rev,
                   add_checkpoint_sanitize_stats stats
                     {
                       empty_checkpoint_sanitize_stats with
                       dropped_blocks = 1;
                       dropped_chars = len;
                     } )
           | _ -> (block :: kept_rev, stats))
        ([], empty_checkpoint_sanitize_stats)
        msg.content
    in
    let kept = List.rev kept_rev in
    if kept = [] then
      ( None,
        !used_ref,
        add_checkpoint_sanitize_stats stats
          { empty_checkpoint_sanitize_stats with dropped_messages = 1 } )
    else (Some { msg with content = kept }, !used_ref, stats)

let cap_checkpoint_messages_total_content
    (messages : Agent_sdk.Types.message list)
  : Agent_sdk.Types.message list * checkpoint_sanitize_stats =
  let rec loop kept remaining stats = function
    | [] -> (kept, stats)
    | msg :: older ->
        let sanitized, used, msg_stats =
          cap_checkpoint_message_to_remaining_content ~remaining msg
        in
        let kept =
          match sanitized with
          | Some msg -> msg :: kept
          | None -> kept
        in
        let remaining = max 0 (remaining - used) in
        loop
          kept
          remaining
          (add_checkpoint_sanitize_stats stats msg_stats)
          older
  in
  loop
    []
    default_max_checkpoint_content_chars_total
    empty_checkpoint_sanitize_stats
    (List.rev messages)

let sanitize_oas_checkpoint
    ?(repair_orphans = true)
    (cp : Agent_sdk.Checkpoint.t)
  : Agent_sdk.Checkpoint.t * checkpoint_sanitize_stats =
  let messages, stats =
    if repair_orphans then (
      let messages, repair_stats =
        repair_broken_tool_call_pairs_with_stats cp.messages
      in
      messages, checkpoint_stats_of_tool_pair_repair repair_stats)
    else cp.messages, empty_checkpoint_sanitize_stats
  in
  ({ cp with messages }, stats)

let resume_checkpoint_of_context (ctx : working_context) : Agent_sdk.Checkpoint.t =
  let checkpoint_context = Agent_sdk.Context.copy ~eio:true (oas_context_of_context ctx) in
  {
    ctx.checkpoint with
    version = Agent_sdk.Checkpoint.checkpoint_version;
    system_prompt = Some (system_prompt_of_context ctx);
    messages = messages_of_context ctx;
    context = checkpoint_context;
  }

(* OAS no longer persists a cumulative-token cap on the checkpoint
   (budget enforcement removed). The per-response output max_tokens is
   resolved from the model default at restore time. *)
let checkpoint_max_tokens (_cp : Agent_sdk.Checkpoint.t) ~(fallback : int) : int =
  fallback

let context_of_oas_checkpoint
    (cp : Agent_sdk.Checkpoint.t)
    ~(primary_model_max_tokens : int) : working_context =
  let system_prompt = Option.value ~default:"" cp.system_prompt in
  let max_tokens =
    checkpoint_max_tokens cp ~fallback:primary_model_max_tokens
  in
  let messages = cp.messages in
  let context = Agent_sdk.Context.copy ~eio:true cp.context in
  let checkpoint =
    { cp with system_prompt = Some system_prompt; messages; context }
  in
  sync_oas_context
    { checkpoint; max_tokens }

let save_oas_checkpoint_classified
    ~(multimodal_policy : Keeper_types_profile.multimodal_policy)
    ~(keeper_name : string)
    ~(session : session_context)
    ~(agent_name : string)
    ~(ctx : working_context)
    ~(generation : int)
  : ( Agent_sdk.Checkpoint.t * Keeper_checkpoint_store.save_oas_outcome
    , string )
    result
  =
  let checkpoint_context = Agent_sdk.Context.copy ~eio:true (oas_context_of_context ctx) in
  Agent_sdk.Context.set_scoped checkpoint_context Agent_sdk.Context.Session
    checkpoint_generation_key (`Int generation);
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
  let checkpoint =
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
  in
  match
    Keeper_checkpoint_store.save_oas_classified
      ~session_dir:session.session_dir
      checkpoint
  with
  | Ok outcome -> Ok (checkpoint, outcome)
  | Error e -> Error e

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
      checkpoint_generation_key
  with
  | Some (`Int value) -> value
  | Some (`Intlit raw) -> Option.value ~default:fallback (int_of_string_opt raw)
  | _ -> fallback

(* ================================================================ *)
(* Checkpoint Loading                                                *)
(* ================================================================ *)

let load_context_from_checkpoint ~trace_id ~primary_model_max_tokens ~base_dir =
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
      let ctx =
        context_of_oas_checkpoint checkpoint ~primary_model_max_tokens
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
