(** Keeper_context_core — shared keeper context utilities.

    Accessors, JSON codecs, save/load extracted to
    [Keeper_context_core_accessors] (godfile decomp). *)

open Printf
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

let find_substring_from
    ~(haystack : string)
    ~(needle : string)
    ~(start : int) : int option =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 || start < 0 || start >= hay_len || needle_len > hay_len
  then None
  else
    let rec loop idx =
      if idx + needle_len > hay_len then None
      else if String.sub haystack idx needle_len = needle then Some idx
      else loop (idx + 1)
    in
    loop start

let strip_world_state_segments (text : string) : string =
  let needle = "## Current World State" in
  let rec loop current =
    match find_substring_from ~haystack:current ~needle ~start:0 with
    | None -> String.trim current
    | Some idx ->
        let seg_start =
          match String.rindex_from_opt current idx '\n' with
          | Some newline_idx -> newline_idx + 1
          | None -> 0
        in
        let current_len = String.length current in
        let seg_end =
          let rec scan i =
            if i >= current_len - 1 then current_len
            else if current.[i] = '\n' && current.[i + 1] = '[' then i + 1
            else scan (i + 1)
          in
          scan idx
        in
        let before = String.sub current 0 seg_start in
        let after = String.sub current seg_end (current_len - seg_end) in
        let combined =
          if before = "" then after
          else if after = "" then before
          else before ^ "\n" ^ after
        in
        loop combined
  in
  loop text

let is_ephemeral_system_context_text (text : string) : bool =
  let trimmed = String.trim text in
  String.starts_with ~prefix:"[system context]" trimmed

let sanitize_checkpoint_text_block (text : string)
  : string option * checkpoint_sanitize_stats =
  if is_ephemeral_system_context_text text then
    ( None,
      {
        empty_checkpoint_sanitize_stats with
        dropped_blocks = 1;
        dropped_chars = String.length text;
      } )
  else if has_world_state_signature text then
    let stripped = strip_world_state_segments text in
    if stripped = "" then
      ( None,
        {
          empty_checkpoint_sanitize_stats with
          dropped_blocks = 1;
          dropped_chars = String.length text;
        } )
    else if String.equal stripped text then
      (Some text, empty_checkpoint_sanitize_stats)
    else
      ( Some stripped,
        {
          empty_checkpoint_sanitize_stats with
          truncated_blocks = 1;
          truncated_chars = String.length text - String.length stripped;
        } )
  else (Some text, empty_checkpoint_sanitize_stats)

