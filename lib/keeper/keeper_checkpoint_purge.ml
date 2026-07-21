(* Deterministic offline checkpoint purge (RFC-0351 S1). See the .mli for the
   rule contract. The implementation works on the closed units produced by
   [Keeper_compaction_unit.partition] so a tool cycle is one indivisible item
   from the first line to the last. *)

type config =
  { dup_threshold : int
  ; keep_recent_messages : int
  ; strip_thinking : bool
  ; clear_tool_results : bool
  }

let default_config =
  { dup_threshold = 3
  ; keep_recent_messages = 20
  ; strip_thinking = true
  ; clear_tool_results = true
  }
;;

let cleared_tool_result_content =
  "[old tool result content cleared by keeper checkpoint purge]"
;;

type report =
  { messages_before : int
  ; messages_after : int
  ; duplicates_dropped : int
  ; reasoning_blocks_stripped : int
  ; reasoning_messages_dropped : int
  ; tool_results_cleared : int
  }

type purge_error =
  | Invalid_config of string
  | Invalid_input_structure of Keeper_compaction_unit.structural_error
  | Invalid_output_structure of Keeper_compaction_unit.structural_error

(* One purge work item: an ordinary message or a whole closed tool cycle.
   [flat_last] is the index of the item's last message in the original list,
   used for the count-based protected tail. *)
type item =
  { unit_ : Keeper_compaction_unit.closed_unit
  ; flat_last : int
  }

let messages_of_unit = function
  | Keeper_compaction_unit.Ordinary_message message -> [ message ]
  | Keeper_compaction_unit.Closed_tool_cycle messages -> messages
;;

let is_text_only (message : Agent_sdk.Types.message) =
  (match message.role with
   | Agent_sdk.Types.User | Agent_sdk.Types.Assistant -> true
   | Agent_sdk.Types.System | Agent_sdk.Types.Tool -> false)
  && Option.is_none message.tool_call_id
  && message.content <> []
  && List.for_all
       (function
         | Agent_sdk.Types.Text _ -> true
         | _ -> false)
       message.content
;;

let has_tool_use (message : Agent_sdk.Types.message) =
  List.exists
    (function
      | Agent_sdk.Types.ToolUse _ -> true
      | _ -> false)
    message.content
;;

(* R2: remove unsigned reasoning blocks. Signed thinking and
   [RedactedThinking] replay byte-exact on tool turns and are kept. *)
let strip_reasoning_blocks (message : Agent_sdk.Types.message) =
  let kept, stripped =
    List.fold_left
      (fun (kept, stripped) block ->
         match block with
         | Agent_sdk.Types.Thinking { signature = None; _ }
         | Agent_sdk.Types.ReasoningDetails _ -> kept, stripped + 1
         | _ -> block :: kept, stripped)
      ([], 0)
      message.content
  in
  { message with Agent_sdk.Types.content = List.rev kept }, stripped
;;

(* R3: replace a tool result's payload with the fixed marker while keeping the
   [tool_use_id] pairing and the typed delivery outcome. *)
let clear_tool_result_blocks (message : Agent_sdk.Types.message) =
  let cleared_count = ref 0 in
  let content =
    List.map
      (fun block ->
         match block with
         | Agent_sdk.Types.ToolResult
             ({ content; json; content_blocks; _ } as result) ->
           if String.equal content cleared_tool_result_content
              && Option.is_none json
              && Option.is_none content_blocks
           then block
           else (
             incr cleared_count;
             Agent_sdk.Types.ToolResult
               { result with
                 content = cleared_tool_result_content
               ; json = None
               ; content_blocks = None
               })
         | _ -> block)
      message.content
  in
  { message with Agent_sdk.Types.content }, !cleared_count
;;

