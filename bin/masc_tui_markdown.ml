module Layout = Masc_tui_message_layout

type span = string * string

type palette = {
  strong : span;
  emphasis : span;
  code : span;
  heading : span;
  quote : span;
  link_text : span;
  link_target : span;
  rule : span;
  bullet : string;
  code_gutter : string;
  quote_gutter : string;
}

let plain_palette =
  { strong = ("", "")
  ; emphasis = ("", "")
  ; code = ("", "")
  ; heading = ("", "")
  ; quote = ("", "")
  ; link_text = ("", "")
  ; link_target = ("", "")
  ; rule = ("", "")
  ; bullet = "-"
  ; code_gutter = "| "
  ; quote_gutter = "> "
  }

(* {1 Inline markers} *)

let kind_plain = "plain"
let kind_strong = "strong"
let kind_emphasis = "emphasis"
let kind_code = "code"
let kind_link_text = "link_text"
let kind_link_target = "link_target"

let starts_at text index marker =
  let length = String.length marker in
  index + length <= String.length text
  && String.equal (String.sub text index length) marker

(* A marker only opens a span when its partner is on the same line. An
   unmatched [*] is a literal asterisk -- keepers write those -- and treating
   it as an opener would swallow the rest of the line. *)
let find_close text ~from ~marker =
  let length = String.length marker in
  let limit = String.length text in
  let rec scan index =
    if index + length > limit then None
    else if starts_at text index marker then Some index
    else scan (index + 1)
  in
  if from >= limit then None else scan from

let is_word_byte byte =
  (byte >= 'a' && byte <= 'z')
  || (byte >= 'A' && byte <= 'Z')
  || (byte >= '0' && byte <= '9')
  || Char.code byte >= 0x80

(* [_] does not mark emphasis inside a word. Half this workspace's chat is
   snake_case, and pairing the underscores in [keeper_tool_descriptor] ate them
   and italicised the middle. [*] keeps the permissive rule -- it is not a
   character identifiers are built from. *)
let underscore_opens text index =
  let before = if index = 0 then ' ' else text.[index - 1] in
  let after_index = index + 1 in
  let after =
    if after_index >= String.length text then ' ' else text.[after_index]
  in
  (not (is_word_byte before)) && after <> ' '

let underscore_closes text index =
  let before = if index = 0 then ' ' else text.[index - 1] in
  let after_index = index + 1 in
  let after =
    if after_index >= String.length text then ' ' else text.[after_index]
  in
  before <> ' ' && not (is_word_byte after)

let find_char text ~from char =
  match String.index_from_opt text from char with
  | Some index -> Some index
  | None -> None

let inline_segments text =
  let limit = String.length text in
  let out = ref [] in
  let pending = Buffer.create (String.length text) in
  let flush_pending () =
    if Buffer.length pending > 0 then begin
      out := (Buffer.contents pending, kind_plain) :: !out;
      Buffer.clear pending
    end
  in
  let emit body kind =
    if String.length body > 0 then begin
      flush_pending ();
      out := (body, kind) :: !out
    end
  in
  let rec walk index =
    if index >= limit then ()
    else
      let literal () =
        Buffer.add_char pending text.[index];
        walk (index + 1)
      in
      let styled ?(closes = fun _ -> true) marker kind =
        let opening = index + String.length marker in
        let rec seek from =
          match find_close text ~from ~marker with
          | None -> None
          | Some closing ->
              if closes closing then Some closing
              else seek (closing + String.length marker)
        in
        match seek opening with
        | None -> literal ()
        | Some closing ->
            let body = String.sub text opening (closing - opening) in
            if String.trim body = "" then literal ()
            else begin
              emit body kind;
              walk (closing + String.length marker)
            end
      in
      match text.[index] with
      | '`' -> styled "`" kind_code
      | '*' when starts_at text index "**" -> styled "**" kind_strong
      | '_' when starts_at text index "__" ->
          if underscore_opens text index then
            styled ~closes:(fun close -> underscore_closes text (close + 1)) "__"
              kind_strong
          else literal ()
      | '*' -> styled "*" kind_emphasis
      | '_' ->
          if underscore_opens text index then
            styled ~closes:(fun close -> underscore_closes text close) "_"
              kind_emphasis
          else literal ()
      | '[' -> (
          (* [label](target). Both halves are kept: a terminal cannot follow a
             link, so hiding the target loses the only usable half. *)
          match find_char text ~from:(index + 1) ']' with
          | Some close_label
            when starts_at text (close_label + 1) "(" -> (
              match find_char text ~from:(close_label + 2) ')' with
              | None -> literal ()
              | Some close_target ->
                  let label =
                    String.sub text (index + 1) (close_label - index - 1)
                  in
                  let target =
                    String.sub text (close_label + 2)
                      (close_target - close_label - 2)
                  in
                  emit label kind_link_text;
                  emit target kind_link_target;
                  walk (close_target + 1))
          | Some _ | None -> literal ())
      | _ -> literal ()
  in
  walk 0;
  flush_pending ();
  List.rev !out

