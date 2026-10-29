type line =
  { seq : int
  ; stream_id : int option
  ; stream : string
  ; text : string
  }

type phase =
  | Command
  | Gate_observation

type outcome =
  | Result_unknown
  | Request_not_sent
  | Observation_ended

type status =
  | Process of Unix.process_status
  | Outcome of phase * outcome
  | Rejected of { why : string; reason : string option }
  | Unrecognized of string

(* The shapes keeper_tool_execute_runtime.ml writes for a stream's end:
   {kind, code|signal} from Exec_core, {outcome}, {phase, outcome} for the
   Gate's trial run, and {rejected, reason?}. Anything else is shown as the
   server wrote it. *)
let parse_status text =
  let unrecognized = Unrecognized text in
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ -> unrecognized
  | `Assoc fields as json ->
    let string_member name =
      match List.assoc_opt name fields with
      | Some (`String value) -> Some value
      | Some _ | None -> None
    in
    (match List.assoc_opt "kind" fields, string_member "rejected", string_member "outcome" with
     | Some _, _, _ ->
       (match Masc.Exec_core.process_status_of_json json with
        | Ok status -> Process status
        | Error _ -> unrecognized)
     | None, Some why, _ -> Rejected { why; reason = string_member "reason" }
     | None, None, Some outcome ->
       let phase =
         match List.assoc_opt "phase" fields with
         | None -> Some Command
         | Some (`String "gate_observation") -> Some Gate_observation
         | Some _ -> None
       in
       (match phase, outcome with
        | Some phase, "unknown" -> Outcome (phase, Result_unknown)
        | Some phase, "request_not_sent" -> Outcome (phase, Request_not_sent)
        | Some phase, "observation_ended" -> Outcome (phase, Observation_ended)
        | Some _, _ | None, _ -> unrecognized)
     | None, None, None -> unrecognized)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> unrecognized
;;

type kind =
  | Command_start
  | Command_more
  | Stdout
  | Stderr
  | Status of status
  | Foreign of string

type row =
  { seq : int
  ; stream_id : int option
  ; kind : kind
  ; text : string
  }

let rows lines =
  let continues_command ~previous (line : line) =
    match previous with
    | Some { kind = Command_start | Command_more; stream_id; _ } ->
      Option.equal Int.equal stream_id line.stream_id
    | Some { kind = Stdout | Stderr | Status _ | Foreign _; _ } | None -> false
  in
  let kind_of ~previous (line : line) =
    match line.stream with
    | "cmd" ->
      if continues_command ~previous line then Command_more else Command_start
    | "stdout" -> Stdout
    | "stderr" -> Stderr
    | "status" -> Status (parse_status line.text)
    | other -> Foreign other
  in
  let step (previous, acc) (line : line) =
    let row =
      { seq = line.seq
      ; stream_id = line.stream_id
      ; kind = kind_of ~previous line
      ; text = line.text
      }
    in
    Some row, row :: acc
  in
  List.rev (snd (List.fold_left step (None, []) lines))
;;

(* A command's rows are one run when commands take turns, and a stream that
   comes back after another one has spoken is the sign they overlapped. *)
let tagged rows =
  let rec interleaved ~current ~finished = function
    | [] -> false
    | (row : row) :: rest ->
      (match row.stream_id with
       | None -> interleaved ~current ~finished rest
       | Some id when Option.equal Int.equal current (Some id) ->
         interleaved ~current ~finished rest
       | Some id when List.exists (Int.equal id) finished -> true
       | Some id ->
         let finished = Option.fold current ~none:finished ~some:(fun c -> c :: finished) in
         interleaved ~current:(Some id) ~finished rest)
  in
  interleaved ~current:None ~finished:[] rows
;;

let unseen ~seen ~latest =
  let newest_seen =
    List.fold_left (fun newest (line : line) -> max newest line.seq) 0 seen
  in
  List.length (List.filter (fun (line : line) -> line.seq > newest_seen) latest)
;;

let tab_width = 8

let expand_tabs ~column text =
  let pieces = String.split_on_char '\t' text in
  let last_index = List.length pieces - 1 in
  let buffer = Buffer.create (String.length text + tab_width) in
  let _, column =
    List.fold_left
      (fun (index, column) piece ->
         Buffer.add_string buffer piece;
         let column = column + Masc_tui_message_layout.display_width piece in
         if index < last_index
         then (
           let padding = tab_width - (column mod tab_width) in
           Buffer.add_string buffer (String.make padding ' ');
           index + 1, column + padding)
         else index + 1, column)
      (0, column)
      pieces
  in
  Buffer.contents buffer, column
;;

type 'snapshot hold =
  | Following
  | Paused of { frozen : 'snapshot; back : int }

let back = function
  | Following -> 0
  | Paused { back; _ } -> back
;;

let scroll_to ~live ~back hold =
  if back <= 0
  then Following
  else (
    match hold, live with
    | Paused paused, (Some _ | None) -> Paused { paused with back }
    | Following, Some frozen -> Paused { frozen; back }
    | Following, None -> Following)
;;

let saturating_add a b = if a > max_int - b then max_int else a + b

let older ~live ~by hold =
  if by <= 0 then hold else scroll_to ~live ~back:(saturating_add (back hold) by) hold
;;

let newer ~by hold =
  if by <= 0 then hold else scroll_to ~live:None ~back:(back hold - by) hold
;;

let oldest ~live hold = scroll_to ~live ~back:max_int hold
let newest (_ : 'snapshot hold) = Following

let shown ~live = function
  | Following -> live
  | Paused { frozen; _ } -> Some frozen
;;
