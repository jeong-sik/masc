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

(* What identifies one wait. The ask's description is carried beside it, not
   in it: two waits are the same wait by (keeper, call id) alone. *)
type key =
  { key_keeper_name : string
  ; key_tool_call_id : string
  }

type pending =
  { keeper_name : string
  ; approval_id : Keeper_tool_approval_id.t
  ; tool_call_id : string
  ; tool_name : string
  ; args : string
  ; question : string
  ; because : string
  ; asked_at : float
  ; timeout_sec : float
  }

type waiter =
  { key : key
  ; entry : pending
  ; resolve : outcome Eio.Promise.u
  }

(* Waiters are held oldest-first so [pending] reads in the order the calls were
   made without sorting. A turn has at most one call awaiting an answer and an
   operator watches a handful of keepers, so the list is short and a linear
   scan is the whole cost. *)
type t =
  { mutable waiters : waiter list
  ; mutex : Stdlib.Mutex.t
  ; mutable answered_total : int
  ; mutable timed_out_total : int
  }

let create () =
  { waiters = []
  ; mutex = Stdlib.Mutex.create ()
  ; answered_total = 0
  ; timed_out_total = 0 }

(* Created at load, so there is no moment where a wait or an answer arrives
   before the registry exists. *)
let shared_registry = create ()
let shared () = shared_registry

let same_key (left : key) (right : key) =
  String.equal left.key_keeper_name right.key_keeper_name
  && String.equal left.key_tool_call_id right.key_tool_call_id

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

let await ?(on_registered = fun () -> ()) t ~approval_id ~clock ~keeper_name ~tool_call_id ~tool_name ~args ~question ~because
    ~timeout_sec =
  let key = { key_keeper_name = keeper_name; key_tool_call_id = tool_call_id } in
  let entry =
    { keeper_name
    ; approval_id
    ; tool_call_id
    ; tool_name
    ; args
    ; question
    ; because
    ; asked_at = Eio.Time.now clock
    ; timeout_sec
    }
  in
  let promise, resolve = Eio.Promise.create () in
  let displaced =
    Stdlib.Mutex.protect t.mutex (fun () ->
        let displaced = take_locked t key in
        t.waiters <- t.waiters @ [ { key; entry; resolve } ];
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
  (* Timeout and an operator answer claim the same exact waiter under the
     registry lock. The winning claim publishes one promise outcome, so a
     successful settlement receipt cannot race a contradictory timeout. *)
  Fun.protect ~finally:remove_self (fun () ->
      on_registered ();
      Watched_work.run
        (fun () -> Eio.Promise.await promise)
        ~watcher:(fun () ->
          Eio.Time.sleep clock timeout_sec;
          let timed_out =
            Stdlib.Mutex.protect t.mutex (fun () ->
              let present =
                List.exists (fun waiter -> waiter.resolve == resolve) t.waiters
              in
              if present then begin
                t.waiters <-
                  List.filter (fun waiter -> waiter.resolve != resolve) t.waiters;
                t.timed_out_total <- t.timed_out_total + 1
              end;
              present)
          in
          if timed_out then Eio.Promise.resolve resolve Timed_out;
          (* A different claim may have removed the wait but not yet resolved
             its promise in another domain. Await its outcome rather than
             manufacture a timeout from absence. *)
          Eio.Promise.await promise))

let settle t ~keeper_name ~tool_call_id decision =
  let key = { key_keeper_name = keeper_name; key_tool_call_id = tool_call_id } in
  match Stdlib.Mutex.protect t.mutex (fun () ->
      let waiter = take_locked t key in
      if Option.is_some waiter then t.answered_total <- t.answered_total + 1;
      waiter) with
  | None -> false
  | Some waiter ->
    Eio.Promise.resolve waiter.resolve (Answered decision);
    true

let pending t =
  Stdlib.Mutex.protect t.mutex (fun () ->
      List.map (fun waiter -> waiter.entry) t.waiters)

type outcome_totals =
  { answered_total : int
  ; timed_out_total : int
  }

let outcome_totals t =
  Stdlib.Mutex.protect t.mutex (fun () ->
      { answered_total = t.answered_total
      ; timed_out_total = t.timed_out_total
      })
