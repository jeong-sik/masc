type message_digest =
  { role : Agent_core.Types.role
  ; bytes : int
  ; sha256 : string
  }

type request_digests =
  { tool_schema_sha256s : string list
  ; messages : message_digest array
  }

(* [Stdlib.compare] equates [0.0] and [-0.0], but Yojson serializes them to
   different provider bytes. Tool inputs, structured tool results, reasoning
   details, and metadata can all carry that raw JSON. Compare only those JSON
   fields again with float bits preserved: the common value-equal path still
   avoids both provider encoding and SHA-256, without calling different wire
   bytes identical. *)
let rec json_wire_equal left right =
  match left, right with
  | `Null, `Null -> true
  | `Bool left, `Bool right -> Bool.equal left right
  | `Int left, `Int right -> Int.equal left right
  | `Intlit left, `Intlit right -> String.equal left right
  | `Float left, `Float right ->
    Int64.equal (Int64.bits_of_float left) (Int64.bits_of_float right)
  | `String left, `String right -> String.equal left right
  | `Assoc left, `Assoc right ->
    List.equal
      (fun (left_key, left_value) (right_key, right_value) ->
         String.equal left_key right_key && json_wire_equal left_value right_value)
      left
      right
  | `List left, `List right | `Tuple left, `Tuple right ->
    List.equal json_wire_equal left right
  | `Variant (left_tag, left_value), `Variant (right_tag, right_value) ->
    String.equal left_tag right_tag && Option.equal json_wire_equal left_value right_value
  | ( (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _
      | `List _ | `Tuple _ | `Variant _)
    , (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _
      | `List _ | `Tuple _ | `Variant _) ) -> false
;;

let reasoning_detail_wire_equal
      (left : Agent_core.Types.reasoning_detail)
      (right : Agent_core.Types.reasoning_detail)
  =
  json_wire_equal left.raw right.raw
;;

let rec content_block_wire_equal left right =
  match left, right with
  | ( Agent_core.Types.ReasoningDetails { details = left; _ }
    , Agent_core.Types.ReasoningDetails { details = right; _ } ) ->
    List.equal reasoning_detail_wire_equal left right
  | Agent_core.Types.ToolUse { input = left; _ }, Agent_core.Types.ToolUse { input = right; _ }
    -> json_wire_equal left right
  | ( Agent_core.Types.ToolResult
        { json = left_json; content_blocks = left_blocks; _ }
    , Agent_core.Types.ToolResult
        { json = right_json; content_blocks = right_blocks; _ } ) ->
    Option.equal json_wire_equal left_json right_json
    && Option.equal (List.equal content_block_wire_equal) left_blocks right_blocks
  | Agent_core.Types.Text _, Agent_core.Types.Text _
  | Agent_core.Types.Thinking _, Agent_core.Types.Thinking _
  | Agent_core.Types.RedactedThinking _, Agent_core.Types.RedactedThinking _
  | Agent_core.Types.Image _, Agent_core.Types.Image _
  | Agent_core.Types.Document _, Agent_core.Types.Document _
  | Agent_core.Types.Audio _, Agent_core.Types.Audio _ -> true
  | ( (Agent_core.Types.Text _ | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ToolUse _ | Agent_core.Types.ToolResult _
      | Agent_core.Types.Image _ | Agent_core.Types.Document _ | Agent_core.Types.Audio _)
    , (Agent_core.Types.Text _ | Agent_core.Types.Thinking _
      | Agent_core.Types.ReasoningDetails _ | Agent_core.Types.RedactedThinking _
      | Agent_core.Types.ToolUse _ | Agent_core.Types.ToolResult _
      | Agent_core.Types.Image _ | Agent_core.Types.Document _ | Agent_core.Types.Audio _) ) ->
    false
;;

let metadata_wire_equal left right =
  List.equal
    (fun (left_key, left_value) (right_key, right_value) ->
       String.equal left_key right_key && json_wire_equal left_value right_value)
    left
    right
;;

module Message_wire_value = struct
  type t = Agent_core.Types.message

  let equal (left : t) (right : t) =
    Agent_core.Types.Message_value.equal left right
    && List.equal content_block_wire_equal left.content right.content
    && metadata_wire_equal left.metadata right.metadata
  ;;

  let hash = Agent_core.Types.Message_value.hash
end

module Message_digest_memo = Hashtbl.Make (Message_wire_value)

