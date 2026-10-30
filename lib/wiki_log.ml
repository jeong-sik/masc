type line =
  { written_at : float
  ; action : string
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

(* The time at the start of the stamped minute, through [minute_time]. The
   fields are range-checked here first, so the conversion is only asked about
   a minute that can exist on the calendar; the conversion itself (the host's
   local time zone, day overflow) lives outside the wiki core. *)
let stamp_time ~minute_time stamp =
  match
    Scanf.sscanf_opt stamp "%4u-%2u-%2u %2u:%2u%!" (fun year month day hour minute ->
      year, month, day, hour, minute)
  with
  | Some (year, month, day, hour, minute)
    when month >= 1 && month <= 12 && day >= 1 && day <= 31 && hour <= 23 && minute <= 59 ->
    minute_time ~year ~month ~day ~hour ~minute
  | Some _ | None -> None
;;

let read_line ~minute_time text =
  if not (String.starts_with ~prefix:header text)
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
            (match stamp_time ~minute_time (String.sub text (String.length header) (close - String.length header)) with
             | None -> `Unreadable
             | Some written_at ->
               if List.exists (String.equal action) known_actions
               then `Read (written_at, action, revision, page)
               else `Unknown))))
;;

let add_line accumulator line = { accumulator with lines = line :: accumulator.lines }

let parse ~minute_time content =
  let counted =
    List.fold_left
      (fun accumulator text ->
         match read_line ~minute_time text with
         | `Read (written_at, action, revision, page) ->
           add_line accumulator { written_at; action; revision; page }
         | `Unknown -> { accumulator with unknown_action = accumulator.unknown_action + 1 }
         | `Unreadable -> { accumulator with unreadable_line = accumulator.unreadable_line + 1 })
      empty
      (complete_lines content)
  in
  { counted with lines = List.rev counted.lines }
;;
