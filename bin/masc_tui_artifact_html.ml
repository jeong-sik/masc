module Html = Markup_document

type image_source = Embedded_base64 of string | Unavailable of string
type image = { label : string; source : image_source }
type cell = { text : string; heading : bool }
type block =
  | Paragraph of string
  | Heading of int * string
  | Preformatted of string
  | List_item of int * string
  | Table of cell list list
  | Image of image

type t = { blocks : block list; images : image list }

let ignored = function
  | "head" | "script" | "style" | "template" | "iframe" | "object" | "embed"
  | "noscript" -> true
  | _ -> false

let hidden attributes = List.mem_assoc "hidden" attributes
  || List.assoc_opt "aria-hidden" attributes = Some "true"

let rec text = function
  | Html.Text value -> value
  | Element {name;attributes;children;_} ->
    if ignored name || hidden attributes then ""
    else if name = "br" then "\n"
    else if name = "img" then Option.value (List.assoc_opt "alt" attributes) ~default:"Image"
    else
      let body = String.concat "" (List.map text children) in
      match name, List.assoc_opt "href" attributes with
      | "a", Some href -> body ^ " (" ^ href ^ ")"
      | _ -> body

let words value =
  let out = Buffer.create (String.length value) in
  let space = ref false in
  String.iter (fun byte -> match byte with
    | ' ' | '\t' | '\n' | '\012' | '\r' -> space := Buffer.length out > 0
    | _ -> if !space then Buffer.add_char out ' ';
        space := false; Buffer.add_char out byte) value;
  Buffer.contents out

let image attributes =
  let label = match List.assoc_opt "alt" attributes with
    | Some value when String.trim value <> "" -> words value
    | Some _ | None -> "Image" in
  let source = match List.assoc_opt "src" attributes with
    | None -> Unavailable "image has no source"
    | Some raw ->
      let uri = String.trim raw in
      (match String.index_opt uri ',' with
       | Some comma ->
         let header = String.sub uri 0 comma in
         (match String.split_on_char ';' header with
          | [media; encoding] when String.equal encoding "base64" ->
            (match String.split_on_char ':' media with
             | ["data"; mime] ->
               (match String.split_on_char '/' (String.lowercase_ascii mime) with
                | ["image"; subtype] when subtype <> "" -> Embedded_base64 uri
                | _ -> Unavailable "data URI is not an image")
             | _ -> Unavailable "external image; use the original web report")
          | _ -> Unavailable "only base64 image data is available in the terminal")
       | None -> Unavailable "external image; use the original web report") in
  {label;source}

let phrasing = function
  | "a" | "abbr" | "b" | "bdi" | "bdo" | "cite" | "code" | "del" | "dfn"
  | "em" | "i" | "ins" | "kbd" | "mark" | "q" | "s" | "samp" | "small"
  | "span" | "strong" | "sub" | "sup" | "time" | "u" | "var" | "wbr" | "br" -> true
  | _ -> false

let rec table_rows nodes =
  List.concat_map (function
    | Html.Text _ -> []
    | Element {name;attributes;children;_} ->
      if ignored name || hidden attributes then []
      else if name = "tr" then
        let cells = List.filter_map (function
          | Html.Element ({name=("th"|"td");attributes;_} as element)
              when not (hidden attributes) ->
            Some {text=words (text (Html.Element element));heading=element.name="th"}
          | Html.Text _ | Element _ -> None) children in
        if cells=[] then [] else [cells]
      else if name = "table" then [] else table_rows children) nodes

let rec flow depth nodes =
  let buffer = Buffer.create 64 in
  let blocks = ref [] in
  let emit block = blocks := block :: !blocks in
  let flush () =
    let value = words (Buffer.contents buffer) in
    Buffer.clear buffer;
    if value <> "" then emit (Paragraph value) in
  let rec walk depth node = match node with
    | Html.Text value -> Buffer.add_string buffer value
    | Element {name;attributes;children;_} ->
      if ignored name || hidden attributes then ()
      else if phrasing name then begin
        List.iter (walk depth) children;
        match name, List.assoc_opt "href" attributes with
        | "a", Some href -> Buffer.add_string buffer (" (" ^ href ^ ")")
        | "br", _ -> Buffer.add_char buffer ' '
        | _ -> ()
      end else begin
        flush ();
        let nested = match name with
          | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" ->
            [Heading (Char.code name.[1] - Char.code '0', words (text node))]
          | "pre" -> [Preformatted (text node)]
          | "img" -> [Image (image attributes)]
          | "svg" | "canvas" -> [Image {label="Graphic";
              source=Unavailable "inline graphic markup; use source or the web report"}]
          | "li" ->
            let inline, nested = List.partition (function
              | Html.Element {name=("ul"|"ol");_} -> false
              | Html.Text _ | Element _ -> true) children in
            List_item (depth, words (String.concat "" (List.map text inline)))
              :: flow (depth + 1) nested
          | "table" -> [Table (table_rows children)]
          | _ -> flow depth children in
        List.iter emit nested
      end in
  List.iter (walk depth) nodes;
  flush ();
  List.rev !blocks

let rec collect_images nodes =
  List.concat_map (function
    | Html.Text _ -> []
    | Element {name;attributes;children;_} ->
      if ignored name || hidden attributes then []
      else match name with
        | "img" -> [image attributes]
        | "svg" | "canvas" -> [{label="Graphic";
            source=Unavailable "inline graphic markup; use source or the web report"}]
        | _ -> collect_images children) nodes

let project source =
  let nodes = Html.parse_html source in
  {blocks=flow 0 nodes;images=collect_images nodes}
let images projection = projection.images
