(* Which lines the turn path appends (RFC librarian-call-only-proposes §5.2).

   The first group pins each row of the table as text. The second runs a
   small model of a Keeper through every order of admissions, endings,
   process restarts, lost appends, failed saves and replaced heads up to a
   depth, and checks after every append that the lines name exactly the
   messages the head closed, each once, under the turn the log showed
   open. *)

open Alcotest
module Log = Masc.Keeper_turn_log
module Marks = Masc.Keeper_turn_log_marks
module Store = Masc.Keeper_turn_log_store
module Writer = Masc.Keeper_turn_log_writer
module Objects = Agent_core.Checkpoint_objects

let log_id =
  match Log.Log_id.of_string (String.make 32 'a') with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let turn_ref = Ids.Turn_ref.make ~trace_id:"trace" ~absolute_turn:1
let admit = Writer.Admit { turn_ref; runtime = "runtime-a"; task = No_task; stimuli = [] }

let mark ?(trace = "a") ?(chat_bytes = 0) closed_messages : Log.mark =
  { trace
  ; closed_messages
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes
  ; external_rows = 0
  }
;;

let digest_of_letter letter =
  match Objects.digest_of_hex (String.make 64 letter) with
  | Ok digest -> digest
  | Error detail -> fail detail
;;

let turn letter messages : Objects.turn =
  { bundle = digest_of_letter letter; messages; chain = Objects.chain_start }
;;

let covered_from ?(first = 0) turns =
  Marks.of_head
    { segment =
        (if first = 0
         then None
         else
           Some
             { segment = digest_of_letter 'f'
             ; segment_messages = first
             ; segment_chain = Objects.chain_start
             })
    ; turns
    ; open_messages = []
    }
;;

(* a holds messages 0 to 2, b 3 and 4, c 5 to 8. *)
let nine = covered_from [ turn 'a' 3; turn 'b' 2; turn 'c' 4 ]

let outcome_text : Log.outcome -> string = function
  | Completed -> "completed"
  | Errored -> "errored"
  | Cancelled -> "cancelled"
  | Save_failed -> "save_failed"
  | Stale_save -> "stale_save"
  | Close_missing -> "close_missing"
  | Process_exited -> "process_exited"
;;

let slices_text slices =
  String.concat " "
    (List.map
       (fun (slice : Log.slice) ->
          Printf.sprintf "%c+%d:%d" (slice.bundle :> string).[0] slice.skip slice.take)
       slices)
;;

let mark_text (mark : Log.mark) =
  Printf.sprintf "%s:%d/chat %d" mark.trace mark.closed_messages mark.chat_bytes
;;

let line_text : Log.line -> string = function
  | Log_started { mark; _ } -> "started at " ^ mark_text mark
  | Opened { baseline; _ } -> "opened from " ^ mark_text baseline
  | Closed { turn; outcome; after; unattributed; own; _ } ->
    Printf.sprintf "closed %d %s to %s before [%s] own [%s]" turn (outcome_text outcome)
      (mark_text after) (slices_text unattributed) (slices_text own)
  | Reset { cause; before; after; closed_before; _ } ->
    Printf.sprintf "reset %s %s -> %s [%s]"
      (match cause with
       | Unannounced -> "unannounced"
       | Announced Cleared -> "cleared"
       | Announced Recovered -> "recovered")
      (mark_text before) (mark_text after) (slices_text closed_before)
;;

let written ?open_turn point : Store.tail =
  Written { rows_end = 1000; point; open_turn; last = Log_started { id = log_id; at = 0.0; mark = point } }
;;

let open_at ?(reset_since = false) opened baseline : Store.open_turn =
  { opened; baseline; reset_since }
;;

let plan_text ?(covered = nine) ~tail ~now event =
  match Writer.plan ~at:1.0 ~new_log_id:log_id ~tail ~now ~covered event with
  | Ok [] -> "nothing"
  | Ok lines -> String.concat " | " (List.map line_text lines)
  | Error (Starts_before_covered { from; first }) ->
    Printf.sprintf "needs the segment before: %d < %d" from first
  | Error (Ends_after_covered { through; last }) -> Printf.sprintf "ends at %d after %d" through last
  | Error (Backwards { from; through }) -> Printf.sprintf "backwards %d %d" from through
;;

let finish ?(ending = Writer.Completed) admitted = Writer.Finish { admitted; ending }

