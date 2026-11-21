module Log = Keeper_turn_log
module Store = Keeper_turn_log_store
module Scan = Private_jsonl_scan

type record =
  | Checkpoint of
      { slices : Log.slice list
      ; internal : Librarian_unit.range
      }
  | Official_files of
      { history : Librarian_unit.range
      ; internal : Librarian_unit.range
      }
  | Every_record of
      { slices : Log.slice list
      ; history : Librarian_unit.range
      ; internal : Librarian_unit.range
      }

type segment =
  { record : record
  ; chat : Librarian_unit.range
  ; external_rows : Librarian_unit.range
  }

type source =
  | Turn of
      { turn : int
      ; outcome : Log.outcome
      ; opened : Librarian_read_unit.opened_line
      ; unattributed : segment
      ; own : segment
      }
  | Announced_reset of
      { cause : Log.announced
      ; segment : segment
      }

type span =
  { line : int
  ; past_line : int
  ; at : float
  ; from : Log.mark
  ; through : Log.mark
  ; next : Log.mark
  ; source : source
  ; resume : Librarian_unit.item_name option
  }

type unreadable =
  | Undecodable of Store.undecodable
  | Out_of_order of Log.order_error

type stop =
  | Log_end
  | Limit_reached
  | Unannounced_reset of
      { line : int
      ; past_line : int
      ; before : Log.mark
      ; after : Log.mark
      }
  | Unreadable_line of
      { offset : int
      ; past_line : int
      ; from : Log.mark
      ; sha : Agent_core.Checkpoint_objects.digest
      ; reason : unreadable
      }

type reading =
  { spans : span list
  ; stop : stop
  ; bytes : int
  }

type read_error =
  | Fault of Librarian_unit.input_fault
  | Unread of { detail : string }

type until =
  | To_end
  | First_with_items of int

let non_empty ({ from; until } : Librarian_unit.range) = until > from

let takes_a_message slices = List.exists (fun ({ take; _ } : Log.slice) -> take > 0) slices

let record_has_items = function
  | Checkpoint { slices; internal } -> takes_a_message slices || non_empty internal
  | Official_files { history; internal } -> non_empty history || non_empty internal
  | Every_record { slices; history; internal } ->
    takes_a_message slices || non_empty history || non_empty internal
;;

let segment_has_items { record; chat; external_rows } =
  record_has_items record || non_empty chat || non_empty external_rows
;;

let has_items span =
  match span.source with
  | Turn { unattributed; own; _ } -> segment_has_items unattributed || segment_has_items own
  | Announced_reset { segment; _ } -> segment_has_items segment
;;

let reach span : Librarian_log.within -> Librarian_read_result.reach = function
  | Whole -> { line = span.line; within = Whole; covered = span.next; turn_log_offset = span.past_line }
  | Item name -> { line = span.line; within = Item name; covered = span.from; turn_log_offset = span.line }
;;

let has_unread = function
  | Error (Fault (_ : Librarian_unit.input_fault) | Unread { detail = (_ : string) }) -> true
  | Ok { spans; stop; bytes = (_ : int) } ->
    (match stop with
     | Log_end | Limit_reached -> List.exists has_items spans
     | Unannounced_reset _ | Unreadable_line _ -> true)
;;

(* {1 What a unit holds} *)

