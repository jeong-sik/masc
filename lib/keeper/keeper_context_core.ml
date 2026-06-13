(** Keeper_context_core — shared keeper context utilities.

    Accessors, JSON codecs, save/load extracted to
    [Keeper_context_core_accessors] (godfile decomp). *)

open Printf
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

include Keeper_context_core_accessors

let add_checkpoint_sanitize_stats
    (a : checkpoint_sanitize_stats)
    (b : checkpoint_sanitize_stats) : checkpoint_sanitize_stats =
  {
    dropped_messages = a.dropped_messages + b.dropped_messages;
    dropped_blocks = a.dropped_blocks + b.dropped_blocks;
    dropped_chars = a.dropped_chars + b.dropped_chars;
    truncated_blocks = a.truncated_blocks + b.truncated_blocks;
    truncated_chars = a.truncated_chars + b.truncated_chars;
  }

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
         | Agent_sdk.Types.Thinking { content; _ } ->
             ( kept_rev,
               kept_text_blocks,
               kept_text_chars,
               kept_tool_results, kept_tool_result_chars,
               add_checkpoint_sanitize_stats stats
                 {
                   empty_checkpoint_sanitize_stats with
                   dropped_blocks = 1;
                   dropped_chars = String.length content;
                 } )
         | Agent_sdk.Types.RedactedThinking text ->
             ( kept_rev,
               kept_text_blocks,
               kept_text_chars,
               kept_tool_results, kept_tool_result_chars,
               add_checkpoint_sanitize_stats stats
                 {
                   empty_checkpoint_sanitize_stats with
                   dropped_blocks = 1;
                   dropped_chars = String.length text;
                 } )
         | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error; _ } ->
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
                     is_error;
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
                   ; is_error
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

let checkpoint_content_chars_of_block = function
  | Agent_sdk.Types.Text text -> String.length text
  | Agent_sdk.Types.Thinking { content; _ } -> String.length content
  | Agent_sdk.Types.RedactedThinking text -> String.length text
  | Agent_sdk.Types.ToolResult { content; _ } -> String.length content
  | _ -> 0

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
           | Agent_sdk.Types.ToolResult
               { tool_use_id; content; is_error; content_blocks; _ } ->
               cap_content
                 (fun content ->
                   Agent_sdk.Types.ToolResult
                     { tool_use_id; content; is_error; json = None; content_blocks })
                 content
           | Agent_sdk.Types.Thinking { content; _ } ->
               cap_content (fun text -> Agent_sdk.Types.Text text) content
           | Agent_sdk.Types.RedactedThinking text ->
               cap_content (fun text -> Agent_sdk.Types.Text text) text
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
  let messages =
    if repair_orphans then repair_broken_tool_call_pairs messages
    else messages
  in
  ({ cp with messages }, stats)

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
  match cp.max_total_tokens with
  | Some value -> value
  | None -> fallback

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

let save_oas_checkpoint
    ~(max_checkpoint_messages : int)
    ~(session : session_context)
    ~(agent_name : string)
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
      model = "runtime";
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

let load_context_from_checkpoint ~max_checkpoint_messages ~trace_id ~primary_model_max_tokens ~base_dir =
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
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string CheckpointFailures)
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
