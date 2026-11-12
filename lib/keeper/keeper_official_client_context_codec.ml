let schema = "masc.official-client-context-message.v4"

let rec content_block_to_json = function
  | Agent_core.Types.Text text ->
    `Assoc [ "type", `String "text"; "text", `String text ]
  | Thinking { content; signature } ->
    `Assoc
      ([ "type", `String "thinking"; "thinking", `String content ]
       @
       match signature with
       | None -> []
       | Some value -> [ "signature", `String value ])
  | ReasoningDetails { reasoning_content; details } ->
    `Assoc
      ([ ( "details"
         , `List
             (List.map
                (fun (detail : Agent_core.Types.reasoning_detail) -> detail.raw)
                details) )
       ; "type", `String "reasoning_details"
       ]
       @
       match reasoning_content with
       | None -> []
       | Some value -> [ "reasoning_content", `String value ])
  | RedactedThinking data ->
    `Assoc [ "type", `String "redacted_thinking"; "data", `String data ]
  | ToolUse { id; name; input } ->
    `Assoc
      [ "type", `String "tool_use"
      ; "id", `String id
      ; "name", `String name
      ; "input", input
      ]
  | ToolResult { tool_use_id; content; outcome; json; content_blocks } ->
    let content =
      match content_blocks with
      | None -> `String content
      | Some blocks -> `List (List.map content_block_to_json blocks)
    in
    let structured_content =
      match json with
      | None -> []
      | Some value -> [ "structured_content", value ]
    in
    let failure =
      match outcome with
      | Agent_core.Types.Tool_succeeded -> []
      | Tool_failed { failure_kind; error_class } ->
        [ "failure_kind", Agent_core.Types.tool_failure_kind_to_yojson failure_kind ]
        @ (match error_class with
           | None -> []
           | Some value ->
             [ "error_class", Agent_core.Types.tool_error_class_to_yojson value ])
    in
    `Assoc
      ([ "type", `String "tool_result"
       ; "tool_use_id", `String tool_use_id
       ; "content", content
       ; "is_error", `Bool (Agent_core.Types.tool_result_outcome_is_error outcome)
       ]
       @ structured_content
       @ failure)
  (* Media by reference, in the history codec's shape: a [Stored] source
     names the blob, it does not carry it. *)
  | (Image _ | Document _ | Audio _) as block -> Agent_core.History.content_block_to_json block
;;

let message_to_json (message : Agent_core.Types.message) =
  `Assoc
    [ "role", `String (Agent_core.Types.role_to_string message.role)
    ; "origin", `String (Agent_core.Types.message_origin_to_string message.origin)
    ; "content_blocks", `List (List.map content_block_to_json message.content)
    ; ( "name"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) message.name )
    ; ( "tool_call_id"
      , Option.fold ~none:`Null ~some:(fun value -> `String value) message.tool_call_id )
    ; (* The input speaker is host attribution for the Librarian (RFC-0468
         §3.2). The official client reads this framing as prompt text and
         its snapshot hashes cover it, so the speaker stays out: the model
         never sees it and the hashes do not move with it. *)
      "metadata", `Assoc (Agent_core.Types.Input_speaker.without message.metadata)
    ]
;;

let to_json message =
  `Assoc [ "schema", `String schema; "message", message_to_json message ]
;;

let encode message = to_json message |> Yojson.Safe.to_string

(* The digest is taken over the whole canonical history as one JSON text, so
   its cost follows the history's size: mapping every message, writing the
   text and hashing it. A Keeper turn asks for it once when it starts, and
   doing that on the turn's own fiber kept every other fiber of its domain
   waiting -- on the server's main domain this one call site was 10% of the
   bytes the domain allocated (2026-11-12, 45 s). The fiber hands the work to
   the CPU pool and waits. It reads nothing but its arguments. A caller that
   is not a fiber, or a process with no pool, digests where it is.

   The text is the one both callers wrote before this function existed, field
   for field: a stored session is compared against this digest, and another
   spelling would read every stored session as a changed context. *)
let canonical_source_sha256 ~system_prompt ~messages ~rest =
  Domain_pool_ref.submit_cpu_or_inline ~name:"official-client-canonical-source-digest"
    (fun () ->
      `Assoc
        (("system_prompt", `String system_prompt)
         :: ("messages", `List (List.map to_json messages))
         :: rest)
      |> Yojson.Safe.to_string
      |> Agent_core_sha256.digest_string
      |> Agent_core_sha256.to_hex)
;;
