module Store = Librarian_store
module Direct = Librarian_direct
module Lane = Librarian_memory_lane
module Read_result = Librarian_read_result
module Room_result = Librarian_room_result
module Last = Librarian_last

type place =
  { memory_dir : string
  ; turns_dir : string
  ; keeper_id : string
  }

type declared =
  { value : Lane.t
  ; resolved : Runtime_exact_output_registry.resolved_lane
  }

type asked =
  | Read of Read_result.asked
  | Room of Room_result.asked

type asking =
  { ask : int
  ; since : float
  ; lane : declared
  ; removed_since : (string * int) list
  ; asked : asked
  ; bottom : Librarian_bottom.t
  }

type state =
  | Idle of
      { store : Store.t
      ; seen_length : int option
      }
  | Asking of
      { store : Store.t
      ; asking : asking
      }
  | Resting of Store.t
  | Refused_at_bottom of Store.t
  | Stopped of Store.stop

type t =
  { state : state
  ; lane : declared option
  ; last_ask : int
  ; narrowing : Librarian_width.t
  ; bottom : Librarian_bottom.t
  ; last_read : Last.read option
  ; last_room : Last.room option
  ; read_alone : bool
  }

let boot { memory_dir; turns_dir; keeper_id } ~at =
  Store.boot ~memory_dir ~turns_dir ~keeper_id ~at
;;

let turns_path { turns_dir; keeper_id; memory_dir = (_ : string) } =
  Keeper_turn_log_store.path_for_keepers_dir ~keepers_dir:turns_dir ~keeper_id
;;

(* §9.2 "the next ask". The length is read before the turn log: read after,
   a turn appended in between would count as seen, and with its hint missed
   no pulse would find it. *)
let ask place t ~at store ~asked =
  let seen_length = Fs_compat.file_size (turns_path place) in
  let idle = { t with state = Idle { store; seen_length } } in
  match t.lane with
  | None -> idle
  | Some declared ->
    let reading =
      Librarian_unread.read ~turns_path:(turns_path place) ~until:(First_with_items 1)
        (Store.tail store)
    in
    if Librarian_unread.has_unread reading
    then (
      let ask = t.last_ask + 1 in
      { t with
        state =
          Asking
            { store
            ; asking =
                { ask
                ; since = at
                ; lane = declared
                ; removed_since = []
                ; asked = Read asked
                ; bottom = t.bottom
                }
            }
      ; last_ask = ask
      })
    else idle
;;

(* §7.4 「자리 내기」: asked once, right after an item read alone was
   committed, under the lane value that item was asked with. It reads no
   turn log, so it is asked whatever is unread. *)
let ask_room t ~at store ~(declared : declared) ~trace =
  let ask = t.last_ask + 1 in
  { t with
    state =
      Asking
        { store
        ; asking =
            { ask
            ; since = at
            ; lane = declared
            ; removed_since = []
            ; asked = Room { trace }
            ; bottom = t.bottom
            }
        }
  ; last_ask = ask
  }
;;

(* The width memory says how wide; the head item alone is asked only from
   the bottom's verdict. *)
let next_ask place t ~at store =
  ask place t ~at store ~asked:(Read_range (Librarian_width.next t.narrowing))
;;

let stopped ~lane ~last_ask stop =
  { state = Stopped stop
  ; lane
  ; last_ask
  ; narrowing = Librarian_width.empty
  ; bottom = Librarian_bottom.empty
  ; last_read = None
  ; last_room = None
  ; read_alone = false
  }
;;

let booted place ~at ~lane ~last_ask (opened : (Store.t, Store.stop) result) =
  match opened with
  | Error stop -> stopped ~lane ~last_ask stop
  | Ok store ->
    next_ask place
      { state = Idle { store; seen_length = None }
      ; lane
      ; last_ask
      ; narrowing = Librarian_width.empty
      ; bottom = Librarian_bottom.empty
      ; last_read = None
      ; last_room = None
      ; read_alone = false
      }
      ~at store
;;

type ended =
  | Read_ended of
      { asked : Read_result.asked
      ; result : Read_result.t
      }
  | Room_ended of Room_result.t

type event =
  | Turn_closed
  | Pulse
  | Ask_ended of
      { ask : int
      ; result : ended
      }
  | Declaration_changed of declared option

(* The answer of an ask that is not the current one is dropped; only one
   that carried an answer is counted. *)
let late place t (result : ended) =
  let answered =
    match result with
    | Read_ended { result = Answered _; asked = (_ : Read_result.asked) }
    | Room_ended (Room_answered _) -> true
    | Read_ended
        { result =
            ( Nothing_to_ask | No_answer _ | Nothing_readable _ | Span_unknown _
            | Memory_diverged _ | Snapshot_fault _ | Input_fault _ | Ask_failed _ )
        ; asked = (_ : Read_result.asked)
        }
    | Room_ended
        ( Room_not_answered _ | Room_memory_diverged _ | Room_snapshot_fault _
        | Room_failed _ ) -> false
  in
  if answered
  then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string LibrarianLateAnswers)
      ~labels:[ "keeper", place.keeper_id ]
      ();
  t
