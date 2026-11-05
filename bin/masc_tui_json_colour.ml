module Ansi = Masc_tui_ansi.Ansi
module Theme = Masc_tui_ansi.Theme

type kind =
  | Key
  | String
  | Number
  | Literal

let parses text =
  match Yojson.Safe.from_string text with
  | _ -> true
  | exception Yojson.Json_error _ -> false

let literals = [ "true"; "false"; "null" ]

(* The index after the string that opens at [start], which is a quote mark. A
   backslash takes the character after it, so an escaped quote mark does not
   end the string. A string with no closing quote mark runs to the end of the
   line. *)
let string_end line start =
  let length = String.length line in
  let rec scan index =
    if index >= length then length
    else
      match line.[index] with
      | '"' -> index + 1
      | '\\' -> scan (index + 2)
      | _ -> scan (index + 1)
  in
  scan (start + 1)

let colon_follows line stop =
  let length = String.length line in
  let rec skip index =
    if index >= length then false
    else
      match line.[index] with
      | ' ' | '\t' -> skip (index + 1)
      | ':' -> true
      | _ -> false
  in
  skip stop

let run_end line start ~in_run =
  let length = String.length line in
  let rec scan index =
    if index < length && in_run line.[index] then scan (index + 1) else index
  in
  scan start

let is_number_character = function
  | '0' .. '9' | '.' | 'e' | 'E' | '+' | '-' -> true
  | _ -> false

let is_letter = function
  | 'a' .. 'z' | 'A' .. 'Z' -> true
  | _ -> false

let tokens line =
  let length = String.length line in
  let rec go index found =
    if index >= length then List.rev found
    else
      match line.[index] with
      | '"' ->
        let stop = string_end line index in
        let kind = if colon_follows line stop then Key else String in
        go stop ((kind, index, stop) :: found)
      | '-' | '0' .. '9' ->
        let stop = run_end line index ~in_run:is_number_character in
        go stop ((Number, index, stop) :: found)
      | 'a' .. 'z' | 'A' .. 'Z' ->
        let stop = run_end line index ~in_run:is_letter in
        let word = String.sub line index (stop - index) in
        if List.mem word literals then go stop ((Literal, index, stop) :: found)
        else go stop found
      | _ -> go (index + 1) found
  in
  go 0 []

(* A string stays the colour of the text around it: it is most of what a note
   says, and a block with every value coloured reads as noise. The two hues
   are the category slots, which no status colour draws. *)
let colour_of = function
  | Key -> Some (Theme.category Theme.Slot_1)
  | Number | Literal -> Some (Theme.category Theme.Slot_2)
  | String -> None

let colour_line line =
  let buffer = Buffer.create (String.length line) in
  let copied =
    List.fold_left
      (fun copied (kind, start, stop) ->
         match colour_of kind with
         | None -> copied
         | Some colour ->
           Buffer.add_substring buffer line copied (start - copied);
           Buffer.add_string buffer colour;
           Buffer.add_substring buffer line start (stop - start);
           Buffer.add_string buffer Ansi.reset;
           stop)
      0 (tokens line)
  in
  Buffer.add_substring buffer line copied (String.length line - copied);
  Buffer.contents buffer
