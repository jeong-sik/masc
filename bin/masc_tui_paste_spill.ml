type t = {
  text : string;
  lines : int;
  bytes : int;
  file_name : string;
}

(* The composer draws at most [Masc_tui_message_layout.composer_max_rows]
   rows. Ten times that is the bound: a paste a couple of screens long is
   still something an operator scrolls through and edits, and past it they
   are working on text the pane never shows them. *)
let inline_max_lines = 10 * Masc_tui_message_layout.composer_max_rows

(* One line can be a whole minified file, so length alone spills too. 8 KiB is
   a dense screenful many times over. *)
let inline_max_bytes = 8192

let count_lines text =
  let count = ref 1 in
  String.iter (fun byte -> if byte = '\n' then incr count) text;
  !count

let of_paste ~now_iso ~nonce text =
  let bytes = String.length text in
  let lines = count_lines text in
  if lines <= inline_max_lines && bytes <= inline_max_bytes then None
  else
    Some
      { text
      ; lines
      ; bytes
      (* The name shape is owned by [Keeper_paste_naming]: the turn-setup
         delivery recognises staged files through the same module, so the
         writer and the matcher cannot drift apart. *)
      ; file_name = Keeper_paste_naming.file_name ~now_iso ~nonce
      }

(* Sizes an operator can act on: lines to recognise what they pasted, bytes
   because a line count says nothing about one long line. *)
let described spill =
  Printf.sprintf "%d line(s), %d bytes" spill.lines spill.bytes

let draft_line spill =
  Printf.sprintf "[pasted %s \xe2\x86\x92 %s]" (described spill) spill.file_name

let message_line spill =
  Printf.sprintf
    "[The operator pasted %s. It is in your working directory as %s -- read \
     that file for the text.]"
    (described spill) spill.file_name

let substituted spill ~replacement text =
  let placeholder = draft_line spill in
  let placeholder_length = String.length placeholder in
  let text_length = String.length text in
  let rec find start =
    if start + placeholder_length > text_length then None
    else if String.equal (String.sub text start placeholder_length) placeholder
    then Some start
    else find (start + 1)
  in
  match find 0 with
  | None -> None
  | Some at ->
      Some
        (String.sub text 0 at
        ^ replacement
        ^ String.sub text
            (at + placeholder_length)
            (text_length - at - placeholder_length))
