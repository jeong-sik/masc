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

type tool_outcome =
  | Started
  | Awaiting_result
  | Returned
  | Failed
  | Never_returned
  | Outcome_unrecorded

type tool_activity =
  { call_id : string option
  ; tool_name : string
  ; args : string
  ; subject : string option
  ; outcome : tool_outcome
  ; duration : string option
  }

type tool_block =
  { activities : tool_activity list
  ; omitted_steps : int
  }

type tool_projection_mode =
  | Compact
  | Full

type tool_projection =
  { activities : tool_activity list
  ; rows : string list
  ; hidden_activity_rows : int
  ; omitted_steps : int
  }

(* Mutable stream state stays private. The typed activity handed to history
   and rendering below is immutable, so neither consumer has to infer an
   outcome from these two booleans. *)
type live_tool_call =
  { call_id : string
  ; tool_name : string
  ; args : string
  ; ended : bool
  ; result_ready : bool
  }

(* [call_id] and [tool_name] are also fields of [tool_activity] above. OCaml
   resolves an unannotated field access to the last record type that declares
   the name, which is this one, so a lambda over [tool_activity list] that
   reads either field has to say the type it is over. #30231 landed two such
   lambdas without annotations and main did not compile. *)
type awaiting_approval =
  { call_id : string
  ; tool_name : string
  ; question : string
  }

type unreadable =
  { count : int
  ; last_detail : string
  }

(* One stretch of the turn as it arrived. The three accumulators above answer
   "what did the turn say / think / call" as totals; the trail answers "in what
   order". A tool-call round interleaves them -- reasoning, then a call, then
   more reasoning -- and flattening that into three blocks is what made a long
   turn read as one wall of text with its calls listed elsewhere. Text and
   thinking nodes own their bytes; a tool node only names the call, whose
   record lives in [reversed_tool_calls] and keeps updating after later nodes
   have opened (arguments stream in, the result lands). *)
type trail_node =
  | Node_thinking of Buffer.t
  | Node_text of Buffer.t
  | Node_tool of string

(* Tool calls are held newest-first so opening one is a prepend; [tool_calls]
   reverses on read. Appending an argument fragment walks the list, which a
   turn's handful of calls makes cheap enough -- the list is short and the
   fragments are what arrive often. *)
