(* Error pages are untrusted and Markup's HTML error recovery can buffer a
   formatting subtree before yielding it. Bound both parser input and nesting;
   limiting the number of emitted signals alone is not a resource bound. *)
let source_limit = 4_096
let depth_limit = 128
let excerpt_limit = 240

type byte_order = Single_byte | Little_endian | Big_endian
type encoding = Detect | Known of Markup.Encoding.t * byte_order | Unsupported of string | Ambiguous

let encoding_of_name name =
  match Uutf.encoding_of_string name with
  | Some `UTF_8 -> Known (Markup.Encoding.utf_8, Single_byte)
  | Some `UTF_16 -> Known (Markup.Encoding.utf_16, Little_endian)
  | Some `UTF_16BE -> Known (Markup.Encoding.utf_16be, Big_endian)
  | Some `UTF_16LE -> Known (Markup.Encoding.utf_16le, Little_endian)
  | Some (`US_ASCII | `ISO_8859_1) -> Known (Markup.Encoding.windows_1252, Single_byte)
  | None ->
      (match String.lowercase_ascii name with
       | "windows-1252" | "cp1252" -> Known (Markup.Encoding.windows_1252, Single_byte)
       | "windows-1251" | "cp1251" -> Known (Markup.Encoding.windows_1251, Single_byte)
       | _ -> Unsupported name)

let html_encoding headers =
  let values = List.filter_map (fun (name, value) ->
    if String.equal (String.lowercase_ascii name) "content-type" then Some value else None) headers in
  match values with
  | [value] ->
      (match Cohttp.Accept.media_ranges (Some value) with
       | [(_, (Cohttp.Accept.MediaType (major, minor), params))]
         when String.equal (String.lowercase_ascii major) "text"
           && String.equal (String.lowercase_ascii minor) "html" ->
           let charsets = List.filter_map (fun (name, value) ->
             if String.equal (String.lowercase_ascii name) "charset" then Some value else None) params in
           Some (match charsets with
             | [] -> Detect
             | [name] -> encoding_of_name name
             | _ :: _ :: _ -> Ambiguous)
       | [(_, (Cohttp.Accept.MediaType _, _))]
       | [(_, (Cohttp.Accept.AnyMediaSubtype _, _))]
       | [(_, (Cohttp.Accept.AnyMedia, _))]
       | [] | _ :: _ :: _ -> None
       | exception Parsing.Parse_error | exception Failure _ -> None)
  | [] | _ :: _ :: _ -> None

type excerpt = { text: Buffer.t; mutable space: bool; mutable cut: bool }

let new_excerpt () = {text=Buffer.create excerpt_limit; space=false; cut=false}
let separate excerpt =
  if Buffer.length excerpt.text > 0 then excerpt.space <- true

let add_text excerpt text =
  let rec add index =
    if index < String.length text && not excerpt.cut then
      match text.[index] with
      | ' ' | '\t' | '\r' | '\n' | '\012' ->
          separate excerpt;
          add (index + 1)
      | character ->
          if excerpt.space then Buffer.add_char excerpt.text ' ';
          excerpt.space <- false;
          Buffer.add_char excerpt.text character;
          if Buffer.length excerpt.text > excerpt_limit then excerpt.cut <- true;
          add (index + 1)
  in
  add 0

type section = Other | Title | Body
type element = { section: section; hidden: bool; block: bool }

let block_element = function
  | "address" | "article" | "aside" | "blockquote" | "br" | "dd" | "div"
  | "dl" | "dt" | "fieldset" | "figcaption" | "figure" | "footer" | "form"
  | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "header" | "hr" | "li"
  | "main" | "nav" | "ol" | "p" | "pre" | "section" | "table" | "td"
  | "th" | "tr" | "ul" -> true
  | _ -> false

let hidden_element = function
  | "script" | "style" | "template" | "svg" | "canvas" | "iframe" -> true
  | _ -> false

(* Truncate before sanitizing: a cut can turn a formerly joined emoji or tag
   sequence into an invisible control that the sanitizer must escape. *)
let safe_excerpt ~limit text =
  let rec fit bytes =
    let head = String_util.utf8_prefix ~max_bytes:bytes text in
    let safe = Masc.Tui_terminal_text.sanitize_terminal_text head in
    if String.length safe <= limit then safe, String.length head < String.length text
    else fit (bytes - 1)
  in
  fit (min limit (String.length text))

