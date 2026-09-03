module Registry = Keeper_tool_approval_registry

(* What one timed-out ask was about. The wait itself is gone — the registry
   does not hold it (registry.mli: a call whose waiter is gone is not held
   for later) — but the question's description is kept so an answer that
   arrives late can still be attributed to the exact call it was shown
   for. [expired_noted_at] bounds that courtesy: an ask older than [ttl_sec]
   is reaped before it can be answered, because an answer that late is not
   about the moment the operator was shown. *)

type expired_ask =
  { expired_keeper_name : string
  ; expired_tool_call_id : string
  ; expired_tool_name : string
  ; expired_args_fingerprint : string
  ; expired_noted_at : float
  }

(* An operator's answer to an expired ask, keyed by the call rather than the
   call id: the retry carries a fresh tool_call_id, so identity here is
   (keeper, tool, canonical-args fingerprint) — the same fingerprint the
   durable approval rules use
   ({!Keeper_approval_queue_rules.request_fingerprint}).

   [remembered_answered_at] is what keeps a 180-second-window human decision
   from becoming a permanent credential: past [ttl_sec] the entry is stale
   and treated as no memory. *)

type remembered =
  { remembered_keeper_name : string
  ; remembered_tool_name : string
  ; remembered_args_fingerprint : string
  ; remembered_decision : Registry.decision
  ; remembered_answered_at : float
  }

(* How long a remembered answer still counts as the decision the operator
   just made.

   The live wait gives an operator 180s to answer (the server's
   [keeper_tool_approval_timeout_sec]); a remembered answer extends that same
   moment to the retry the operator already knows is coming. Fifteen minutes
   is that order — minutes past the live window, nowhere near days: inside
   it, the identical call arriving is recognizably the retry that prompted
   the answer; past it, the conversation has moved on and the answer was
   about a call in a context that no longer holds, so the call is asked
   about again.

   This is a safety bound on how long one human decision can authorize, not
   a budget on keeper flow — the class of bound the constitution's
   budget_gate prohibition explicitly exempts. It is also what makes the
   yolo stance safe to flip: while a keeper stands in [Yolo] the gate never
   asks and never consumes, and without an age bound a memory banked before
   the flip would fire on the first gated call after the flip back. *)
let ttl_sec = 900.0

type t =
  { mutable expired : expired_ask list
  ; mutable remembered : remembered list
  ; mutex : Stdlib.Mutex.t
  }

let create () =
  { expired = []; remembered = []; mutex = Stdlib.Mutex.create () }

(* Created at load, so there is no moment where a timeout or a late answer
   arrives before the store exists — the same argument the registry makes
   for its own [shared]. *)
let shared_store = create ()
let shared () = shared_store

let fingerprint_of (args : Yojson.Safe.t) =
  Keeper_approval_queue_rules.request_fingerprint args

(* Entries older than the TTL leave on every write and every read, so the
   lists cannot grow on nothing but time: an unattended keeper whose asks
   keep timing out leaves entries that the next operation reaps, and a
   remembered answer nobody's retry ever claims does not outlive its
   moment. Under the mutex; callers already hold it. *)
let reap_locked t ~now =
  let fresh noted_at = now -. noted_at <= ttl_sec in
  t.expired <-
    List.filter (fun ask -> fresh ask.expired_noted_at) t.expired;
  t.remembered <-
    List.filter (fun entry -> fresh entry.remembered_answered_at) t.remembered

(* NDT-OK: wall-clock default at this boundary; the gate passes its own
   clock's reading so ages are measured against the same clock family the
   wait ran on, and tests inject [~now]. *)
let note_timed_out t ?(now = Unix.gettimeofday ()) ~keeper_name ~tool_call_id
    ~tool_name ~args () =
  let entry =
    { expired_keeper_name = keeper_name
    ; expired_tool_call_id = tool_call_id
    ; expired_tool_name = tool_name
    ; expired_args_fingerprint = fingerprint_of args
    ; expired_noted_at = now
    }
  in
  Stdlib.Mutex.protect t.mutex (fun () ->
      reap_locked t ~now;
      t.expired <- entry :: t.expired)

type remember_outcome =
  | Remembered of { tool_name : string }
  | No_matching_ask

let same_ask (ask : expired_ask) ~keeper_name ~tool_call_id =
  String.equal ask.expired_keeper_name keeper_name
  && String.equal ask.expired_tool_call_id tool_call_id

let same_identity (left : remembered) ~keeper_name ~tool_name ~args_fingerprint =
  String.equal left.remembered_keeper_name keeper_name
  && String.equal left.remembered_tool_name tool_name
  && String.equal left.remembered_args_fingerprint args_fingerprint

let remember_late t ?(now = Unix.gettimeofday ()) ~keeper_name ~tool_call_id
    decision () =
  Stdlib.Mutex.protect t.mutex (fun () ->
      reap_locked t ~now;
      (* [expired] is newest-first, and so is this match: if a provider ever
         recycles a call id, the answer attaches to the newest ask that
         carried it. That is the safe direction — it is the prompt the
         operator was shown most recently, and the older entry with the same
         id describes an ask its own timeout already ended. *)
      match
        List.find_opt
          (fun ask -> same_ask ask ~keeper_name ~tool_call_id)
          t.expired
      with
      | None -> No_matching_ask
      | Some ask ->
          t.expired <-
            List.filter
              (fun expired -> not (same_ask expired ~keeper_name ~tool_call_id))
              t.expired;
          let entry =
            { remembered_keeper_name = ask.expired_keeper_name
            ; remembered_tool_name = ask.expired_tool_name
            ; remembered_args_fingerprint = ask.expired_args_fingerprint
            ; remembered_decision = decision
            ; remembered_answered_at = now
            }
          in
          (* One identity keeps one standing answer, the operator's latest:
             answering twice is a change of mind, not two answers. *)
          t.remembered <-
            entry
            :: List.filter
                 (fun existing ->
                   not
                     (same_identity existing ~keeper_name:entry.remembered_keeper_name
                        ~tool_name:entry.remembered_tool_name
                        ~args_fingerprint:entry.remembered_args_fingerprint))
                 t.remembered;
          Remembered { tool_name = ask.expired_tool_name })

let take t ?(now = Unix.gettimeofday ()) ~keeper_name ~tool_name ~args () =
  let args_fingerprint = fingerprint_of args in
  Stdlib.Mutex.protect t.mutex (fun () ->
      (* A stale entry is reaped before the lookup, so an aged memory reads
         as no memory and the call is asked about again. *)
      reap_locked t ~now;
      match
        List.find_opt
          (fun entry ->
            same_identity entry ~keeper_name ~tool_name ~args_fingerprint)
          t.remembered
      with
      | None -> None
      | Some entry ->
          (* Consumed by the one call it settles: the next identical call is
             asked about again, because the operator said yes to this call,
             not to every call that looks like it. *)
          t.remembered <-
            List.filter
              (fun existing ->
                not
                  (same_identity existing ~keeper_name ~tool_name
                     ~args_fingerprint))
              t.remembered;
          Some entry.remembered_decision)