;;

(* §9.2 "a failed commit". Effects that make no snapshot mean the plan and
   the snapshot codec disagree. The store is as it was, and asking again at
   once would ask the same question, so the writer rests until a pulse.
   [after] goes on from the store a commit left. *)
let settled t store ~after (committed : Store.committed) =
  match committed with
  | Committed { store; line = (_ : Librarian_log.commit) } -> after store
  | Committed_without_snapshot (_ : Librarian_log.commit) ->
    { t with state = Stopped Store_unwritable }
  | Stopped stop -> { t with state = Stopped stop }
  | Not_a_snapshot (_ : Librarian_envelope.refusal) -> { t with state = Resting store }
;;

(* A commit that moved reading: [narrowing] is what the writer remembers
   once the commit is on disk, and the head item's size facts are about an
   item already passed (§7.4 「읽은 자리가 움직였다」). *)
let moved t ~narrowing = { t with narrowing; bottom = Librarian_bottom.empty }

(* A skip changes no snapshot, so it ends with its line on disk or with no
   line, and no line stops the store (§9.2 「건너뛰기 규칙」). [last] is what
   the line sets once it is on disk, as for a commit. *)
let after_skip place t ~at ~narrowing ~last : (Store.skipped, Store.stop) result -> t = function
  | Ok { store; line = (_ : Librarian_log.commit) } ->
    next_ask place { (moved t ~narrowing) with last_read = Some last } ~at store
  | Error stop -> { t with state = Stopped stop }
;;

(* §7.3 「Refused_by_lane, Silent_lane」 and §7.4: only the slots the lane
   declares now are read. Above the bottom, a refusal from one of them
   narrows by what the question carried and asks again at once (§7.6). At
   the bottom the refusals for size are learnt first, whatever the result
   saw, and then folded over the slots declared now, only while the
   snapshot the question was made against is the one now. Every slot sized
   for the input: the item with Memory gives way to the item alone, and the
   item alone is skipped. Every slot sized and not all for the input:
   [Refused_at_bottom]. Otherwise, and with no refusal above the bottom, the
   writer rests, unless none of them is in the result and the lane value
   moved while the ask was out: asking again uses the new value and does not
   repeat. A refusal narrows what the writer holds now: after a declaration
   that changed only slots, the ask is still out and what it holds is
   empty. *)