(* R1 bookkeeping: positions (item indices) of every unprotected text-only
   ordinary message, grouped by the message's full derived representation. *)
let duplicate_positions_to_drop ~dup_threshold ~protected items =
  let groups : (string, int list) Hashtbl.t = Hashtbl.create 64 in
  List.iteri
    (fun position item ->
       match item.unit_ with
       | Keeper_compaction_unit.Ordinary_message message
         when (not (protected item)) && is_text_only message ->
         let key = Agent_sdk.Types.show_message message in
         let positions =
           Option.value ~default:[] (Hashtbl.find_opt groups key)
         in
         Hashtbl.replace groups key (position :: positions)
       | _ -> ())
    items;
  let dropped = Hashtbl.create 64 in
  Hashtbl.iter
    (fun _key positions ->
       if List.length positions >= dup_threshold
       then (
         (* [positions] is in reverse traversal order: the head is the last
            occurrence. Keep the first and last occurrence; drop the middle. *)
         match positions with
         | _last :: rest ->
           (match List.rev rest with
            | _first :: middle ->
              List.iter
                (fun position -> Hashtbl.replace dropped position ())
                middle
            | [] -> ())
         | [] -> ()))
    groups;
  dropped
;;

let purge_messages ~config messages =
  if config.dup_threshold < 2
  then
    Error
      (Invalid_config
         (Printf.sprintf
            "dup_threshold must be >= 2 (got %d): every group keeps its first \
             and last occurrence"
            config.dup_threshold))
  else if config.keep_recent_messages < 0
  then
    Error
      (Invalid_config
         (Printf.sprintf
            "keep_recent_messages must be >= 0 (got %d)"
            config.keep_recent_messages))
  else (
    match Keeper_compaction_unit.partition messages with
    | Error structural -> Error (Invalid_input_structure structural)
    | Ok { closed_prefix; protected_suffix } ->
      let messages_before = List.length messages in
      let items =
        let flat_index = ref (-1) in
        List.map
          (fun unit_ ->
             let unit_messages = messages_of_unit unit_ in
             flat_index := !flat_index + List.length unit_messages;
             { unit_; flat_last = !flat_index })
          closed_prefix
      in
      let protected_from = messages_before - config.keep_recent_messages in
      let protected item = item.flat_last >= protected_from in
      let dropped_positions =
        duplicate_positions_to_drop
          ~dup_threshold:config.dup_threshold
          ~protected
          items
      in
      let duplicates_dropped = Hashtbl.length dropped_positions in
      let reasoning_blocks_stripped = ref 0 in
      let reasoning_messages_dropped = ref 0 in
      let tool_results_cleared = ref 0 in
      let purge_item item =
        if protected item
        then messages_of_unit item.unit_
        else (
          match item.unit_ with
          | Keeper_compaction_unit.Ordinary_message message ->
            if config.strip_thinking
               && (match message.role with
                   | Agent_sdk.Types.Assistant -> true
                   | Agent_sdk.Types.User
                   | Agent_sdk.Types.System
                   | Agent_sdk.Types.Tool -> false)
               && not (has_tool_use message)
            then (
              let stripped_message, stripped = strip_reasoning_blocks message in
              reasoning_blocks_stripped := !reasoning_blocks_stripped + stripped;
              match stripped_message.Agent_sdk.Types.content with
              | [] ->
                incr reasoning_messages_dropped;
                []
              | _ :: _ -> [ stripped_message ])
            else [ message ]
          | Keeper_compaction_unit.Closed_tool_cycle cycle_messages ->
            if config.clear_tool_results
            then
              List.map
                (fun message ->
                   let cleared_message, cleared =
                     clear_tool_result_blocks message
                   in
                   tool_results_cleared := !tool_results_cleared + cleared;
                   cleared_message)
                cycle_messages
            else cycle_messages)
      in
      let purged_prefix =
        List.concat
          (List.filteri
             (fun position _item -> not (Hashtbl.mem dropped_positions position))
             items
           |> List.map purge_item)
      in
      let purged = purged_prefix @ protected_suffix in
      (match Keeper_compaction_unit.validate purged with
       | Error structural -> Error (Invalid_output_structure structural)
       | Ok () ->
         Ok
           ( purged
           , { messages_before
             ; messages_after = List.length purged
             ; duplicates_dropped
             ; reasoning_blocks_stripped = !reasoning_blocks_stripped
             ; reasoning_messages_dropped = !reasoning_messages_dropped
             ; tool_results_cleared = !tool_results_cleared
             } )))
;;

let purge ~config (ckpt : Agent_sdk.Checkpoint.t) =
  match purge_messages ~config ckpt.messages with
  | Error error -> Error error
  | Ok (messages, report) ->
    Ok ({ ckpt with Agent_sdk.Checkpoint.messages }, report)
;;
