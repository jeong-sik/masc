module Html = Markup_document

type image_source =
  | Embedded_data of Masc_tui_image_payload.t
  | Embedded_svg of string
  | Unavailable of string
type image = { label : string; source : image_source }
type cell = { text : string; heading : bool }
type block =
  | Paragraph of string
  | Heading of int * string
  | Preformatted of string
  | List_item of int * string
  | List_continuation of int * string
  | Table of cell list list
  | Image of image

type t = { blocks : block list; images : image list }

(* Parse element names once; all reading paths share the same block/inline
   boundary, including text extracted from table cells and preformatted nodes. *)
type element = Suppressed | Inline | Link | Break | Picture | Svg | Graphic
  | Heading_element of int | Preformatted_element | List_element | Table_element | Block

let element = function
  | "head" | "script" | "style" | "template" | "iframe" | "object" | "embed"
  | "noscript" -> Suppressed
  | "a" -> Link
  | "br" -> Break
  | "img" -> Picture
  | "svg" -> Svg
  | "canvas" -> Graphic
  | "h1" -> Heading_element 1 | "h2" -> Heading_element 2
  | "h3" -> Heading_element 3 | "h4" -> Heading_element 4
  | "h5" -> Heading_element 5 | "h6" -> Heading_element 6
  | "pre" -> Preformatted_element
  | "li" -> List_element
  | "table" -> Table_element
  | "abbr" | "b" | "bdi" | "bdo" | "cite" | "code" | "del" | "dfn"
  | "em" | "i" | "ins" | "kbd" | "mark" | "q" | "s" | "samp" | "small"
  | "span" | "strong" | "sub" | "sup" | "time" | "u" | "var" | "wbr" -> Inline
  | _ -> Block

let attribute key attributes = List.assoc_opt ("", key) attributes
let hidden attributes = List.mem_assoc ("", "hidden") attributes
  || attribute "aria-hidden" attributes = Some "true"

let rec text = function
  | Html.Text value -> value
  | Element {name;attributes;children;_} ->
    if hidden attributes then ""
    else match element name with
      | Suppressed -> ""
      | Break -> "\n"
      | Picture -> Option.value (attribute "alt" attributes) ~default:"Image"
      | Link -> String.concat "" (List.map text children)
        ^ (match attribute "href" attributes with Some href -> " (" ^ href ^ ")" | None -> "")
      | Inline -> String.concat "" (List.map text children)
      | Svg | Graphic | Heading_element _ | Preformatted_element | List_element
      | Table_element | Block -> "\n" ^ String.concat "" (List.map text children) ^ "\n"

let words value =
  let out = Buffer.create (String.length value) in
  let space = ref false in
  String.iter (fun byte -> match byte with
    | ' ' | '\t' | '\n' | '\012' | '\r' -> space := Buffer.length out > 0
    | _ -> if !space then Buffer.add_char out ' ';
        space := false; Buffer.add_char out byte) value;
  Buffer.contents out

let image attributes =
  let label = match attribute "alt" attributes with
    | Some value when String.trim value <> "" -> words value
    | Some _ | None -> "Image" in
  let source = match attribute "src" attributes with
    | None -> Unavailable "image has no source"
    | Some raw ->
      let uri = String.trim raw in
      (match Masc_tui_image_payload.of_data_uri uri with
       | Ok payload -> Embedded_data payload
       | Error detail -> Unavailable detail) in
  {label;source}

let svg_image node =
  {label="SVG";source=(match Html.to_xml node with
    | Ok source -> Embedded_svg source
    | Error detail -> Unavailable ("SVG serialization failed: " ^ detail))}

let rec table_parts nodes =
  List.concat_map (function
    | Html.Text _ -> []
    | Element {name;attributes;children;_} ->
      if element name = Suppressed || hidden attributes then []
      else if name = "caption" then [`Caption children]
      else if name = "tr" then
        let cells = List.filter_map (function
          | Html.Element ({name=("th"|"td");attributes;_} as element)
              when not (hidden attributes) ->
            Some {text=words (text (Html.Element element));heading=element.name="th"}
          | Html.Text _ | Element _ -> None) children in
        if cells=[] then [] else [`Row cells]
      else if name = "table" then [] else table_parts children) nodes

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
      if hidden attributes then ()
      else match element name with
        | Suppressed -> ()
        | Inline -> List.iter (walk depth) children
        | Link ->
          List.iter (walk depth) children;
          Option.iter (fun href -> Buffer.add_string buffer (" (" ^ href ^ ")"))
            (attribute "href" attributes)
        | Break -> Buffer.add_char buffer ' '
        | (Picture | Svg | Graphic | Heading_element _ | Preformatted_element
          | List_element | Table_element | Block) as kind ->
          flush ();
          let nested = match kind with
            | Heading_element level -> [Heading (level, words (text node))]
            | Preformatted_element ->
              [Preformatted (String.concat "" (List.map text children))]
            | Picture -> [Image (image attributes)]
            | Svg -> [Image (svg_image node)]
            | Graphic -> [Image {label="Graphic";
                source=Unavailable "inline graphic markup; use source or the web report"}]
            | List_element ->
              let first = ref true in
              flow (depth + 1) children |> List.map (function
                | Paragraph value ->
                  if !first then begin first := false; List_item (depth,value) end
                  else List_continuation (depth,value)
                | (Heading _ | Preformatted _ | List_item _ | List_continuation _
                  | Table _ | Image _) as block -> block)
            | Table_element ->
              let rows = ref [] in
              let parts = ref [] in
              let append block = parts := block :: !parts in
              let flush_rows () = match !rows with
                | [] -> ()
                | pending -> rows := []; append (Table (List.rev pending)) in
              table_parts children |> List.iter (function
                | `Row cells -> rows := cells :: !rows
                | `Caption children ->
                  flush_rows ();
                  List.iter append (flow depth children));
              flush_rows ();
              List.rev !parts
            | Block -> flow depth children
            | Suppressed | Inline | Link | Break -> [] in
          List.iter emit nested in
  List.iter (walk depth) nodes;
  flush ();
  List.rev !blocks

let rec collect_images nodes =
  List.concat_map (function
    | Html.Text _ -> []
    | (Element {name;attributes;children;_} as node) ->
      if element name = Suppressed || hidden attributes then []
      else match element name with
        | Picture -> [image attributes]
        | Svg -> [svg_image node]
        | Graphic -> [{label="Graphic";
            source=Unavailable "inline graphic markup; use source or the web report"}]
        | Suppressed -> []
        | Inline | Link | Break | Heading_element _ | Preformatted_element
        | List_element | Table_element | Block -> collect_images children) nodes

let project source =
  let nodes = Html.parse_html source in
  {blocks=flow 0 nodes;images=collect_images nodes}
let images projection = projection.images
