type terminal_boundary_outcome =
  | Terminal_completed
  | Durable_stimulus_deferred
  | Terminal_failed of
      { failure_class : Tool_result.tool_failure_class
      ; effect_disposition : Tool_result.failure_effect_disposition
      ; diagnostic : string
      }

type host_stop =
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Terminal_tool_boundary of
      { tool_name : string
      ; outcome : terminal_boundary_outcome
      }

type dynamic_tool_result =
  { success : bool
  ; content : string
  ; content_blocks : Agent_core.Types.content_block list option
  ; abort_turn : host_stop option
  }

type dynamic_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  ; call : call_id:string -> Yojson.Safe.t -> dynamic_tool_result
  }

let dynamic_tool_bytes tools =
  List.fold_left
    (fun acc tool ->
       acc
       + String.length tool.name
       + String.length tool.description
       + String.length (Yojson.Safe.to_string tool.input_schema))
    0
    tools
;;

(* Wire schemas: Codex DynamicToolCallOutputContentItem (inputText/inputImage),
   MCP ImageContent (image/data/mimeType). Both consume the same typed producer
   result; neither may silently turn a non-text result into successful prose. *)
type content_transport = Codex | Mcp

let project_content transport ~content ~content_blocks =
  (* None is the producer's text-only result; unknown/unsupported media fail below.
     DET-OK: preserve explicit text for None; Some blocks is authoritative,
     including an empty list. *)
  let blocks = Option.value ~default:[Agent_core.Types.Text content] content_blocks in
  let text value = match transport with
    | Codex -> `Assoc ["type", `String "inputText"; "text", `String value]
    | Mcp -> `Assoc ["type", `String "text"; "text", `String value]
  in
  let unsupported kind = Error ("official-client tool result cannot deliver " ^ kind) in
  let project = function
    | Agent_core.Types.Text value -> Ok (text value)
    | Agent_core.Types.Image {media_type; data; source_type} ->
      (match transport, source_type with
       | Codex, Base64 -> Ok (`Assoc
           ["type", `String "inputImage";
            "imageUrl", `String ("data:" ^ media_type ^ ";base64," ^ data)])
       | Codex, Url -> Ok (`Assoc ["type", `String "inputImage"; "imageUrl", `String data])
       | Mcp, Base64 -> Ok (`Assoc
           ["type", `String "image"; "mimeType", `String media_type; "data", `String data])
       | (Codex | Mcp), File_id -> unsupported "file-id image content"
       | Mcp, Url -> unsupported "URL image content over MCP")
    | Agent_core.Types.Audio _ -> unsupported "audio content"
    | Agent_core.Types.Document _ -> unsupported "document content"
    | Agent_core.Types.Thinking _
    | Agent_core.Types.ReasoningDetails _
    | Agent_core.Types.RedactedThinking _ -> unsupported "reasoning content as a tool result"
    | Agent_core.Types.ToolUse _
    | Agent_core.Types.ToolResult _ -> unsupported "nested tool-call content"
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | block :: rest ->
      match project block with
      | Error detail -> Error detail
      | Ok item -> loop (item :: acc) rest
  in
  loop [] blocks

let codex_content_items = project_content Codex
let mcp_content = project_content Mcp