let no_answer place t ~at store (asking : asking) ~asked (question : Read_result.question) slots =
  let declared_now =
    match t.lane with
    | None -> []
    | Some declared -> declared.value.http @ declared.value.cli
  in
  let still_declared =
    List.filter
      (fun ((key : Lane.slot_key), _) -> List.exists (Lane.equal_slot_key key) declared_now)
      slots
  in
  let lane_moved =
    match t.lane with
    | None -> true
    | Some declared -> not (Lane.equal declared.value asking.lane.value)
  in
  (* What the result was, for the row (§12.2): whether a slot declared now
     said nothing is read against the slots declared now, as the verdict is. *)
  let lane_result ~one_item =
    Last.Lane
      { one_item; silent = Last.silent ~declared:declared_now slots; basis = question.basis; slots }
  in
  let ended ~one_item t = { t with last_read = Some (lane_result ~one_item) } in
  (* With no slot declared now in the result, the ask said nothing about the
     lane held now, so it sets nothing. *)
  let rest ~one_item t =
    if List.is_empty still_declared && lane_moved
    then next_ask place t ~at store
    else { (ended ~one_item t) with state = Resting store }
  in
  (* §7.4 「옛 Memory 를 두고 한 판정으로 내려가지 않는다」. *)
  let judged_now =
    String.equal
      (question.basis :> string)
      (Librarian_log.snapshot_after (Store.tail store) :> string)
  in
  let verdict () : Librarian_bottom.verdict =
    match t.lane with
    | None -> Not_all
    | Some declared -> Librarian_bottom.fold declared.value slots
  in
  match (asked : Read_result.asked), Librarian_width.breadth question.offered with
  | Read_range asked, Wider wider ->
    let refused =
      List.exists
        (fun ((_ : Lane.slot_key), (outcome : Librarian_slot_outcome.unanswered)) ->
           match outcome with
           | Refused (_ : Librarian_slot_outcome.refusal) -> true
           | Silent (_ : Librarian_slot_outcome.silence) -> false)
        still_declared
    in
    if refused
    then
      next_ask place
        { (ended ~one_item:false t) with
          narrowing = Librarian_width.refused t.narrowing ~asked wider
        }
        ~at store
    else rest ~one_item:false t
  | Read_range (_ : Librarian_width.width), One_item ->
    let t = { t with bottom = Librarian_bottom.learn t.bottom With_memory question.id slots } in
    if not judged_now
    then next_ask place t ~at store
    else (
      match verdict () with
      | Input -> ask place (ended ~one_item:true t) ~at store ~asked:Read_item_alone
      | All_not_input -> { (ended ~one_item:true t) with state = Refused_at_bottom store }
      | Not_all -> rest ~one_item:true t)
  | Read_item_alone, (One_item | Wider (_ : Librarian_width.wider)) ->
    let t = { t with bottom = Librarian_bottom.learn t.bottom Alone question.id slots } in
    if not judged_now
    then next_ask place t ~at store
    else (
      match verdict () with
      | Input ->
        let narrowing =
          Librarian_width.committed t.narrowing
            (Librarian_width.passed question.offered question.reach.within)
        in
        after_skip place t ~at ~narrowing ~last:(lane_result ~one_item:true)
          (Store.commit_skip store ~at ~hole:(Item_exceeds_window question.missing) question.reach)
      | All_not_input -> { (ended ~one_item:true t) with state = Refused_at_bottom store }
      | Not_all -> rest ~one_item:true t)
;;

(* After an item read alone, making room is asked at once, unless a direct
   write removed a fact or the lane value moved while the item was asked:
   what it showed is already old (§7.4 「자리 내기」). *)
let after_alone place t ~at store (asking : asking) ~trace =
  match t.lane with
  | Some declared
    when List.is_empty asking.removed_since && Lane.equal declared.value asking.lane.value ->
    ask_room t ~at store ~declared ~trace
  | Some _ | None -> next_ask place t ~at store
;;

