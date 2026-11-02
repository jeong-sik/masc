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

(* The original bytes name the file. Unicode is classified by scalar, but is
   never normalized or decoded as a URL. *)
let is_ascii_path_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | '/' | '.' | '-' | '_' | '~' | '+' | '@' | '%' -> true
  | _ -> false

let scalar_at text index =
  let decoded = String.get_utf_8_uchar text index in
  Uchar.utf_decode_uchar decoded, index + Uchar.utf_decode_length decoded

let scalar_before text index =
  let start = ref (index - 1) in
  while !start > 0 && Char.code text.[!start] land 0xc0 = 0x80 do
    decr start
  done;
  let scalar, _ = scalar_at text !start in
  !start, scalar

let is_control scalar =
  match Uucp.Gc.general_category scalar with
  | `Cc | `Cs -> true
  | `Cf | `Cn | `Co | `Ll | `Lm | `Lo | `Lt | `Lu | `Mc | `Me | `Mn
  | `Nd | `Nl | `No | `Pc | `Pd | `Pe | `Pf | `Pi | `Po | `Ps
  | `Sc | `Sk | `Sm | `So | `Zl | `Zp | `Zs -> false

let is_path_scalar scalar =
  let code = Uchar.to_int scalar in
  if code < 128 then is_ascii_path_char (Char.chr code)
  else
    match Uucp.Gc.general_category scalar with
    | `Cc | `Cs | `Pe | `Pf | `Pi | `Ps | `Zl | `Zp | `Zs -> false
    | `Cf | `Cn | `Co | `Ll | `Lm | `Lo | `Lt | `Lu | `Mc | `Me | `Mn
    | `Nd | `Nl | `No | `Pc | `Pd | `Po | `Sc | `Sk | `Sm | `So -> true

let is_unicode_punctuation scalar =
  if Uchar.to_int scalar < 128 then false
  else match Uucp.Gc.general_category scalar with
    | `Pc | `Pd | `Pe | `Pf | `Pi | `Po | `Ps -> true
    | `Cc | `Cf | `Cn | `Co | `Cs | `Ll | `Lm | `Lo | `Lt | `Lu | `Mc
    | `Me | `Mn | `Nd | `Nl | `No | `Sc | `Sk | `Sm | `So | `Zl | `Zp | `Zs -> false

(* A closer immediately after the extension may hold the whole name, spaces
   and punctuation included. Whether it does is [holds_one_path]'s call. *)
let enclosed_start text ~at ~after =
  if after >= String.length text then None
  else
    let closer, _ = scalar_at text after in
    let closer_code = Uchar.to_int closer in
    let category = Uucp.Gc.general_category closer in
    let quote = closer_code = 0x60 || closer_code = 0x22 || closer_code = 0x27 in
    let brackets = category = `Pe || category = `Pf in
    if not (quote || brackets) then None
    else
      let rec find index depth =
        if index <= 0 then None
        else
          let start, scalar = scalar_before text index in
          let code = Uchar.to_int scalar in
          let kind = Uucp.Gc.general_category scalar in
          if code = 0x0a || code = 0x0d then None
          else if quote then
            if code = closer_code then Some index else find start depth
          else if kind = category then find start (depth + 1)
          else if (category = `Pe && kind = `Ps) || (category = `Pf && kind = `Pi) then
            if depth = 0 then Some index else find start (depth - 1)
          else find start depth
      in
      find at 0

let has_white_space text ~start ~stop =
  let rec loop index =
    index < stop
    &&
    let scalar, next = scalar_at text index in
    Uucp.White.is_white_space scalar || loop next
  in
  loop start

let path_roots = [ "/"; "~/"; "./"; "../" ]

let opens_on_a_root text start =
  List.exists
    (fun root ->
      let length = String.length root in
      start + length <= String.length text
      && String.equal (String.sub text start length) root)
    path_roots

(* A wrapper holds whatever the writer put in it: "(see docs/a.png)",
   "`open /tmp/a.png`", "`a.png and b.png`". It is one path only when it
   starts after the previous extension, so it cannot swallow an earlier
   name, and when any space in it sits inside a name that opens on a root.
   Otherwise the bare expansion reads the words before the path as words. *)
let holds_one_path text ~start ~stop ~previous_end =
  start >= previous_end
  && ((not (has_white_space text ~start ~stop)) || opens_on_a_root text start)

let valid_enclosed text ~start ~stop =
  let rec loop index =
    if index >= stop then true
    else
      let scalar, next = scalar_at text index in
      not (is_control scalar) && loop next
  in
  loop start

(* A bare Unicode first directory could also be a word directly preceding an
   absolute path. Require a delimiter or ./ for that ambiguous shape. *)
let ambiguous_bare text ~start ~at =
  let rec first_slash index =
    if index >= at then None
    else if Char.equal text.[index] '/' then Some index
    else first_slash (index + 1)
  in
  match first_slash start with
  | None -> false
  | Some slash ->
      let rec has_non_ascii index =
        index < slash && (Char.code text.[index] >= 0x80 || has_non_ascii (index + 1))
      in
      has_non_ascii start

let find_from haystack needle start =
  let hl = String.length haystack and nl = String.length needle in
  let rec go index =
    if index + nl > hl then None
    else if String.equal (String.sub haystack index nl) needle then Some index
    else go (index + 1)
  in
  go start

let paths text =
  if not (String.is_valid_utf_8 text) then [] else
  let limit = String.length text in
  let lowered = String.lowercase_ascii text in
  let ext_length = String.length extension in
  let rec expand_left index =
    if index <= 0 then Some 0
    else
      let start, scalar = scalar_before text index in
      if is_control scalar && not (Uucp.White.is_white_space scalar) then None
      else if is_path_scalar scalar then expand_left start
      else Some index
  in
  let rec advance_token index stop has_url =
    if index >= stop then has_url
    else
      let scalar, next = scalar_at text index in
      let has_url =
        if Uucp.White.is_white_space scalar then false
        else has_url ||
          (Uchar.to_int scalar = 0x3a && next + 1 < limit
           && Char.equal text.[next] '/' && Char.equal text.[next + 1] '/')
      in
      advance_token next stop has_url
  in
  let rec scan from has_url found =
    match find_from lowered extension from with
    | None -> List.rev found
    | Some at ->
        let has_url = advance_token from at has_url in
        let after = at + ext_length in
        (* A full stop closes a sentence and a full stop opens an extension,
           and both are path characters. They are told apart by what comes
           next: "docs/a.png." ends there, "backup.png.bak" does not. *)
        let ends_the_path = if after >= limit then true else
          let scalar, next = scalar_at text after in
          if Char.equal text.[after] '.' || is_unicode_punctuation scalar then
            next >= limit || let following, _ = scalar_at text next in
            not (is_path_scalar following)
          else not (is_path_scalar scalar)
        in
        let found =
          if not ends_the_path || has_url then found
          else
            let enclosed =
              match enclosed_start text ~at ~after with
              | Some start
                when holds_one_path text ~start ~stop:after ~previous_end:from ->
                  Some start
              | Some _ | None -> None
            in
            let start = match enclosed with Some start -> Some start | None -> expand_left at in
            match start with
            | Some start when start < at
                && (Option.is_some enclosed || not (ambiguous_bare text ~start ~at))
                && (start = 0 || not (Char.equal text.[start - 1] ':'))
                && valid_enclosed text ~start ~stop:after ->
                String.sub text start (after - start) :: found
            | Some _ | None -> found
        in
        scan after has_url found
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
      (scan 0 false [])
  in
  List.rev unique_rev
