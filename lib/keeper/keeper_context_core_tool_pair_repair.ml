let default_max_checkpoint_tool_result_chars = 8_000

let tool_use_ids_of_message (msg : Agent_sdk.Types.message) : string list =
  List.filter_map
    (function
      | Agent_sdk.Types.ToolUse { id; _ } -> Some id
      (* Only [ToolUse] carries a tool-use id; other blocks contribute none. *)
      | Agent_sdk.Types.Text _
      | Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.RedactedThinking _
      | Agent_sdk.Types.ToolResult _
      | Agent_sdk.Types.Image _
      | Agent_sdk.Types.Document _
      | Agent_sdk.Types.Audio _ -> None)
    msg.content

let tool_result_ids_of_message (msg : Agent_sdk.Types.message) : string list =
  List.filter_map
    (function
      | Agent_sdk.Types.ToolResult { tool_use_id; _ } -> Some tool_use_id
      (* Only [ToolResult] carries a tool_use_id reference; others contribute none. *)
      | Agent_sdk.Types.Text _
      | Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.RedactedThinking _
      | Agent_sdk.Types.ToolUse _
      | Agent_sdk.Types.Image _
      | Agent_sdk.Types.Document _
      | Agent_sdk.Types.Audio _ -> None)
    msg.content

let has_tool_result_block (msg : Agent_sdk.Types.message) : bool =
  List.exists
    (function
      | Agent_sdk.Types.ToolResult _ -> true
      (* Only [ToolResult] qualifies; other blocks are not tool-result evidence. *)
      | Agent_sdk.Types.Text _
      | Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.RedactedThinking _
      | Agent_sdk.Types.ToolUse _
      | Agent_sdk.Types.Image _
      | Agent_sdk.Types.Document _
      | Agent_sdk.Types.Audio _ -> false)
    msg.content

(** Trim messages to at most [max_count] while preserving ToolUse/ToolResult
    pairing.  Drops from the front.  If the drop point lands on a
    ToolResult whose ToolUse would be the last dropped message, advance
    the drop by 1 so the orphan ToolResult is also removed (pair stays
    together on the dropped side).  This may yield fewer than [max_count]
    messages but never creates orphans.

    Root cause of recurring "unexpected tool_use_id" errors: the previous
    implementation used [List.filteri (fun i _ -> i >= drop)] which splits
    on message index, breaking mid-pair boundaries. *)
let trim_messages_preserving_pairs
    (messages : Agent_sdk.Types.message list) ~(max_count : int)
    : Agent_sdk.Types.message list =
  let n = List.length messages in
  if n <= max_count then messages
  else
    let drop = n - max_count in
    (* If the first kept message would be an orphan ToolResult,
       drop it too so the pair stays together on the removed side. *)
    let effective_drop =
      match List.nth_opt messages drop with
      | Some msg when has_tool_result_block msg ->
          (* Advance drop to skip the orphan ToolResult *)
          drop + 1
      | _ -> drop
    in
    List.filteri (fun i _ -> i >= effective_drop) messages

let tool_result_text_of_block
    ~(tool_use_id : string)
    ~(content : string)
    ~(json : Yojson.Safe.t option) : string =
  let content = Inference_utils.sanitize_text_utf8 (String.trim content) in
  if content <> "" then content
  else
    match json with
    | Some value ->
        (* Stringify json only when it fits the per-result cap. Larger
           payloads collapse to a stub so a single orphan-repair pass
           cannot inflate one Text block to multi-MB and trigger the same
           escape-depth blow-up that motivated the artifact-store work
           (see [tool_blob_store] and the tool-output-washing series). *)
        let serialized = Yojson.Safe.to_string value in
        let len = String.length serialized in
        if len <= default_max_checkpoint_tool_result_chars then serialized
        else Printf.sprintf "[tool:json id:%s bytes:%d elided]" tool_use_id len
    | None -> Printf.sprintf "[tool result %s]" tool_use_id

let tool_use_text_of_block
    ~(tool_use_id : string)
    ~(tool_name : string)
    ~(input : Yojson.Safe.t) : string =
  let tool_name = Inference_utils.sanitize_text_utf8 (String.trim tool_name) in
  let tool_use_id =
    Inference_utils.sanitize_text_utf8 (String.trim tool_use_id)
  in
  let tool_name = if tool_name = "" then "unknown_tool" else tool_name in
  let input_json =
    Yojson.Safe.to_string input |> Inference_utils.sanitize_text_utf8
  in
  Printf.sprintf "[tool use %s %s input=%s]" tool_name tool_use_id input_json

type tool_pair_repair_stats =
  { downgraded_tool_uses : int
  ; downgraded_tool_results : int
  }

let empty_tool_pair_repair_stats =
  { downgraded_tool_uses = 0; downgraded_tool_results = 0 }

let add_tool_pair_repair_stats left right =
  { downgraded_tool_uses =
      left.downgraded_tool_uses + right.downgraded_tool_uses
  ; downgraded_tool_results =
      left.downgraded_tool_results + right.downgraded_tool_results
  }

let tool_pair_repair_stats_changed stats =
  stats.downgraded_tool_uses > 0 || stats.downgraded_tool_results > 0

let pair_repair_metadata_key = "masc.tool_pair_repair"

let pair_repair_metadata_keys =
  [ "was_fabricated"; "fabrication_source"; pair_repair_metadata_key ]