(* The current reading ask's result (§9.3, the table under "Asking a"). *)
let ended_read place t ~at store (asking : asking) ~(asked : Read_result.asked)
  : Read_result.t -> t
  = function
  | Answered { question; answer; slot } ->
    let plan =
      Librarian_plan.of_answer ~shown:(Read question.shown) ~facts:(Store.memory store).facts
        ~removed_since:asking.removed_since ~at ~trace_id:question.trace answer
    in
    let narrowing =
      Librarian_width.committed t.narrowing
        (Librarian_width.passed question.offered question.reach.within)
    in
    let committed = Store.commit_read store ~at ~question ~slot plan in
    (* A range shows Memory, so its read is one with Memory, and what the
       last room ask said is about a Memory before it (§12.2 E5, W3). *)
    (match asked with
     | Read_range (_ : Librarian_width.width) ->
       settled t store committed ~after:(fun store ->
         next_ask place
           { (moved t ~narrowing) with
             last_read = Some Last.Committed
           ; read_alone = false
           ; last_room = None
           }
           ~at store)
     | Read_item_alone ->
       settled t store committed ~after:(fun store ->
         after_alone place
           { (moved t ~narrowing) with last_read = Some Last.Committed; read_alone = true }
           ~at store asking ~trace:question.trace))
  | Nothing_to_ask -> next_ask place t ~at store
  | No_answer { question; slots } -> no_answer place t ~at store asking ~asked question slots
  | Nothing_readable { reach; missing; offered } ->
    (* A skip counts as a commit of what it passed (§7.6). *)
    let narrowing =
      Librarian_width.committed t.narrowing (Librarian_width.passed offered reach.within)
    in
    after_skip place t ~at ~narrowing ~last:Last.Committed
      (Store.commit_skip store ~at ~hole:(Content_missing missing) reach)
  | Span_unknown { before; reach } ->
    (* It passes no unit with items. *)
    after_skip place t ~at ~narrowing:t.narrowing ~last:Last.Committed
      (Store.commit_skip store ~at ~hole:(Unknown_span { before; after = reach.covered }) reach)
  | Memory_diverged { expected; observed } ->
    { t with state = Stopped (Log_diverged { expected; observed }) }
  (* A file the store does not open does not mend itself: the store stops
     as boot and a commit stop it for the same file. *)
  | Snapshot_fault fault -> { t with state = Stopped (Store.stop_of_snapshot_fault fault) }
  | Input_fault (_ : Librarian_unit.input_fault) ->
    { t with state = Resting store; last_read = Some Last.Input_fault }
  | Ask_failed failed -> { t with state = Resting store; last_read = Some (Last.Ask_failed failed) }
;;

(* A token for a log field, one for each outcome. *)
let unanswered_token : Librarian_slot_outcome.unanswered -> string = function
  | Refused (Sized Input_too_large) -> "input_too_large"
  | Refused (Sized Output_over_reserve) -> "output_over_reserve"
  | Refused (Sized Window_reached) -> "window_reached"
  | Refused Unsized -> "refused"
  | Silent Not_called -> "not_called"
  | Silent Unavailable -> "unavailable"
  | Silent Busy -> "busy"
  | Silent Lost -> "lost"
  | Silent (Unusable (_ : Librarian_answer.rejection)) -> "unusable"
;;

(* How a current room ask ended, as [LibrarianRoomOutcomes] names it. Only
   [Made] writes a line, so the counter is where the others are seen. *)
type room_end =
  | Made
  (** Its line is on disk (§8.2 step 4), whether or not the snapshot was
      written after it. *)
  | Proposed_nothing (** Its answer had no op, and kept the working state. *)
  | Left_out (** Every op it proposed was left out (§8.2). *)
  | Stale (** A direct write removed a fact while it was asked (§8.3). *)
  | Unanswered (** No slot answered. *)
  | Failed (** The ask failed before or during its walk. *)
  | Snapshot_refused
  (** Its plan changes Memory, and the snapshot codec does not write the
      result: no line, and reading rests as for any such commit. *)
  | Store_stopped
  (** The store stopped: the snapshot was not the one the log names when it
      was asked or when its line was to be written, or the line could not be
      written. *)

let room_end_token = function
  | Made -> "made"
  | Proposed_nothing -> "proposed_nothing"
  | Left_out -> "left_out"
  | Stale -> "stale"
  | Unanswered -> "unanswered"
  | Failed -> "failed"
  | Snapshot_refused -> "snapshot_refused"
  | Store_stopped -> "store_stopped"
;;

let envelope_refusal_text : Librarian_envelope.refusal -> string = function
  | Revision_not_next { snapshot; line } ->
    Printf.sprintf "revision_not_next (snapshot %d, line %d)" snapshot line
  | Facts_inconsistent detail -> "facts_inconsistent: " ^ detail
  | Not_encodable detail -> "not_encodable: " ^ detail
;;

let count_room place room_end =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LibrarianRoomOutcomes)
    ~labels:[ "keeper", place.keeper_id; "outcome", room_end_token room_end ]
    ()