(* Every store's range from where the unit starts to where it ends. *)
type ranges =
  { history : Librarian_unit.range
  ; internal : Librarian_unit.range
  ; chat : Librarian_unit.range
  ; external_rows : Librarian_unit.range
  }

let ranges ~(from : Log.mark) ~(through : Log.mark) =
  let same_session = String.equal from.session through.session in
  let official start until : Librarian_unit.range =
    { from = (if same_session then start else 0); until }
  in
  { history = official from.history_bytes through.history_bytes
  ; internal = official from.internal_bytes through.internal_bytes
  ; chat = { from = from.chat_bytes; until = through.chat_bytes }
  ; external_rows = { from = from.external_rows; until = through.external_rows }
  }
;;

(* §5.3: one turn's segment is read from its checkpoint when a slice takes
   a message, with the internal file's replies the checkpoint does not
   replay, and from the official-client files when none does. *)
let one_turn ~slices ({ history; internal; chat; external_rows } : ranges) =
  { record =
      (if takes_a_message slices
       then Checkpoint { slices; internal }
       else Official_files { history; internal })
  ; chat
  ; external_rows
  }
;;

(* §5.3: a stretch that can hold several turns is read from every record. *)
let stretch ~slices ({ history; internal; chat; external_rows } : ranges) =
  { record = Every_record { slices; history; internal }; chat; external_rows }
;;

let whole ~from ~through slices = stretch ~slices (ranges ~from ~through)

(* One store's range cut at [at], kept inside it. *)
let cut ({ from; until } : Librarian_unit.range) at : Librarian_unit.range * Librarian_unit.range =
  let at = Int.max from (Int.min until at) in
  { from; until = at }, { from = at; until }
;;

(* Where a turn's stores are cut between what no turn claims and what the
   turn closed (§5.3). *)
type split =
  | At_baseline of Log.mark
  | Not_split
  (* A [Reset] followed the turn's [Opened], or reading went past a line of
     the turn without reading it (§5.4). The turn claims nothing: every range
     and every slice of its [Closed] is unattributed. *)

let turn_segments ~from ~(through : Log.mark) ~split ~unattributed ~own =
  let all = ranges ~from ~through in
  let end_of (range : Librarian_unit.range) = range.until in
  let (history_at, internal_at, chat_at, external_at), unattributed, own =
    match split with
    | Not_split ->
      ( (end_of all.history, end_of all.internal, end_of all.chat, end_of all.external_rows)
      , unattributed @ own
      , [] )
    | At_baseline (baseline : Log.mark) ->
      let same_session = String.equal baseline.session through.session in
      let official range value = if same_session then value else end_of range in
      ( ( official all.history baseline.history_bytes
        , official all.internal baseline.internal_bytes
        , baseline.chat_bytes
        , baseline.external_rows )
      , unattributed
      , own )
  in
  let history_before, history_after = cut all.history history_at in
  let internal_before, internal_after = cut all.internal internal_at in
  let chat_before, chat_after = cut all.chat chat_at in
  let external_before, external_after = cut all.external_rows external_at in
  ( stretch ~slices:unattributed
      { history = history_before
      ; internal = internal_before
      ; chat = chat_before
      ; external_rows = external_before
      }
  , one_turn ~slices:own
      { history = history_after
      ; internal = internal_after
      ; chat = chat_after
      ; external_rows = external_after
      } )
;;

(* {1 Where reading stands among the lines} *)

(* What reading has of an open turn's lines before its [Closed] (§5.4). *)
type turn_start =
  | Read of
      { opened : Librarian_read_unit.opened
      ; baseline : Log.mark
      }
  | Read_then_passed of { opened : Librarian_read_unit.opened }
  (* Reading went past a line after the [Opened] without reading it. That
     line may have been a [Reset], so the baseline splits nothing. *)
  | Passed
  (* Reading went past the [Opened] itself without reading it. *)

type open_turn =
  { offset : int (** Byte offset of the [Opened] line. *)
  ; opening : turn_start
  }

(* {!Log.position} with what the open turn's [Opened] said. *)
type known =
  | Not_started
  | Between_turns
  | In_turn of
      { turn : open_turn
      ; reset_since : bool
      }

type place =
  | Resumed
  (* Reading started past the first line and has read no [Opened] or
     [Closed] yet, so whether a turn is open is not known. A [Reset] is in
     order either way. *)
  | Known of known

let position : known -> Log.position = function
  | Not_started -> Nothing_written
  | Between_turns -> Between_turns
  | In_turn { turn; reset_since } -> Turn_open { opened = turn.offset; reset_since }
;;

(* Where a line the order accepted leaves reading. *)
let known_after known ~at : Log.line -> known = function
  | Log_started _ | Closed _ -> Between_turns
  | Opened { runtime; task; stimuli; baseline; _ } ->
    In_turn
      { turn = { offset = at; opening = Read { opened = { runtime; task; stimuli }; baseline } }
      ; reset_since = false
      }
  | Reset _ ->
    (match known with
     | In_turn { turn; reset_since = (_ : bool) } -> In_turn { turn; reset_since = true }
     | Not_started | Between_turns -> Between_turns)
;;

(* Where a line that reading went past without reading it leaves reading.
   What the line said is not known. *)
let known_after_passed : known -> known = function
  | In_turn { turn = { offset; opening = Read { opened; baseline = (_ : Log.mark) } }; reset_since } ->
    In_turn { turn = { offset; opening = Read_then_passed { opened } }; reset_since }
  | ( In_turn
        { turn = { opening = Read_then_passed _ | Passed; offset = (_ : int) }
        ; reset_since = (_ : bool)
        }
    | Not_started | Between_turns ) as known -> known
;;

(* What a turn's [Closed] takes from the lines before it: what its [Opened]
   said, and where its stores are cut. *)
let opened_and_split ({ opening; offset = (_ : int) } : open_turn) ~reset_since
  : Librarian_read_unit.opened_line * split
  =
  match opening with
  | Read { opened; baseline } ->
    Opened_read opened, (if reset_since then Not_split else At_baseline baseline)
  | Read_then_passed { opened } -> Opened_read opened, Not_split
  | Passed -> Opened_passed, Not_split
;;

type walk =
  { place : place
  ; resumed : (int * Librarian_unit.item_name) option
  (** The unit the tail read through an item, by its line, and that item. *)
  ; from : Log.mark (** Where the next unit starts. *)
  ; spans : span list (** Newest first. *)
  ; with_items : int
  ; bytes : int
  }

let read_failed error = Error (Unread { detail = Scan.error_to_string error })

(* How reading a turn's lines again from its [Opened] ended. *)
type replayed =
  | Replayed of
      { known : known
      ; bytes : int
      }
  | No_opened
  (* The [Closed] names a line that reads and is not an [Opened], or no line
     at all: that [Closed] is out of order. *)

type replaying =
  | Before_opened
  | Replaying of known

(* The lines of the turn whose [Opened] is at [turn], up to its [Closed] at
   [closed]: they say what the turn's [Opened] held and whether a [Reset]
   followed it.

   Reading stands at [start], past [turn]. A line before [start] that does
   not decode, or that the order refuses, is one reading already went past,
   and it is passed here too: the [Closed] is read without what that line
   said (§5.4). So no line before [start] stops a read.

   The lines from [start] to [closed] were read before this turn's lines
   are read again, each as an announced [Reset], which is in order anywhere.
   One of them that does not read now is a file that changed between the
   two reads. *)
let replay ~turns_path ~start ~turn ~closed =
  let ended state bytes =
    match state with
    | Before_opened -> No_opened
    | Replaying known -> Replayed { known; bytes }
  in
  let not_read state ~at bytes : (_, (replayed, read_error) result) Scan.step =
    if at >= start
    then Stop (read_failed Scan.Moved)
    else (
      match state with
      | Before_opened ->
        Continue
          (Replaying (In_turn { turn = { offset = at; opening = Passed }; reset_since = false }), bytes)
      | Replaying known -> Continue (Replaying (known_after_passed known), bytes))
  in
  let read (state, bytes) ({ at; past; row = (_ : string); line } : Store.scanned)
    : (_, (replayed, read_error) result) Scan.step
    =
    if at >= closed
    then Stop (Ok (ended state bytes))
    else (
      let bytes = bytes + past - at in
      match line, state with
      | Error (_ : Store.undecodable), (Before_opened | Replaying _) -> not_read state ~at bytes
      | Ok (Opened _ as opened), Before_opened ->
        Continue (Replaying (known_after Not_started ~at opened), bytes)
      | Ok (Log_started _ | Closed _ | Reset _), Before_opened -> Stop (Ok No_opened)
      | Ok line, Replaying known ->
        (match Log.step (position known) ~offset:at line with
         | Ok (_ : Log.position) -> Continue (Replaying (known_after known ~at line), bytes)
         | Error (_ : Log.order_error) -> not_read state ~at bytes))
  in
  match Store.fold_from turns_path ~from:turn ~init:(Before_opened, 0) ~f:read with
  | Ok (Stopped replayed) -> replayed
  | Ok (Reached_end ((_ : replaying), (_ : int))) -> read_failed Scan.Moved
  | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) -> Ok No_opened
  | Error (Scan_failed error) -> read_failed error
;;

let stopped walk stop = Scan.Stop (Ok (walk, stop))

let resume_at walk ~line =
  match walk.resumed with
  | Some (resumed, name) when Int.equal resumed line -> Some name
  | Some (_ : int * Librarian_unit.item_name) | None -> None
;;

(* [row] is the line at [at] without its line break, and [past] is just past
   that line break. *)
let refused walk ~at ~past ~row reason =
  stopped walk
    (Unreadable_line
       { offset = at
       ; past_line = past
       ; from = walk.from
       ; sha = Agent_core.Checkpoint_objects.digest_of_bytes row
       ; reason
       })
;;

let add_span ~until walk span =
  let items = has_items span in
  let with_items = if items then walk.with_items + 1 else walk.with_items in
  let walk = { walk with spans = span :: walk.spans; from = span.next; with_items } in
  match until with
  | First_with_items count when items && with_items >= count -> stopped walk Limit_reached
  | To_end | First_with_items _ -> Scan.Continue walk
;;

let on_reset ~until walk ~at ~past ~written ~(cause : Log.reset_cause) ~before ~after ~closed_before =
  match cause with
  | Unannounced -> stopped walk (Unannounced_reset { line = at; past_line = past; before; after })
  | Announced cause ->
    add_span ~until walk
      { line = at
      ; past_line = past
      ; at = written
      ; from = walk.from
      ; through = before
      ; next = after
      ; source = Announced_reset { cause; segment = whole ~from:walk.from ~through:before closed_before }
      ; resume = resume_at walk ~line:at
      }
;;

let on_known ~until walk known ~at ~past ~row (line : Log.line) =
  match Log.step (position known) ~offset:at line with
  | Error error -> refused walk ~at ~past ~row (Out_of_order error)
  | Ok (_ : Log.position) ->
    let walk = { walk with place = Known (known_after known ~at line) } in
    (match line with
     | Log_started { mark; id = (_ : Log.Log_id.t); at = (_ : float) } ->
       Scan.Continue { walk with from = mark }
     | Opened _ -> Scan.Continue walk
     | Reset { cause; before; after; closed_before; at = written } ->
       on_reset ~until walk ~at ~past ~written ~cause ~before ~after ~closed_before
     | Closed { turn; at = closed_at; outcome; after; unattributed; own } ->
       (match known with
        | In_turn { turn = open_turn; reset_since } ->
          let opened, split = opened_and_split open_turn ~reset_since in
          let unattributed, own =
            turn_segments ~from:walk.from ~through:after ~split ~unattributed ~own
          in
          add_span ~until walk
            { line = at
            ; past_line = past
            ; at = closed_at
            ; from = walk.from
            ; through = after
            ; next = after
            ; source = Turn { turn; outcome; opened; unattributed; own }
            ; resume = resume_at walk ~line:at
            }
        (* The order refuses a [Closed] with no open turn before here. *)
        | Not_started | Between_turns ->
          refused walk ~at ~past ~row (Out_of_order Closed_without_open)))
;;

let on_line ~turns_path ~until ~start walk ~at ~past ~row (line : Log.line) =
  match walk.place, line with
  | Known known, (Log_started _ | Opened _ | Closed _ | Reset _) ->
    on_known ~until walk known ~at ~past ~row line
  | Resumed, Reset { cause; before; after; closed_before; at = written } ->
    on_reset ~until walk ~at ~past ~written ~cause ~before ~after ~closed_before
  | Resumed, (Log_started _ | Opened _) -> on_known ~until walk Between_turns ~at ~past ~row line
  | Resumed, Closed { turn; _ } ->
    if turn >= start
    then on_known ~until walk Between_turns ~at ~past ~row line
    else (
      match replay ~turns_path ~start ~turn ~closed:at with
      | Error error -> Scan.Stop (Error error)
      | Ok No_opened -> refused walk ~at ~past ~row (Out_of_order Closed_without_open)
      | Ok (Replayed { known; bytes }) ->
        on_known ~until { walk with bytes = walk.bytes + bytes } known ~at ~past ~row line)
;;

let checked_id ~turns_path ~expected =
  let replaced observed = Error (Fault (Turn_log_replaced { expected; observed })) in
  match Store.read_start turns_path with
  | Ok (Some { id; at = (_ : float); mark = (_ : Log.mark) }) ->
    if Log.Log_id.equal id expected then Ok () else replaced (Some id)
  | Ok None | Error (Row_undecodable _ | Log_start_missing) -> replaced None
  | Error (Read_failed { path; detail }) -> read_failed (Scan.Read_failed { path; detail })
  | Error Moved_while_reading -> read_failed Scan.Moved
;;

let read ~turns_path ~until (tail : Librarian_log.line) =
  let expected, start, covered, resumed =
    match tail with
    | Started { turn_log; turn_log_offset; covered; _ } -> turn_log, turn_log_offset, covered, None
    | Committed { turn_log; turn_log_offset; covered; covers_through; _ } ->
      let resumed =
        match covers_through with
        | Through { line; within = Item name } -> Some (line, name)
        | Through { within = Whole; line = (_ : int) } | Before_first -> None
      in
      turn_log, turn_log_offset, covered, resumed
  in
  match checked_id ~turns_path ~expected with
  | Error error -> Error error
  | Ok () ->
    let init =
      { place = (if Int.equal start 0 then Known Not_started else Resumed)
      ; resumed
      ; from = covered
      ; spans = []
      ; with_items = 0
      ; bytes = 0
      }
    in
    let reading walk stop = Ok { spans = List.rev walk.spans; stop; bytes = walk.bytes } in
    (match
       Store.fold_from turns_path ~from:start ~init
         ~f:(fun walk ({ at; past; row; line } : Store.scanned) ->
           let walk = { walk with bytes = walk.bytes + past - at } in
           match line with
           | Error reason -> refused walk ~at ~past ~row (Undecodable reason)
           | Ok line -> on_line ~turns_path ~until ~start walk ~at ~past ~row line)
     with
     | Ok (Reached_end walk) -> reading walk Log_end
     | Ok (Stopped (Ok (walk, stop))) -> reading walk stop
     | Ok (Stopped (Error error)) -> Error error
     | Error (Not_a_row_start { from; length }) -> Error (Fault (Position_lost { offset = from; length }))
     | Error (Scan_failed error) -> read_failed error)
;;
