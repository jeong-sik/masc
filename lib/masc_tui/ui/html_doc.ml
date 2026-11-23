module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid
module Html = Markup_document

type image_source =
  | Embedded_data of { mime : string; bytes_len : int }
  | Embedded_svg of string
  | Unavailable of string

type image = {
  label : string;
  source : image_source;
}

type cell = {
  text : string;
  heading : bool;
}

type block =
  | Paragraph of string
  | Heading of int * string
  | Preformatted of string
  | List_item of int * string
  | List_continuation of int * string
  | Table of cell list list
  | Image of image

type document = {
  blocks : block list;
  images : image list;
}

type rendered_line = {
  text : string;
  style : Style.t;
  is_search_match : bool;
}

type element =
  | Suppressed
  | Inline
  | Link
  | Break
  | Picture
  | Svg
  | Graphic
  | Heading_element of int
  | Preformatted_element
  | List_element
  | Table_element
  | Block

let element name =
  match String.lowercase_ascii name with
  | "head"
  | "script"
  | "style"
  | "template"
  | "iframe"
  | "object"
  | "embed"
  | "noscript" ->
      Suppressed
  | "a" -> Link
  | "br" -> Break
  | "img" -> Picture
  | "svg" -> Svg
  | "canvas" -> Graphic
  | "h1" -> Heading_element 1
  | "h2" -> Heading_element 2
  | "h3" -> Heading_element 3
  | "h4" -> Heading_element 4
  | "h5" -> Heading_element 5
  | "h6" -> Heading_element 6
  | "pre" -> Preformatted_element
  | "li" -> List_element
  | "table" -> Table_element
  | "abbr"
  | "b"
  | "bdi"
  | "bdo"
  | "cite"
  | "code"
  | "del"
  | "dfn"
  | "em"
  | "i"
  | "ins"
  | "kbd"
  | "mark"
  | "q"
  | "s"
  | "samp"
  | "small"
  | "span"
  | "strong"
  | "sub"
  | "sup"
  | "time"
  | "u"
  | "var"
  | "wbr" ->
      Inline
  | _ -> Block

let attribute key attributes = List.assoc_opt ("", key) attributes

let hidden attributes =
  List.mem_assoc ("", "hidden") attributes
  ||
  match attribute "aria-hidden" attributes with
  | Some v -> String.equal (String.lowercase_ascii (String.trim v)) "true"
  | None -> false

let words value =
  let out = Buffer.create (String.length value) in
  let space = ref false in
  String.iter
    (fun byte ->
      match byte with
      | ' ' | '\t' | '\n' | '\012' | '\r' -> space := Buffer.length out > 0
      | _ ->
          if !space then Buffer.add_char out ' ';
          space := false;
          Buffer.add_char out byte)
    value;
  Buffer.contents out

let rec text = function
  | Html.Text value -> value
  | Html.Element { name; attributes; children; _ } ->
      if hidden attributes then ""
      else
        match element name with
        | Suppressed -> ""
        | Break -> "\n"
        | Picture -> Option.value (attribute "alt" attributes) ~default:"Image"
        | Link -> (
            let body = String.concat "" (List.map text children) in
            match attribute "href" attributes with
            | Some href when not (String.equal (String.trim href) "") ->
                body ^ " (" ^ String.trim href ^ ")"
            | Some _ | None -> body)
        | Inline -> String.concat "" (List.map text children)
        | Svg
        | Graphic
        | Heading_element _
        | Preformatted_element
        | List_element
        | Table_element
        | Block ->
            "\n" ^ String.concat "" (List.map text children) ^ "\n"

let parse_data_uri uri =
  if not (String.starts_with ~prefix:"data:" uri) then
    Unavailable "external image source; use open in browser"
  else
    match String.index_opt uri ',' with
    | None -> Unavailable "malformed data URI"
    | Some comma ->
        let meta = String.sub uri 5 (comma - 5) in
        let payload_len = String.length uri - comma - 1 in
        let mime =
          match String.split_on_char ';' meta with
          | m :: _ when not (String.equal (String.trim m) "") -> String.trim m
          | [] | _ :: _ -> "application/octet-stream"
        in
        Embedded_data { mime; bytes_len = max 0 payload_len }

