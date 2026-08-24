type t =
  | Say of string
  | Task_for_keeper of {
      title : string;
      body : string;
    }
  | Task_missing_title
  | Help
  | Switch_keeper of string
  | Switch_keeper_missing_name
  | Interrupt_turn
  | Toggle_thinking
  | Unknown of string

(* One list, drawn by /help and kept beside the parser so a new command
   cannot ship without its line. *)
let help_lines =
  [ "/task <title>   create a task for this keeper (lines below become the body)"
  ; "/keeper <name>  switch this pane to another keeper"
  ; "/interrupt      signal the streaming turn to stop"
  ; "/thinking       fold or unfold reasoning blocks in this pane"
  ; "/help           this list"
  ]

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
    | "help", _ -> Help
    | "keeper", "" -> Switch_keeper_missing_name
    | "keeper", name -> Switch_keeper name
    | "interrupt", _ -> Interrupt_turn
    | "thinking", _ -> Toggle_thinking
    | word, _ -> Unknown word

(* How [/keeper <name>] finds its keeper. The command grammar stays closed —
   no prefix matching on command words — but a keeper NAME is an argument,
   and an operator mid-thought types the least of it that still names one
   keeper. Exact match wins outright so a keeper whose full name prefixes
   another's is still reachable; otherwise a prefix must be unique, and an
   ambiguous one reports its candidates instead of guessing. *)
type keeper_match =
  | Keeper_found of string
  | Keeper_ambiguous of string list
  | Keeper_unknown

let resolve_keeper_name ~names typed =
  if List.exists (String.equal typed) names then Keeper_found typed
  else
    match
      List.filter (fun name -> String.starts_with ~prefix:typed name) names
    with
    | [ name ] -> Keeper_found name
    | [] -> Keeper_unknown
    | candidates -> Keeper_ambiguous candidates

let task_message ~task_id ~title ~body =
  if String.equal (String.trim body) "" then Printf.sprintf "[%s] %s" task_id title
  else Printf.sprintf "[%s] %s\n%s" task_id title body
