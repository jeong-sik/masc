type t =
  | Say of string
  | Task_for_keeper of {
      title : string;
      body : string;
    }
  | Task_missing_title
  | Unknown of string

let slash = '/'

(* The first line and the rest, split once on the first newline. *)
let split_first_line text =
  match String.index_opt text '\n' with
  | None -> (text, "")
  | Some at ->
      (String.sub text 0 at, String.sub text (at + 1) (String.length text - at - 1))

(* The word after the slash and whatever follows it on the line. The word
   ends at the first blank; a line that is only the word has an empty rest. *)
let split_word line =
  let is_blank c = c = ' ' || c = '\t' in
  let length = String.length line in
  let rec word_end i = if i < length && not (is_blank line.[i]) then word_end (i + 1) else i in
  let stop = word_end 0 in
  let rest = String.sub line stop (length - stop) in
  (String.sub line 0 stop, String.trim rest)

let parse text =
  if String.length text = 0 || text.[0] <> slash then Say text
  else
    let first, body = split_first_line text in
    let line = String.sub first 1 (String.length first - 1) in
    match split_word line with
    | "task", "" -> Task_missing_title
    | "task", title -> Task_for_keeper { title; body }
    | word, _ -> Unknown word

let task_message ~task_id ~title ~body =
  if String.equal (String.trim body) "" then Printf.sprintf "[%s] %s" task_id title
  else Printf.sprintf "[%s] %s\n%s" task_id title body
