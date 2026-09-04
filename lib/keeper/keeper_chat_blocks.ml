(** Backend mirror of dashboard/src/lib/chat-blocks.ts:parseTextToChatBlocks.

    The output JSON is intentionally identical to the dashboard's block
    shape so the dashboard can prefer server-provided blocks and skip its
    local parser. *)

type image_block = {
  src : string;
  cap : string option;
}

type link_block = {
  url : string;
  title : string;
  meta : string;
}

type text_block = { html : string }

type list_block = { items : string list }

type callout_block = {
  severity : string option;
  html : string;
}

type table_cell =
  | Cell_text of string
  | Cell_value of {
      v : string;
      num : bool option;
      muted : bool option;
    }

type table_block = {
  head : table_cell list;
  rows : table_cell list list;
}

type code_block = {
  cap : string option;
  html : string;
  source : string option;
}

type mermaid_block = {
  source : string;
  caption : string option;
}

type svg_block = {
  svg : string;
  cap : string option;
}

type voice_block = {
  secs : float option;
  wave : float list option;
  via : string option;
  size : string option;
  transcript : string option;
  src : string option;
}

type attach_block = {
  name : string;
  dims : string option;
  src : string option;
  svg : string option;
  ph : string option;
  via : string option;
  size : string option;
  data : string option;
  mime_type : string option;
  size_bytes : int option;
  kind : string option;
}

type fusion_block = {
  board_post_id : string;
  run_id : string;
}

type status_kind =
  | Continuation_checkpoint
  | Awaiting_gate_approval

type status_block = { kind : status_kind }

let status_kind_connector_text = function
  | Continuation_checkpoint ->
    "작업이 체크포인트에 저장되었습니다. 다음 주기에 이어서 처리합니다."
  | Awaiting_gate_approval ->
    "승인 대기: 외부 작업을 실행하기 전에 확인이 필요합니다."
;;

type connector_projection =
  | Connector_text of string
  | Connector_status of status_block
  | Connector_no_visible_reply

let connector_projection ~turn_outcome ~reply =
  match turn_outcome, reply with
  | Keeper_turn_outcome.Continuation_checkpoint, _ ->
    Connector_status { kind = Continuation_checkpoint }
  | Keeper_turn_outcome.Awaiting_gate_approval, _ ->
    Connector_status { kind = Awaiting_gate_approval }
  | Keeper_turn_outcome.Terminal_effect_settled, _ ->
    Connector_no_visible_reply
  | Keeper_turn_outcome.Visible_reply, Some reply ->
    let reply = String.trim reply in
    if String.equal reply ""
    then Connector_no_visible_reply
    else Connector_text reply
  | Keeper_turn_outcome.Visible_reply, None ->
    Connector_no_visible_reply
  | Keeper_turn_outcome.No_visible_reply, _ ->
    Connector_no_visible_reply
;;

type trace_tool_status =
  | Trace_tool_pending
  | Trace_tool_ok
  | Trace_tool_err

type trace_step =
  | Trace_think of {
      text : string;
      content_withheld : bool;
      ts : string option;
      agent_core_block_index : int option;
    }
  | Trace_reason of {
      text : string;
      detail : string option;
      ts : string option;
    }
  | Trace_tool of {
      name : string;
      tool_call_id : string option;
      execution_id : Ids.Execution_id.t option;
      status : trace_tool_status option;
      dur : string option;
      args : Yojson.Safe.t option;
      result : Yojson.Safe.t option;
      ts : string option;
      agent_core_block_index : int option;
    }

type trace_block =
  { trace : trace_step list
  ; omitted : int
  }

type thinking_block = {
  content : string;
  redacted : bool;
}

type chat_block =
  | Text of text_block
  | Heading of text_block
  | Unordered_list of list_block
  | Callout of callout_block
  | Table of table_block
  | Code of code_block
  | Mermaid of mermaid_block
  | Svg of svg_block
  | Voice of voice_block
  | Attach of attach_block
  | Image of image_block
  | Link of link_block
  | Fusion of fusion_block
  | Status of status_block
  | Trace of trace_block
  | Thinking of thinking_block

