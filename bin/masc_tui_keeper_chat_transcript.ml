module Live = Masc_tui_keeper_chat_live
module Projection = Masc_tui_keeper_chat_projection

(* Everything this hands out came off the wire, so it is scrubbed of terminal
   control bytes on the way out rather than on the way in. Scrubbing each
   fragment as it arrives would not be sound: an escape can be split across two
   deltas, and neither half looks like one. The accumulated string is where the
   sequence is whole and can be caught. *)
let safe_line text = Projection.terminal_safe_text text
let safe_block text = Projection.terminal_safe_text ~preserve_newlines:true text

type phase =
  | Waiting
  | Working
  | Stream_ended
  | Stream_failed of string

type interrupt =
  | Not_requested
  | Signal_sent of { turn_id : int option }
  | Signal_declined of string
  | Signal_error of string

type tool_call =
  { call_id : string
  ; tool_name : string
  ; args : string
  ; subject : string option
  ; ended : bool
  ; result_ready : bool
  }

type unreadable =
  { count : int
  ; last_detail : string
  }

(* Tool calls are held newest-first so opening one is a prepend; [tool_calls]
   reverses on read. Appending an argument fragment walks the list, which a
   turn's handful of calls makes cheap enough -- the list is short and the
   fragments are what arrive often. *)
type t =
  { keeper_name : string
  ; request_id : string
  ; text_buffer : Buffer.t
  ; thinking_buffer : Buffer.t
  ; mutable reversed_tool_calls : tool_call list
  ; mutable phase : phase
  ; mutable interrupt : interrupt
  ; mutable checkpoints : int
  ; mutable unreadable_count : int
  ; mutable last_unreadable : string
  }

let create ~keeper_name ~request_id =
  { keeper_name
  ; request_id
  ; text_buffer = Buffer.create 1024
  ; thinking_buffer = Buffer.create 256
  ; reversed_tool_calls = []
  ; phase = Waiting
  ; interrupt = Not_requested
  ; checkpoints = 0
  ; unreadable_count = 0
  ; last_unreadable = ""
  }

let keeper_name t = t.keeper_name
let request_id t = t.request_id
let phase t = t.phase
let interrupt t = t.interrupt
let note_interrupt t interrupt = t.interrupt <- interrupt
let text t = safe_block (Buffer.contents t.text_buffer)
let thinking t = safe_block (Buffer.contents t.thinking_buffer)
let tool_calls t = List.rev t.reversed_tool_calls

let unreadable t =
  if t.unreadable_count = 0 then None
  else Some { count = t.unreadable_count; last_detail = t.last_unreadable }

(* How far the call got. Argument fragments arrive before the call is closed,
   and the result lands after that, so the three states are distinguishable
   and worth distinguishing: a row stuck at the middle marker is a tool that
   is running, which is exactly what an operator is waiting to know. *)
let subject_of ~tool_name ~args =
  if String.equal (String.trim args) "" then None
  else Masc.Keeper_chat_tool_trail.tool_subject ~name:tool_name ~args

let finished_marker = "✓"

let marker_of call =
  if call.result_ready then finished_marker
  else if call.ended then "▶"
  else "·"

let pad_to width text =
  let length = String.length text in
  if length >= width then text else text ^ String.make (width - length) ' '

(* One formatter for rows drawn live and rows read back from the transcript.
   The names are padded to a common column so a block of calls lines up, which
   is only meaningful within one block -- hence the width is computed per
   call. *)
let render_rows rows =
  let name_width =
    List.fold_left
      (fun widest (_, tool_name, _) -> max widest (String.length tool_name))
      0 rows
  in
  List.map
    (fun (marker, tool_name, args) ->
      match subject_of ~tool_name ~args with
      | None -> safe_line (Printf.sprintf "%s %s" marker tool_name)
      | Some subject ->
          safe_line
            (Printf.sprintf "%s %s %s" marker (pad_to name_width tool_name)
               subject))
    rows

let tool_rows t =
  tool_calls t
  |> List.map (fun call -> (marker_of call, call.tool_name, call.args))
  |> render_rows

let completed_tool_rows pairs =
  pairs
  |> List.map (fun (tool_name, args) -> (finished_marker, tool_name, args))
  |> render_rows

type status_kind =
  | Progress
  | Attention

