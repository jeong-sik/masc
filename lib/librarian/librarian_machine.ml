module Store = Librarian_store
module Direct = Librarian_direct
module Lane = Librarian_memory_lane
module Read_result = Librarian_read_result

type place =
  { memory_dir : string
  ; turns_dir : string
  ; keeper_id : string
  }

type declared =
  { value : Lane.t
  ; resolved : Runtime_exact_output_registry.resolved_lane
  }

type asking =
  { ask : int
  ; since : float
  ; lane : Lane.t
  ; removed_since : (string * int) list
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
  | Stopped of Store.stop

type t =
  { state : state
  ; lane : declared option
  ; last_ask : int
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
let next_ask place t ~at store =
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
          Asking { store; asking = { ask; since = at; lane = declared.value; removed_since = [] } }
      ; last_ask = ask
      })
    else idle
;;

let booted place ~at ~lane ~last_ask (opened : (Store.t, Store.stop) result) =
  match opened with
  | Error stop -> { state = Stopped stop; lane; last_ask }
  | Ok store ->
    next_ask place { state = Idle { store; seen_length = None }; lane; last_ask } ~at store
;;

type ended = Read_ended of Read_result.t

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
let late place t (result : Read_result.t) =
  (match result with
   | Answered _ ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string LibrarianLateAnswers)
       ~labels:[ "keeper", place.keeper_id ]
       ()
   | Nothing_to_ask | No_answer _ | Nothing_readable _ | Span_unknown _ | Memory_diverged _
   | Input_fault _ | Ask_failed _ -> ());
  t
;;

(* §9.2 "a failed commit". Effects that make no snapshot mean the plan and
   the snapshot codec disagree. The store is as it was, and asking again at
   once would ask the same question, so the writer rests until a pulse. *)
let after_commit place t ~at store (committed : Store.committed) =
  match committed with
  | Committed { store; line = (_ : Librarian_log.commit) } -> next_ask place t ~at store
  | Committed_without_snapshot (_ : Librarian_log.commit) ->
    { t with state = Stopped Store_unwritable }
  | Stopped stop -> { t with state = Stopped stop }
  | Not_a_snapshot (_ : Librarian_envelope.refusal) -> { t with state = Resting store }
;;

(* §9.3 "Refused_by_lane, Silent_lane": only the slots the lane declares now
   are read. When none of them is in the result and the lane value moved
   while the ask was out, asking again uses the new value and does not
   repeat; otherwise the writer rests. The width layer reads the outcomes
   themselves. *)
let no_answer place t ~at store (asking : asking) slots =
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
    | Some declared -> not (Lane.equal declared.value asking.lane)
  in
  if List.is_empty still_declared && lane_moved
  then next_ask place t ~at store
  else { t with state = Resting store }
;;