let image attributes =
  let label =
    match attribute "alt" attributes with
    | Some value when not (String.equal (String.trim value) "") -> words value
    | Some _ | None -> "Image"
  in
  let source =
    match attribute "src" attributes with
    | None -> Unavailable "image has no source"
    | Some raw -> parse_data_uri (String.trim raw)
  in
  { label; source }

let svg_image node =
  {
    label = "SVG";
    source =
      (match Html.to_xml node with
       | Ok source -> Embedded_svg source
       | Error detail -> Unavailable ("SVG serialization failed: " ^ detail));
  }

let rec table_parts nodes =
  List.concat_map
    (function
      | Html.Text _ -> []
      | Html.Element { name; attributes; children; _ } -> (
          let lname = String.lowercase_ascii name in
          if element lname = Suppressed || hidden attributes then []
          else if String.equal lname "caption" then [ `Caption children ]
          else if String.equal lname "tr" then
            let cells =
              List.filter_map
                (function
                  | Html.Element
                      ({ name = cname; attributes = cattrs; _ } as el) ->
                      let lc = String.lowercase_ascii cname in
                      if (String.equal lc "th" || String.equal lc "td")
                         && not (hidden cattrs)
                      then
                        Some
                          {
                            text =
                              Grapheme.sanitize_controls
                                (words (text (Html.Element el)));
                            heading = String.equal lc "th";
                          }
                      else None
                  | Html.Text _ -> None)
                children
            in
            if cells = [] then [] else [ `Row cells ]
          else if String.equal lname "table" then []
          else table_parts children))
    nodes

let rec flow depth nodes =
  let buffer = Buffer.create 64 in
  let blocks = ref [] in
  let emit block = blocks := block :: !blocks in
  let flush () =
    let value = words (Buffer.contents buffer) in
    Buffer.clear buffer;
    if not (String.equal value "") then emit (Paragraph value)
  in
  let rec walk depth node =
    match node with
    | Html.Text value -> Buffer.add_string buffer value
    | Html.Element { name; attributes; children; _ } -> (
        if hidden attributes then ()
        else
          match element name with
          | Suppressed -> ()
          | Inline -> List.iter (walk depth) children
          | Link ->
              List.iter (walk depth) children;
              Option.iter
                (fun href ->
                  let trimmed = String.trim href in
                  if not (String.equal trimmed "") then
                    Buffer.add_string buffer (" (" ^ trimmed ^ ")"))
                (attribute "href" attributes)
          | Break -> Buffer.add_char buffer ' '
          | ( Picture
            | Svg
            | Graphic
            | Heading_element _
            | Preformatted_element
            | List_element
            | Table_element
            | Block ) as kind ->
              flush ();
              let nested =
                match kind with
                | Heading_element level -> [ Heading (level, words (text node)) ]
                | Preformatted_element ->
                    [ Preformatted (String.concat "" (List.map text children)) ]
                | Picture -> [ Image (image attributes) ]
                | Svg -> [ Image (svg_image node) ]
                | Graphic ->
                    [
                      Image
                        {
                          label = "Graphic";
                          source =
                            Unavailable
                              "inline graphic markup; use source or browser";
                        };
                    ]
                | List_element ->
                    let first = ref true in
                    flow (depth + 1) children
                    |> List.map (function
                         | Paragraph value ->
                             if !first then begin
                               first := false;
                               List_item (depth, value)
                             end
                             else List_continuation (depth, value)
                         | ( Heading _
                           | Preformatted _
                           | List_item _
                           | List_continuation _
                           | Table _
                           | Image _ ) as b ->
                             b)
                | Table_element ->
                    let rows = ref [] in
                    let parts = ref [] in
                    let append b = parts := b :: !parts in
                    let flush_rows () =
                      match !rows with
                      | [] -> ()
                      | pending ->
                          rows := [];
                          append (Table (List.rev pending))
                    in
                    table_parts children
                    |> List.iter (function
                         | `Row cells -> rows := cells :: !rows
                         | `Caption cap ->
                             flush_rows ();
                             List.iter append (flow depth cap));
                    flush_rows ();
                    List.rev !parts
                | Block -> flow depth children
                | Suppressed | Inline | Link | Break -> []
              in
              List.iter emit nested)
  in
  List.iter (walk depth) nodes;
  flush ();
  List.rev !blocks