type digest_memo = message_digest Message_digest_memo.t

let create_digest_memo () = Message_digest_memo.create 128

let message_digest memo message =
  match Message_digest_memo.find_opt memo message with
  | Some digest -> digest
  | None ->
    let payload = Keeper_provider_input_snapshot.message_payload message in
    let digest =
      { role = message.Agent_core.Types.role
      ; bytes = String.length payload.Keeper_provider_input_snapshot.payload_bytes
      ; sha256 = payload.Keeper_provider_input_snapshot.payload_sha256
      }
    in
    Message_digest_memo.add memo message digest;
    digest
;;

let digest_request ~memo ~tools ~messages =
  { tool_schema_sha256s =
      List.map
        (fun tool ->
           (Keeper_provider_input_snapshot.tool_schema_payload tool)
             .Keeper_provider_input_snapshot.payload_sha256)
        tools
  ; messages = Array.of_list (List.map (message_digest memo) messages)
  }
;;

let message_count digests = Array.length digests.messages

type previous_request =
  | No_request_yet
  | Request_not_digested
  | Request_digested of request_digests

type message_change =
  | Appended of
      { kept : int
      ; added : int
      }
  | Tail_removed of
      { kept : int
      ; removed : int
      }
  | Block_dropped of
      { at : int
      ; dropped : int
      ; kept_after : int
      ; added : int
      }
  | Rewritten_in_place of
      { first_index : int
      ; last_index : int
      ; rewritten : int
      ; previous_bytes : int
      ; current_bytes : int
      ; first_previous_role : Agent_core.Types.role
      ; first_current_role : Agent_core.Types.role
      ; added : int
      }
  | Diverged_at of
      { index : int
      ; previous_role : Agent_core.Types.role
      ; previous_bytes : int
      ; current_role : Agent_core.Types.role
      ; current_bytes : int
      ; previous_count : int
      ; current_count : int
      }

type change =
  | First_request_of_turn
  | Previous_request_not_digested
  | Follows_previous_request of
      { messages : message_change
      ; tools_changed : bool
      }

let common_prefix_length ~previous ~current =
  let limit = Int.min (Array.length previous) (Array.length current) in
  let rec scan index =
    if index < limit && String.equal previous.(index).sha256 current.(index).sha256
    then scan (index + 1)
    else index
  in
  scan 0
;;

(* The length of the longest suffix of [previous] that is also a prefix of
   [current]. It is the Knuth-Morris-Pratt failure value at the last position
   of the sequence [current], separator, [previous]: the separator matches no
   digest, so the value never exceeds either length, and the whole scan is
   linear in the two lengths. *)
let longest_suffix_that_prefixes ~previous ~current =
  let current_count = Array.length current in
  let length = current_count + 1 + Array.length previous in
  let digest_at position =
    if position < current_count
    then Some current.(position).sha256
    else if position = current_count
    then None
    else Some previous.(position - current_count - 1).sha256
  in
  let same left right = Option.equal String.equal (digest_at left) (digest_at right) in
  let failure = Array.make length 0 in
  for position = 1 to length - 1 do
    let rec fall_back candidate =
      if candidate > 0 && not (same position candidate)
      then fall_back failure.(candidate - 1)
      else candidate
    in
    let candidate = fall_back failure.(position - 1) in
    failure.(position) <- (if same position candidate then candidate + 1 else candidate)
  done;
  failure.(length - 1)
;;

(* [from] is the first position where the two lists differ. The lists are a
   rewrite in place when no message moved: the previous list is not longer
   than the current one, and after the last differing position below
   [previous_count] at least one message is equal at the same position. That
   aligned message is what tells a rewrite apart from a shift. *)
let rewritten_in_place ~previous ~current ~from =
  let previous_count = Array.length previous in
  if previous_count > Array.length current
  then None
  else (
    let rec scan index ((rewritten, last_index, previous_bytes, current_bytes) as acc) =
      if index = previous_count
      then acc
      else if String.equal previous.(index).sha256 current.(index).sha256
      then scan (index + 1) acc
      else
        scan
          (index + 1)
          ( rewritten + 1
          , index
          , previous_bytes + previous.(index).bytes
          , current_bytes + current.(index).bytes )
    in
    let rewritten, last_index, previous_bytes, current_bytes =
      scan from (0, from, 0, 0)
    in
    if last_index < previous_count - 1
    then
      Some
        (Rewritten_in_place
           { first_index = from
           ; last_index
           ; rewritten
           ; previous_bytes
           ; current_bytes
           ; first_previous_role = previous.(from).role
           ; first_current_role = current.(from).role
           ; added = Array.length current - previous_count
           })
    else None)
