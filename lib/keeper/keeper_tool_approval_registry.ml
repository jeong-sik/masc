type decision =
  | Approve
  | Deny
[@@deriving enumerate]

let decision_to_string = function
  | Approve -> "approve"
  | Deny -> "deny"

let decision_of_string s = List.find_opt (fun v -> String.equal (decision_to_string v) s) all_of_decision

type outcome =
  | Answered of decision
  | Timed_out
  | Displaced

(* Reused provider call IDs displace the old wait. Decisions additionally
   name the immutable approval ID of the question the operator saw. *)
type key =
  { key_keeper_name : string
  ; key_tool_call_id : string
  }

type pending =
  { keeper_name : string
  ; tool_call_id : string
  ; approval_id : string
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

(* Take the matching waiter out of the list, returning it. Under the mutex;
   the promise is resolved by the caller outside it, because resolving can
   schedule the waiting fiber and nothing should run holding this lock. *)
let take_locked t matches =
  let taken = ref None in
  t.waiters <-
    List.filter
      (fun waiter ->
        if Option.is_none !taken && matches waiter then begin
          taken := Some waiter;
          false
        end
        else true)
      t.waiters;
  !taken

let await t ~clock ~on_registered ~keeper_name ~tool_call_id ~approval_id ~tool_name ~args ~question ~because
    ~timeout_sec =
  let key = { key_keeper_name = keeper_name; key_tool_call_id = tool_call_id } in
  let entry =
    { keeper_name
    ; tool_call_id
    ; approval_id
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
        let displaced = take_locked t (fun waiter -> same_key waiter.key key) in
        t.waiters <- t.waiters @ [ { key; entry; resolve } ];
        displaced)
  in
  Keeper_tool_approval_broadcast.waits_changed ~keeper_name;
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
  (* A decision settled as the wait's timeout passed is the decision: the
     operator was told it applied, and the call must run under it rather
     than be reported as timed out. An answer and a displacement announce
     the change where they take the wait out; a timeout and a turn that ends
     while waiting are announced once [remove_self] has run. *)
  match Fun.protect ~finally:remove_self (fun () ->
      on_registered ();
      match
        Watched_work.run
          (fun () -> Eio.Promise.await promise)
          ~watcher:(fun () ->
            Eio.Time.sleep clock timeout_sec;
            Timed_out)
      with
      | Timed_out ->
        (* The timer, not a decision, ended this wait: the one outcome the
           timeout measurement counts as a timeout. *)
        t.timed_out_total <- t.timed_out_total + 1;
        Timed_out
      | (Displaced | Answered _) as outcome -> outcome)
  with
  | Timed_out ->
    Keeper_tool_approval_broadcast.waits_changed ~keeper_name;
    Timed_out
  | (Displaced | Answered _) as outcome -> outcome
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Keeper_tool_approval_broadcast.waits_changed ~keeper_name;
    Printexc.raise_with_backtrace exn backtrace

let settle t ~keeper_name ~tool_call_id ~approval_id decision =
  let key = { key_keeper_name = keeper_name; key_tool_call_id = tool_call_id } in
  let matches waiter =
    same_key waiter.key key && String.equal waiter.entry.approval_id approval_id
  in
  match Stdlib.Mutex.protect t.mutex (fun () -> take_locked t matches) with
  | None -> false
  | Some waiter ->
    (* Counted on the resolved answer, not on [settle]'s return value: the
       wait this resolves is an answer reaching an operator's call either
       way. *)
    t.answered_total <- t.answered_total + 1;
    Eio.Promise.resolve waiter.resolve (Answered decision);
    Keeper_tool_approval_broadcast.waits_changed ~keeper_name;
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