let test_nothing_written () =
  let now = mark 9 in
  check string "an admission starts the log and opens its turn"
    "started at a:9/chat 0 | opened from a:9/chat 0"
    (plan_text ~tail:Nothing_written ~now admit);
  check string "a process start starts the log" "started at a:9/chat 0"
    (plan_text ~tail:Nothing_written ~now Process_start);
  check string "an ending has nothing to close" "nothing"
    (plan_text ~tail:Nothing_written ~now (finish (Recorded { opened = 40 })))
;;

let test_admission () =
  check string "every earlier turn is closed" "opened from a:9/chat 0"
    (plan_text ~tail:(written (mark 5)) ~now:(mark 9) admit);
  check string "the last turn was never closed: both lines in one append"
    "closed 40 close_missing to a:9/chat 0 before [b+0:2] own [c+0:4] | opened from a:9/chat 0"
    (plan_text ~tail:(written ~open_turn:(open_at 40 (mark 5)) (mark 3)) ~now:(mark 9) admit)
;;

let test_ending () =
  let tail = written ~open_turn:(open_at 40 (mark 5)) (mark 3) in
  check string "closed before the admission is not the turn's"
    "closed 40 completed to a:9/chat 0 before [b+0:2] own [c+0:4]"
    (plan_text ~tail ~now:(mark 9) (finish (Recorded { opened = 40 })));
  check string "the split falls inside a bundle"
    "closed 40 errored to a:9/chat 0 before [a+2:1 b+0:2 c+0:1] own [c+1:3]"
    (plan_text
       ~tail:(written ~open_turn:(open_at 40 (mark 6)) (mark 2))
       ~now:(mark 9)
       (finish ~ending:Errored (Recorded { opened = 40 })));
  check string "a failed closing save closes nothing"
    "closed 40 save_failed to a:5/chat 0 before [b+0:2] own []"
    (plan_text
       ~covered:(covered_from [ turn 'a' 3; turn 'b' 2 ])
       ~tail ~now:(mark 5)
       (finish ~ending:Save_failed (Recorded { opened = 40 })));
  check string "a turn whose Opened was not written writes nothing" "nothing"
    (plan_text ~tail ~now:(mark 9) (finish Not_recorded));
  check string "the open turn is another turn's" "nothing"
    (plan_text ~tail ~now:(mark 9) (finish (Recorded { opened = 77 })));
  check string "the turn is closed already" "nothing"
    (plan_text ~tail:(written (mark 9)) ~now:(mark 9) (finish (Recorded { opened = 40 })))
;;

let test_process_start () =
  check string "the last turn died open"
    "closed 40 process_exited to a:9/chat 0 before [] own [c+0:4]"
    (plan_text ~tail:(written ~open_turn:(open_at 40 (mark 5)) (mark 5)) ~now:(mark 9) Process_start);
  check string "no open turn" "nothing"
    (plan_text ~tail:(written (mark 5)) ~now:(mark 9) Process_start);
  check string "no open turn and a replaced head: the next line that is written says so" "nothing"
    (plan_text ~tail:(written (mark 5)) ~now:(mark ~trace:"b" 0) Process_start)
;;

(* The reset keeps the other stores where the last line left them, and its
   history part is the empty mark of the new head. *)
let test_replaced_head () =
  let two = covered_from [ turn 'd' 2 ] in
  check string "another trace, seen at an admission"
    "reset unannounced a:9/chat 7 -> b:0/chat 7 [] | opened from b:2/chat 30"
    (plan_text ~covered:two
       ~tail:(written (mark ~chat_bytes:7 9))
       ~now:(mark ~trace:"b" ~chat_bytes:30 2)
       admit);
  check string "fewer closed messages on the same trace, with a turn left open"
    "reset unannounced a:9/chat 0 -> a:0/chat 0 [] | closed 40 close_missing to a:2/chat 0 before [d+0:2] own [] | opened from a:2/chat 0"
    (plan_text ~covered:two
       ~tail:(written ~open_turn:(open_at 40 (mark 9)) (mark 9))
       ~now:(mark 2) admit);
  check string "seen when the turn ends: what the new head holds is named, not as the turn's"
    "reset unannounced a:9/chat 0 -> b:0/chat 0 [] | closed 40 completed to b:2/chat 0 before [d+0:2] own []"
    (plan_text ~covered:two
       ~tail:(written ~open_turn:(open_at 40 (mark 9)) (mark 9))
       ~now:(mark ~trace:"b" 2)
       (finish (Recorded { opened = 40 })));
  check string "after that reset the same head is not lower again" "opened from b:2/chat 0"
    (plan_text ~covered:two ~tail:(written (mark ~trace:"b" 0)) ~now:(mark ~trace:"b" 2) admit);
  check string "an empty head on a trace the log already starts from" "opened from a:0/chat 0"
    (plan_text ~covered:(covered_from []) ~tail:(written (mark 0)) ~now:(mark 0) admit)