;;

(* A room ask that writes no line leaves its outcome in the Keeper's log
   too: the commit log holds what changed Memory or the working state. *)
let room_not_committed place room_end why =
  count_room place room_end;
  Log.Keeper.info ~keeper_name:place.keeper_id "librarian make room (%s): %s"
    (room_end_token room_end) why
;;

(* The current room ask's result (§9.3, the rows of [Make_room]). Making room
   never holds reading up: whatever it ends in, the next ask reads on, and
   the narrowing and the size facts stay as they are. *)
let ended_room place t ~at store (asking : asking) : Room_result.t -> t = function
  | Room_answered { question; answer; slot } ->
    (match asking.removed_since with
     | _ :: _ as removed ->
       (* An answer about facts that are gone is not committed (§8.3). *)
       room_not_committed place Stale
         (Printf.sprintf "a direct write removed %d fact(s) while it was asked"
            (List.length removed));
       next_ask place { t with last_room = Some Last.Stale } ~at store
     | [] ->
       let plan =
         Librarian_plan.of_answer ~shown:(Room { memory = question.memory })
           ~facts:(Store.memory store).facts ~removed_since:[] ~at ~trace_id:question.trace
           answer
       in
       if Store.changes store plan
       then (
         let committed = Store.commit_room store ~at ~question ~slot plan in
         (* Counted by what the commit did: an answer is made once its line
            is on disk. *)
         (match committed with
          | Committed { store = (_ : Store.t); line = (_ : Librarian_log.commit) }
          | Committed_without_snapshot (_ : Librarian_log.commit) -> count_room place Made
          | Stopped (_ : Store.stop) -> count_room place Store_stopped
          | Not_a_snapshot refusal ->
            room_not_committed place Snapshot_refused
              (Printf.sprintf "the answer of %s: %s" slot (envelope_refusal_text refusal)));
         settled t store committed ~after:(fun store ->
           next_ask place { t with last_room = Some Last.Made } ~at store))
       else (
         (match plan.effects.not_applied with
          | [] -> room_not_committed place Proposed_nothing ("the answer of " ^ slot)
          | _ :: _ as left_out ->
            room_not_committed place Left_out
              (Printf.sprintf "the answer of %s: [%s]" slot
                 (String.concat ", "
                    (List.map
                       (fun (number, why, (_ : Librarian_answer.new_fact option)) ->
                          Printf.sprintf "%d:%s" number (Librarian_effects.why_not_kind why))
                       left_out))));
         next_ask place { t with last_room = Some Last.Unchanged } ~at store))
  | Room_not_answered { question; slots } ->
    room_not_committed place Unanswered
      (String.concat ", "
         (List.map
            (fun ((key : Lane.slot_key), outcome) ->
               Printf.sprintf "%s:%s" key.id (unanswered_token outcome))
            slots));
    (* Fits_none only when every slot declared now refused it for its input:
       the same fold the head item's verdict is, over Memory alone. *)
    let room =
      match t.lane with
      | Some declared ->
        (match Librarian_bottom.fold declared.value slots with
         | Input -> Last.Fits_none { memory = question.basis; lane = asking.lane.value }
         | All_not_input | Not_all -> Last.Not_judged)
      | None -> Last.Not_judged
    in
    next_ask place { t with last_room = Some room } ~at store
  | Room_memory_diverged { expected; observed } ->
    count_room place Store_stopped;
    { t with state = Stopped (Log_diverged { expected; observed }) }
  | Room_snapshot_fault fault ->
    count_room place Store_stopped;
    { t with state = Stopped (Store.stop_of_snapshot_fault fault) }
  | Room_failed (_ : Read_result.failed) ->
    count_room place Failed;
    next_ask place { t with last_room = Some Last.Not_judged } ~at store
;;

let ended place t ~at store (asking : asking) = function
  | Read_ended { asked; result } -> ended_read place t ~at store asking ~asked result
  | Room_ended result -> ended_room place t ~at store asking result
;;

let same_lane (held : declared option) (next : declared option) =
  Option.equal (fun (held : declared) (next : declared) -> Lane.equal held.value next.value) held
    next
;;

(* Every pair of a state and an event, each with the way it runs. *)
let table place t ~at event =
  match t.state, event with
  (* Idle, Turn_closed: a unit closed, so the next ask reads it. *)
  | Idle { store; seen_length = (_ : int option) }, Turn_closed -> next_ask place t ~at store
  (* Asking, Resting, Refused_at_bottom, Stopped, Turn_closed: the ask that
     is out reads to the end it saw, a rest waits for the pulse, a head item
     every slot sized waits for an event that changes its question, a
     stopped store reads nothing. *)
  | (Asking _ | Resting _ | Refused_at_bottom _ | Stopped _), Turn_closed -> t
  (* Idle, Pulse: a length other than the one seen, or one not read, is a
     turn whose hint did not come; the same length is not read. *)
  | Idle { store; seen_length }, Pulse ->
    (match seen_length, Fs_compat.file_size (turns_path place) with
     | Some seen, Some length when Int.equal seen length -> t
     | (Some _ | None), (Some _ | None) -> next_ask place t ~at store)
  (* Resting, Pulse: a lane whose every slot a provider holds is not asked. *)
  | Resting store, Pulse ->
    (match t.lane with
     | Some declared when Lane.lane_held ~now:at declared.resolved -> t
     | Some _ | None -> next_ask place t ~at store)
  (* Asking, Refused_at_bottom, Stopped, Pulse: an ask is out, the head
     item's question gets the same answer however late it is asked again
     (§7.4), or the store is stopped. *)
  | (Asking _ | Refused_at_bottom _ | Stopped _), Pulse -> t
  (* Asking, Ask_ended of the current ask: its result is committed or ends
     the ask. *)
  | Asking { store; asking }, Ask_ended { ask; result } when Int.equal ask asking.ask ->
    ended place t ~at store asking result
  (* Asking, Ask_ended of another number; Idle, Resting, Refused_at_bottom,
     Stopped, Ask_ended: a late answer. *)
  | (Idle _ | Asking _ | Resting _ | Refused_at_bottom _ | Stopped _), Ask_ended { ask = (_ : int); result }
    -> late place t result
  (* Idle, Resting, Refused_at_bottom, Declaration_changed: the new value is
     held and the next ask reads with it; with no value that is Idle. A size
     fact needs no clearing: a slot of another value has another key. *)
  | ( (Idle { store; seen_length = (_ : int option) } | Resting store | Refused_at_bottom store)
    , Declaration_changed lane ) -> next_ask place { t with lane } ~at store
  (* Asking, Declaration_changed: with the question side the same only the
     slots changed, and the ask goes on. Another question side, or no lane
     value, gives the next ask a new number, so the ask that is out is
     cancelled and its answer is late. *)
  | Asking { store; asking = (_ : asking) }, Declaration_changed lane ->
    (match t.lane, lane with
     | Some held, Some next
       when Lane.equal_question_side held.value.question next.value.question -> { t with lane }
     | (Some _ | None), (Some _ | None) -> next_ask place { t with lane } ~at store)
  (* Stopped, Declaration_changed: held for the boot that opens the store. *)
  | Stopped (_ : Store.stop), Declaration_changed lane -> { t with lane }
;;

(* The same value changes no state, but its resolution is the one the
   registry published last: the admitted target with its credential and body
   timeout, and the slots a provider holds. The next ask and a rest's held
   check go through it. Another lane value empties the narrowing in every
   state (§7.6 "비움"): what one lane refused says nothing of another. *)
let decide place t ~at event =
  match event with
  | Declaration_changed lane when same_lane t.lane lane -> { t with lane }
  | Declaration_changed (_ : declared option) ->
    table place { t with narrowing = Librarian_width.empty } ~at event
  | Turn_closed | Pulse | Ask_ended _ -> table place t ~at event
;;

type unavailable =
  | Store_stopped of Store.stop
  | Keeper_retired

type write_answer =
  | Written of Librarian_log.commit
  | Already_held
  | Already_done
  | Already_absent
  | Refused of Direct.refusal
  | Not_a_snapshot of Librarian_envelope.refusal
  | Unavailable of unavailable

(* The facts a commit removed, each with the commit, as the plan reads them. *)
let removed_by (line : Librarian_log.commit) =
  List.map
    (fun (fact, (_ : Librarian_effects.removal)) ->
       Keeper_memory_os_types.memory_id fact, line.seq)
    line.effects.removed
;;

let write place t ~at ~by ~trace write =
  let commit store ~after =
    match Direct.plan ~by ~at ~trace_id:trace (Store.memory store).facts write with
    | Already_held -> t, Already_held
    | Already_done -> t, Already_done
    | Already_absent -> t, Already_absent
    | Refused refusal -> t, Refused refusal
    | Writes { effects; facts = (_ : Keeper_memory_os_types.fact list) } ->
      (match Store.commit_direct store ~at ~by ~trace write effects with
       | Committed { store; line } -> after store line, Written line
       | Committed_without_snapshot line ->
         { t with state = Stopped Store_unwritable }, Written line
       | Stopped stop -> { t with state = Stopped stop }, Unavailable (Store_stopped stop)
       | Not_a_snapshot refusal -> t, Not_a_snapshot refusal)
  in
  match t.state with
  | Idle { store; seen_length } ->
    commit store ~after:(fun store (_ : Librarian_log.commit) ->
      { t with state = Idle { store; seen_length } })
  | Asking { store; asking } ->
    commit store ~after:(fun store line ->
      { t with
        state =
          Asking
            { store
            ; asking = { asking with removed_since = asking.removed_since @ removed_by line }
            }
      })
  | Resting store ->
    commit store ~after:(fun store (_ : Librarian_log.commit) -> { t with state = Resting store })
  (* Memory changed, so the head item with Memory is another question (§9.3). *)
  | Refused_at_bottom store ->
    commit store ~after:(fun store (_ : Librarian_log.commit) -> next_ask place t ~at store)
  | Stopped stop -> t, Unavailable (Store_stopped stop)
;;

type act_refusal =
  | Nothing_to_resume
  | Not_stopped
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Not_replaced
  | Turn_log_unread
  | Act_unavailable of unavailable

type act_answer =
  | Done
  | Not_done of act_refusal

let resume place ~boot t ~at =
  match t.state with
  | Stopped (_ : Store.stop) ->
    booted place ~at ~lane:t.lane ~last_ask:t.last_ask (boot ()), Done
  | Resting store | Refused_at_bottom store ->
    next_ask place { t with bottom = Librarian_bottom.empty } ~at store, Done
  | Idle _ | Asking _ -> t, Not_done Nothing_to_resume
;;

let adopt { memory_dir; turns_dir; keeper_id } t ~at ~by ~observed =
  match t.state with
  | Idle _ | Asking _ | Resting _ | Refused_at_bottom _ -> t, Not_done Not_stopped
  | Stopped ((Memory_unreadable | Store_unwritable | Raised _) as stop) ->
    t, Not_done (Act_unavailable (Store_stopped stop))
  | Stopped (Log_diverged _ | Log_unreadable) ->
    (match Store.adopt ~memory_dir ~turns_dir ~keeper_id ~at ~by ~observed with
     | Ok store ->
       next_ask { memory_dir; turns_dir; keeper_id } { t with narrowing = Librarian_width.empty }
         ~at store
       , Done
     | Error Snapshot_mismatch -> t, Not_done Snapshot_mismatch
     | Error Snapshot_unreadable -> t, Not_done Snapshot_unreadable
     | Error (Not_adopted stop) -> t, Not_done (Act_unavailable (Store_stopped stop)))
;;

(* The turn log a line reads. *)
let reading_log : Librarian_log.line -> Keeper_turn_log.Log_id.t = function
  | Started { turn_log; _ } | Committed { turn_log; _ } -> turn_log
;;

(* The file's first line, when it names [observed]. *)
let observed_start turns_path ~observed =
  match Keeper_turn_log_store.read_start turns_path with
  | Error (Read_failed { path = (_ : string); detail = (_ : string) } | Moved_while_reading) ->
    Error Turn_log_unread
  | Ok None
  | Error
      ( Row_undecodable
          { offset = (_ : int); reason = (_ : Keeper_turn_log_store.undecodable) }
      | Log_start_missing ) ->
    (* No [Log_started] line names [observed]. *)
    Error Not_replaced
  | Ok (Some (start : Keeper_turn_log_store.start)) ->
    if Keeper_turn_log.Log_id.equal start.id observed then Ok start else Error Not_replaced
;;

(* What a restart passes, read from the disk when it is taken: the file's
   first line names [observed], and the reader, run again from the tail,
   finds that file is another turn log or that the stored offset is not one
   of its lines. Each fault is taken only when the file it is about is the
   one [observed] names, so a file replaced in between is refused, not
   recorded as what it is not. [Turn_log_replaced] carries the first line
   the reader read. [Position_lost] comes from the reader's own open of the
   file after that line, so the first line is read once more after it. Any
   other answer of the reader is no reason to start over. *)
let restart_from place store ~observed =
  let turns_path = turns_path place in
  let is_observed id = Keeper_turn_log.Log_id.equal id observed in
  match observed_start turns_path ~observed with
  | Error refusal -> Error refusal
  | Ok start ->
    let tail = Store.tail store in
    (match Librarian_unread.read ~turns_path ~until:(First_with_items 1) tail with
     | Error (Fault (Turn_log_replaced { expected; observed = Some now })) when is_observed now ->
       Ok (Librarian_log.Turn_log_replaced { from = expected; to_ = now }, start)
     | Error (Fault (Position_lost { offset; length })) when is_observed (reading_log tail) ->
       Result.map
         (fun (again : Keeper_turn_log_store.start) ->
            Librarian_log.Position_lost { offset; length }, again)
         (observed_start turns_path ~observed)
     | Error (Fault (Turn_log_replaced _ | Position_lost _ | Line_unreadable _ | Content_unreadable _))
     | Ok (_ : Librarian_unread.reading) -> Error Not_replaced
     | Error (Unread { detail = (_ : string) }) -> Error Turn_log_unread)
;;

(* §12.4: a refusal leaves the value as it is, so an ask that is out goes
   on. An accepted restart cancels it, and the next ask reads the file from
   its first line with no width or size fact kept (§7.6) and without how the
   last ask ended, which was about where reading stood before (§9.2, §12.2
   E3). *)
let restart_reading place t ~at ~observed =
  match t.state with
  | Stopped stop -> t, Not_done (Act_unavailable (Store_stopped stop))
  | Idle { store; seen_length = (_ : int option) }
  | Asking { store; asking = (_ : asking) }
  | Resting store
  | Refused_at_bottom store ->
    (match restart_from place store ~observed with
     | Error refusal -> t, Not_done refusal
     | Ok (hole, start) ->
       (match Store.commit_restart store ~at ~hole ~start with
        | Ok { store; line = (_ : Librarian_log.commit) } ->
          ( next_ask place
              { (moved t ~narrowing:Librarian_width.empty) with last_read = None }
              ~at store
          , Done )
        | Error stop ->
          (* §9.2: the line is not on disk, so the act is refused as the
             store stops. *)
          { t with state = Stopped stop }, Not_done (Act_unavailable (Store_stopped stop))))
;;

type fiber_change =
  | Keep
  | Start of asking
  | Cancel
  | Cancel_then_start of asking

let out = function
  | Asking { asking; store = (_ : Store.t) } -> Some asking
  | Idle _ | Resting _ | Refused_at_bottom _ | Stopped _ -> None
;;

let fiber_change ~before ~after =
  match out before.state, out after.state with
  | None, None -> Keep
  | Some was, Some now -> if Int.equal was.ask now.ask then Keep else Cancel_then_start now
  | Some (_ : asking), None -> Cancel
  | None, Some now -> Start now
;;
