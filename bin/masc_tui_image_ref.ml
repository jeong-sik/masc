(* The image files a message names, so a reader can look at one without
   retyping its path into /image.

   Anchored on the extension and grown leftwards rather than split on spaces.
   A path in prose arrives wrapped -- in a markdown link, in backticks, in
   parentheses, with a comma after it -- and every wrapper is a different
   split rule, while the extension is in the same place in all of them. *)

(* Only PNG. [Masc_tui_graphics.place] says f=100, and nothing else reaches
   the screen; offering to open a .jpg would be offering a refusal. The
   extension is a guess about the bytes, not a claim: the viewer sniffs before
   it draws, so a .png holding something else is still turned away there. *)
let extension = ".png"

(* What an ASCII path is made of, once the shell quoting and the prose
   punctuation are gone. [:] is deliberately absent -- it ends the expansion
   at a URL's scheme, which is how one is told apart from a relative path
   below. *)
let is_path_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | '/' | '.' | '-' | '_' | '~' | '+' | '@' | '%' -> true
  | _ -> false

(* What the scalar just left of a growing path does to it. *)
type left_edge =
  | Name_part  (* part of the name: keep growing *)
  | Boundary  (* the name starts after it *)
  | Refused  (* no path is offered *)

(* Outside ASCII a letter, a mark or a number belongs to the name, so
   "/tmp/화면1.png" is read whole, with the bytes it was written in.
   Punctuation, symbols and spaces end the name, as ASCII punctuation does,
   so "a.png、b.png" is two names. Controls and format characters are not
   separators: they draw nothing and sit inside words (ZWNJ in Persian, a
   soft hyphen), so "/tmp/pre<ESC>post.png" names one file and "post.png"
   would be another. A scalar this table cannot classify is not guessed at
   either. *)
let left_edge scalar =
  let code = Uchar.to_int scalar in
  if code < 0x80 && is_path_char (Char.chr code) then Name_part
  else
    match Uucp.Gc.general_category scalar with
    | `Cc -> if Uucp.White.is_white_space scalar then Boundary else Refused
    | `Ll | `Lm | `Lo | `Lt | `Lu | `Mc | `Me | `Mn | `Nd | `Nl | `No ->
        Name_part
    | `Cf | `Cn | `Co | `Cs -> Refused
    | `Pc | `Pd | `Pe | `Pf | `Pi | `Po | `Ps | `Sc | `Sk | `Sm | `So | `Zl
    | `Zp | `Zs ->
        Boundary

let is_mark scalar =
  match Uucp.Gc.general_category scalar with
  | `Mc | `Me | `Mn -> true
  | `Cc | `Cf | `Cn | `Co | `Cs | `Ll | `Lm | `Lo | `Lt | `Lu | `Nd | `Nl
  | `No | `Pc | `Pd | `Pe | `Pf | `Pi | `Po | `Ps | `Sc | `Sk | `Sm | `So
  | `Zl | `Zp | `Zs ->
      false

let scalar_at text index =
  let decoded = String.get_utf_8_uchar text index in
  (Uchar.utf_decode_uchar decoded, index + Uchar.utf_decode_length decoded)

(* [text] is valid UTF-8 here, so the nearest byte that is not a
   continuation byte starts the scalar ending at [index]. *)
let scalar_before text index =
  let start = ref (index - 1) in
  while !start > 0 && Char.code text.[!start] land 0xc0 = 0x80 do
    decr start
  done;
  let scalar, _ = scalar_at text !start in
  (!start, scalar)

(* A mark belongs to the scalar before it. When that scalar ended the name
   ("⚠️a.png": U+FE0F after the sign), its marks are not where a name
   starts either. *)
let rec skip_marks text index stop =
  if index >= stop then index
  else
    let scalar, next = scalar_at text index in
    if is_mark scalar then skip_marks text next stop else index