let escape_html raw =
  raw
  |> String.split_on_char '&'
  |> String.concat "&amp;"
  |> String.split_on_char '<'
  |> String.concat "&lt;"
  |> String.split_on_char '>'
  |> String.concat "&gt;"
  |> String.split_on_char '"'
  |> String.concat "&quot;"
  |> String.split_on_char '\''
  |> String.concat "&#39;"
;;

let image_extensions = [ "png"; "jpg"; "jpeg"; "gif"; "webp"; "svg" ];;

let path_extension pathname =
  match String.rindex_opt pathname '.' with
  | None -> ""
  | Some i ->
    let ext = String.sub pathname (i + 1) (String.length pathname - i - 1) in
    String.lowercase_ascii ext
;;

(* [Uri.of_string], [Uri.path], [Uri.host] and [path_extension] are total —
   Uri parses arbitrary strings without raising — so the previous [try]
   wrappers around these helpers guarded nothing they could name. *)
let is_image_url url =
  let uri = Uri.of_string url in
  let path = Uri.path uri in
  List.mem (path_extension path) image_extensions
;;

let hostname_title url =
  let uri = Uri.of_string url in
  let host = Option.value (Uri.host uri) ~default:url in
  let host =
    if String.length host > 4 && String.sub host 0 4 = "www."
    then String.sub host 4 (String.length host - 4)
    else host
  in
  if host = "" then url else host
;;

let standalone_url_re =
  Re.Pcre.re ~flags:[ `CASELESS ] "^https?://\\S+$" |> Re.compile |> Re.execp
;;

let is_http_url url =
  match Uri.scheme (Uri.of_string url) with
  | Some "http" | Some "https" -> true
  | _ -> false
;;

(* [Invalid_url] was removed from this vocabulary: its only producer was an
   exception arm behind [Uri.of_string], which does not raise, so the reason
   could never occur. *)
type dropped_http_url_reason =
  | Missing_scheme
  | Unsupported_scheme of string

let dropped_http_url_reason_to_string = function
  | Missing_scheme -> "missing_scheme"
  | Unsupported_scheme scheme -> "unsupported_scheme:" ^ scheme
;;

let redacted_http_url_opt ?on_drop url =
  let url = Observability_redact.redact_text url in
  let drop reason =
    Option.iter (fun f -> f reason) on_drop;
    None
  in
  match Uri.scheme (Uri.of_string url) with
  | Some "http" | Some "https" -> Some url
  | Some scheme -> drop (Unsupported_scheme scheme)
  | None -> drop Missing_scheme
;;

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix
;;

let opt_bool_field key = function
  | None -> []
  | Some value -> [ (key, `Bool value) ]
;;

let opt_float_field key = function
  | None -> []
  | Some value -> [ (key, `Float value) ]
;;

let opt_int_field key = function
  | None -> []
  | Some value -> [ (key, `Int value) ]
;;

let opt_json_field key = function
  | None -> []
  | Some value -> [ (key, value) ]
;;