let rec collect_images nodes =
  List.concat_map
    (function
      | Html.Text _ -> []
      | Html.Element { name; attributes; children; _ } as node -> (
          if element name = Suppressed || hidden attributes then []
          else
            match element name with
            | Picture -> [ image attributes ]
            | Svg -> [ svg_image node ]
            | Graphic ->
                [
                  {
                    label = "Graphic";
                    source =
                      Unavailable "inline graphic markup; use source or browser";
                  };
                ]
            | Suppressed -> []
            | Inline
            | Link
            | Break
            | Heading_element _
            | Preformatted_element
            | List_element
            | Table_element
            | Block ->
                collect_images children))
    nodes

let project source =
  let nodes = Html.parse_html source in
  { blocks = flow 0 nodes; images = collect_images nodes }

let contains_ci ~needle ~haystack =
  let n = String.lowercase_ascii (String.trim needle) in
  let h = String.lowercase_ascii haystack in
  let nl = String.length n and hl = String.length h in
  if nl = 0 then false
  else if nl > hl then false
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.equal (String.sub h i nl) n then true
      else loop (i + 1)
    in
    loop 0

let split_long_word ~max_width word =
  let clusters = Grapheme.split_clusters word in
  let buf = Buffer.create (String.length word) in
  let rec loop cur_w acc = function
    | [] ->
        let acc =
          if Buffer.length buf > 0 then Buffer.contents buf :: acc else acc
        in
        List.rev acc
    | (g, gw) :: rest ->
        let gw = max 0 gw in
        if Buffer.length buf > 0 && cur_w + gw > max_width then (
          let piece = Buffer.contents buf in
          Buffer.clear buf;
          Buffer.add_string buf g;
          loop gw (piece :: acc) rest)
        else (
          Buffer.add_string buf g;
          loop (cur_w + gw) acc rest)
  in
  loop 0 [] clusters

