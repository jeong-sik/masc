open Result.Syntax

type catalog_error =
  | Tool_missing
  | Tool_ambiguous
  | Invalid_input_schema of string

type reply_error =
  | Tool_reported_error
  | Invalid_reply_shape of string
  | Nontext_content of int
  | Empty_markdown

let tool_name = "convert_to_markdown"

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None

let validate_input_schema schema =
  let* schema = Lane_addon_json.canonical schema
      |> Result.map_error (fun detail -> Invalid_input_schema detail) in
  let uri = Option.bind (member "properties" schema) (member "uri") in
  match member "type" schema, member "required" schema,
        Option.bind uri (member "type") with
  | Some (`String "object"), Some (`List [`String "uri"]), Some (`String "string") -> Ok ()
  | _ -> Error (Invalid_input_schema
      "convert_to_markdown must require only one string uri in an object")

let validate_catalog tools =
  match List.filter (fun (tool : Agent_core_protocol.Mcp_schema.Sdk_types.tool) ->
      String.equal tool.name tool_name) tools with
  | [] -> Error Tool_missing
  | [tool] -> validate_input_schema tool.input_schema
  | _ :: _ :: _ -> Error Tool_ambiguous

let markdown reply =
  let json = Keeper_media_reading_reply.reply_json reply in
  let* () = match member "isError" json with
    | Some (`Bool true) -> Error Tool_reported_error
    | None | Some (`Bool false) -> Ok ()
    | Some (`Null | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) ->
      Error (Invalid_reply_shape "isError is not a boolean") in
  let* content = match member "content" json with
    | Some (`List content) -> Ok content
    | None | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
      Error (Invalid_reply_shape "content is not an array") in
  let rec texts index reversed = function
    | [] -> Ok (List.rev reversed)
    | block :: rest ->
      (match member "type" block, member "text" block with
       | Some (`String "text"), Some (`String text) ->
         texts (index + 1) (text :: reversed) rest
       | Some (`String "text"), _ ->
         Error (Invalid_reply_shape "text content has no string text")
       | Some (`String _), _ -> Error (Nontext_content index)
       | _ -> Error (Invalid_reply_shape "content block has no string type")) in
  let* parts = texts 0 [] content in
  let text = String.concat "\n\n" parts in
  if String.trim text = "" then Error Empty_markdown else Ok text