let table_cell_to_yojson = function
  | Cell_text value -> `String value
  | Cell_value { v; num; muted } ->
    `Assoc
      ([ ("v", `String v) ] @ opt_bool_field "num" num @ opt_bool_field "muted" muted)
;;

let trace_tool_status_to_label = function
  | Trace_tool_pending -> "pending"
  | Trace_tool_ok -> "ok"
  | Trace_tool_err -> "err"
;;

let status_kind_to_label = function
  | Continuation_checkpoint -> "continuation_checkpoint"
  | Awaiting_gate_approval -> "external_effect_pending"
;;

let status_kind_of_label = function
  | "continuation_checkpoint" -> Some Continuation_checkpoint
  | "external_effect_pending" -> Some Awaiting_gate_approval
  | _ -> None
;;

let trace_tool_status_of_label = function
  | "pending" -> Some Trace_tool_pending
  | "ok" -> Some Trace_tool_ok
  | "err" -> Some Trace_tool_err
  | _ -> None
;;

let trace_status_to_yojson = function
  | None -> []
  | Some status -> [ ("status", `String (trace_tool_status_to_label status)) ]
;;

let trace_step_to_yojson = function
  | Trace_think { text; content_withheld; ts; agent_core_block_index } ->
    (* Mirrors the [Thinking { redacted }] wire rule: the flag is only emitted
       when true, and [text] is forced to "" at the boundary regardless of the
       in-memory record, so a caller-side bug cannot ship reasoning text behind
       a flag that claims the content was not carried. *)
    let wire_text = if content_withheld then "" else text in
    `Assoc
      ([ ("kind", `String "think"); ("text", `String wire_text) ]
       @ (if content_withheld then [ ("content_withheld", `Bool true) ] else [])
       @ Json_util.string_field_if_present "ts" ts
       @ opt_int_field "agent_core_block_index" agent_core_block_index)
  | Trace_reason { text; detail; ts } ->
    `Assoc
      ([ ("kind", `String "reason"); ("text", `String text) ]
       @ Json_util.string_field_if_present "detail" detail
       @ Json_util.string_field_if_present "ts" ts)
  | Trace_tool
      { name
      ; tool_call_id
      ; execution_id
      ; status
      ; dur
      ; args
      ; result
      ; ts
      ; agent_core_block_index
      } ->
    `Assoc
      ([ ("kind", `String "tool"); ("name", `String name) ]
       @ Json_util.string_field_if_present "tool_call_id" tool_call_id
       @ Json_util.string_field_if_present "execution_id"
           (Option.map Ids.Execution_id.to_string execution_id)
       @ trace_status_to_yojson status
       @ Json_util.string_field_if_present "dur" dur
       @ opt_json_field "args" args
       @ opt_json_field "result" result
       @ Json_util.string_field_if_present "ts" ts
       @ opt_int_field "agent_core_block_index" agent_core_block_index)
;;

let table_cell_of_yojson = function
  | `String value -> Some (Cell_text value)
  | `Assoc fields ->
    (match List.assoc_opt "v" fields with
     | Some (`String v) ->
       let bool_field key =
         match List.assoc_opt key fields with
         | Some (`Bool b) -> Some b
         | _ -> None
       in
       Some (Cell_value { v; num = bool_field "num"; muted = bool_field "muted" })
     | _ -> None)
  | _ -> None
;;

let list_all_map f items =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | item :: rest ->
      (match f item with
       | None -> None
       | Some value -> loop (value :: acc) rest)
  in
  loop [] items
;;

let string_list_of_yojson = function
  | `List items ->
    list_all_map
      (function
        | `String value -> Some value
        | _ -> None)
      items
  | _ -> None
;;

let table_cells_of_yojson = function
  | `List items -> list_all_map table_cell_of_yojson items
  | _ -> None
;;

let table_rows_of_yojson = function
  | `List rows -> list_all_map table_cells_of_yojson rows
  | _ -> None
;;