let with_pair_repair_metadata ~kind ~count (msg : Agent_sdk.Types.message) =
  let metadata =
    List.filter
      (fun (key, _) -> not (List.mem key pair_repair_metadata_keys))
      msg.metadata
  in
  { msg with
    metadata =
      [ "was_fabricated", `Bool true
      ; "fabrication_source", `String "tool_pair_repair"
      ; ( pair_repair_metadata_key
        , `Assoc
            [ "version", `Int 1
            ; "kind", `String kind
            ; "count", `Int count
            ] )
      ]
      @ metadata
  }

let repair_dangling_tool_use_messages_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  let repair_with_next
      (current : Agent_sdk.Types.message)
      (next_opt : Agent_sdk.Types.message option) =
    let next_tool_result_ids =
      match next_opt with
      | Some next -> tool_result_ids_of_message next
      | None -> []
    in
    let has_dangling =
      List.exists
        (function
          | Agent_sdk.Types.ToolUse { id; _ } ->
              not (List.mem id next_tool_result_ids)
          (* Only [ToolUse] blocks can be dangling without a paired ToolResult. *)
          | Agent_sdk.Types.Text _
          | Agent_sdk.Types.Thinking _
          | Agent_sdk.Types.RedactedThinking _
          | Agent_sdk.Types.ToolResult _
          | Agent_sdk.Types.Image _
          | Agent_sdk.Types.Document _
          | Agent_sdk.Types.Audio _ -> false)
        current.content
    in
    if not has_dangling then (current, empty_tool_pair_repair_stats)
    else
      let downgraded_tool_uses = ref 0 in
      let content =
        List.map
          (function
            | Agent_sdk.Types.ToolUse { id; name; input }
              when not (List.mem id next_tool_result_ids) ->
                incr downgraded_tool_uses;
                Agent_sdk.Types.Text
                  (tool_use_text_of_block
                     ~tool_use_id:id ~tool_name:name ~input)
            | other -> other)
          current.content
      in
      ( { current with content }
        |> with_pair_repair_metadata
             ~kind:"downgraded_tool_use"
             ~count:!downgraded_tool_uses
      , { empty_tool_pair_repair_stats with
          downgraded_tool_uses = !downgraded_tool_uses
        } )
  in
  let rec loop acc_stats acc = function
    | [] -> List.rev acc, acc_stats
    | [ current ] ->
        let repaired, repair_stats = repair_with_next current None in
        ( List.rev (repaired :: acc)
        , add_tool_pair_repair_stats acc_stats repair_stats )
    | current :: ((next :: _) as rest) ->
        let repaired, repair_stats = repair_with_next current (Some next) in
        loop
          (add_tool_pair_repair_stats acc_stats repair_stats)
          (repaired :: acc) rest
  in
  loop empty_tool_pair_repair_stats [] messages

let repair_dangling_tool_use_messages messages =
  fst (repair_dangling_tool_use_messages_with_stats messages)

let repair_orphan_tool_result_messages_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  let rec loop acc_stats prev acc = function
    | [] -> List.rev acc, acc_stats
    | msg :: rest ->
        let repaired, stats =
          if not (has_tool_result_block msg) then
            (msg, empty_tool_pair_repair_stats)
          else
            let prev_tool_use_ids =
              match prev with
              | Some previous -> tool_use_ids_of_message previous
              | None -> []
            in
            (* Anthropic validates ToolResult blocks against ToolUse blocks
               in the immediately previous message. If checkpoint capping
               drops that predecessor, the resumed history becomes invalid.
               Downgrade only the orphaned structured result blocks to
               plain text so the semantic output survives without replaying
               provider-specific tool metadata. *)
            let has_orphan =
              List.exists
                (function
                  | Agent_sdk.Types.ToolResult { tool_use_id; _ } ->
                      not (List.mem tool_use_id prev_tool_use_ids)
                  (* Only [ToolResult] can be orphaned w.r.t. prior ToolUse ids. *)
                  | Agent_sdk.Types.Text _
                  | Agent_sdk.Types.Thinking _
                  | Agent_sdk.Types.RedactedThinking _
                  | Agent_sdk.Types.ToolUse _
                  | Agent_sdk.Types.Image _
                  | Agent_sdk.Types.Document _
                  | Agent_sdk.Types.Audio _ -> false)
                msg.content
            in
            if not has_orphan then (msg, empty_tool_pair_repair_stats)
            else
              let downgraded_tool_results = ref 0 in
              let content =
                List.map
                  (function
                    | Agent_sdk.Types.ToolResult { tool_use_id; content; json; _ } ->
                        incr downgraded_tool_results;
                        Agent_sdk.Types.Text
                          (tool_result_text_of_block ~tool_use_id ~content ~json)
                    | other -> other)
                  msg.content
              in
              ( { msg with content }
                |> with_pair_repair_metadata
                     ~kind:"downgraded_tool_result"
                     ~count:!downgraded_tool_results
              , { empty_tool_pair_repair_stats with
                  downgraded_tool_results = !downgraded_tool_results
                } )
        in
        loop
          (add_tool_pair_repair_stats acc_stats stats)
          (Some repaired) (repaired :: acc) rest
  in
  loop empty_tool_pair_repair_stats None [] messages

let repair_orphan_tool_result_messages messages =
  fst (repair_orphan_tool_result_messages_with_stats messages)

let repair_broken_tool_call_pairs_with_stats
    (messages : Agent_sdk.Types.message list)
    : Agent_sdk.Types.message list * tool_pair_repair_stats =
  let messages, dangling_stats =
    repair_dangling_tool_use_messages_with_stats messages
  in
  let messages, orphan_stats = repair_orphan_tool_result_messages_with_stats messages in
  messages, add_tool_pair_repair_stats dangling_stats orphan_stats

let repair_broken_tool_call_pairs
    (messages : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  fst (repair_broken_tool_call_pairs_with_stats messages)