(* {1 Wrapping styled segments} *)

let span_of_palette palette kind =
  if String.equal kind kind_strong then palette.strong
  else if String.equal kind kind_emphasis then palette.emphasis
  else if String.equal kind kind_code then palette.code
  else if String.equal kind kind_link_text then palette.link_text
  else if String.equal kind kind_link_target then palette.link_target
  else ("", "")

type token = {
  word : string;
  kind : string;
  space_before : bool;
}

(* Words carry their styling, so a wrap inside a bold sentence reopens bold on
   the next row instead of ending it there. *)
let tokens_of_segments segments =
  let tokens = ref [] in
  let first = ref true in
  List.iter
    (fun (text, kind) ->
       let pieces = String.split_on_char ' ' text in
       List.iteri
         (fun index piece ->
            let space_before = (not !first) && index > 0 in
            if String.length piece > 0 || space_before then begin
              tokens := { word = piece; kind; space_before } :: !tokens;
              first := false
            end)
         pieces)
    segments;
  List.rev !tokens

let render_token palette token =
  let opening, closing = span_of_palette palette token.kind in
  if String.equal token.word "" then "" else opening ^ token.word ^ closing

let wrap_tokens palette ~width tokens =
  let width = max 1 width in
  let rows = ref [] in
  let current = Buffer.create 128 in
  let current_cells = ref 0 in
  let flush () =
    rows := Buffer.contents current :: !rows;
    Buffer.clear current;
    current_cells := 0
  in
  (* The word is measured once by [place] and carried in: measuring it again
     to decide the row and a third time to advance the count segmented every
     word of every rendered line three times over. *)
  let push ~word_cells token =
    let separator = if !current_cells > 0 && token.space_before then " " else "" in
    let cells = Layout.display_width separator + word_cells in
    if !current_cells > 0 && !current_cells + cells > width then flush ();
    let separator = if !current_cells > 0 && token.space_before then " " else "" in
    Buffer.add_string current separator;
    Buffer.add_string current (render_token palette token);
    current_cells :=
      !current_cells + Layout.display_width separator + word_cells
  in
  let place token =
    let word_cells = Layout.display_width token.word in
    if word_cells <= width then push ~word_cells token
    else begin
      (* A word wider than the row is split between scalars rather than allowed
         to push the frame past its border. The tail stays open so the next
         word joins it instead of starting a row of its own. *)
      if !current_cells > 0 then flush ();
      let rec emit = function
        | [] -> ()
        | [ tail ] ->
            Buffer.add_string current
              (render_token palette { token with word = tail });
            current_cells := Layout.display_width tail
        | chunk :: rest ->
            Buffer.add_string current
              (render_token palette { token with word = chunk });
            current_cells := Layout.display_width chunk;
            flush ();
            emit rest
      in
      emit (Layout.split_cells ~max_cells:width token.word)
    end
  in
  List.iter place tokens;
  if Buffer.length current > 0 || !rows = [] then flush ();
  List.rev !rows

let wrap_inline palette ~width ~prefix ~continuation text =
  let prefix_cells = Layout.display_width prefix in
  let body_width = max 1 (width - prefix_cells) in
  let rows =
    wrap_tokens palette ~width:body_width (tokens_of_segments (inline_segments text))
  in
  List.mapi
    (fun index row -> (if index = 0 then prefix else continuation) ^ row)
    rows

(* {1 Blocks} *)

let fence_marker line =
  let trimmed = String.trim line in
  if starts_at trimmed 0 "```" then Some "```"
  else if starts_at trimmed 0 "~~~" then Some "~~~"
  else None

let is_rule line =
  let trimmed = String.trim line in
  let distinct char =
    String.length trimmed >= 3 && String.for_all (fun c -> c = char) trimmed
  in
  distinct '-' || distinct '*' || distinct '_'

let heading_level line =
  let rec count index =
    if index < String.length line && line.[index] = '#' then count (index + 1)
    else index
  in
  let level = count 0 in
  if level >= 1 && level <= 6 && level < String.length line
     && line.[level] = ' '
  then Some (level, String.trim (String.sub line level (String.length line - level)))
  else None

