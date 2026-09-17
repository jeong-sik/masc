type message_digest =
  { role : Agent_core.Types.role
  ; bytes : int
  ; sha256 : string
  }

type request_digests =
  { system_prompt_sha256 : string option
  ; tool_schema_sha256s : string list
  ; messages : message_digest array
  }

let message_digest message =
  let payload = Keeper_provider_input_snapshot.message_payload message in
  { role = message.Agent_core.Types.role
  ; bytes = String.length payload.Keeper_provider_input_snapshot.payload_bytes
  ; sha256 = payload.Keeper_provider_input_snapshot.payload_sha256
  }
;;

let digest_request ~system_prompt ~tools ~messages =
  { system_prompt_sha256 =
      Option.map
        (fun payload -> payload.Keeper_provider_input_snapshot.payload_sha256)
        (Keeper_provider_input_snapshot.system_prompt_payload system_prompt)
  ; tool_schema_sha256s =
      List.map
        (fun tool ->
           (Keeper_provider_input_snapshot.tool_schema_payload tool)
             .Keeper_provider_input_snapshot.payload_sha256)
        tools
  ; messages = Array.of_list (List.map message_digest messages)
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
  | Front_dropped of
      { dropped : int
      ; kept : int
      ; added : int
      }
  | Tail_removed of
      { kept : int
      ; removed : int
      }
  | Rewritten_at of
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
      ; system_prompt_changed : bool
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

let classify_messages ~previous ~current =
  let previous_count = Array.length previous in
  let current_count = Array.length current in
  let common = common_prefix_length ~previous ~current in
  if common = previous_count
  then Appended { kept = previous_count; added = current_count - previous_count }
  else if common = current_count
  then Tail_removed { kept = current_count; removed = previous_count - current_count }
  else (
    (* Both lists hold a message at [common] and the two differ, so the
       previous list is not a prefix of the current one and any overlap found
       here leaves at least one message dropped. The overlap is looked for only
       when the lists already differ at their first message: with a shared
       first message the prefix a cache reuses is [common] messages long, and
       [Rewritten_at] reports that length where [Front_dropped] would not. *)
    let kept =
      if common = 0 then longest_suffix_that_prefixes ~previous ~current else 0
    in
    if kept > 0
    then
      Front_dropped
        { dropped = previous_count - kept; kept; added = current_count - kept }
    else
      Rewritten_at
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
      ; system_prompt_changed =
          not
            (Option.equal
               String.equal
               previous.system_prompt_sha256
               current.system_prompt_sha256)
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
  | Front_dropped { dropped; kept; added } ->
    `Assoc
      [ "kind", `String "front_dropped"
      ; "dropped", `Int dropped
      ; "kept", `Int kept
      ; "added", `Int added
      ]
  | Tail_removed { kept; removed } ->
    `Assoc [ "kind", `String "tail_removed"; "kept", `Int kept; "removed", `Int removed ]
  | Rewritten_at
      { index
      ; previous_role
      ; previous_bytes
      ; current_role
      ; current_bytes
      ; previous_count
      ; current_count
      } ->
    `Assoc
      [ "kind", `String "rewritten_at"
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
  | Follows_previous_request { messages; system_prompt_changed; tools_changed } ->
    `Assoc
      [ "kind", `String "follows_previous_request"
      ; "messages", message_change_to_json messages
      ; "system_prompt_changed", `Bool system_prompt_changed
      ; "tools_changed", `Bool tools_changed
      ]
;;
