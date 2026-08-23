type decision =
  | Approve
  | Deny

let decision_to_string = function
  | Approve -> "approve"
  | Deny -> "deny"

let decision_of_string = function
  | "approve" -> Some Approve
  | "deny" -> Some Deny
  | _ -> None

type outcome =
  | Answered of decision
  | Timed_out
  | Displaced

type pending =
  { keeper_name : string
  ; tool_call_id : string
  }

type waiter =
  { key : pending
  ; resolve : outcome Eio.Promise.u
  }

(* Waiters are held oldest-first so [pending] reads in the order the calls were
   made without sorting. A turn has at most one call awaiting an answer and an
   operator watches a handful of keepers, so the list is short and a linear
   scan is the whole cost. *)
type t =
  { mutable waiters : waiter list
  ; mutex : Stdlib.Mutex.t
  }

let create () = { waiters = []; mutex = Stdlib.Mutex.create () }

(* Created at load, so there is no moment where a wait or an answer arrives
   before the registry exists. *)
let shared_registry = create ()
let shared () = shared_registry

let same_key (left : pending) (right : pending) =
  String.equal left.keeper_name right.keeper_name
  && String.equal left.tool_call_id right.tool_call_id

(* Take the waiter for [key] out of the list, returning it. Under the mutex;
   the promise is resolved by the caller outside it, because resolving can
   schedule the waiting fiber and nothing should run holding this lock. *)
let take_locked t key =
  let taken = ref None in
  t.waiters <-
    List.filter
      (fun waiter ->
        if Option.is_none !taken && same_key waiter.key key then begin
          taken := Some waiter;
          false
        end
        else true)
      t.waiters;
  !taken

let await t ~clock ~keeper_name ~tool_call_id ~timeout_sec =
  let key = { keeper_name; tool_call_id } in
  let promise, resolve = Eio.Promise.create () in
  let displaced =
    Stdlib.Mutex.protect t.mutex (fun () ->
        let displaced = take_locked t key in
        t.waiters <- t.waiters @ [ { key; resolve } ];
        displaced)
  in
  (* A second wait on the same id means the id is not naming one call. The
     first waiter is told so rather than left to time out, and never shares the
     new one's answer: that would approve a call its operator never saw. *)
  Option.iter
    (fun waiter -> Eio.Promise.resolve waiter.resolve Displaced)
    displaced;
  let remove_self () =
    Stdlib.Mutex.protect t.mutex (fun () ->
        t.waiters <-
          List.filter (fun waiter -> waiter.resolve != resolve) t.waiters)
  in
  Fun.protect ~finally:remove_self (fun () ->
      Eio.Fiber.first
        (fun () -> Eio.Promise.await promise)
        (fun () ->
          Eio.Time.sleep clock timeout_sec;
          Timed_out))

let settle t ~keeper_name ~tool_call_id decision =
  let key = { keeper_name; tool_call_id } in
  match Stdlib.Mutex.protect t.mutex (fun () -> take_locked t key) with
  | None -> false
  | Some waiter ->
      Eio.Promise.resolve waiter.resolve (Answered decision);
      true

let pending t =
  Stdlib.Mutex.protect t.mutex (fun () ->
      List.map (fun waiter -> waiter.key) t.waiters)
