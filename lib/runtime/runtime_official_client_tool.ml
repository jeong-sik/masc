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

(* The media types the Codex app-server image item accepts. The same closed set
   guards the initial images ([Runtime_codex_app_server.validate_images]), which
   reads it from here so a tool-result image and a turn image cannot be judged
   by two lists that drift apart. *)
let codex_image_media_types =
  [ "image/png"; "image/jpeg"; "image/gif"; "image/webp" ]
;;

let project_content transport ~content ~content_blocks =
  (* DET-OK: [None] is the producer's text-only result, so [content] is the payload;
     [Some] stays authoritative even when empty, and unsupported media error below. *)
  let blocks = Option.value ~default:[Agent_core.Types.Text content] content_blocks in
  let text value = match transport with
    | Codex -> `Assoc ["type", `String "inputText"; "text", `String value]
    | Mcp -> `Assoc ["type", `String "text"; "text", `String value]
  in
  let unsupported kind = Error ("official-client tool result cannot deliver " ^ kind) in
  let malformed detail = Error ("official-client tool result image " ^ detail) in
  (* Fail closed on this side of the process boundary. The producer has already
     run, so a payload the app-server or the MCP client rejects comes back as a
     turn failure seconds later, attributed to the thread rather than to the
     tool that built it -- and with the tool's effect already applied. The
     initial-image path refuses the same shapes before dispatch; a tool result
     is model input too. *)
  let base64_payload ~media_type data =
    if String.trim data = "" then malformed "carries no base64 data"
    else if String.exists (fun c -> c = '\n' || c = '\r') data
    then malformed "base64 data must not contain newlines"
    else Ok (media_type, data)
  in
  let codex_base64 ~media_type data =
    if not (List.mem media_type codex_image_media_types)
    then
      malformed
        (Printf.sprintf
           "media type %S is not one of %s"
           media_type
           (String.concat ", " codex_image_media_types))
    else base64_payload ~media_type data
  in
  let project = function
    | Agent_core.Types.Text value -> Ok (text value)
    | Agent_core.Types.Image {media_type; data; source_type} ->
      (match transport, source_type with
       | Codex, Base64 ->
         Result.map
           (fun (media_type, data) -> `Assoc
              ["type", `String "inputImage";
               "imageUrl", `String ("data:" ^ media_type ^ ";base64," ^ data)])
           (codex_base64 ~media_type data)
       | Codex, Url -> Ok (`Assoc ["type", `String "inputImage"; "imageUrl", `String data])
       (* MCP's ImageContent does not close the media-type set the way the
          app-server does, so only the payload shape is checked here. *)
       | Mcp, Base64 ->
         Result.map
           (fun (media_type, data) -> `Assoc
              ["type", `String "image"; "mimeType", `String media_type;
               "data", `String data])
           (base64_payload ~media_type data)
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
