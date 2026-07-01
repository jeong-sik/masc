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

type trace_tool_status =
  | Trace_tool_pending
  | Trace_tool_ok
  | Trace_tool_err

type trace_step =
  | Trace_think of {
      text : string;
      ts : string option;
      oas_block_index : int option;
    }
  | Trace_reason of {
      text : string;
      detail : string option;
      ts : string option;
    }
  | Trace_tool of {
      name : string;
      tool_call_id : string option;
      status : trace_tool_status option;
      dur : string option;
      args : Yojson.Safe.t option;
      result : Yojson.Safe.t option;
      ts : string option;
      oas_block_index : int option;
    }

type trace_block = { trace : trace_step list }

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

let is_image_url url =
  try
    let uri = Uri.of_string url in
    let path = Uri.path uri in
    List.mem (path_extension path) image_extensions
  with
  | _ -> false
;;

let hostname_title url =
  try
    let uri = Uri.of_string url in
    let host = Option.value (Uri.host uri) ~default:url in
    let host =
      if String.length host > 4 && String.sub host 0 4 = "www."
      then String.sub host 4 (String.length host - 4)
      else host
    in
    if host = "" then url else host
  with
  | _ -> url
;;

let standalone_url_re =
  Re.Pcre.re ~flags:[ `CASELESS ] "^https?://\\S+$" |> Re.compile |> Re.execp
;;

let is_http_url url =
  try
    let scheme = Uri.scheme (Uri.of_string url) in
    match scheme with
    | Some "http" | Some "https" -> true
    | _ -> false
  with
  | _ -> false
;;

type dropped_http_url_reason =
  | Missing_scheme
  | Unsupported_scheme of string
  | Invalid_url

let dropped_http_url_reason_to_string = function
  | Missing_scheme -> "missing_scheme"
  | Unsupported_scheme scheme -> "unsupported_scheme:" ^ scheme
  | Invalid_url -> "invalid_url"
;;

let redacted_http_url_opt ?on_drop url =
  let url = Observability_redact.redact_text url in
  let drop reason =
    Option.iter (fun f -> f reason) on_drop;
    None
  in
  try
    match Uri.scheme (Uri.of_string url) with
    | Some "http" | Some "https" -> Some url
    | Some scheme -> drop (Unsupported_scheme scheme)
    | None -> drop Missing_scheme
  with
  | _ -> drop Invalid_url
;;

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix
;;

let opt_string_field key = function
  | None -> []
  | Some value -> [ (key, `String value) ]
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
  | Trace_think { text; ts; oas_block_index } ->
    `Assoc
      ([ ("kind", `String "think"); ("text", `String text) ]
       @ opt_string_field "ts" ts
       @ opt_int_field "oas_block_index" oas_block_index)
  | Trace_reason { text; detail; ts } ->
    `Assoc
      ([ ("kind", `String "reason"); ("text", `String text) ]
       @ opt_string_field "detail" detail
       @ opt_string_field "ts" ts)
  | Trace_tool
      { name; tool_call_id; status; dur; args; result; ts; oas_block_index } ->
    `Assoc
      ([ ("kind", `String "tool"); ("name", `String name) ]
       @ opt_string_field "tool_call_id" tool_call_id
       @ trace_status_to_yojson status
       @ opt_string_field "dur" dur
       @ opt_json_field "args" args
       @ opt_json_field "result" result
       @ opt_string_field "ts" ts
       @ opt_int_field "oas_block_index" oas_block_index)
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
            @ opt_string_field "severity" severity)
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
       @ opt_string_field "caption" caption)
  | Svg { svg; cap } ->
    `Assoc ([ ("t", `String "svg"); ("svg", `String svg) ] @ opt_string_field "cap" cap)
  | Voice { secs; wave; via; size; transcript; src } ->
    let fields =
      [ ("t", `String "voice") ]
      @ opt_float_field "secs" secs
      @ (match wave with
         | None -> []
         | Some values -> [ ("wave", `List (List.map (fun v -> `Float v) values)) ])
      @ opt_string_field "via" via
      @ opt_string_field "size" size
      @ opt_string_field "transcript" transcript
      @ opt_string_field "src" src
    in
    `Assoc fields
  | Attach { name; dims; src; svg; ph; via; size; data; mime_type; size_bytes; kind } ->
    `Assoc
      ([ ("t", `String "attach"); ("name", `String name) ]
       @ opt_string_field "dims" dims
       @ opt_string_field "src" src
       @ opt_string_field "svg" svg
       @ opt_string_field "ph" ph
       @ opt_string_field "via" via
       @ opt_string_field "size" size
       @ opt_string_field "data" data
       @ opt_string_field "mimeType" mime_type
       @ opt_int_field "sizeBytes" size_bytes
       @ opt_string_field "kind" kind)
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
  | Trace { trace } ->
    `Assoc
      [ ("t", `String "trace")
      ; ("trace", `List (List.map trace_step_to_yojson trace))
      ]
  | Thinking { content; redacted } ->
    (* redacted defaults to false (omitted); only emit when true so the
       common non-redacted case stays minimal and legacy decoders that do
       not know "thinking" still parse the rest of the list. *)
    let base = [ ("t", `String "thinking"); ("content", `String content) ] in
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
        (match get_step_string "kind" with
          | Some "think" ->
            Option.bind (get_step_string "text") (fun text ->
              Some
                (Trace_think
                   { text
                   ; ts = get_step_string "ts"
                   ; oas_block_index =
                       (match get_step_int "oas_block_index" with
                        | Some _ as v -> v
                        | None -> get_step_int "oasBlockIndex")
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
                  ; status
                  ; dur = get_step_string "dur"
                  ; args = List.assoc_opt "args" step_fields
                  ; result = List.assoc_opt "result" step_fields
                  ; ts = get_step_string "ts"
                  ; oas_block_index =
                      (match get_step_int "oas_block_index" with
                       | Some _ as v -> v
                       | None -> get_step_int "oasBlockIndex")
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
     | Some "trace" ->
       Option.bind (List.assoc_opt "trace" fields) (fun trace_json ->
         Option.bind (trace_steps_of_yojson trace_json) (fun trace ->
           if trace = [] then None else Some (Trace { trace })))
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
         Some (Thinking { content; redacted }))
     | _ -> None)
  | _ -> None
;;

let blocks_of_yojson = function
  | `List items ->
    let blocks = List.filter_map block_of_yojson items in
    if blocks = [] then None else Some blocks
  | _ -> None
