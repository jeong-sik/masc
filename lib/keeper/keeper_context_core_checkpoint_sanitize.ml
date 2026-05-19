module History_migration = Keeper_context_core_history_migration
module Tool_pair_repair = Keeper_context_core_tool_pair_repair

let default_max_checkpoint_text_blocks_per_message = 32
let default_max_checkpoint_text_chars_per_message = 16 * 1024
let default_max_checkpoint_content_chars_total = 512 * 1024
let checkpoint_text_cap_marker = "\n[capped]"
let default_max_checkpoint_tool_result_chars =
  Tool_pair_repair.default_max_checkpoint_tool_result_chars
let default_max_checkpoint_tool_results_per_message = 20
let default_max_checkpoint_tool_result_total_chars = 200_000

type checkpoint_sanitize_stats = {
  dropped_messages : int;
  dropped_blocks : int;
  dropped_chars : int;
  truncated_blocks : int;
  truncated_chars : int;
}

let empty_checkpoint_sanitize_stats =
  {
    dropped_messages = 0;
    dropped_blocks = 0;
    dropped_chars = 0;
    truncated_blocks = 0;
    truncated_chars = 0;
  }

let checkpoint_sanitize_changed (stats : checkpoint_sanitize_stats) : bool =
  stats.dropped_messages > 0
  || stats.dropped_blocks > 0
  || stats.dropped_chars > 0
  || stats.truncated_blocks > 0
  || stats.truncated_chars > 0

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
      (String.sub text 0 kept ^ checkpoint_text_cap_marker, len - kept)

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
  else if History_migration.has_world_state_signature text then
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
      (fun ( kept_rev
           , kept_text_blocks
           , kept_text_chars
           , kept_tool_results
           , kept_tool_result_chars
           , stats ) block ->
        match block with
        | Agent_sdk.Types.Text text ->
            let sanitized_text, text_stats = sanitize_checkpoint_text_block text in
            (match sanitized_text with
             | None ->
                 ( kept_rev,
                   kept_text_blocks,
                   kept_text_chars,
                   kept_tool_results,
                   kept_tool_result_chars,
                   add_checkpoint_sanitize_stats stats text_stats )
             | Some text ->
                 if kept_text_blocks >= default_max_checkpoint_text_blocks_per_message
                 then
                   ( kept_rev,
                     kept_text_blocks,
                     kept_text_chars,
                     kept_tool_results,
                     kept_tool_result_chars,
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
                       kept_tool_results,
                       kept_tool_result_chars,
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
                       kept_tool_results,
                       kept_tool_result_chars,
                       add_checkpoint_sanitize_stats
                         (add_checkpoint_sanitize_stats stats text_stats)
                         block_stats ))
        | Agent_sdk.Types.Thinking { content; _ } ->
            ( kept_rev,
              kept_text_blocks,
              kept_text_chars,
              kept_tool_results,
              kept_tool_result_chars,
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
              kept_tool_results,
              kept_tool_result_chars,
              add_checkpoint_sanitize_stats stats
                {
                  empty_checkpoint_sanitize_stats with
                  dropped_blocks = 1;
                  dropped_chars = String.length text;
                } )
        | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error; _ } ->
            let tool_chars = String.length content in
            if
              kept_tool_results >= default_max_checkpoint_tool_results_per_message
              || kept_tool_result_chars + tool_chars
                 > default_max_checkpoint_tool_result_total_chars
            then
              let stub_content = "[tool result cleared]" in
              let stub =
                Agent_sdk.Types.ToolResult
                  { tool_use_id; content = stub_content; is_error; json = None }
              in
              ( stub :: kept_rev,
                kept_text_blocks,
                kept_text_chars,
                kept_tool_results + 1,
                kept_tool_result_chars + String.length stub_content,
                add_checkpoint_sanitize_stats stats
                  {
                    empty_checkpoint_sanitize_stats with
                    dropped_blocks = 1;
                    dropped_chars = tool_chars;
                  } )
            else if tool_chars > default_max_checkpoint_tool_result_chars then
              let capped =
                String.sub content 0 default_max_checkpoint_tool_result_chars
                ^ checkpoint_text_cap_marker
              in
              let block =
                Agent_sdk.Types.ToolResult
                  { tool_use_id; content = capped; is_error; json = None }
              in
              ( block :: kept_rev,
                kept_text_blocks,
                kept_text_chars,
                kept_tool_results + 1,
                kept_tool_result_chars + default_max_checkpoint_tool_result_chars,
                add_checkpoint_sanitize_stats stats
                  {
                    empty_checkpoint_sanitize_stats with
                    truncated_blocks = 1;
                    truncated_chars =
                      tool_chars - default_max_checkpoint_tool_result_chars;
                  } )
            else
              ( block :: kept_rev,
                kept_text_blocks,
                kept_text_chars,
                kept_tool_results + 1,
                kept_tool_result_chars + tool_chars,
                stats )
        | _ ->
            ( block :: kept_rev,
              kept_text_blocks,
              kept_text_chars,
              kept_tool_results,
              kept_tool_result_chars,
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
    0 msg.content

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
            if len = 0 then (rebuild content :: kept_rev, stats)
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
          | Agent_sdk.Types.ToolResult { tool_use_id; content; is_error; _ } ->
              cap_content
                (fun content ->
                  Agent_sdk.Types.ToolResult
                    { tool_use_id; content; is_error; json = None })
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
        let stats = add_checkpoint_sanitize_stats stats msg_stats in
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
    if repair_orphans then Tool_pair_repair.repair_broken_tool_call_pairs messages
    else messages
  in
  ({ cp with messages }, stats)
