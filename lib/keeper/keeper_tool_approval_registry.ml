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

(* Provider call ownership detects overlapping reuse and displaces the
   previous wait. Operator answers identify an admission independently. *)
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

type retirement =
  { retiring_entry : pending
  ; published : unit Eio.Promise.t
  }

type settlement_claim =
  | Claimed of waiter
  | Publishing_timeout of unit Eio.Promise.t
  | No_wait

(* Waiters are held oldest-first so [pending] reads in the order the calls were
   made without sorting. A turn has at most one call awaiting an answer and an
   operator watches a handful of keepers, so the list is short and a linear
   scan is the whole cost. *)
type t =
  { mutable waiters : waiter list
  ; mutable retiring : retirement list
  ; mutex : Stdlib.Mutex.t
  ; mutable answered_total : int
  ; mutable timed_out_total : int
  }

let create () =
  { waiters = []
  ; retiring = []
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

let await ?(on_registered = fun () -> ()) ?(on_timed_out = fun () -> ()) t ~approval_id ~clock ~keeper_name ~tool_call_id ~tool_name ~args ~question ~because
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
          let published, mark_published = Eio.Promise.create () in
          let retirement = { retiring_entry = entry; published } in
          let timed_out =
            Stdlib.Mutex.protect t.mutex (fun () ->
              let present =
                List.exists (fun waiter -> waiter.resolve == resolve) t.waiters
              in
              if present then begin
                t.waiters <-
                  List.filter (fun waiter -> waiter.resolve != resolve) t.waiters;
                t.retiring <- retirement :: t.retiring;
                t.timed_out_total <- t.timed_out_total + 1
              end;
              present)
          in
          if timed_out then begin
            Fun.protect
              ~finally:(fun () ->
                Stdlib.Mutex.protect t.mutex (fun () ->
                  t.retiring <- List.filter (fun row -> row != retirement) t.retiring);
                Eio.Promise.resolve mark_published ())
              on_timed_out;
            Eio.Promise.resolve resolve Timed_out
          end;
          (* A different claim may have removed the wait but not yet resolved
             its promise in another domain. Await its outcome rather than
             manufacture a timeout from absence. *)
          Eio.Promise.await promise))

let settle t ~keeper_name ~approval_id decision =
  match Stdlib.Mutex.protect t.mutex (fun () ->
      let taken = ref None in
      t.waiters <- List.filter (fun waiter ->
        if Option.is_none !taken
          && String.equal waiter.entry.keeper_name keeper_name
          && Keeper_tool_approval_id.equal waiter.entry.approval_id approval_id
        then (taken := Some waiter; false) else true) t.waiters;
      match !taken with
      | Some waiter ->
          t.answered_total <- t.answered_total + 1;
          Claimed waiter
      | None ->
          (match List.find_opt (fun (row : retirement) ->
            String.equal row.retiring_entry.keeper_name keeper_name
            && Keeper_tool_approval_id.equal row.retiring_entry.approval_id approval_id) t.retiring with
           | Some row -> Publishing_timeout row.published
           | None -> No_wait)) with
  | No_wait -> false
  | Publishing_timeout published ->
      Eio.Promise.await published;
      false
  | Claimed waiter ->
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
