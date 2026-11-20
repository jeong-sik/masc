(** How many waiting-inventory changes this terminal has heard for each Keeper,
    and whether it can hear one now. A watcher holding an unverified request
    waits on it instead of a timer: the server announces a change when the
    Keeper's queue moves or its store fence rises or lifts (#36205), and only a
    live observer stream carries that announcement. An observer stream that
    (re)opens may have missed changes for every Keeper, so it moves them all;
    [/reconcile] moves one Keeper by hand. Both counts only grow, so their sum
    does too. The main loop writes and watcher fibers read, so the state is one
    immutable value swapped atomically on the session handle [t]. *)

module Keeper_chat = Masc_tui_keeper_chat_projection
module Keepers = Map.Make (String)

type heard =
  { reopened : int
  ; changed : int Keepers.t
  ; hearing : Keeper_chat.inventory_hearing
  }

type t =
  { heard : heard Atomic.t
  ; moved : Eio.Condition.t
  }

type news =
  | Heard_news
  | Stream_lost

let create () =
  { heard =
      Atomic.make
        { reopened = 0; changed = Keepers.empty; hearing = Keeper_chat.No_observer_stream }
  ; moved = Eio.Condition.create ()
  }

let rec update t f =
  let before = Atomic.get t.heard in
  if Atomic.compare_and_set t.heard before (f before)
  then Eio.Condition.broadcast t.moved
  else update t f

let keeper_changed t keeper =
  update t (fun heard ->
    { heard with
      changed =
        Keepers.update keeper
          (function Some count -> Some (count + 1) | None -> Some 1)
          heard.changed })

let stream_reopened t =
  update t (fun heard -> { heard with reopened = heard.reopened + 1 })

(* The main loop calls this every pass with what its observer state says;
   only a change wakes the watchers. *)
let observe_hearing t hearing =
  let same =
    match (Atomic.get t.heard).hearing, hearing with
    | Keeper_chat.Observer_stream_live, Keeper_chat.Observer_stream_live
    | Keeper_chat.No_observer_stream, Keeper_chat.No_observer_stream -> true
    | Keeper_chat.Observer_stream_live, Keeper_chat.No_observer_stream
    | Keeper_chat.No_observer_stream, Keeper_chat.Observer_stream_live -> false
  in
  if not same then update t (fun heard -> { heard with hearing })

let hearing t = (Atomic.get t.heard).hearing

let generation_of heard keeper =
  heard.reopened
  + (match Keepers.find_opt keeper heard.changed with Some count -> count | None -> 0)

(* A Keeper this terminal has heard nothing about has heard zero changes. *)
let generation t keeper = generation_of (Atomic.get t.heard) keeper

let await_after t keeper seen =
  Eio.Condition.loop_no_mutex t.moved (fun () ->
    if generation t keeper > seen then Some () else None)

(* Waits for a change the observer stream announces. A stream that closes
   meanwhile can announce nothing more, so the wait ends with [Stream_lost]
   instead of outliving it. *)
let await_news t keeper seen =
  Eio.Condition.loop_no_mutex t.moved (fun () ->
    let heard = Atomic.get t.heard in
    if generation_of heard keeper > seen then Some Heard_news
    else
      match heard.hearing with
      | Keeper_chat.Observer_stream_live -> None
      | Keeper_chat.No_observer_stream -> Some Stream_lost)