let bullet_item line =
  let trimmed_left =
    let rec skip index =
      if index < String.length line && line.[index] = ' ' then skip (index + 1)
      else index
    in
    skip 0
  in
  let indent = trimmed_left in
  let rest = String.sub line indent (String.length line - indent) in
  if String.length rest >= 2
     && (rest.[0] = '-' || rest.[0] = '*' || rest.[0] = '+')
     && rest.[1] = ' '
  then Some (indent, String.sub rest 2 (String.length rest - 2))
  else None

let ordered_item line =
  let limit = String.length line in
  let rec digits index =
    if index < limit && line.[index] >= '0' && line.[index] <= '9' then
      digits (index + 1)
    else index
  in
  let indent =
    let rec skip index =
      if index < limit && line.[index] = ' ' then skip (index + 1) else index
    in
    skip 0
  in
  let after_digits = digits indent in
  if after_digits > indent && after_digits + 1 < limit
     && (line.[after_digits] = '.' || line.[after_digits] = ')')
     && line.[after_digits + 1] = ' '
  then
    Some
      ( indent
      , String.sub line indent (after_digits - indent + 1)
      , String.sub line (after_digits + 2) (limit - after_digits - 2) )
  else None

let quote_body line =
  let trimmed = String.trim line in
  if String.length trimmed >= 1 && trimmed.[0] = '>' then
    Some (String.trim (String.sub trimmed 1 (String.length trimmed - 1)))
  else None

(* Fenced code is not wrapped at spaces: the alignment is the reason it was
   fenced. A line wider than the row is split where the row ends. *)
let code_rows palette ~width line =
  let gutter = palette.code_gutter in
  let body_width = max 1 (width - Layout.display_width gutter) in
  let opening, closing = palette.code in
  if String.length line = 0 then [ opening ^ gutter ^ closing ]
  else
    Layout.split_cells ~max_cells:body_width line
    |> List.map (fun chunk -> opening ^ gutter ^ chunk ^ closing)

(* One source line outside a fence, as the rows it becomes. Flat rather than
   nested so each block form is readable next to the others. *)
let block_rows palette ~width line =
  let heading_rows body =
    let opening, closing = palette.heading in
    wrap_inline palette ~width ~prefix:"" ~continuation:"" body
    |> List.map (fun row -> opening ^ row ^ closing)
  in
  let quote_rows body =
    let opening, closing = palette.quote in
    wrap_inline palette ~width ~prefix:palette.quote_gutter
      ~continuation:palette.quote_gutter body
    |> List.map (fun row -> opening ^ row ^ closing)
  in
  let item_rows ~indent ~marker body =
    let prefix = String.make indent ' ' ^ marker ^ " " in
    let continuation = String.make (Layout.display_width prefix) ' ' in
    wrap_inline palette ~width ~prefix ~continuation body
  in
  if String.trim line = "" then [ "" ]
  else if is_rule line then
    let opening, closing = palette.rule in
    [ opening
      ^ String.concat "" (List.init width (fun _ -> "\xe2\x94\x80"))
      ^ closing
    ]
  else
    match heading_level line with
    | Some (_level, body) -> heading_rows body
    | None -> (
        match quote_body line with
        | Some body -> quote_rows body
        | None -> (
            match bullet_item line with
            | Some (indent, body) ->
                item_rows ~indent ~marker:palette.bullet body
            | None -> (
                match ordered_item line with
                | Some (indent, marker, body) -> item_rows ~indent ~marker body
                | None ->
                    wrap_inline palette ~width ~prefix:"" ~continuation:"" line)))

let closes_fence line ~opened =
  match (fence_marker line, opened) with
  | Some marker, Some opened -> String.equal marker opened
  | Some _, None -> true
  | None, _ -> false

let render ~palette ~width text =
  let width = max 1 width in
  let rows = ref [] in
  let emit_all list = List.iter (fun row -> rows := row :: !rows) list in
  let rec walk fence = function
    | [] -> ()
    | line :: rest -> (
        match fence with
        | Some _ when closes_fence line ~opened:fence -> walk None rest
        | Some _ ->
            emit_all (code_rows palette ~width line);
            walk fence rest
        | None when Option.is_some (fence_marker line) ->
            walk (fence_marker line) rest
        | None ->
            emit_all (block_rows palette ~width line);
            walk None rest)
  in
  walk None (String.split_on_char '\n' text);
  List.rev !rows
