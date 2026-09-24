type t =
  { author : string
  ; kind : Agent_observation.annotation_kind
  ; text : string
  }

type parsed =
  | Memo of t
  | Malformed of string
  | Not_a_memo

let head = "masc("

(* The one table of kind words. The printer, the reader, the tool schema's
   enum and the runtime's error message all derive from it, so a fifth kind
   reaches every one of them by being added here. *)
let word_of_kind = function
  | Agent_observation.Comment -> "comment"
  | Agent_observation.Decision -> "decision"
  | Agent_observation.Question -> "question"
  | Agent_observation.Bookmark -> "bookmark"
;;

let kind_words = List.map word_of_kind Agent_observation.all_annotation_kinds

(* The printer leaves the plain kind's word out. *)
let kind_word = function
  | Agent_observation.Comment -> None
  | (Agent_observation.Decision | Agent_observation.Question | Agent_observation.Bookmark) as kind ->
    Some (word_of_kind kind)
;;

(* The reader's side, the plain kind spelled out included. The absent word
   is read as the plain comment by [parse_body] before a word reaches here. *)
let kind_of_word word =
  List.find_opt
    (fun kind -> String.equal (word_of_kind kind) word)
    Agent_observation.all_annotation_kinds
;;

let is_author_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '.' | '-' -> true
  | _ -> false
;;

(* The comment markers the reader strips. A block comment is a memo only
   when it closes on its own row: a memo is one line, and the rows a block
   comment goes on to cover are not part of it. Blocks are tried first so
   that [<!--] is not read as the line marker [--]. *)
type markers =
  | Block of
      { opens : string
      ; closes : string
      }
  | Line of string

let known_markers =
  [ Block { opens = "(*"; closes = "*)" }
  ; Block { opens = "/*"; closes = "*/" }
  ; Block { opens = "<!--"; closes = "-->" }
  ; Line "//"
  ; Line "#"
  ; Line "--"
  ]
;;

let strip_markers comment =
  let comment = String.trim comment in
  let n = String.length comment in
  let after opens = String.sub comment (String.length opens) (n - String.length opens) in
  let inner_of ~opens ~closes =
    let o = String.length opens and c = String.length closes in
    if n >= o + c && String.ends_with ~suffix:closes comment
    then Some (String.sub comment o (n - o - c))
    else None
  in
  List.find_map
    (fun marker ->
      match marker with
      | Block { opens; closes } ->
        if String.starts_with ~prefix:opens comment then Some (inner_of ~opens ~closes) else None
      | Line opens -> if String.starts_with ~prefix:opens comment then Some (Some (after opens)) else None)
    known_markers
  |> Option.join
;;

let parse_body body =
  let body = String.trim body in
  if not (String.starts_with ~prefix:head body)
  then Not_a_memo
  else begin
    let n = String.length body in
    let start = String.length head in
    let rec author_end i = if i < n && is_author_char body.[i] then author_end (i + 1) else i in
    let stop = author_end start in
    if stop = start
    then Malformed "no author between masc( and )"
    else if stop >= n || not (Char.equal body.[stop] ')')
    then Malformed "the author is not closed by )"
    else begin
      let author = String.sub body start (stop - start) in
      let rest = String.sub body (stop + 1) (n - stop - 1) in
      match String.index_opt rest ':' with
      | None -> Malformed "no : after the author"
      | Some colon ->
        let word = String.trim (String.sub rest 0 colon) in
        let text = String.trim (String.sub rest (colon + 1) (String.length rest - colon - 1)) in
        let kind = if String.equal word "" then Some Agent_observation.Comment else kind_of_word word in
        (match kind with
         | None -> Malformed ("unknown kind " ^ word)
         | Some kind -> if String.equal text "" then Malformed "the memo has no text" else Memo { author; kind; text })
    end
  end
;;

let of_comment comment =
  match strip_markers comment with
  | None -> Not_a_memo
  | Some inner -> parse_body inner
;;

let contains ~sub text =
  let n = String.length text and m = String.length sub in
  let rec at i = i + m <= n && (String.equal (String.sub text i m) sub || at (i + 1)) in
  m > 0 && at 0
;;

(* What ends a line for some reader a memo lands in. A lone CR ends a [//]
   comment in JS and TS, which also end one at U+2028 and U+2029; NEL
   (U+0085) is a line end in Unicode-aware readers. The other C0 controls
   and DEL have no place in one line of text. A tab is text. *)
let line_break_in text =
  String.exists
    (fun c -> (not (Char.equal c '\t')) && (Char.code c < 0x20 || Char.code c = 0x7f))
    text
  || contains ~sub:"\xc2\x85" text
  || contains ~sub:"\xe2\x80\xa8" text
  || contains ~sub:"\xe2\x80\xa9" text
;;

let make ~author ~kind ~text =
  let text = String.trim text in
  if String.equal author ""
  then Error "the author is empty"
  else if not (String.for_all is_author_char author)
  then Error "the author may use letters, digits, _ . -"
  else if String.equal text ""
  then Error "the memo has no text"
  else if line_break_in text
  then Error "a memo is one line: the text has a line break or a control character"
  else Ok { author; kind; text }
;;

(* A line comment runs to the end of the line, and [make] keeps line breaks
   out of the text. A block comment ends at its closer, and in OCaml a
   second opener nests, so either inside the text leaves the rest of the
   line, or of the file, outside the comment. *)
let breaks_comment markers t =
  match markers with
  | Line _ -> None
  | Block { opens; closes } ->
    if contains ~sub:closes t.text
    then Some (Printf.sprintf "the text has %s, which ends the comment early" closes)
    else if contains ~sub:opens t.text
    then Some (Printf.sprintf "the text has %s, which opens a comment inside the memo" opens)
    else None
;;

let to_body t =
  let word =
    match kind_word t.kind with
    | None -> ""
    | Some word -> " " ^ word
  in
  head ^ t.author ^ ")" ^ word ^ ": " ^ t.text
;;

let to_line markers t =
  match markers with
  | Block { opens; closes } -> opens ^ " " ^ to_body t ^ " " ^ closes
  | Line opens -> opens ^ " " ^ to_body t
;;
