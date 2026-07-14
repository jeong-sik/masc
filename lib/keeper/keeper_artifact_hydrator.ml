let default_keep_recent = 3

module Canonical_tool = Agent_sdk.Canonical_tool

let keep_recent_from_env () =
  match Sys.getenv_opt "MASC_TOOL_HYDRATE_RECENT" with
  | None -> default_keep_recent
  | Some s ->
      (match int_of_string_opt (String.trim s) with
       | Some n when n >= 0 -> n
       | _ -> default_keep_recent)

(* Try to fetch [sha256] from the store, returning the bytes on hit and
   the original marker string on miss / store error. *)
let try_hydrate ~store ~sha256 ~marker =
  try
    match Tool_blob_store.fetch store ~sha256 with
    | Some bytes -> Some bytes
    | None -> None
  with
  (* Issue #8619: re-raise Eio cancellation so shutdown / racing fibers
     are not silently masked as a hydration miss. Other exceptions
     (filesystem error, blob corruption) keep the prior degraded
     behaviour: caller falls back to the marker string. *)
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ ->
    ignore marker;
    None

let hydrate_block ~store ~remaining
    (block : Agent_sdk.Types.content_block) : Agent_sdk.Types.content_block =
  match block with
  | Agent_sdk.Types.ToolResult _ ->
      let result =
        match Canonical_tool.tool_result_of_block block with
        | Some result -> result
        | None ->
            invalid_arg
              "keeper_artifact_hydrator: OAS canonical tool-result projection unavailable"
      in
      if !remaining = 0 then block
      else
        (match Tool_output.decode_from_oas result.Canonical_tool.content with
         | Tool_output.Stored { sha256; _ } ->
             (match
                try_hydrate ~store ~sha256 ~marker:result.Canonical_tool.content
              with
              | Some bytes ->
                  decr remaining;
                  Agent_sdk.Types.ToolResult
                    { tool_use_id = result.Canonical_tool.call_id
                    ; content = bytes
                    ; outcome = result.Canonical_tool.outcome
                    ; json = result.Canonical_tool.structured_content
                    ; content_blocks = result.Canonical_tool.content_blocks
                    }
              | None -> block)
         | Tool_output.Inline _ -> block)
  | _ -> block

let hydrate_messages ~store ~keep_recent
    (messages : Agent_sdk.Types.message list) : Agent_sdk.Types.message list =
  let remaining = ref keep_recent in
  (* "Recent" = tail of the message list. Reverse first so iteration
     visits the LAST message first; the counter then ticks down on the
     newest Stored markers and older ones keep their markers. Reverse
     again to restore order before returning.

     Within a single message, ToolResult blocks are scanned in original
     order — multi-ToolResult messages are rare in practice and the
     newest-first preference is satisfied at the message granularity. *)
  let reversed = List.rev messages in
  let mapped =
    List.map
      (fun (msg : Agent_sdk.Types.message) ->
        let new_content =
          List.map (hydrate_block ~store ~remaining) msg.content
        in
        { msg with content = new_content })
      reversed
  in
  List.rev mapped

let hydrate_recent ~store ~keep_recent messages =
  hydrate_messages ~store ~keep_recent messages
