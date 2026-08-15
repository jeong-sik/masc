(** Tool schemas for Tool_misc — separated to break Config dependency cycle *)

open Masc_domain

type control_operation =
  | Pause
  | Resume
  | Pause_status

let control_operations = [ Pause; Resume; Pause_status ]

let control_operation_id = function
  | Pause -> "pause"
  | Resume -> "resume"
  | Pause_status -> "pause_status"
;;

let control_schema = function
  | Pause -> Tool_descriptors_gen.masc_pause_schema
  | Resume -> Tool_descriptors_gen.masc_resume_schema
  | Pause_status -> Tool_descriptors_gen.masc_pause_status_schema
;;

let control_schemas = List.map control_schema control_operations

let web_search_schema : tool_schema =
  { name = "masc_web_search"
  ; description =
      "Search the public web. Use exact tool name WebSearch. Example input: \
       {\"query\":\"OCaml 5.2 release date\",\"limit\":5,\"includeContent\":true}. \
       Returns result.results with title, url, snippet. With includeContent:true \
       the response gains a human-readable content_text rendering of every \
       fetched page. Do not use snake_case names like web_search."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "query"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String
                          "Plain-text search query. Example: \"OCaml 5.2 release date\"." )
                    ] )
              ; ( "limit"
                , `Assoc
                    [ "type", `String "integer"
                    ; ( "description"
                      , `String "Maximum number of results to return (1-10, default 5)." )
                    ] )
              ; ( "includeContent"
                , `Assoc
                    [ "type", `String "boolean"
                    ; ( "description"
                      , `String
                          "When true, also fetch each result page and add a human-readable content_text rendering. Recommended for research." )
                    ] )
              ; ( "contentMaxChars"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Maximum fetched characters per result inside content_text."
                    ; "minimum", `Int 100
                    ; "maximum", `Int 20000
                    ; "default", `Int 4000
                    ] )
              ; ( "contentTimeout"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Per-result content fetch timeout in seconds."
                    ; "minimum", `Int 1
                    ; "maximum", `Int 60
                    ; "default", `Int 15
                    ] )
              ] )
        ; "required", `List [ `String "query" ]
        ; "additionalProperties", `Bool false
        ]
  }
;;

let web_fetch_schema : tool_schema =
  { name = "masc_web_fetch"
  ; description =
      "Fetch one web page for deeper reading. Use exact tool name WebFetch. \
       Example input: {\"url\":\"https://ocaml.org/news\",\"extractMode\":\"markdown\",\"maxChars\":5000}. \
       Returns text, title, final_url, http_status, truncated. Use after WebSearch \
       when you need a citation or full article text. Do not use snake_case names \
       like web_fetch."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "url"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "description"
                      , `String "Full URL to fetch. Example: \"https://ocaml.org/news\"." )
                    ] )
              ; ( "timeout"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Request timeout in seconds."
                    ; "minimum", `Int 1
                    ; "maximum", `Int 60
                    ; "default", `Int 15
                    ] )
              ; ( "extractMode"
                , `Assoc
                    [ "type", `String "string"
                    ; "enum", `List [ `String "markdown"; `String "text" ]
                    ; ( "description"
                      , `String
                          "Output extraction mode. markdown (default) preserves headings/lists/links; text returns flattened plain text." )
                    ; "default", `String "markdown"
                    ] )
              ; ( "maxChars"
                , `Assoc
                    [ "type", `String "integer"
                    ; "description", `String "Maximum extracted content characters to return."
                    ; "minimum", `Int 1
                    ; "maximum", `Int 100000
                    ; "default", `Int 50000
                    ] )
              ] )
        ; "required", `List [ `String "url" ]
        ; "additionalProperties", `Bool false
        ]
  }
;;

let web_schemas = [ web_search_schema; web_fetch_schema ]

(* [schemas] is the generated public misc schema set. Operator control and web
   runtime schemas use the dedicated projections above. *)
let schemas : tool_schema list = Tool_descriptors_gen.schemas

type mcp_runtime_operation =
  | Start
  | Broadcast
  | Messages

let mcp_runtime_operations = [ Start; Broadcast; Messages ]

let mcp_runtime_tool_name = function
  | Start -> "masc_start"
  | Broadcast -> "masc_broadcast"
  | Messages -> "masc_messages"
;;

let mcp_runtime_operation_of_tool_name = function
  | "masc_start" -> Some Start
  | "masc_broadcast" -> Some Broadcast
  | "masc_messages" -> Some Messages
  | _ -> None
;;

let mcp_runtime_schema operation =
  let name = mcp_runtime_tool_name operation in
  match
    List.find_opt
      (fun (schema : tool_schema) -> String.equal schema.name name)
      schemas
  with
  | Some schema -> schema
  | None -> invalid_arg ("missing MCP runtime schema: " ^ name)
;;

let mcp_runtime_schemas = List.map mcp_runtime_schema mcp_runtime_operations
