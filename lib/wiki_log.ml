type line =
  { action : string
  ; revision : int
  ; page : string
  }

let known_actions = [ "create"; "update" ]

type t =
  { lines : line list
  ; unknown_action : int
  ; unreadable_line : int
  }

let empty = { lines = []; unknown_action = 0; unreadable_line = 0 }
let header = "## ["

let has_prefix ~prefix text =
  String.length text >= String.length prefix
  && String.equal (String.sub text 0 (String.length prefix)) prefix
;;

(* Every complete line, and not the last piece of a line still being written.
   [String.split_on_char] gives one piece per line plus a last piece that is
   empty when the text ended in a newline and is the unfinished line when it
   did not; dropping that last piece is right in both cases. *)
let complete_lines content =
  if String.length content = 0
  then []
  else List.rev (List.tl (List.rev (String.split_on_char '\n' content)))
;;

let revision_of word =
  if String.length word >= 2 && word.[0] = 'r'
  then int_of_string_opt (String.sub word 1 (String.length word - 1))
  else None
;;

(* The three fields read, or why the line did not. [rest] is the line after
   the timestamp: "<action> r<N> | <page> | <author> | <note>". *)
let read_fields rest =
  match String.split_on_char '|' rest with
  | head :: page :: _ ->
    (match String.split_on_char ' ' (String.trim head) with
     | [ action; revision ] ->
       (match revision_of revision with
        | Some revision -> `Read (action, revision, String.trim page)
        | None -> `Unreadable)
     | _ -> `Unreadable)
  | _ -> `Unreadable
;;

let read_line text =
  if not (has_prefix ~prefix:header text)
  then `Unreadable
  else (
    match String.index_opt text ']' with
    | None -> `Unreadable
    | Some close ->
      let rest = String.sub text (close + 1) (String.length text - close - 1) in
      (match String.trim rest with
       | "" -> `Unreadable
       | rest ->
         (match read_fields rest with
          | `Unreadable -> `Unreadable
          | `Read (action, revision, page) ->
            if List.exists (String.equal action) known_actions
            then `Read (action, revision, page)
            else `Unknown)))
;;

let add_line accumulator line = { accumulator with lines = line :: accumulator.lines }

let parse content =
  let counted =
    List.fold_left
      (fun accumulator text ->
         match read_line text with
         | `Read (action, revision, page) ->
           add_line accumulator { action; revision; page }
         | `Unknown -> { accumulator with unknown_action = accumulator.unknown_action + 1 }
         | `Unreadable -> { accumulator with unreadable_line = accumulator.unreadable_line + 1 })
      empty
      (complete_lines content)
  in
  { counted with lines = List.rev counted.lines }
;;