let float_list_of_yojson = function
  | `List items ->
    list_all_map
      (function
        | `Float value -> Some value
        | `Int value -> Some (float_of_int value)
        | _ -> None)
      items
  | _ -> None
;;

let line_to_block line : chat_block option =
  let trimmed = String.trim line in
  if trimmed = ""
  then None
  else if standalone_url_re trimmed && is_http_url trimmed
  then (
    if is_image_url trimmed
    then Some (Image { src = trimmed; cap = None })
    else
      Some
        (Link
           { url = trimmed
           ; title = hostname_title trimmed
           ; meta = hostname_title trimmed
           }))
  else Some (Text { html = escape_html line })
;;

let push_text_fragment acc fragment =
  fragment
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun acc line ->
          match line_to_block line with
          | None -> acc
          | Some block -> block :: acc)
       acc
;;

let md_image_re = Re.Pcre.re "!\\[([^\\]]*)\\]\\(([^)]+)\\)" |> Re.compile

let code_fence_re =
  Re.Pcre.re
    "```([A-Za-z0-9_+.#-]*)[ \t]*\r?\n([\\s\\S]*?)\r?\n```[ \t]*(?:\r?\n|$)"
  |> Re.compile

type next_match =
  | Image_match of Re.Group.t
  | Code_match of Re.Group.t

let earlier_match left right =
  match left, right with
  | None, None -> None
  | Some _, None -> left
  | None, Some _ -> right
  | Some (Image_match image), Some (Code_match code) ->
    if Re.Group.start code 0 <= Re.Group.start image 0 then right else left
  | Some (Code_match code), Some (Image_match image) ->
    if Re.Group.start code 0 <= Re.Group.start image 0 then left else right
  | Some _, Some _ -> left

let parse_text_to_blocks text : chat_block list =
  let rec scan acc last_index =
    let next_image =
      Option.map (fun group -> Image_match group) (Re.exec_opt ~pos:last_index md_image_re text)
    in
    let next_code =
      Option.map (fun group -> Code_match group) (Re.exec_opt ~pos:last_index code_fence_re text)
    in
    match earlier_match next_image next_code with
    | None ->
      push_text_fragment acc (String.sub text last_index (String.length text - last_index))
    | Some (Image_match group) ->
      let start = Re.Group.start group 0 in
      let stop = Re.Group.stop group 0 in
      let before = String.sub text last_index (start - last_index) in
      let alt = Re.Group.get group 1 in
      let url = Re.Group.get group 2 in
      let acc = push_text_fragment acc before in
      if is_http_url url then
        let cap = if String.trim alt = "" then None else Some alt in
        let acc = Image { src = url; cap } :: acc in
        scan acc stop
      else
        let fallback = String.sub text start (stop - start) in
        scan (push_text_fragment acc fallback) stop
    | Some (Code_match group) ->
      let start = Re.Group.start group 0 in
      let stop = Re.Group.stop group 0 in
      let before = String.sub text last_index (start - last_index) in
      let lang = Re.Group.get group 1 |> String.trim in
      let source = Re.Group.get group 2 in
      let cap = if lang = "" then None else Some (String.lowercase_ascii lang) in
      let acc = push_text_fragment acc before in
      let acc =
        match cap with
        | Some lang when has_prefix ~prefix:"mermaid" lang ->
          Mermaid { source; caption = None } :: acc
        | _ -> Code { cap; html = escape_html source; source = Some source } :: acc
      in
      scan acc stop
  in
  List.rev (scan [] 0)
;;

let block_to_yojson = function
  | Text { html } ->
    `Assoc [ ("t", `String "p"); ("html", `String html) ]
  | Heading { html } ->
    `Assoc [ ("t", `String "h4"); ("html", `String html) ]
  | Unordered_list { items } ->
    `Assoc
      [ ("t", `String "ul")
      ; ("items", `List (List.map (fun item -> `String item) items))
      ]
  | Callout { severity; html } ->
    `Assoc ([ ("t", `String "callout"); ("html", `String html) ]
            @ Json_util.string_field_if_present "severity" severity)
  | Table { head; rows } ->
    `Assoc
      [ ("t", `String "table")
      ; ("head", `List (List.map table_cell_to_yojson head))
      ; ( "rows"
        , `List
            (List.map
               (fun row -> `List (List.map table_cell_to_yojson row))
               rows) )
      ]
  | Code { cap; html; source } ->
    let fields = [ ("t", `String "code"); ("html", `String html) ] in
    let fields =
      match cap with
      | None -> fields
      | Some c -> fields @ [ ("cap", `String c) ]
    in
    let fields =
      match source with
      | None -> fields
      | Some s -> fields @ [ ("source", `String s) ]
    in
    `Assoc fields
  | Mermaid { source; caption } ->
    `Assoc
      ([ ("t", `String "mermaid"); ("source", `String source) ]
       @ Json_util.string_field_if_present "caption" caption)
  | Svg { svg; cap } ->
    `Assoc ([ ("t", `String "svg"); ("svg", `String svg) ] @ Json_util.string_field_if_present "cap" cap)
  | Voice { secs; wave; via; size; transcript; src } ->
    let fields =
      [ ("t", `String "voice") ]
      @ opt_float_field "secs" secs
      @ (match wave with
         | None -> []
         | Some values -> [ ("wave", `List (List.map (fun v -> `Float v) values)) ])
      @ Json_util.string_field_if_present "via" via
      @ Json_util.string_field_if_present "size" size
      @ Json_util.string_field_if_present "transcript" transcript
      @ Json_util.string_field_if_present "src" src
    in
    `Assoc fields
  | Attach { name; dims; src; svg; ph; via; size; data; mime_type; size_bytes; kind } ->
    `Assoc
      ([ ("t", `String "attach"); ("name", `String name) ]
       @ Json_util.string_field_if_present "dims" dims
       @ Json_util.string_field_if_present "src" src
       @ Json_util.string_field_if_present "svg" svg
       @ Json_util.string_field_if_present "ph" ph
       @ Json_util.string_field_if_present "via" via
       @ Json_util.string_field_if_present "size" size
       @ Json_util.string_field_if_present "data" data
       @ Json_util.string_field_if_present "mimeType" mime_type
       @ opt_int_field "sizeBytes" size_bytes
       @ Json_util.string_field_if_present "kind" kind)
  | Image { src; cap } ->
    let fields = [ ("t", `String "image"); ("src", `String src) ] in
    let fields =
      match cap with
      | None -> fields
      | Some c -> fields @ [ ("cap", `String c) ]
    in
    `Assoc fields
  | Link { url; title; meta } ->
    `Assoc
      [ ("t", `String "link")
      ; ("url", `String url)
      ; ("title", `String title)
      ; ("meta", `String meta)
      ]
  | Fusion { board_post_id; run_id } ->
    `Assoc
      [ ("t", `String "fusion")
      ; ("board_post_id", `String board_post_id)
      ; ("run_id", `String run_id)
      ]
  | Status { kind } ->
    `Assoc
      [ ("t", `String "status")
      ; ("kind", `String (status_kind_to_label kind))
      ]
  | Trace { trace; omitted } ->
    (* [omitted] is emitted only when non-zero, so a normal turn's wire shape
       is unchanged. It states how many steps this surface did not carry — a
       shorter [trace] with no count would read as a shorter turn. *)
    `Assoc
      ([ ("t", `String "trace")
       ; ("trace", `List (List.map trace_step_to_yojson trace))
       ]
       @ (if omitted > 0 then [ ("omitted", `Int omitted) ] else []))
  | Thinking { content; redacted } ->
    (* redacted defaults to false (omitted); only emit when true so the
       common non-redacted case stays minimal and legacy decoders that do
       not know "thinking" still parse the rest of the list.

       [redacted = true] is a signature-only marker: force [content] to ""
       at the wire boundary regardless of what the in-memory record holds,
       so a caller-side bug that builds [Thinking { content = <real text>;
       redacted = true }] can never persist or transmit the reasoning text
       behind a flag that claims it was scrubbed. *)
    let wire_content = if redacted then "" else content in
    let base = [ ("t", `String "thinking"); ("content", `String wire_content) ] in
    `Assoc (if redacted then base @ [ ("redacted", `Bool true) ] else base)