let sanitize_checkpoint_message
    (msg : Agent_sdk.Types.message)
  : Agent_sdk.Types.message option * checkpoint_sanitize_stats =
  let kept_rev, _, _, _, _, stats =
    List.fold_left
      (fun (kept_rev, kept_text_blocks, kept_text_chars,
            kept_tool_results, kept_tool_result_chars, stats) block ->
         match block with
         | Agent_sdk.Types.Text text ->
             let sanitized_text, text_stats =
               sanitize_checkpoint_text_block text
             in
             (match sanitized_text with
              | None ->
                  ( kept_rev,
                    kept_text_blocks,
                    kept_text_chars,
                    kept_tool_results, kept_tool_result_chars,
                    add_checkpoint_sanitize_stats stats text_stats )
              | Some text ->
                  if kept_text_blocks
                     >= default_max_checkpoint_text_blocks_per_message
                  then
                    ( kept_rev,
                      kept_text_blocks,
                      kept_text_chars,
                      kept_tool_results, kept_tool_result_chars,
                      add_checkpoint_sanitize_stats
                        (add_checkpoint_sanitize_stats stats text_stats)
                        {
                          empty_checkpoint_sanitize_stats with
                          dropped_blocks = 1;
                          dropped_chars = String.length text;
                        } )
                  else
                    let remaining =
                      default_max_checkpoint_text_chars_per_message
                      - kept_text_chars
                    in
                    if remaining <= 0 then
                      ( kept_rev,
                        kept_text_blocks,
                        kept_text_chars,
                        kept_tool_results, kept_tool_result_chars,
                        add_checkpoint_sanitize_stats
                          (add_checkpoint_sanitize_stats stats text_stats)
                          {
                            empty_checkpoint_sanitize_stats with
                            dropped_blocks = 1;
                            dropped_chars = String.length text;
                          } )
                    else
                      let capped_text, truncated_chars =
                        truncate_checkpoint_text ~max_chars:remaining text
                      in
                      let block_stats =
                        if truncated_chars > 0 then
                          {
                            empty_checkpoint_sanitize_stats with
                            truncated_blocks = 1;
                            truncated_chars;
                          }
                        else empty_checkpoint_sanitize_stats
                      in
                      ( Agent_sdk.Types.Text capped_text :: kept_rev,
                        kept_text_blocks + 1,
                        kept_text_chars + String.length capped_text,
                        kept_tool_results, kept_tool_result_chars,
                        add_checkpoint_sanitize_stats
                          (add_checkpoint_sanitize_stats stats text_stats)
                          block_stats ))
         | Agent_sdk.Types.ToolResult _ ->
             let result =
               match Canonical_tool.tool_result_of_block block with
               | Some result -> result
               | None ->
                   invalid_arg
                     "keeper_context_core: OAS canonical tool-result projection unavailable"
             in
             let tool_use_id = result.Canonical_tool.call_id in
             let content = result.Canonical_tool.content in
             let tool_chars = String.length content in
             if kept_tool_results
                >= default_max_checkpoint_tool_results_per_message
                || kept_tool_result_chars + tool_chars
                   > default_max_checkpoint_tool_result_total_chars
             then
               (* Over count or aggregate byte budget: stub the result.
                  The two triggers are split into separate [reason]
                  labels (and named in [stub_content]) so operators
                  reading the Otel_metric_store rate or inspecting a stubbed
                  checkpoint know which cap to revisit, and so an
                  LLM that later reads the checkpoint can tell that a
                  payload was removed (and why) rather than silently
                  reasoning over the placeholder. *)
               let stub_reason =
                 if kept_tool_results
                    >= default_max_checkpoint_tool_results_per_message
                 then "over_count"
                 else "over_aggregate_bytes"
               in
               let stub_content =
                 Printf.sprintf
                   "[tool result cleared: reason=%s tool_use_id=%s \
                    original_bytes=%d; removed by \
                    Keeper_context_core.sanitize_checkpoint_message \
                    to fit checkpoint budget]"
                   stub_reason
                   tool_use_id
                   tool_chars
               in
               let () =
                 Otel_metric_store.inc_counter
                   Otel_metric_store.metric_keeper_context_tool_result_compacted
                   ~labels:[ "action", "stubbed"; "reason", stub_reason ]
                   ()
               in
               let stub =
                 Agent_sdk.Types.ToolResult
                   { tool_use_id;
                     content = stub_content;
                     outcome = result.Canonical_tool.outcome;
                     json = None;
                     content_blocks = None }
               in
               ( stub :: kept_rev,
                 kept_text_blocks, kept_text_chars,
                 kept_tool_results + 1,
                 kept_tool_result_chars + String.length stub_content,
                 add_checkpoint_sanitize_stats stats
                   { empty_checkpoint_sanitize_stats with
                     dropped_blocks = 1;
                     dropped_chars = tool_chars } )
             else if tool_chars > default_max_checkpoint_tool_result_chars
             then
               (* Individual result too large: truncate.  The cap
                  marker already advertises truncation in the content
                  itself; the counter increment is what surfaces the
                  rate to operators without log scraping. *)
               let () =
                 Otel_metric_store.inc_counter
                   Otel_metric_store.metric_keeper_context_tool_result_compacted
                   ~labels:
                     [ "action", "truncated"; "reason", "over_single_byte" ]
                   ()
               in
               let capped =
                 String.sub content 0
                   default_max_checkpoint_tool_result_chars
                 ^ checkpoint_text_cap_marker
               in
               let block =
                 Agent_sdk.Types.ToolResult
                   { tool_use_id
                   ; content = capped
                   ; outcome = result.Canonical_tool.outcome
                   ; json = None
                   ; content_blocks = None
                   }
               in
               ( block :: kept_rev,
                 kept_text_blocks, kept_text_chars,
                 kept_tool_results + 1,
                 kept_tool_result_chars
                 + default_max_checkpoint_tool_result_chars,
                 add_checkpoint_sanitize_stats stats
                   { empty_checkpoint_sanitize_stats with
                     truncated_blocks = 1;
                     truncated_chars =
                       tool_chars
                       - default_max_checkpoint_tool_result_chars } )
             else
               (* Within budget: keep as-is *)
               ( block :: kept_rev,
                 kept_text_blocks, kept_text_chars,
                 kept_tool_results + 1,
                 kept_tool_result_chars + tool_chars,
                 stats )
         | _ ->
             ( block :: kept_rev,
               kept_text_blocks, kept_text_chars,
               kept_tool_results, kept_tool_result_chars,
               stats ))
      ([], 0, 0, 0, 0, empty_checkpoint_sanitize_stats)
      msg.content
  in
  let kept = List.rev kept_rev in
  if kept = [] then
    ( None,
      add_checkpoint_sanitize_stats stats
        { empty_checkpoint_sanitize_stats with dropped_messages = 1 } )
  else (Some { msg with content = kept }, stats)

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

let sanitize_checkpoint_messages
    (messages : Agent_sdk.Types.message list)
  : Agent_sdk.Types.message list * checkpoint_sanitize_stats =
  let messages, stats =
    List.fold_right
      (fun msg (acc, stats) ->
         let sanitized_opt, msg_stats = sanitize_checkpoint_message msg in
         let acc =
           match sanitized_opt with
           | Some sanitized -> sanitized :: acc
           | None -> acc
         in
         let stats =
           add_checkpoint_sanitize_stats stats msg_stats
         in
         (acc, stats))
      messages
      ([], empty_checkpoint_sanitize_stats)
  in
  let messages, total_stats = cap_checkpoint_messages_total_content messages in
  (messages, add_checkpoint_sanitize_stats stats total_stats)

let sanitize_oas_checkpoint
    ?(repair_orphans = true)
    (cp : Agent_sdk.Checkpoint.t)
  : Agent_sdk.Checkpoint.t * checkpoint_sanitize_stats =
  let messages, stats = sanitize_checkpoint_messages cp.messages in
  let messages, stats =
    if repair_orphans then (
      let messages, repair_stats = repair_broken_tool_call_pairs_with_stats messages in
      messages, add_checkpoint_sanitize_stats stats
        (checkpoint_stats_of_tool_pair_repair repair_stats))
    else messages, stats
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
     [Image] and re-trigger the RFC-0265 reroute. Ingestion is provider-free at
     both write boundaries. This is also the migration path for images persisted
     by pre-existing checkpoints. No-op for Inherit/Reroute (safe-by-default).
     [multimodal_policy]/[keeper_name] are required so every checkpoint write
     path is compiler-forced to declare its policy (N-of-M closure). *)
  let checkpoint_messages =
    List.map
      (Keeper_vision_ingest.evict_message
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