;;

let classify_messages ~previous ~current =
  let previous_count = Array.length previous in
  let current_count = Array.length current in
  let common = common_prefix_length ~previous ~current in
  if common = previous_count
  then Appended { kept = previous_count; added = current_count - previous_count }
  else if common = current_count
  then Tail_removed { kept = current_count; removed = previous_count - current_count }
  else (
    (* Both lists hold a message at [common] and the two differ. A block was
       dropped at [common] when a suffix of what followed it in the previous
       request is where the current request continues; the longest such suffix
       is the smallest drop. *)
    let previous_rest = Array.sub previous common (previous_count - common) in
    let current_rest = Array.sub current common (current_count - common) in
    let kept_after =
      longest_suffix_that_prefixes ~previous:previous_rest ~current:current_rest
    in
    if kept_after > 0
    then
      Block_dropped
        { at = common
        ; dropped = Array.length previous_rest - kept_after
        ; kept_after
        ; added = Array.length current_rest - kept_after
        }
    else
      match rewritten_in_place ~previous ~current ~from:common with
      | Some change -> change
      | None ->
        Diverged_at
          { index = common
          ; previous_role = previous.(common).role
          ; previous_bytes = previous.(common).bytes
          ; current_role = current.(common).role
          ; current_bytes = current.(common).bytes
          ; previous_count
          ; current_count
          })
;;

let compare_requests ~previous ~current =
  match previous with
  | No_request_yet -> First_request_of_turn
  | Request_not_digested -> Previous_request_not_digested
  | Request_digested previous ->
    Follows_previous_request
      { messages = classify_messages ~previous:previous.messages ~current:current.messages
      ; tools_changed =
          not
            (List.equal
               String.equal
               previous.tool_schema_sha256s
               current.tool_schema_sha256s)
      }
;;

let message_change_to_json = function
  | Appended { kept; added } ->
    `Assoc [ "kind", `String "appended"; "kept", `Int kept; "added", `Int added ]
  | Tail_removed { kept; removed } ->
    `Assoc [ "kind", `String "tail_removed"; "kept", `Int kept; "removed", `Int removed ]
  | Block_dropped { at; dropped; kept_after; added } ->
    `Assoc
      [ "kind", `String "block_dropped"
      ; "at", `Int at
      ; "dropped", `Int dropped
      ; "kept_after", `Int kept_after
      ; "added", `Int added
      ]
  | Rewritten_in_place
      { first_index
      ; last_index
      ; rewritten
      ; previous_bytes
      ; current_bytes
      ; first_previous_role
      ; first_current_role
      ; added
      } ->
    `Assoc
      [ "kind", `String "rewritten_in_place"
      ; "first_index", `Int first_index
      ; "last_index", `Int last_index
      ; "rewritten", `Int rewritten
      ; "previous_bytes", `Int previous_bytes
      ; "current_bytes", `Int current_bytes
      ; "first_previous_role", `String (Agent_core.Types.role_to_string first_previous_role)
      ; "first_current_role", `String (Agent_core.Types.role_to_string first_current_role)
      ; "added", `Int added
      ]
  | Diverged_at
      { index
      ; previous_role
      ; previous_bytes
      ; current_role
      ; current_bytes
      ; previous_count
      ; current_count
      } ->
    `Assoc
      [ "kind", `String "diverged_at"
      ; "index", `Int index
      ; "previous_role", `String (Agent_core.Types.role_to_string previous_role)
      ; "previous_bytes", `Int previous_bytes
      ; "current_role", `String (Agent_core.Types.role_to_string current_role)
      ; "current_bytes", `Int current_bytes
      ; "previous_count", `Int previous_count
      ; "current_count", `Int current_count
      ]
;;

let change_to_json = function
  | First_request_of_turn -> `Assoc [ "kind", `String "first_request_of_turn" ]
  | Previous_request_not_digested ->
    `Assoc [ "kind", `String "previous_request_not_digested" ]
  | Follows_previous_request { messages; tools_changed } ->
    `Assoc
      [ "kind", `String "follows_previous_request"
      ; "messages", message_change_to_json messages
      ; "tools_changed", `Bool tools_changed
      ]
;;
