(** Closed MarkItDown MCP adapter. No storage, effects, Gate decisions or URI
    fetching occur here. Arguments come only from the verified media original. *)
type catalog_error =
  | Tool_missing
  | Tool_ambiguous
  | Invalid_input_schema of string

type reply_error =
  | Tool_reported_error
  | Invalid_reply_shape of string
  | Nontext_content of int
  | Empty_markdown

val tool_name : string
val validate_catalog :
  Agent_core_protocol.Mcp_schema.Sdk_types.tool list -> (unit, catalog_error) result
(** Require exactly one [convert_to_markdown] accepting the original's sole
    required string [uri]. The pinned server's tool is in the Channel's first
    catalog page; this is not a general paginated MCP relay. Tool annotations
    confer no authorization. *)
val markdown : Keeper_media_reading_reply.t -> (string, reply_error) result
(** Interpret only an already captured SDK value. Retain all nonempty text in
    content order. An error result, malformed result, or nontext success block
    is not a successful reading. Optional structured content/metadata remain
    in the complete Reply; no SDK inverse is used. *)
