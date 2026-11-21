let schema = "masc.official-client-context-message.v5"

type rendering =
  | Canonical_source
  | Session_start of { started_at : float }

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
  | ToolReference _ as block -> Agent_core.History.content_block_to_json block
  | (Image _ | Document _ | Audio _) as block -> Agent_core.History.content_block_to_json block
;;

(* When a Tool message's results entered the conversation, as Agent Core
   stamped it. A missing stamp is [unrecorded]: it is not guessed from turn
   boundaries or the tool-call ledger. A broken stamp is shown as broken, as a
   Librarian header shows a broken input speaker
   ([Keeper_input_speaker.header_value]), so one message does not stop a
   Start. Only a session start adds the age: the canonical source carries
   none, so its digest does not move with the clock. *)
let result_time rendering (metadata : Agent_core.Types.metadata) =
  let state name = "state", `String name in
  match Agent_core.Types.Tool_results_appended_at.classify metadata with
  | Absent -> `Assoc [ state "unrecorded" ]
  | Invalid -> `Assoc [ state "invalid" ]
  | Duplicate -> `Assoc [ state "duplicate" ]
  | Present appended_at ->
    let age =
      match rendering with
      | Canonical_source -> []
      | Session_start { started_at } ->
        let age_seconds =
          Int.max 0 (Float.to_int (Float.round (started_at -. appended_at)))
        in
        [ ( "age_at_session_start"
          , `String (Keeper_age_text.of_seconds (Float.of_int age_seconds)) )
        ; "age_seconds", `Int age_seconds
        ]
    in
    `Assoc
      ([ state "recorded"
       ; "appended_at", `String (Time_codec.rfc3339_of_unix appended_at)
       ]
       @ age)
;;

let message_to_json rendering (message : Agent_core.Types.message) =
  let result_time =
    match message.role with
    | Agent_core.Types.Tool -> [ "result_time", result_time rendering message.metadata ]
    | Agent_core.Types.System | User | Assistant -> []
  in
  `Assoc
    ([ "role", `String (Agent_core.Types.role_to_string message.role)
     ; "origin", `String (Agent_core.Types.message_origin_to_string message.origin)
     ]
     @ result_time
     @ [ "content_blocks", `List (List.map content_block_to_json message.content)
       ; ( "name"
         , Option.fold ~none:`Null ~some:(fun value -> `String value) message.name )
       ; ( "tool_call_id"
         , Option.fold ~none:`Null ~some:(fun value -> `String value) message.tool_call_id )
       ; (* Two Agent Core keys stay out. The input speaker is host
            attribution for the Librarian. The appended-at
            stamp reaches the model as [result_time] above, not as a bare Unix
            float. The official client reads this framing as prompt text and
            its snapshot hashes cover it. *)
         ( "metadata"
         , `Assoc
             (message.metadata
              |> Agent_core.Types.Input_speaker.without
              |> Agent_core.Types.Tool_results_appended_at.without) )
       ])
;;

let to_json rendering message =
  `Assoc [ "schema", `String schema; "message", message_to_json rendering message ]
;;

let encode rendering message = to_json rendering message |> Yojson.Safe.to_string

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
         :: ("messages", `List (List.map (to_json Canonical_source) messages))
         :: rest)
      |> Yojson.Safe.to_string
      |> Agent_core_sha256.digest_string
      |> Agent_core_sha256.to_hex)
;;