let excerpt_of_html ~encoding body =
  let source = if String.length body > source_limit then String.sub body 0 source_limit else body in
  let parser = Markup.parse_html ?encoding ~context:`Document (Markup.string source) in
  let signals = Markup.signals parser in
  let title = new_excerpt () and visible = new_excerpt () in
  let root = {section=Other;hidden=false;block=false} in
  let limited = ref (String.length body > source_limit) in
  let rec read depth stack =
    if visible.cut then ()
    else match Markup.next signals with
    | None -> ()
    | Some (`Start_element ((_, name), attributes)) ->
        if depth >= depth_limit then limited := true
        else
          let parent = match stack with [] -> root | frame :: _ -> frame in
          let hidden = parent.hidden || hidden_element name
            || List.exists (fun ((namespace, key), _) ->
                 String.equal namespace "" && String.equal key "hidden") attributes in
          let section = match parent.section with
            | Other -> if String.equal name "body" then Body
                else if String.equal name "title" then Title else Other
            | Title -> if String.equal name "body" then Body else Title
            | Body -> Body in
          let block = block_element name in
          if not hidden && section = Body && block then separate visible;
          read (depth + 1) ({section;hidden;block} :: stack)
    | Some `End_element ->
        (match stack with
         | [] -> ()
         | frame :: rest ->
             if not frame.hidden && frame.section = Body && frame.block then separate visible;
             read (depth - 1) rest)
    | Some (`Text parts) ->
        let frame = match stack with [] -> root | current :: _ -> current in
        if not frame.hidden then
          (match frame.section with
           | Other -> ()
           | Title -> List.iter (add_text title) parts
           | Body -> List.iter (add_text visible) parts);
        read depth stack
    | Some (`Doctype _ | `Xml _ | `PI _ | `Comment _) -> read depth stack
  in
  read 0 [];
  let body_text = Buffer.contents visible.text |> String_util.utf8_prefix ~max_bytes:excerpt_limit in
  let title_text = Buffer.contents title.text |> String_util.utf8_prefix ~max_bytes:excerpt_limit in
  let include_title = not (String.equal title_text "")
    && not (String.starts_with ~prefix:title_text body_text) in
  let raw, excerpt_cut =
    if include_title && not (String.equal body_text "") then
      let separator = " · " in
      let title_limit = (excerpt_limit - String.length separator) / 2 in
      let title_head, title_cut = safe_excerpt ~limit:title_limit title_text in
      let body_limit = excerpt_limit - String.length separator - String.length title_head in
      let body_head, body_cut = safe_excerpt ~limit:body_limit body_text in
      title_head ^ separator ^ body_head, title_cut || body_cut
    else
      let text = if include_title then title_text else body_text in
      safe_excerpt ~limit:excerpt_limit text in
  let cut = !limited || visible.cut || (include_title && title.cut) || excerpt_cut in
  raw, cut

let has_bom body =
  String.starts_with ~prefix:"\xEF\xBB\xBF" body
  || String.starts_with ~prefix:"\xFE\xFF" body
  || String.starts_with ~prefix:"\xFF\xFE" body

(* A JSON document cannot begin with '<'. For a large response only that
   decisive prefix admits the HTML parser. Short responses can use Yojson's
   own grammar, preserving special refusal decoders for JSON bodies. *)
let html_candidate ~encoding body =
  let length = String.length body in
  let start, order =
    if String.starts_with ~prefix:"\xEF\xBB\xBF" body then 3, Single_byte
    else if String.starts_with ~prefix:"\xFE\xFF" body then 2, Big_endian
    else if String.starts_with ~prefix:"\xFF\xFE" body then 2, Little_endian
    else match encoding with
      | Detect | Unsupported _ | Ambiguous -> 0, Single_byte
      | Known (_, order) -> 0, order in
  let bound = min length source_limit in
  let rec starts_with_tag index =
    let code, step = match order with
      | Single_byte when index < bound -> Some (Char.code body.[index]), 1
      | Little_endian when index + 1 < bound ->
          Some (Char.code body.[index] + (Char.code body.[index + 1] * 256)), 2
      | Big_endian when index + 1 < bound ->
          Some ((Char.code body.[index] * 256) + Char.code body.[index + 1]), 2
      | Single_byte | Little_endian | Big_endian -> None, 0 in
    match code with
    | Some (0x20 | 0x09 | 0x0a | 0x0c | 0x0d) -> starts_with_tag (index + step)
    | Some 0x3c -> true
    | Some _ | None -> false in
  if starts_with_tag start then true
  else if length > source_limit then false
  else
    let json_body = if start = 3 && order = Single_byte
      then String.sub body start (length - start) else body in
    if String.equal (String.trim json_body) "" then false
    else match Yojson.Safe.from_string json_body with
      | _ -> false
      | exception Yojson.Json_error _ -> true

let html_response ~status_code ~headers ~body =
  match html_encoding headers with
  | None -> None
  | Some encoding ->
      let candidate = html_candidate ~encoding body in
      let encoding = if has_bom body then Detect else encoding in
      match encoding with
      | Unsupported _ | Ambiguous -> None
      | Detect | Known _ when candidate ->
          let encoding = match encoding with Known (value, _) -> Some value | Detect -> None
            | Unsupported _ | Ambiguous -> None in
          let text, cut = excerpt_of_html ~encoding body in
          let suffix = if cut then "…" else "" in
          let detail = if String.equal text "" then "HTML response" ^ suffix
            else "HTML text (may include hidden content): " ^ text ^ suffix in
          Some (Printf.sprintf "HTTP %d: %s" status_code detail)
      | Detect | Known _ -> None