(* What came just before a scalar inside a candidate. *)
type preceding =
  | Name_start  (* the candidate's first scalar *)
  | Slash
  | Unicode_run
  | Ascii_letter_or_digit
  | Accent  (* a mark on an ASCII letter or digit *)
  | Other_ascii

(* Korean, Japanese, Chinese and Thai prose glues words onto a name with no
   space: "결과는/tmp/a.png", "画像はscreenshot.png",
   "/tmp/a.svgを/tmp/a.png". The text cannot say where the word ends, so a
   run of non-ASCII letters is read as a name only where nothing can be
   glued onto it -- right after a [/]. The one other place is an accent on
   an ASCII letter or digit ("cafe" + U+0301). *)
let unicode_runs_open_segments text ~start ~stop =
  let rec loop index preceding =
    if index >= stop then true
    else
      let scalar, next = scalar_at text index in
      let code = Uchar.to_int scalar in
      if code < 0x80 then
        let preceding =
          match Char.chr code with
          | '/' -> Slash
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> Ascii_letter_or_digit
          | _ -> Other_ascii
        in
        loop next preceding
      else
        match preceding with
        | Slash | Unicode_run -> loop next Unicode_run
        | (Ascii_letter_or_digit | Accent) when is_mark scalar -> loop next Accent
        | Name_start | Ascii_letter_or_digit | Accent | Other_ascii -> false
  in
  loop start Name_start

let find_from haystack needle start =
  let hl = String.length haystack and nl = String.length needle in
  let rec go index =
    if index + nl > hl then None
    else if String.equal (String.sub haystack index nl) needle then Some index
    else go (index + 1)
  in
  go start

let paths text =
  (* An invalid byte leaves no scalar boundary to grow across. *)
  if not (String.is_valid_utf_8 text) then []
  else
    let limit = String.length text in
    let lowered = String.lowercase_ascii text in
    let ext_length = String.length extension in
    (* [floor] is where the last name that ended at its extension ended.
       Growing back into it would join two names, as in "a.png와b.png". *)
    let rec expand_left ~floor index =
      if index <= floor then if floor = 0 then Some 0 else None
      else
        let start, scalar = scalar_before text index in
        match left_edge scalar with
        | Name_part -> expand_left ~floor start
        | Boundary -> Some index
        | Refused -> None
    in
    (* Whether the whitespace-separated token being read so far holds a
       "://". A URL's path, query and fragment have no bytes on this disk,
       so "https://example.com/?path=/tmp/사진.png" offers nothing. *)
    let rec in_url_token index stop has_url =
      if index >= stop then has_url
      else
        let scalar, next = scalar_at text index in
        let has_url =
          if Uucp.White.is_white_space scalar then false
          else
            has_url
            || Uchar.to_int scalar = Char.code ':'
               && next + 1 < limit
               && Char.equal text.[next] '/'
               && Char.equal text.[next + 1] '/'
        in
        in_url_token next stop has_url
    in
    let rec scan from ~floor has_url found =
      match find_from lowered extension from with
      | None -> List.rev found
      | Some at ->
          let has_url = in_url_token from at has_url in
          let after = at + ext_length in
          (* A full stop closes a sentence and a full stop opens an extension,
             and both are path characters. They are told apart by what comes
             next: "docs/a.png." ends there, "backup.png.bak" does not. A
             scalar outside ASCII ends it too: Korean puts its particle right
             after the word, so "/tmp/a.png를" names /tmp/a.png. A mark does
             not: it is an accent on the "g", and the extension is not
             ".png". *)
          let ends_the_path =
            if after >= limit then true
            else
              let scalar, next = scalar_at text after in
              if Uchar.to_int scalar >= 0x80 then not (is_mark scalar)
              else if Char.equal text.[after] '.' then
                next >= limit || not (is_path_char text.[next])
              else not (is_path_char text.[after])
          in
          let found =
            if (not ends_the_path) || has_url then found
            else
              match
                Option.map (fun start -> skip_marks text start at)
                  (expand_left ~floor at)
              with
              | Some start
                when start < at
                     && unicode_runs_open_segments text ~start ~stop:at
                     (* [//host/file.png] is what a URL leaves behind once
                        the expansion stops at its colon. It reads as an
                        absolute path and is not one. *)
                     && (start = 0 || not (Char.equal text.[start - 1] ':')) ->
                  String.sub text start (after - start) :: found
              | Some _ | None -> found
          in
          let floor = if ends_the_path then after else floor in
          scan after ~floor has_url found
    in
    (* Named twice in one message is one file to look at. Order is first
       mention, since that is the order a reader met them in. *)
    let module String_set = Set.Make (String) in
    let _, unique_rev =
      List.fold_left
        (fun (seen, acc) path ->
          if String_set.mem path seen then (seen, acc)
          else (String_set.add path seen, path :: acc))
        (String_set.empty, [])
        (scan 0 ~floor:0 false [])
    in
    List.rev unique_rev