let phase_text t =
  match t.phase with
  | Waiting -> "waiting for the run to start"
  | Working ->
      let calls = List.length t.reversed_tool_calls in
      let work =
        if calls = 0 then "working"
        else Printf.sprintf "working, %d tool call(s)" calls
      in
      (* A checkpoint means the turn ran out of context and carried on rather
         than stopping. An operator watching a turn take a long time is owed
         the difference between that and a stall. *)
      if t.checkpoints = 0 then work
      else
        Printf.sprintf "%s, continued past %d context checkpoint(s)" work
          t.checkpoints
  | Stream_ended -> "stream ended; settling the outcome"
  | Stream_failed message -> "stream reported an error: " ^ message

(* Says what was sent, not what became of the turn. A signalled turn parked in
   an uncancellable section keeps running, and reading the signal as the
   outcome is what hid a 63-minute hang (masc #29229). The stream ending is
   what ends the turn, so the row says the turn is still streaming. *)
let interrupt_text t =
  match t.interrupt with
  | Not_requested -> None
  | Signal_sent { turn_id = None } ->
      Some "interrupt signalled; still streaming until it stops"
  | Signal_sent { turn_id = Some turn_id } ->
      Some
        (Printf.sprintf
           "interrupt signalled for turn %d; still streaming until it stops"
           turn_id)
  | Signal_declined reason -> Some ("interrupt was not signalled: " ^ reason)
  | Signal_error detail -> Some ("interrupt request got no answer: " ^ detail)

let unreadable_text t =
  if t.unreadable_count = 0 then None
  else
    Some
      (Printf.sprintf
         "%d stream line(s) could not be read for the live view (last: %s); \
          the recorded outcome is unaffected"
         t.unreadable_count t.last_unreadable)

let status_rows t =
  [ Some (Progress, phase_text t)
  ; Option.map (fun text -> (Attention, text)) (interrupt_text t)
  ; Option.map (fun text -> (Attention, text)) (unreadable_text t)
  ]
  |> List.filter_map (fun row -> row)
  |> List.map (fun (kind, text) -> (kind, safe_line text))

(* Rewrite the one call [call_id] names, leaving the rest as they are. A
   fragment for an id that never opened is dropped rather than opening a
   nameless row -- same call the connector trail makes. *)
let update_call t call_id f =
  let found = ref false in
  let updated =
    List.map
      (fun call ->
        if (not !found) && String.equal call.call_id call_id then begin
          found := true;
          f call
        end
        else call)
      t.reversed_tool_calls
  in
  if !found then t.reversed_tool_calls <- updated

let apply t (delta : Live.delta) =
  match delta with
  | Live.Run_started -> (
      match t.phase with
      | Waiting -> t.phase <- Working
      (* A second RUN_STARTED is a stream defect the strict decode reports as
         Duplicate_run_start. Nothing to draw differently for it here, and
         moving a finished turn back to Working would be wrong. *)
      | Working | Stream_ended | Stream_failed _ -> ())
  | Live.Text text -> Buffer.add_string t.text_buffer text
  | Live.Thinking text -> Buffer.add_string t.thinking_buffer text
  | Live.Tool_started { call_id; tool_name } ->
      t.reversed_tool_calls <-
        { call_id
        ; tool_name
        ; args = ""
        ; subject = None
        ; ended = false
        ; result_ready = false
        }
        :: t.reversed_tool_calls
  | Live.Tool_args { call_id; fragment } ->
      update_call t call_id (fun call ->
          let args =
            match fragment with
            | Live.Args_delta delta -> call.args ^ delta
            | Live.Args_snapshot snapshot -> snapshot
          in
          { call with
            args
          ; subject = subject_of ~tool_name:call.tool_name ~args
          })
  | Live.Tool_ended { call_id } ->
      update_call t call_id (fun call -> { call with ended = true })
  | Live.Tool_result { call_id } ->
      update_call t call_id (fun call -> { call with result_ready = true })
  | Live.Checkpoint -> t.checkpoints <- t.checkpoints + 1
  | Live.External_effect_completed ->
      (* The turn handed work to something outside it and that work finished.
         It is not a turn outcome: the run says when it ends. *)
      ()
  | Live.Run_failed { message } -> t.phase <- Stream_failed message
  | Live.Run_finished -> t.phase <- Stream_ended
  | Live.Undecodable detail ->
      t.unreadable_count <- t.unreadable_count + 1;
      t.last_unreadable <- detail