(* The current ask's result (§9.3, the table under "Asking a"). *)
let ended place t ~at store (asking : asking) : Read_result.t -> t = function
  | Answered { question; answer; slot } ->
    let plan =
      Librarian_plan.of_answer ~shown:question.shown ~facts:(Store.memory store).facts
        ~removed_since:asking.removed_since ~at ~trace_id:question.trace answer
    in
    after_commit place t ~at store (Store.commit_read store ~at ~question ~slot plan)
  | Nothing_to_ask -> next_ask place t ~at store
  | No_answer { slots } -> no_answer place t ~at store asking slots
  | Nothing_readable { reach; missing } ->
    after_commit place t ~at store
      (Store.commit_skip store ~at ~hole:(Content_missing missing) reach)
  | Span_unknown { before; reach } ->
    after_commit place t ~at store
      (Store.commit_skip store ~at ~hole:(Unknown_span { before; after = reach.covered }) reach)
  | Memory_diverged { expected; observed } ->
    { t with state = Stopped (Log_diverged { expected; observed }) }
  | Input_fault (_ : Librarian_unit.input_fault) | Ask_failed (_ : Read_result.failed) ->
    { t with state = Resting store }
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
  (* Asking, Resting, Stopped, Turn_closed: the ask that is out reads to the
     end it saw, a rest waits for the pulse, a stopped store reads nothing. *)
  | (Asking _ | Resting _ | Stopped _), Turn_closed -> t
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
  (* Asking, Stopped, Pulse: an ask is out, or the store is stopped. *)
  | (Asking _ | Stopped _), Pulse -> t
  (* Asking, Ask_ended of the current ask: its result is committed or ends
     the ask. *)
  | Asking { store; asking }, Ask_ended { ask; result = Read_ended result }
    when Int.equal ask asking.ask -> ended place t ~at store asking result
  (* Asking, Ask_ended of another number; Idle, Resting, Stopped, Ask_ended:
     a late answer. *)
  | ( (Idle _ | Asking _ | Resting _ | Stopped _)
    , Ask_ended { ask = (_ : int); result = Read_ended result } ) -> late place t result
  (* Idle, Resting, Declaration_changed: the new value is held and the next
     ask reads with it; with no value that is Idle. *)
  | (Idle { store; seen_length = (_ : int option) } | Resting store), Declaration_changed lane ->
    next_ask place { t with lane } ~at store
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

let decide place t ~at event =
  match event with
  | Declaration_changed lane when same_lane t.lane lane -> t
  | Turn_closed | Pulse | Ask_ended _ | Declaration_changed _ -> table place t ~at event
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

let write t ~at ~by ~trace write =
  let commit store ~stay =
    match Direct.plan ~by ~at ~trace_id:trace (Store.memory store).facts write with
    | Already_held -> t, Already_held
    | Already_done -> t, Already_done
    | Already_absent -> t, Already_absent
    | Refused refusal -> t, Refused refusal
    | Writes { effects; facts = (_ : Keeper_memory_os_types.fact list) } ->
      (match Store.commit_direct store ~at ~by ~trace write effects with
       | Committed { store; line } -> { t with state = stay store line }, Written line
       | Committed_without_snapshot line ->
         { t with state = Stopped Store_unwritable }, Written line
       | Stopped stop -> { t with state = Stopped stop }, Unavailable (Store_stopped stop)
       | Not_a_snapshot refusal -> t, Not_a_snapshot refusal)
  in
  match t.state with
  | Idle { store; seen_length } ->
    commit store ~stay:(fun store (_ : Librarian_log.commit) -> Idle { store; seen_length })
  | Asking { store; asking } ->
    commit store ~stay:(fun store line ->
      Asking
        { store; asking = { asking with removed_since = asking.removed_since @ removed_by line } })
  | Resting store -> commit store ~stay:(fun store (_ : Librarian_log.commit) -> Resting store)
  | Stopped stop -> t, Unavailable (Store_stopped stop)
;;

type act_refusal =
  | Nothing_to_resume
  | Not_stopped
  | Snapshot_mismatch
  | Snapshot_unreadable
  | Act_unavailable of unavailable

type act_answer =
  | Done
  | Not_done of act_refusal

let resume place ~boot t ~at =
  match t.state with
  | Stopped (_ : Store.stop) ->
    booted place ~at ~lane:t.lane ~last_ask:t.last_ask (boot ()), Done
  | Resting store -> next_ask place t ~at store, Done
  | Idle _ | Asking _ -> t, Not_done Nothing_to_resume
;;

let adopt { memory_dir; turns_dir; keeper_id } t ~at ~by ~observed =
  match t.state with
  | Idle _ | Asking _ | Resting _ -> t, Not_done Not_stopped
  | Stopped ((Memory_unreadable | Store_unwritable) as stop) ->
    t, Not_done (Act_unavailable (Store_stopped stop))
  | Stopped (Log_diverged _ | Log_unreadable) ->
    (match Store.adopt ~memory_dir ~turns_dir ~keeper_id ~at ~by ~observed with
     | Ok store -> next_ask { memory_dir; turns_dir; keeper_id } t ~at store, Done
     | Error Snapshot_mismatch -> t, Not_done Snapshot_mismatch
     | Error Snapshot_unreadable -> t, Not_done Snapshot_unreadable
     | Error (Not_adopted stop) -> t, Not_done (Act_unavailable (Store_stopped stop)))
;;

type fiber_change =
  | Keep
  | Start of asking
  | Cancel
  | Cancel_then_start of asking

let out = function
  | Asking { asking; store = (_ : Store.t) } -> Some asking
  | Idle _ | Resting _ | Stopped _ -> None
;;

let fiber_change ~before ~after =
  match out before.state, out after.state with
  | None, None -> Keep
  | Some was, Some now -> if Int.equal was.ask now.ask then Keep else Cancel_then_start now
  | Some (_ : asking), None -> Cancel
  | None, Some now -> Start now
;;