type t =
  { keeper_name : string
  ; request_id : string
  ; started_at : float
        (* When the request left, not when the run started. The wait before
           RUN_STARTED is the part that hid a 63-minute hang (masc #29229), so
           the age has to cover it. *)
  ; text_buffer : Buffer.t
  ; thinking_buffer : Buffer.t
  ; mutable reversed_tool_calls : live_tool_call list
  ; mutable reversed_trail : trail_node list
  ; mutable phase : phase
  ; mutable interrupt : interrupt
  ; mutable checkpoints : int
  ; mutable unreadable_count : int
  ; mutable last_unreadable : string
  ; mutable awaiting : awaiting_approval option
  }

let create ~keeper_name ~request_id ~started_at =
  { keeper_name
  ; request_id
  ; started_at
  ; text_buffer = Buffer.create 1024
  ; thinking_buffer = Buffer.create 256
  ; reversed_tool_calls = []
  ; reversed_trail = []
  ; phase = Waiting
  ; interrupt = Not_requested
  ; checkpoints = 0
  ; unreadable_count = 0
  ; last_unreadable = ""
  ; awaiting = None
  }

(* Consecutive deltas of one kind are one stretch; a delta of another kind in
   between closes it. Coalescing here rather than at draw time keeps the trail
   bounded by the turn's shape (rounds), not by its chunking on the wire. *)
let trail_thinking t text =
  (match t.reversed_trail with
   | Node_thinking buffer :: _ -> Buffer.add_string buffer text
   | (Node_text _ | Node_tool _) :: _ | [] ->
       let buffer = Buffer.create 256 in
       Buffer.add_string buffer text;
       t.reversed_trail <- Node_thinking buffer :: t.reversed_trail)

let trail_text t text =
  (match t.reversed_trail with
   | Node_text buffer :: _ -> Buffer.add_string buffer text
   | (Node_thinking _ | Node_tool _) :: _ | [] ->
       let buffer = Buffer.create 256 in
       Buffer.add_string buffer text;
       t.reversed_trail <- Node_text buffer :: t.reversed_trail)

let keeper_name t = t.keeper_name
let request_id t = t.request_id
let phase t = t.phase
let interrupt t = t.interrupt
let note_interrupt t interrupt = t.interrupt <- interrupt
let text t = safe_block (Buffer.contents t.text_buffer)
let thinking t = safe_block (Buffer.contents t.thinking_buffer)

let awaiting_approval t = t.awaiting

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

let make_tool_activity ~call_id ~tool_name ~args ~outcome ~duration =
  let call_id =
    match call_id with
    | Some value when String.trim value <> "" -> Some value
    | Some _ | None -> None
  in
  { call_id
  ; tool_name
  ; args
  ; subject = subject_of ~tool_name ~args
  ; outcome
  ; duration
  }

let activity_of_live_call (call : live_tool_call) =
  make_tool_activity ~call_id:(Some call.call_id) ~tool_name:call.tool_name
    ~args:call.args
    ~outcome:
      (if call.result_ready then Returned
       else if call.ended then Awaiting_result
       else Started)
    ~duration:None

let tool_calls t =
  List.rev t.reversed_tool_calls |> List.map activity_of_live_call

let tool_block ?(omitted_steps = 0) activities : tool_block =
  { activities; omitted_steps }

(* Which reasoning lines the pane shows, kept here rather than in the drawing
   because it is a question about the content. The whole trail, minus the runs
   of blank lines models emit: reasoning is the only part of a live turn the
   durable transcript does not keep, so one line out of it would say what the
   keeper concluded without saying how it got there. *)
let thinking_lines t =
  Buffer.contents t.thinking_buffer
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")

let finished_marker = "✓"

let marker_of_outcome = function
  | Started | Never_returned -> "·"
  | Awaiting_result -> "▶"
  | Returned -> finished_marker
  | Failed -> "\xe2\x9c\x97"
  | Outcome_unrecorded -> "?"

let pad_to width text =
  let length = String.length text in
  if length >= width then text else text ^ String.make (width - length) ' '

(* One formatter for rows drawn live and rows read back from the transcript.
   The names are padded to a common column so a block of calls lines up, which
   is only meaningful within one block -- hence the width is computed per
   call. A trailer, when a row has one, goes after the subject: it is the
   part only a persisted step knows (how long the call took), and a row
   without one draws exactly as before. *)
let render_activity_rows (activities : tool_activity list) =
  let name_width =
    List.fold_left
      (fun widest (activity : tool_activity) ->
        max widest (String.length activity.tool_name))
      0 activities
  in
  let with_trailer text = function
    | None -> text
    | Some trailer -> Printf.sprintf "%s \xc2\xb7 %s" text trailer
  in
  List.map
    (fun (activity : tool_activity) ->
      let marker = marker_of_outcome activity.outcome in
      match activity.subject with
      | None ->
          safe_line
            (with_trailer
               (Printf.sprintf "%s %s" marker activity.tool_name)
               activity.duration)
      | Some subject ->
          safe_line
            (with_trailer
               (Printf.sprintf "%s %s %s" marker
                  (pad_to name_width activity.tool_name) subject)
               activity.duration))
    activities

let plural count noun =
  Printf.sprintf "%d %s%s" count noun (if count = 1 then "" else "s")

let omitted_steps_row count =
  Printf.sprintf "(%s not carried by the transcript)" (plural count "step")

let compact_outcome_parts (activities : tool_activity list) =
  let count outcome =
    List.fold_left
      (fun total activity ->
        if activity.outcome = outcome then total + 1 else total)
      0 activities
  in
  [ Started, "started"
  ; Awaiting_result, "awaiting result"
  ; Returned, "returned"
  ; Failed, "failed"
  ; Never_returned, "never returned"
  ; Outcome_unrecorded, "outcome unrecorded"
  ]
  |> List.filter_map (fun (outcome, label) ->
         match count outcome with
         | 0 -> None
         | count -> Some (Printf.sprintf "%d %s" count label))

let compact_marker (activities : tool_activity list) =
  if List.exists (fun activity -> activity.outcome = Failed) activities then
    marker_of_outcome Failed
  else if
    List.exists (fun activity -> activity.outcome = Awaiting_result) activities
  then marker_of_outcome Awaiting_result
  else if
    List.exists
      (fun activity ->
        activity.outcome = Started || activity.outcome = Never_returned)
      activities
  then marker_of_outcome Started
  else if
    List.exists
      (fun activity -> activity.outcome = Outcome_unrecorded)
      activities
  then marker_of_outcome Outcome_unrecorded
  else marker_of_outcome Returned

(* Both projections retain the same typed activities. [Full] is the shipping
   view and therefore stays byte-compatible with the old formatter. [Compact]
   folds only the presentation rows; it reports exactly how many detail rows
   it hid and keeps failures/open calls visible in its outcome summary. *)
let project_tool_block mode (block : tool_block) =
  let activity_count = List.length block.activities in
  let full_activity_rows = render_activity_rows block.activities in
  let activity_rows, hidden_activity_rows =
    match mode, block.activities with
    | (Full | Compact), ([] | [ _ ]) ->
        full_activity_rows, 0
    | Full, _ -> full_activity_rows, 0
    | Compact, activities ->
        let outcomes = String.concat ", " (compact_outcome_parts activities) in
        let hidden_activity_rows = List.length full_activity_rows in
        ( [ safe_line
              (Printf.sprintf "%s %s · %s · %s hidden"
                 (compact_marker activities)
                 (plural activity_count "tool call") outcomes
                 (plural hidden_activity_rows "detail row"))
          ]
        , hidden_activity_rows )
  in
  let rows =
    if block.omitted_steps = 0 then activity_rows
    else activity_rows @ [ omitted_steps_row block.omitted_steps ]
  in
  { activities = block.activities
  ; rows
  ; hidden_activity_rows
  ; omitted_steps = block.omitted_steps
  }

let tool_rows t =
  let projection = project_tool_block Full (tool_block (tool_calls t)) in
  projection.rows

type trail_item =
  | Trail_thinking of string list
  | Trail_tools of tool_block
  | Trail_text of string

(* The turn in arrival order, one item per stretch. Consecutive tool calls
   render as one block so their names align, same as [tool_rows]; a call whose
   arguments or result landed after later stretches opened still reads its
   current record, because the node names the call and the record keeps
   updating. Blank stretches are dropped here so the pane never budgets a row
   for an empty heading. *)
let trail t =
  let call_of id =
    List.find_opt
      (fun (call : live_tool_call) -> String.equal call.call_id id)
      t.reversed_tool_calls
  in
  let flush_tools acc group =
    match group with
    | [] -> acc
    | calls ->
        let activities =
          calls |> List.rev |> List.map activity_of_live_call
        in
        Trail_tools (tool_block activities) :: acc
  in
  let rec walk acc group = function
    | [] -> List.rev (flush_tools acc group)
    | Node_tool id :: rest -> (
        match call_of id with
        | Some call -> walk acc (call :: group) rest
        | None -> walk acc group rest)
    | Node_thinking buffer :: rest ->
        let acc = flush_tools acc group in
        let lines =
          Buffer.contents buffer
          |> String.split_on_char '\n'
          |> List.filter (fun line -> String.trim line <> "")
          |> List.map safe_line
        in
        let acc =
          match lines with [] -> acc | lines -> Trail_thinking lines :: acc
        in
        walk acc [] rest
    | Node_text buffer :: rest ->
        let acc = flush_tools acc group in
        let text = safe_block (Buffer.contents buffer) in
        let acc =
          if String.trim text = "" then acc else Trail_text text :: acc
        in
        walk acc [] rest
  in
  walk [] [] (List.rev t.reversed_trail)

type status_kind =
  | Progress
  | Attention

let phase_text t =
  match t.phase with
  | Waiting -> "waiting for the run to start"
  | Working when Option.is_some t.awaiting ->
      (* The turn is not working, it is waiting on a person. Saying "working"
         here would read as a slow tool rather than a question on screen. *)
      "held at a tool call, waiting for your answer"
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

(* An age, not a duration budget: the row says how long this turn has been
   outstanding so a watcher can tell slow from stuck. Rendered from a clock the
   caller passes rather than one read here, so a test can state the instant.
   A clock that moved backwards says nothing instead of a negative age. *)
let elapsed_text ~now t =
  Masc_tui_message_layout.age_text ~now ~since:t.started_at

let progress_text ~now t =
  match elapsed_text ~now t with
  | None -> phase_text t
  | Some age -> Printf.sprintf "%s · %s" (phase_text t) age

(* The question, as an Attention row. It is the one row an operator has to act
   on, so it is styled like the others that need them rather than like
   progress. *)
let awaiting_text t =
  Option.map
    (fun (awaiting : awaiting_approval) ->
      Printf.sprintf "%s  [y] allow  [n] deny" awaiting.question)
    t.awaiting

let status_rows ~now t =
  [ Some (Progress, progress_text ~now t)
  ; Option.map (fun text -> (Attention, text)) (awaiting_text t)
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
      (fun (call : live_tool_call) ->
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
  | Live.Text text ->
      Buffer.add_string t.text_buffer text;
      trail_text t text
  | Live.Thinking text ->
      Buffer.add_string t.thinking_buffer text;
      trail_thinking t text
  | Live.Tool_started { call_id; tool_name } ->
      t.reversed_tool_calls <-
        { call_id
        ; tool_name
        ; args = ""
        ; ended = false
        ; result_ready = false
        }
        :: t.reversed_tool_calls;
      t.reversed_trail <- Node_tool call_id :: t.reversed_trail
  | Live.Tool_args { call_id; fragment } ->
      update_call t call_id (fun call ->
          let args =
            match fragment with
            | Live.Args_delta delta -> call.args ^ delta
            | Live.Args_snapshot snapshot -> snapshot
          in
          { call with args })
  | Live.Tool_ended { call_id } ->
      update_call t call_id (fun call -> { call with ended = true })
  | Live.Tool_result { call_id } ->
      update_call t call_id (fun call -> { call with result_ready = true })
  | Live.Approval_requested { call_id; tool_name; args; question } ->
      (* The arguments go on the call's own row, which the pane already draws;
         the prompt carries the question. *)
      (match args with
       | "" -> ()
       | args ->
           update_call t call_id (fun call -> { call with args }));
      t.awaiting <- Some { call_id; tool_name; question }
  | Live.Approval_settled { call_id; outcome = _ } ->
      (* Cleared whatever the answer was, including none: the prompt is over
         either way, and leaving it up would ask again for a call that has
         already been decided. Guarded by id so a late settle for a superseded
         call cannot clear a prompt now waiting on a different one. *)
      (match t.awaiting with
       | Some awaiting when String.equal awaiting.call_id call_id ->
           t.awaiting <- None
       | Some _ | None -> ())
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