;;

(* The turn was admitted at 2 and never closed. A clear then wrote its reset
   and put the head back to nothing. The five messages closed since are the
   kept ones, not the turn's, though its baseline falls among them. *)
let test_reset_inside_the_turn () =
  check string "a reset followed the Opened: nothing is the turn's"
    "closed 40 close_missing to a:5/chat 0 before [a+0:3 b+0:2] own [] | opened from a:5/chat 0"
    (plan_text
       ~covered:(covered_from [ turn 'a' 3; turn 'b' 2 ])
       ~tail:(written ~open_turn:(open_at ~reset_since:true 40 (mark 2)) (mark 0))
       ~now:(mark 5) admit)
;;

(* A clear or a recovering purge is about to change the head. Its line names
   what was closed since the last unit, so what the path drops is named
   before it goes, and moves only the history part of the mark. *)
let test_announced_reset () =
  let keep kept (mark : Log.mark) = { mark with closed_messages = kept } in
  let cleared = Writer.Reset { cause = Cleared; after = keep 0 } in
  check string "the log had not started"
    "started at a:9/chat 4 | reset cleared a:9/chat 4 -> a:0/chat 4 []"
    (plan_text ~tail:Nothing_written ~now:(mark ~chat_bytes:4 9) cleared);
  check string "what was closed since the last unit is named, the other stores stay"
    "reset cleared a:9/chat 30 -> a:0/chat 30 [b+0:2 c+0:4]"
    (plan_text ~tail:(written (mark ~chat_bytes:7 3)) ~now:(mark ~chat_bytes:30 9) cleared);
  check string "an open turn stays open"
    "reset recovered a:9/chat 0 -> a:6/chat 0 [b+0:2 c+0:4]"
    (plan_text
       ~tail:(written ~open_turn:(open_at 40 (mark 5)) (mark 3))
       ~now:(mark 9)
       (Writer.Reset { cause = Recovered; after = keep 6 }));
  check string "a head replaced before it: the unannounced reset goes first"
    "reset unannounced a:9/chat 0 -> b:0/chat 0 [] | reset cleared b:2/chat 0 -> b:0/chat 0 [d+0:2]"
    (plan_text ~covered:(covered_from [ turn 'd' 2 ]) ~tail:(written (mark 9))
       ~now:(mark ~trace:"b" 2) cleared)
;;

let named_text ~tail now =
  match Writer.named ~tail ~now with
  | Ok No_log -> "no log"
  | Ok (Named_below below) -> Printf.sprintf "named below %d" below
  | Error () -> "the head was not read"
;;

(* Which of the head's messages a unit will still read from the head: the
   ones past the last unit's mark, so a purge may rewrite only the ones below
   it. A replaced head has none below it: the next line is the reset [plan]
   writes, which puts the mark at the new head's empty start. *)
let test_named () =
  let now ?trace closed () = Ok (mark ?trace closed) in
  check string "nothing written: the head is not read" "no log"
    (named_text ~tail:Nothing_written (fun () -> fail "the head was read"));
  check string "the head grew past the last unit: what that unit counts" "named below 3"
    (named_text ~tail:(written ~open_turn:(open_at 40 (mark 5)) (mark 3)) (now 9));
  check string "another trace: none" "named below 0"
    (named_text ~tail:(written (mark 9)) (now ~trace:"b" 2));
  check string "fewer closed messages on the same trace: none" "named below 0"
    (named_text ~tail:(written (mark 9)) (now 2));
  check string "after that reset the same head is not replaced again" "named below 0"
    (named_text ~tail:(written (mark ~trace:"b" 0)) (now ~trace:"b" 2));
  check string "a head that is not read: the error" "the head was not read"
    (named_text ~tail:(written (mark 9)) (fun () -> Error ()))
;;

(* A path about to drop a head the log does not read: the last mark, then
   no closed message on the trace the path leaves. *)
let test_drop () =
  let emptied trace (mark : Log.mark) = { mark with trace; closed_messages = 0 } in
  let drop ~tail ~now ~after =
    line_text (Writer.drop ~at:1.0 ~new_log_id:log_id ~tail ~now ~after)
  in
  check string "the log had not started: its first line at the emptied mark"
    "started at a:0/chat 4" (drop ~tail:Nothing_written ~now:(mark ~chat_bytes:4 0) ~after:(emptied "a"));
  check string "from the last mark, the other stores where it left them"
    "reset unannounced a:9/chat 7 -> a:0/chat 7 []"
    (drop ~tail:(written (mark ~chat_bytes:7 9)) ~now:(mark ~chat_bytes:30 0) ~after:(emptied "a"));
  check string "written even when the last mark counts nothing"
    "reset unannounced a:0/chat 0 -> b:0/chat 0 []"
    (drop ~tail:(written ~open_turn:(open_at 40 (mark 0)) (mark 0)) ~now:(mark 0) ~after:(emptied "b"))
;;

let test_ranges () =
  let behind = covered_from ~first:5 [ turn 'c' 4 ] in
  check string "the unit starts before the head's own turns" "needs the segment before: 3 < 5"
    (plan_text ~covered:behind
       ~tail:(written ~open_turn:(open_at 40 (mark 5)) (mark 3))
       ~now:(mark 9)
       (finish (Recorded { opened = 40 })));
  (* The head was replaced by one that had already grown past the last mark.
     A count cannot see it. The turn is still closed. *)
  check string "a baseline past the end" "closed 40 completed to a:9/chat 0 before [c+0:4] own []"
    (plan_text
       ~tail:(written ~open_turn:(open_at 40 (mark 12)) (mark 5))
       ~now:(mark 9)
       (finish (Recorded { opened = 40 })))
;;

(* {1 The model} *)

type message =
  { id : int
  ; owner : int option
  (* Offset of the Opened the log showed open, on this head, when the
     message was closed. *)
  }

type head =
  { generation : int
  ; trace : string
  ; turns : (Objects.turn * message list) list (* Closed turns, oldest first. *)
  ; open_messages : int
  }

type state =
  { tail : Store.tail (* What reading the log forward gives. *)
  ; position : Log.position
  ; next_offset : int
  ; head : head
  ; unnamed : message list (* Closed on this head, and no line has named them yet. *)
  ; point_generation : int (* The head the last line that ends a unit saw. *)
  ; opened_on : (int * int) list (* Opened offset, generation of the head it was admitted on. *)
  ; running : Writer.admitted option (* The turn the process is running. *)
  ; next_id : int
  ; clock : int
  }

type step =
  | Admit of
      { close_ok : bool
      ; append_ok : bool
      }
  | Finish of
      { save_ok : bool
      ; append_ok : bool
      }
  | Process_restart of
      { close_ok : bool
      ; append_ok : bool
      }
  | Recreated (* Another trace, nothing in it. *)
  | Emptied (* The same trace, nothing in it: a head this build cannot decode. *)
  | Cleared_keeping (* The same trace, one kept message put in open. *)
  | Shrink of
      { cause : Log.announced
      ; changed : bool
      }
  (* A clear or a recovering purge through the reset function: the closing
     save and the line landed; [changed] is whether the head change followed.
     A failed change and a kill leave the same disk. A closing save or an
     append that fails changes nothing, so the model leaves them out. *)
  | Dropped of { changed : bool }
  (* A path drops the head without reading it, after its line landed. *)

let step_text = function
  | Admit { close_ok; append_ok } -> Printf.sprintf "admit(close %b, append %b)" close_ok append_ok
  | Finish { save_ok; append_ok } -> Printf.sprintf "finish(save %b, append %b)" save_ok append_ok
  | Process_restart { close_ok; append_ok } ->
    Printf.sprintf "restart(close %b, append %b)" close_ok append_ok
  | Recreated -> "recreated"
  | Emptied -> "emptied"
  | Cleared_keeping -> "cleared keeping one"
  | Shrink { cause; changed } ->
    Printf.sprintf "%s(changed %b)"
      (match cause with
       | Cleared -> "clear"
       | Recovered -> "recover")
      changed
  | Dropped { changed } -> Printf.sprintf "drop(changed %b)" changed
;;

(* A head replaced by one that had already grown past the last mark. The
   lines cannot show it (RFC §5.2), so the model stops following that order
   and counts it. *)
exception Invisible

type seen =
  { mutable orders : int
  ; mutable invisible : int
  ; mutable closed_lines : int
  ; mutable close_missing : int
  ; mutable process_exited : int
  ; mutable resets : int
  ; mutable announced : int
  ; mutable announced_unchanged : int
  ; mutable dropped : int
  ; mutable own_messages : int
  ; mutable unattributed_messages : int
  }

let seen =
  { orders = 0
  ; invisible = 0
  ; closed_lines = 0
  ; close_missing = 0
  ; process_exited = 0
  ; resets = 0
  ; announced = 0
  ; announced_unchanged = 0
  ; dropped = 0
  ; own_messages = 0
  ; unattributed_messages = 0
  }
;;

let digests : (int, Objects.digest) Hashtbl.t = Hashtbl.create 64

let digest number =
  match Hashtbl.find_opt digests number with
  | Some digest -> digest
  | None ->
    let digest = Objects.digest_of_bytes (string_of_int number) in
    Hashtbl.add digests number digest;
    digest
;;

let closed_ids head = List.concat_map (fun ((_ : Objects.turn), messages) -> messages) head.turns
let ids messages = List.map (fun message -> message.id) messages

let mark_of state : Log.mark =
  { trace = state.head.trace
  ; closed_messages = List.length (closed_ids state.head)
  ; session = ""
  ; history_bytes = 0
  ; internal_bytes = 0
  ; chat_bytes = state.clock
  ; external_rows = 0
  }
;;

let covered_of state =
  covered_from (List.map (fun (turn, (_ : message list)) -> turn) state.head.turns)
;;

let shown_open state =
  match state.tail with
  | Written { open_turn = Some { reset_since = true; _ }; _ } -> None
  | Written { open_turn = Some { opened; reset_since = false; _ }; _ } ->
    if Int.equal (List.assoc opened state.opened_on) state.head.generation
    then Some opened
    else None
  | Written { open_turn = None; _ } | Nothing_written -> None
;;

let close_open state =
  let count = state.head.open_messages in
  if count = 0
  then state
  else (
    let owner = shown_open state in
    let messages = List.init count (fun index -> { id = state.next_id + index; owner }) in
    let turn : Objects.turn =
      { bundle = digest state.next_id; messages = count; chain = Objects.chain_start }
    in
    { state with
      head =
        { state.head with turns = state.head.turns @ [ turn, messages ]; open_messages = 0 }
    ; unnamed = state.unnamed @ messages
    ; next_id = state.next_id + count
    })
;;

let replace_head state ~trace ~open_messages =
  { state with
    head = { generation = state.head.generation + 1; trace; turns = []; open_messages }
  ; unnamed = []
  }
;;

let named state slices =
  List.concat_map
    (fun (slice : Log.slice) ->
       match
         List.find_opt
           (fun ((turn : Objects.turn), (_ : message list)) ->
              String.equal (turn.bundle :> string) (slice.bundle :> string))
           state.head.turns
       with
       | None -> fail "a slice names a bundle the head does not hold"
       | Some ((_ : Objects.turn), messages) ->
         if slice.take < 1 || slice.skip < 0 || slice.skip + slice.take > List.length messages
         then fail "a slice reaches outside its bundle"
         else
           ids
             (List.filteri
                (fun index (_ : message) -> index >= slice.skip && index < slice.skip + slice.take)
                messages))
    slices
;;

(* [check] writes a line for every call. The model makes millions, so it
   speaks only when something is wrong. *)
let expect label holds = if not holds then fail label

let expect_ids label expected actual =
  if not (List.equal Int.equal expected actual)
  then (
    let text numbers = String.concat " " (List.map string_of_int numbers) in
    failf "%s: expected [%s], got [%s]" label (text expected) (text actual))
;;

let rec drop count list =
  if count <= 0
  then list
  else (
    match list with
    | [] -> []
    | _ :: rest -> drop (count - 1) rest)
;;

(* What a drop's line leaves: the next unit names the whole head from its
   first message, as no turn's. *)
let named_again state =
  List.map (fun message -> { message with owner = None }) (closed_ids state.head)
;;

let apply_line ~dropping ~now state (line : Log.line) =
  let offset = state.next_offset in
  let position =
    match Log.step state.position ~offset line with
    | Ok position -> position
    | Error
        ( Not_started | Started_twice | Opened_while_open _ | Closed_without_open
        | Closed_another_turn _ | Own_after_reset _ ) ->
      fail ("a line the reader's order rule refuses: " ^ line_text line)
  in
  let state = { state with position; next_offset = offset + 1 } in
  let rows_end = offset + 1 in
  match line, state.tail with
  | Log_started { mark; _ }, (Nothing_written | Written _) ->
    if dropping
    then
      expect "a drop starts the log at no closed message of the head's trace"
        (mark = { now with trace = state.head.trace; closed_messages = 0 });
    { state with
      tail = Written { rows_end; point = mark; open_turn = None; last = line }
    ; unnamed = (if dropping then named_again state else [])
    ; point_generation = state.head.generation
    }
  | (Opened _ | Closed _ | Reset _), Nothing_written -> fail "a line before the log started"
  | Opened { baseline; _ }, Written { point; open_turn = (_ : Store.open_turn option); _ } ->
    expect "the baseline is where the head ends now" (baseline = now);
    { state with
      tail =
        Written
          { rows_end
          ; point
          ; open_turn = Some { opened = offset; baseline; reset_since = false }
          ; last = line
          }
    ; opened_on = (offset, state.head.generation) :: state.opened_on
    }
  | Reset { cause = Announced _; before; after; closed_before; _ }, Written { open_turn; _ } ->
    seen.announced <- seen.announced + 1;
    expect "an announced reset starts where the stores end now" (before = now);
    expect "it moves the history count only, on the same trace"
      (after = { now with closed_messages = after.closed_messages });
    expect_ids "it names every message closed since the last unit, in order"
      (ids state.unnamed) (named state closed_before);
    (* The next unit starts at [after]. Until the change lands that names
       again what lies above it, as no turn's. *)
    { state with
      tail =
        Written
          { rows_end
          ; point = after
          ; open_turn =
              Option.map (fun (turn : Store.open_turn) -> { turn with reset_since = true }) open_turn
          ; last = line
          }
    ; unnamed =
        List.map
          (fun message -> { message with owner = None })
          (drop after.closed_messages (closed_ids state.head))
    ; point_generation = state.head.generation
    }
  | Reset { cause = Unannounced; before; after; closed_before; _ }, Written { point; open_turn; _ }
    when dropping ->
    seen.dropped <- seen.dropped + 1;
    expect "a drop starts at the last mark" (before = point);
    expect "it ends at no closed message of the head's trace, other stores untouched"
      (after = { point with trace = state.head.trace; closed_messages = 0 });
    expect "a drop names nothing" (List.is_empty closed_before);
    { state with
      tail =
        Written
          { rows_end
          ; point = after
          ; open_turn =
              Option.map (fun (turn : Store.open_turn) -> { turn with reset_since = true }) open_turn
          ; last = line
          }
    ; unnamed = named_again state
    ; point_generation = state.head.generation
    }
  | Reset { cause = Unannounced; before; after; closed_before; _ }, Written { point; open_turn; _ } ->
    seen.resets <- seen.resets + 1;
    expect "the reset starts at the last mark" (before = point);
    expect "the reset ends at the empty mark of the head, other stores untouched"
      (after = { point with trace = now.trace; closed_messages = 0 });
    expect "the reset names nothing" (List.is_empty closed_before);
    expect_ids "the next unit names everything the new head holds"
      (ids (closed_ids state.head)) (ids state.unnamed);
    { state with
      tail =
        Written
          { rows_end
          ; point = after
          ; open_turn =
              Option.map (fun (turn : Store.open_turn) -> { turn with reset_since = true }) open_turn
          ; last = line
          }
    ; point_generation = state.head.generation
    }
  | Closed { turn; outcome; after; unattributed; own; _ }, Written { open_turn; _ } ->
    seen.closed_lines <- seen.closed_lines + 1;
    (match outcome with
     | Close_missing -> seen.close_missing <- seen.close_missing + 1
     | Process_exited -> seen.process_exited <- seen.process_exited + 1
     | Completed | Errored | Cancelled | Save_failed | Stale_save -> ());
    (match open_turn with
     | Some { opened; _ } -> expect "the line closes the open turn" (Int.equal opened turn)
     | None -> fail "a Closed with no turn open");
    expect "the line ends where the head ends now" (after = now);
    let named_before = named state unattributed in
    let named_own = named state own in
    let is_own message = message.owner = Some turn in
    expect_ids "every message closed since the last unit is named once, in order"
      (ids state.unnamed) (named_before @ named_own);
    expect_ids "own is what was closed while the log showed this turn open"
      (ids (List.filter is_own state.unnamed)) named_own;
    seen.own_messages <- seen.own_messages + List.length named_own;
    seen.unattributed_messages <- seen.unattributed_messages + List.length named_before;
    { state with
      tail = Written { rows_end; point = after; open_turn = None; last = line }
    ; unnamed = []
    ; point_generation = state.head.generation
    }
;;

(* The lines landed. A head the last line did not see must be announced by a
   reset in front, when a count or a trace can show it. *)
let append ?(dropping = false) state ~now lines =
  (match state.tail, lines with
   | Nothing_written, _ | Written _, [] -> ()
   | Written _, _ :: _ when dropping -> ()
   | Written { point; _ }, first :: _ ->
     let replaced = state.head.generation <> state.point_generation in
     let visible =
       (not (String.equal now.Log.trace point.trace))
       || now.closed_messages < point.closed_messages
     in
     (match first, replaced with
      | Log.Reset { cause = Unannounced; _ }, true -> ()
      | Log.Reset { cause = Unannounced; _ }, false -> fail "a reset for a head that was not replaced"
      | (Log_started _ | Opened _ | Closed _ | Reset { cause = Announced _; _ }), false -> ()
      | (Log_started _ | Opened _ | Closed _ | Reset { cause = Announced _; _ }), true ->
        if visible then fail "a replaced head and no reset in front" else raise Invisible));
  let state = List.fold_left (apply_line ~dropping ~now) state lines in
  (* Where the log says the next unit starts is where the unnamed begin. *)
  (match state.tail with
   | Written { point; _ } when state.head.generation = state.point_generation ->
     expect_ids "nothing is skipped and nothing is named twice"
       (ids (drop point.closed_messages (closed_ids state.head)))
       (ids state.unnamed)
   | Written _ | Nothing_written -> ());
  state
;;

let plan state event =
  let now = mark_of state in
  match
    Writer.plan ~at:(float_of_int state.clock) ~new_log_id:log_id ~tail:state.tail ~now
      ~covered:(covered_of state) event
  with
  | Ok lines -> now, lines
  | Error (Starts_before_covered _ | Ends_after_covered _ | Backwards _) ->
    fail "the whole head was given and a range fell outside it"
;;

let last_offset state = state.next_offset - 1

let take state step =
  let state = { state with clock = state.clock + 1 } in
  match step with
  | Admit { close_ok; append_ok } ->
    let state = if close_ok then close_open state else state in
    let now, lines = plan state admit in
    (match List.rev lines with
     | Log.Opened _ :: _ -> ()
     | (Log_started _ | Closed _ | Reset _) :: _ | [] -> fail "an admission does not end in Opened");
    let state, admitted =
      if append_ok
      then (
        let state = append state ~now lines in
        state, Writer.Recorded { opened = last_offset state })
      else state, Writer.Not_recorded
    in
    { state with
      running = Some admitted
    ; head = { state.head with open_messages = state.head.open_messages + 1 }
    }
  | Finish { save_ok; append_ok } ->
    let admitted =
      match state.running with
      | Some admitted -> admitted
      | None -> fail "the model ended a turn that was not running"
    in
    let state = if save_ok then close_open state else state in
    let ending = if save_ok then Writer.Completed else Writer.Save_failed in
    let now, lines = plan state (Writer.Finish { admitted; ending }) in
    (match admitted, lines with
     | Not_recorded, _ :: _ -> fail "a turn with no Opened wrote a line"
     | Not_recorded, [] | Recorded _, _ -> ());
    let state = if append_ok then append state ~now lines else state in
    { state with running = None }
  | Process_restart { close_ok; append_ok } ->
    let state = { state with running = None } in
    let state = if close_ok then close_open state else state in
    let now, lines = plan state Writer.Process_start in
    if append_ok then append state ~now lines else state
  | Shrink { cause; changed } ->
    let state = close_open state in
    (* What the path keeps closed: nothing for a clear, whose kept message
       goes in open; the first half of the closed turns for a recovery. *)
    let kept_turns =
      match cause with
      | Cleared -> []
      | Recovered -> List.filteri (fun index _ -> index < List.length state.head.turns / 2) state.head.turns
    in
    let kept = List.length (List.concat_map (fun ((_ : Objects.turn), messages) -> messages) kept_turns) in
    let now, lines =
      plan state (Writer.Reset { cause; after = (fun mark -> { mark with closed_messages = kept }) })
    in
    (match List.rev lines with
     | Log.Reset { cause = Announced last; _ } :: _ when last = cause -> ()
     | (Log_started _ | Opened _ | Closed _ | Reset _) :: _ | [] ->
       fail "a reset does not end in its announced line");
    let state = append state ~now lines in
    if changed
    then (
      let generation = state.head.generation + 1 in
      let open_messages =
        match cause with
        | Cleared -> 1
        | Recovered -> 0
      in
      { state with
        head = { generation; trace = state.head.trace; turns = kept_turns; open_messages }
      ; unnamed = []
      ; point_generation = generation
      })
    else (
      seen.announced_unchanged <- seen.announced_unchanged + 1;
      state)
  | Dropped { changed } ->
    let now = { (mark_of state) with closed_messages = 0 } in
    let line =
      Writer.drop ~at:(float_of_int state.clock) ~new_log_id:log_id ~tail:state.tail ~now
        ~after:(fun mark -> { mark with trace = state.head.trace; closed_messages = 0 })
    in
    let state = append ~dropping:true state ~now [ line ] in
    if changed
    then (
      let generation = state.head.generation + 1 in
      { state with
        head = { generation; trace = state.head.trace; turns = []; open_messages = 0 }
      ; unnamed = []
      ; point_generation = generation
      })
    else state
  | Recreated ->
    replace_head state ~trace:(Printf.sprintf "t%d" (state.head.generation + 1)) ~open_messages:0
  | Emptied -> replace_head state ~trace:state.head.trace ~open_messages:0
  | Cleared_keeping -> replace_head state ~trace:state.head.trace ~open_messages:1
;;

let both = [ true; false ]

(* A save that has nothing to close cannot fail, so only one of the two is
   tried. [resets] adds the shrinking paths; they widen every state by four,
   so they are followed one step less deep. *)
let steps ~resets state =
  let saves = if state.head.open_messages > 0 then both else [ true ] in
  let pairs make =
    List.concat_map (fun first -> List.map (fun append_ok -> make first append_ok) both) saves
  in
  let restarts = pairs (fun close_ok append_ok -> Process_restart { close_ok; append_ok }) in
  match state.running with
  | Some (_ : Writer.admitted) ->
    pairs (fun save_ok append_ok -> Finish { save_ok; append_ok }) @ restarts
  | None ->
    pairs (fun close_ok append_ok -> Admit { close_ok; append_ok })
    @ restarts
    @ [ Recreated; Emptied; Cleared_keeping ]
    @
    if resets
    then
      List.concat_map
        (fun cause -> List.map (fun changed -> Shrink { cause; changed }) both)
        [ Log.Cleared; Log.Recovered ]
      @ List.map (fun changed -> Dropped { changed }) both
    else []
;;

let start =
  { tail = Nothing_written
  ; position = Nothing_written
  ; next_offset = 0
  ; head = { generation = 0; trace = "t0"; turns = []; open_messages = 0 }
  ; unnamed = []
  ; point_generation = 0
  ; opened_on = []
  ; running = None
  ; next_id = 0
  ; clock = 0
  }
;;

let rec explore ~resets state path remaining =
  if remaining = 0
  then seen.orders <- seen.orders + 1
  else
    List.iter
      (fun step ->
         let path = step :: path in
         match take state step with
         | state -> explore ~resets state path (remaining - 1)
         | exception Invisible -> seen.invisible <- seen.invisible + 1
         | exception exn ->
           Printf.eprintf "order: %s\n%!" (String.concat ", " (List.rev_map step_text path));
           raise exn)
      (steps ~resets state)
;;

let test_every_order () =
  explore ~resets:false start [] 8;
  explore ~resets:true start [] 7;
  (* The model must have reached every kind of line, or it has shown
     nothing. *)
  List.iter
    (fun (label, count) -> check bool label true (count > 0))
    [ "orders followed to the end", seen.orders
    ; "orders the lines cannot show", seen.invisible
    ; "Closed lines", seen.closed_lines
    ; "Close_missing", seen.close_missing
    ; "Process_exited", seen.process_exited
    ; "resets", seen.resets
    ; "announced resets", seen.announced
    ; "announced resets whose change did not follow", seen.announced_unchanged
    ; "drops", seen.dropped
    ; "messages named as a turn's own", seen.own_messages
    ; "messages named before a baseline", seen.unattributed_messages
    ];
  Printf.printf
    "orders %d, not visible %d, closed %d (missing %d, exited %d), resets %d, announced %d \
     (unchanged %d), drops %d, own %d, before %d\n%!"
    seen.orders seen.invisible seen.closed_lines seen.close_missing seen.process_exited seen.resets
    seen.announced seen.announced_unchanged seen.dropped seen.own_messages seen.unattributed_messages
;;

let () =
  run "keeper_turn_log_writer"
    [ ( "table"
      , [ test_case "nothing written" `Quick test_nothing_written
        ; test_case "admission" `Quick test_admission
        ; test_case "ending" `Quick test_ending
        ; test_case "process start" `Quick test_process_start
        ; test_case "a replaced head" `Quick test_replaced_head
        ; test_case "a reset inside the turn" `Quick test_reset_inside_the_turn
        ; test_case "an announced reset" `Quick test_announced_reset
        ; test_case "what the log has named" `Quick test_named
        ; test_case "a drop" `Quick test_drop
        ; test_case "ranges" `Quick test_ranges
        ] )
    ; "model", [ test_case "every order to a depth" `Quick test_every_order ]
    ]
;;
