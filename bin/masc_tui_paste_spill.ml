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
      ; file_name = Printf.sprintf "pasted-%s-%s.txt" now_iso nonce
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
