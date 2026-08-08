open Checkpoint_types
open Result_syntax

let checkpoint_version = Checkpoint_types.checkpoint_version

let context_diff_is_empty diff =
  diff.Context.added = [] && diff.removed = [] && diff.changed = []
;;

let list_sub lst start len =
  if len <= 0
  then []
  else (
    let rec drop n rest =
      if n <= 0
      then rest
      else (
        match rest with
        | [] -> []
        | _ :: tail -> drop (n - 1) tail)
    in
    let rec take n rest acc =
      if n <= 0
      then List.rev acc
      else (
        match rest with
        | [] -> List.rev acc
        | item :: tail -> take (n - 1) tail (item :: acc))
    in
    take len (drop start lst) [])
;;

let common_prefix_len left right =
  let rec loop n = function
    | x :: xs, y :: ys when x = y -> loop (n + 1) (xs, ys)
    | [], _ | _, [] -> n
    | _ :: _, _ :: _ -> n
  in
  loop 0 (left, right)
;;

let common_suffix_len left right prefix_len =
  let left_arr = Array.of_list left in
  let right_arr = Array.of_list right in
  let max_len =
    min (Array.length left_arr - prefix_len) (Array.length right_arr - prefix_len)
  in
  let rec loop n =
    if n >= max_len
    then n
    else (
      let left_idx = Array.length left_arr - 1 - n in
      let right_idx = Array.length right_arr - 1 - n in
      if left_arr.(left_idx) = right_arr.(right_idx) then loop (n + 1) else n)
  in
  loop 0
;;

let compute_message_splice before after =
  let prefix_len = common_prefix_len before after in
  let suffix_len = common_suffix_len before after prefix_len in
  let before_mid_len = List.length before - prefix_len - suffix_len in
  let after_mid_len = List.length after - prefix_len - suffix_len in
  { start_index = prefix_len
  ; delete_count = max 0 before_mid_len
  ; insert = list_sub after prefix_len (max 0 after_mid_len)
  }
;;

let apply_message_splice messages splice =
  let total = List.length messages in
  if
    splice.start_index < 0
    || splice.delete_count < 0
    || splice.start_index > total
    || splice.start_index + splice.delete_count > total
  then
    Error
      (Error.Io
         (ValidationFailed
            { detail =
                Printf.sprintf
                  "Invalid message splice: start=%d delete=%d total=%d"
                  splice.start_index
                  splice.delete_count
                  total
            }))
  else (
    let prefix = list_sub messages 0 splice.start_index in
    let suffix =
      list_sub
        messages
        (splice.start_index + splice.delete_count)
        (total - splice.start_index - splice.delete_count)
    in
    Ok (prefix @ splice.insert @ suffix))
;;

let sampling_patch_changed (before : t) (after : t) =
  before.temperature <> after.temperature
  || before.top_p <> after.top_p
  || before.top_k <> after.top_k
  || before.min_p <> after.min_p
  || before.enable_thinking <> after.enable_thinking
  || before.preserve_thinking <> after.preserve_thinking
  || before.thinking_budget <> after.thinking_budget
  || before.reasoning_effort <> after.reasoning_effort
;;

let limits_patch_changed (before : t) (after : t) =
  before.disable_parallel_tool_use <> after.disable_parallel_tool_use
  || before.response_format <> after.response_format
  || before.cache_system_prompt <> after.cache_system_prompt
;;

let delta_version = 3

let apply_context_patch ctx diff =
  let next = Context.copy ctx in
  List.iter (fun key -> Context.delete next key) diff.Context.removed;
  List.iter (fun (key, value) -> Context.set next key value) diff.Context.added;
  List.iter (fun (key, value) -> Context.set next key value) diff.Context.changed;
  next
;;