let wrap_text ~width text =
  let w = max 8 width in
  let wrap_one_line raw =
    let clean = Grapheme.sanitize_controls raw in
    let words = String.split_on_char ' ' clean in
    let rec loop cur cur_w acc = function
      | [] ->
          let acc = if cur <> "" || acc = [] then cur :: acc else acc in
          List.rev acc
      | word :: rest ->
          let ww = Grapheme.display_width word in
          if cur = "" then
            if ww <= w then loop word ww acc rest
            else
              match split_long_word ~max_width:w word with
              | [] -> loop "" 0 acc rest
              | [ single ] -> loop single (Grapheme.display_width single) acc rest
              | pieces -> (
                  match List.rev pieces with
                  | [] -> loop "" 0 acc rest
                  | last :: rev_init ->
                      let acc' = List.rev_append (List.rev rev_init) acc in
                      loop last (Grapheme.display_width last) acc' rest)
          else if cur_w + 1 + ww <= w then
            loop (cur ^ " " ^ word) (cur_w + 1 + ww) acc rest
          else loop "" 0 (cur :: acc) (word :: rest)
    in
    loop "" 0 [] words
  in
  let lines = List.concat_map wrap_one_line (String.split_on_char '\n' text) in
  if lines = [] then [ "" ] else lines

let wrap_prefixed ~width ~first_prefix ~cont_prefix text =
  let pw = Grapheme.display_width first_prefix in
  let inner_w = max 8 (width - pw) in
  match wrap_text ~width:inner_w text with
  | [] -> [ first_prefix ]
  | first :: rest ->
      (first_prefix ^ first) :: List.map (fun l -> cont_prefix ^ l) rest

let wrap_preformatted_line ~width ~prefix line =
  let pw = Grapheme.display_width prefix in
  let inner_w = max 8 (width - pw) in
  let clean = Grapheme.sanitize_controls line in
  if String.equal clean "" then [ prefix ]
  else
    split_long_word ~max_width:inner_w clean
    |> List.map (fun piece -> prefix ^ piece)

let compute_col_widths ~max_total rows =
  let ncols =
    List.fold_left (fun acc row -> max acc (List.length row)) 0 rows
  in
  if ncols = 0 then [||]
  else
    let widths = Array.make ncols 1 in
    List.iter
      (fun row ->
        List.iteri
          (fun i (c : cell) ->
            if i < ncols then
              let clean = Grapheme.sanitize_controls c.text in
              widths.(i) <- max widths.(i) (Grapheme.display_width clean))
          row)
      rows;
    let sep_total = max 0 (ncols - 1) * 3 in
    let budget = max ncols (max_total - sep_total) in
    let sum = Array.fold_left ( + ) 0 widths in
    if sum <= budget then widths
    else
      let per = max 4 (budget / ncols) in
      Array.map (fun w -> min w per) widths

let pad_cell ~width text =
  let clean = Grapheme.sanitize_controls text in
  let clipped = Grapheme.truncate_to_width ~max_width:width clean in
  let w = Grapheme.display_width clipped in
  if w >= width then clipped else clipped ^ String.make (width - w) ' '

let render_lines ~(theme : Theme.t) ~width ~lang ?(search_query = "") source =
  let width = max 12 width in
  let bg = Color.of_rgb theme.surface_1 in
  let pre_bg = Color.of_rgb theme.surface_0 in
  let body_st = Typography.primary ~bg theme in
  let h1_st =
    Style.make ~fg:(Color.of_rgb theme.accent) ~bg
      ~attrs:(Attr.union Attr.bold Attr.underline)
      ()
  in
  let h2_st = Typography.anchor ~bg theme in
  let h3_st = Typography.accent ~bg ~bold:true theme in
  let pre_st = Style.make ~fg:(Color.of_rgb theme.text_secondary) ~bg:pre_bg () in
  let bullet_st = Typography.primary ~bg theme in
  let th_st = Typography.anchor ~bg theme in
  let img_st = Typography.accent ~bg theme in
  let sep_st = Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg () in
  let mk style text =
    let is_search_match =
      if String.equal (String.trim search_query) "" then false
      else contains_ci ~needle:search_query ~haystack:text
    in
    { text; style; is_search_match }
  in
  let doc = project source in
  let render_block = function
    | Heading (level, txt) ->
        let st =
          if level <= 1 then h1_st
          else if level = 2 then h2_st
          else h3_st
        in
        let prefix =
          if level <= 1 then ""
          else String.make (min 6 (max 1 level)) '#' ^ " "
        in
        let lines =
          wrap_prefixed ~width ~first_prefix:prefix
            ~cont_prefix:(String.make (Grapheme.display_width prefix) ' ')
            txt
          |> List.map (mk st)
        in
        if level <= 1 then
          let rule =
            String.concat ""
              (List.init (min width 48) (fun _ -> "\xe2\x94\x80"))
          in
          lines @ [ mk sep_st rule ]
        else lines
    | Paragraph txt -> wrap_text ~width txt |> List.map (mk body_st)
    | Preformatted raw ->
        let raw_lines = String.split_on_char '\n' raw in
        List.concat_map
          (fun ln ->
            wrap_preformatted_line ~width ~prefix:"  " ln |> List.map (mk pre_st))
          raw_lines
    | List_item (depth, txt) ->
        let indent = String.make (min 12 (max 0 depth * 2)) ' ' in
        let first_prefix = indent ^ "\xe2\x80\xa2 " in
        let cont_prefix = indent ^ "  " in
        wrap_prefixed ~width ~first_prefix ~cont_prefix txt
        |> List.map (mk bullet_st)
    | List_continuation (depth, txt) ->
        let indent = String.make (min 12 ((max 0 depth * 2) + 2)) ' ' in
        wrap_prefixed ~width ~first_prefix:indent ~cont_prefix:indent txt
        |> List.map (mk bullet_st)
    | Table rows ->
        let widths = compute_col_widths ~max_total:width rows in
        let ncols = Array.length widths in
        if ncols = 0 then []
        else
          let sep = " \xe2\x94\x82 " in
          let rule_str =
            Array.to_list widths
            |> List.map (fun w ->
                   String.concat "" (List.init w (fun _ -> "\xe2\x94\x80")))
            |> String.concat "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80"
          in
          List.concat_map
            (fun cells ->
              let is_hdr =
                List.exists (fun (c : cell) -> c.heading) cells
              in
              let padded =
                List.init ncols (fun i ->
                    let txt =
                      match List.nth_opt cells i with
                      | Some c -> c.text
                      | None -> ""
                    in
                    pad_cell ~width:widths.(i) txt)
              in
              let row_line =
                mk (if is_hdr then th_st else body_st) (String.concat sep padded)
              in
              if is_hdr then [ row_line; mk sep_st rule_str ] else [ row_line ])
            rows
    | Image img ->
        let ko = Say.equal_lang lang Say.Lang_ko in
        let lbl =
          if ko && String.equal img.label "Image" then "이미지"
          else if ko && String.equal img.label "Graphic" then "그래픽"
          else img.label
        in
        let detail =
          match img.source with
          | Embedded_data { mime; bytes_len } ->
              if ko then
                Printf.sprintf "내장 이미지 (%s, %dB)" mime bytes_len
              else Printf.sprintf "embedded image (%s, %dB)" mime bytes_len
          | Embedded_svg svg ->
              if ko then
                Printf.sprintf "내장 SVG (%dB)" (String.length svg)
              else Printf.sprintf "embedded SVG (%dB)" (String.length svg)
          | Unavailable reason -> reason
        in
        wrap_text ~width (Printf.sprintf "\xe2\x96\xa7 %s \xc2\xb7 %s" lbl detail)
        |> List.map (mk img_st)
  in
  let rendered =
    doc.blocks
    |> List.concat_map (fun b -> render_block b @ [ mk body_st "" ])
  in
  match rendered with
  | [] ->
      (* Do not fall back to raw source (which could leak stripped <script>/<style> markup). *)
      let empty_msg =
        Say.resolve lang
          (Say.make ~ko:"(표시할 HTML 본문이 없습니다)"
             ~en:"(No visible HTML content)")
      in
      [ mk sep_st empty_msg ]
  | _ -> rendered

let search_match_lines ~theme ~width ~lang ~query source =
  let lines = render_lines ~theme ~width ~lang ~search_query:query source in
  let out = ref [] in
  List.iteri
    (fun idx (ln : rendered_line) ->
      if ln.is_search_match then out := idx :: !out)
    lines;
  List.rev !out

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang ?(scroll = 0)
    ?(search_query = "") ?active_match_line source =
  if Rect.is_empty rect then 0
  else
    let lines =
      render_lines ~theme ~width:rect.w ~lang ~search_query source
    in
    let total = List.length lines in
    let max_scroll = max 0 (total - max 1 rect.h) in
    let skip = min max_scroll (max 0 scroll) in
    let arr = Array.of_list lines in
    let show = min rect.h (max 0 (total - skip)) in
    let match_bg = Color.of_rgb theme.selection_bg in
    let active_bg = Color.of_rgb theme.accent in
    let active_fg = Color.of_rgb theme.surface_0 in
    for i = 0 to show - 1 do
      let idx = skip + i in
      let ln = arr.(idx) in
      let y = rect.y + i in
      let row_rect = Rect.make ~x:rect.x ~y ~w:rect.w ~h:1 in
      let style =
        match active_match_line with
        | Some am when Int.equal am idx && ln.is_search_match ->
            Style.make ~fg:active_fg ~bg:active_bg ~attrs:Attr.bold ()
        | _ when ln.is_search_match ->
            { ln.style with bg = match_bg; attrs = Attr.union ln.style.attrs Attr.bold }
        | _ -> ln.style
      in
      Cell_grid.fill_rect ~clip:row_rect grid ~rect:row_rect ~style ();
      ignore
        (Cell_grid.put_text ~clip:row_rect grid ~x:rect.x ~y ~style
           (Grapheme.truncate_to_width ~max_width:rect.w ln.text))
    done;
    total