;;

let blocks_to_yojson blocks = `List (List.map block_to_yojson blocks)

let block_of_yojson json : chat_block option =
  match json with
  | `Assoc fields ->
    let get_string key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let get_float key =
      match List.assoc_opt key fields with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (float_of_int i)
      | _ -> None
    in
    let get_int key =
      match List.assoc_opt key fields with
      | Some (`Int i) -> Some i
      | _ -> None
    in
    let trace_step_of_yojson = function
      | `Assoc step_fields ->
        let get_step_string key =
          match List.assoc_opt key step_fields with
          | Some (`String s) -> Some s
          | _ -> None
        in
        let get_step_int key =
          match List.assoc_opt key step_fields with
          | Some (`Int i) -> Some i
          | _ -> None
        in
        let get_step_bool key =
          match List.assoc_opt key step_fields with
          | Some (`Bool b) -> b
          | _ -> false
        in
        (match get_step_string "kind" with
          | Some "think" ->
            (* "text" stays required so a payload that merely omits it is
               rejected rather than silently read as a withheld step. The
               in-memory record cannot hold text alongside the flag: a payload
               carrying both loses the text here, matching the encoder. *)
            Option.bind (get_step_string "text") (fun text ->
              let content_withheld = get_step_bool "content_withheld" in
              Some
                (Trace_think
                   { text = (if content_withheld then "" else text)
                   ; content_withheld
                   ; ts = get_step_string "ts"
                   ; agent_core_block_index =
                       (match get_step_int "agent_core_block_index" with
                        | Some _ as v -> v
                        | None -> get_step_int "agent_coreBlockIndex")
                   }))
         | Some "reason" ->
           Option.bind (get_step_string "text") (fun text ->
             Some
               (Trace_reason
                  { text
                  ; detail = get_step_string "detail"
                  ; ts = get_step_string "ts"
                  }))
          | Some "tool" ->
            Option.bind (get_step_string "name") (fun name ->
             let status =
                match get_step_string "status" with
                | None -> None
                | Some status -> trace_tool_status_of_label status
              in
             Some
               (Trace_tool
                  { name
                  ; tool_call_id =
                      (match get_step_string "tool_call_id" with
                       | Some _ as v -> v
                       | None -> get_step_string "toolCallId")
                  ; execution_id =
                      (match get_step_string "execution_id" with
                       | Some raw when String.trim raw <> "" ->
                         Some (Ids.Execution_id.of_string raw)
                       | Some _ | None -> None)
                  ; status
                  ; dur = get_step_string "dur"
                  ; args = List.assoc_opt "args" step_fields
                  ; result = List.assoc_opt "result" step_fields
                  ; ts = get_step_string "ts"
                  ; agent_core_block_index =
                      (match get_step_int "agent_core_block_index" with
                       | Some _ as v -> v
                       | None -> get_step_int "agent_coreBlockIndex")
                  }))
         | _ -> None)
      | _ -> None
    in
    let trace_steps_of_yojson = function
      | `List items -> list_all_map trace_step_of_yojson items
      | _ -> None
    in
    (match get_string "t" with
     | Some "p" ->
       Option.map (fun html -> Text { html }) (get_string "html")
     | Some "h4" ->
       Option.map (fun html -> Heading { html }) (get_string "html")
     | Some "ul" ->
       Option.bind (List.assoc_opt "items" fields) (fun items ->
         Option.bind (string_list_of_yojson items) (fun items ->
           if items = [] then None else Some (Unordered_list { items })))
     | Some "callout" ->
       Option.bind (get_string "html") (fun html ->
         let severity =
           match get_string "severity" with
           | Some ("info" | "warn" | "bad" as severity) -> Some severity
           | _ -> None
         in
         Some (Callout { severity; html }))
     | Some "table" ->
       Option.bind (List.assoc_opt "head" fields) (fun head_json ->
         Option.bind (table_cells_of_yojson head_json) (fun head ->
           Option.bind (List.assoc_opt "rows" fields) (fun rows_json ->
             Option.map (fun rows -> Table { head; rows }) (table_rows_of_yojson rows_json))))
     | Some "code" ->
       Option.bind (get_string "html") (fun html ->
         let cap = get_string "cap" in
         let source = get_string "source" in
         Some (Code { cap; html; source }))
     | Some "mermaid" ->
       Option.bind (get_string "source") (fun source ->
         Some (Mermaid { source; caption = get_string "caption" }))
     | Some "svg" ->
       Option.bind (get_string "svg") (fun svg ->
         Some (Svg { svg; cap = get_string "cap" }))
     | Some "voice" ->
       let wave =
         match List.assoc_opt "wave" fields with
         | None -> None
         | Some json -> float_list_of_yojson json
       in
       Some
         (Voice
            { secs = get_float "secs"
            ; wave
            ; via = get_string "via"
            ; size = get_string "size"
            ; transcript = get_string "transcript"
            ; src = get_string "src"
            })
     | Some "attach" ->
       Option.bind (get_string "name") (fun name ->
         Some
           (Attach
              { name
              ; dims = get_string "dims"
              ; src = get_string "src"
              ; svg = get_string "svg"
              ; ph = get_string "ph"
              ; via = get_string "via"
              ; size = get_string "size"
              ; data = get_string "data"
              ; mime_type = get_string "mimeType"
              ; size_bytes = get_int "sizeBytes"
              ; kind = get_string "kind"
              }))
     | Some "image" ->
       Option.bind (get_string "src") (fun src ->
         let cap = get_string "cap" in
         Some (Image { src; cap }))
     | Some "link" ->
       Option.bind (get_string "url") (fun url ->
         Option.bind (get_string "title") (fun title ->
           let meta = Option.value (get_string "meta") ~default:title in
           Some (Link { url; title; meta })))
     | Some "fusion" ->
       (* board_post_id is the lazy-fetch key and is required (Option.bind
          rejects its absence); run_id is a display/cross-reference convenience.
          NDT-OK / sound-partial: allow — a missing run_id degrades only the
          card's run label, not identity, so "" is sound rather than a
          permissive default over unknown input (mirrors the link arm above). *)
       Option.bind (get_string "board_post_id") (fun board_post_id ->
         let run_id = Option.value (get_string "run_id") ~default:"" in
         Some (Fusion { board_post_id; run_id }))
     | Some "status" ->
       Option.bind (get_string "kind") (fun label ->
         Option.map (fun kind -> Status { kind }) (status_kind_of_label label))
     | Some "trace" ->
       Option.bind (List.assoc_opt "trace" fields) (fun trace_json ->
         Option.bind (trace_steps_of_yojson trace_json) (fun trace ->
           if trace = []
           then None
           else (
             let omitted =
               match List.assoc_opt "omitted" fields with
               | Some (`Int n) when n > 0 -> n
               | _ -> 0
             in
             Some (Trace { trace; omitted }))))
     | Some "thinking" ->
       (* content is required (empty string for signature-only redacted thinking);
          redacted defaults to false and is only honoured when explicitly
          [true], matching the encoder's omission rule. *)
       Option.bind (get_string "content") (fun content ->
         let redacted =
           match List.assoc_opt "redacted" fields with
           | Some (`Bool true) -> true
           | _ -> false
         in
         (* Scrub any smuggled content at the decode boundary too: a legacy
            writer, a hand-crafted payload, or a replayed record could carry
            [redacted=true] alongside non-empty content. The in-memory
            [Thinking] value must never expose reasoning text behind a flag
            that claims it was redacted, regardless of how the JSON reached
            this decoder. *)
         let content = if redacted then "" else content in
         Some (Thinking { content; redacted }))
     | _ -> None)
  | _ -> None
;;

let blocks_of_yojson = function
  | `List items ->
    let blocks = List.filter_map block_of_yojson items in
    if blocks = [] then None else Some blocks
  | _ -> None
