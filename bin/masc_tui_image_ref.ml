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

(* What a path is made of, once the shell quoting and the prose punctuation
   are gone. [:] is deliberately absent -- it ends the expansion at a URL's
   scheme, which is how one is told apart from a relative path below. *)
let is_path_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
  | '/' | '.' | '-' | '_' | '~' | '+' | '@' | '%' -> true
  | _ -> false

let find_from haystack needle start =
  let hl = String.length haystack and nl = String.length needle in
  let rec go index =
    if index + nl > hl then None
    else if String.equal (String.sub haystack index nl) needle then Some index
    else go (index + 1)
  in
  go start

let paths text =
  let limit = String.length text in
  let lowered = String.lowercase_ascii text in
  let ext_length = String.length extension in
  let rec expand_left index =
    if index > 0 && is_path_char text.[index - 1] then expand_left (index - 1)
    else index
  in
  let rec scan from found =
    match find_from lowered extension from with
    | None -> List.rev found
    | Some at ->
        let after = at + ext_length in
        (* A full stop closes a sentence and a full stop opens an extension,
           and both are path characters. They are told apart by what comes
           next: "docs/a.png." ends there, "backup.png.bak" does not. *)
        let ends_the_path =
          after >= limit
          || (not (is_path_char text.[after]))
          || (Char.equal text.[after] '.'
             && (after + 1 >= limit || not (is_path_char text.[after + 1])))
        in
        let start = expand_left at in
        (* [//host/file.png] is what a URL leaves behind once the expansion
           stops at its colon. It reads as an absolute path and is not one. *)
        let is_url = start > 0 && Char.equal text.[start - 1] ':' in
        let has_stem = start < at in
        let found =
          if ends_the_path && has_stem && not is_url then
            String.sub text start (after - start) :: found
          else found
        in
        scan after found
  in
  (* Named twice in one message is one file to look at. Order is first
     mention, since that is the order a reader met them in. *)
  let seen = Hashtbl.create 8 in
  scan 0 []
  |> List.filter (fun path ->
         if Hashtbl.mem seen path then false
         else begin
           Hashtbl.add seen path ();
           true
         end)