let compute_delta (before : t) (after : t) =
  let operations = ref [] in
  let push op = operations := op :: !operations in
  if
    before.session_id <> after.session_id
    || before.agent_name <> after.agent_name
    || before.model <> after.model
    || before.created_at <> after.created_at
  then
    push
      (Replace_identity
         { session_id = after.session_id
         ; agent_name = after.agent_name
         ; model = after.model
         ; created_at = after.created_at
         });
  if before.system_prompt <> after.system_prompt
  then push (Replace_system_prompt after.system_prompt);
  let message_splice = compute_message_splice before.messages after.messages in
  if message_splice.delete_count <> 0 || message_splice.insert <> []
  then push (Splice_messages message_splice);
  if before.usage <> after.usage then push (Replace_usage after.usage);
  if before.turn_count <> after.turn_count then push (Replace_turn_count after.turn_count);
  if before.tools <> after.tools then push (Replace_tools after.tools);
  if before.tool_choice <> after.tool_choice
  then push (Replace_tool_choice after.tool_choice);
  if sampling_patch_changed before after
  then
    push
      (Replace_sampling
         { temperature = after.temperature
         ; top_p = after.top_p
         ; top_k = after.top_k
         ; min_p = after.min_p
         ; enable_thinking = after.enable_thinking
         ; preserve_thinking = after.preserve_thinking
         ; thinking_budget = after.thinking_budget
         ; reasoning_effort = after.reasoning_effort
         });
  if limits_patch_changed before after
  then
    push
      (Replace_limits
         { disable_parallel_tool_use = after.disable_parallel_tool_use
         ; response_format = after.response_format
         ; cache_system_prompt = after.cache_system_prompt
         });
  let context_diff = Context.diff before.context after.context in
  if not (context_diff_is_empty context_diff) then push (Patch_context context_diff);
  if before.mcp_sessions <> after.mcp_sessions
  then push (Replace_mcp_sessions after.mcp_sessions);
  if before.working_context <> after.working_context
  then push (Replace_working_context after.working_context);
  { delta_version
  ; base_checkpoint_version = checkpoint_version
  ; base_checkpoint_hash = Checkpoint_codec.checkpoint_hash before
  ; result_checkpoint_hash = Checkpoint_codec.checkpoint_hash after
  ; created_at = after.created_at
  ; operations = List.rev !operations
  }
;;

let apply_delta base delta =
  if delta.delta_version <> delta_version
  then
    Error
      (Error.Serialization
         (VersionMismatch { expected = delta_version; got = delta.delta_version }))
  else if delta.base_checkpoint_version <> checkpoint_version
  then
    Error
      (Error.Serialization
         (VersionMismatch
            { expected = checkpoint_version; got = delta.base_checkpoint_version }))
  else
    let* () = Checkpoint_codec.validate_checkpoint base in
    if Checkpoint_codec.checkpoint_hash base <> delta.base_checkpoint_hash
    then
      Error
        (Error.Io (ValidationFailed { detail = "Checkpoint.delta base hash mismatch" }))
    else (
      let apply_op (checkpoint : t) (op : delta_op) =
        match op with
        | Replace_identity (patch : identity_patch) ->
          Ok
            { checkpoint with
              session_id = patch.session_id
            ; agent_name = patch.agent_name
            ; model = patch.model
            ; created_at = patch.created_at
            }
        | Replace_system_prompt system_prompt -> Ok { checkpoint with system_prompt }
        | Splice_messages splice ->
          let+ messages = apply_message_splice checkpoint.messages splice in
          { checkpoint with messages }
        | Replace_usage usage -> Ok { checkpoint with usage }
        | Replace_turn_count turn_count -> Ok { checkpoint with turn_count }
        | Replace_tools tools -> Ok { checkpoint with tools }
        | Replace_tool_choice tool_choice -> Ok { checkpoint with tool_choice }
        | Replace_sampling (patch : sampling_patch) ->
          Ok
            { checkpoint with
              temperature = patch.temperature
            ; top_p = patch.top_p
            ; top_k = patch.top_k
            ; min_p = patch.min_p
            ; enable_thinking = patch.enable_thinking
            ; preserve_thinking = patch.preserve_thinking
            ; thinking_budget = patch.thinking_budget
            ; reasoning_effort = patch.reasoning_effort
            }
        | Replace_limits (patch : limits_patch) ->
          Ok
            { checkpoint with
              disable_parallel_tool_use = patch.disable_parallel_tool_use
            ; response_format = patch.response_format
            ; cache_system_prompt = patch.cache_system_prompt
            }
        | Patch_context diff ->
          Ok { checkpoint with context = apply_context_patch checkpoint.context diff }
        | Replace_mcp_sessions mcp_sessions -> Ok { checkpoint with mcp_sessions }
        | Replace_working_context working_context ->
          Ok { checkpoint with working_context }
      in
      let initial = { base with context = Context.copy base.context } in
      let* checkpoint =
        List.fold_left
          (fun acc op ->
             let* checkpoint = acc in
             apply_op checkpoint op)
          (Ok initial)
          delta.operations
      in
      let* () = Checkpoint_codec.validate_checkpoint checkpoint in
      if Checkpoint_codec.checkpoint_hash checkpoint <> delta.result_checkpoint_hash
      then
        Error
          (Error.Io
             (ValidationFailed { detail = "Checkpoint.delta result hash mismatch" }))
      else Ok checkpoint)
;;
