module Registry = Keeper_tool_approval_registry

(* What one timed-out ask was about. The wait itself is gone — the registry
   does not hold it (registry.mli: a call whose waiter is gone is not held
   for later) — but the question's description is kept so an answer that
   arrives late can still be attributed to the exact call it was shown
   for. *)

type expired_ask =
  { expired_keeper_name : string
  ; expired_tool_call_id : string
  ; expired_tool_name : string
  ; expired_args_fingerprint : string
  }

(* An operator's answer to an expired ask, keyed by the call rather than the
   call id: the retry carries a fresh tool_call_id, so identity here is
   (keeper, tool, canonical-args fingerprint) — the same fingerprint the
   durable approval rules use
   ({!Keeper_approval_queue_rules.request_fingerprint}). *)

type remembered =
  { remembered_keeper_name : string
  ; remembered_tool_name : string
  ; remembered_args_fingerprint : string
  ; remembered_decision : Registry.decision
  }

(* Entries leave [expired] only by being answered, and leave [remembered]
   only by being consumed by the identical call arriving at the gate. The
   list grows while asks time out unanswered — that is exactly the case
   where nobody is answering, so the entries sit harmlessly until the one
   answer that needs them arrives. *)
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

let note_timed_out t ~keeper_name ~tool_call_id ~tool_name ~args =
  let entry =
    { expired_keeper_name = keeper_name
    ; expired_tool_call_id = tool_call_id
    ; expired_tool_name = tool_name
    ; expired_args_fingerprint = fingerprint_of args
    }
  in
  Stdlib.Mutex.protect t.mutex (fun () ->
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

let remember_late t ~keeper_name ~tool_call_id decision =
  Stdlib.Mutex.protect t.mutex (fun () ->
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

let take t ~keeper_name ~tool_name ~args =
  let args_fingerprint = fingerprint_of args in
  Stdlib.Mutex.protect t.mutex (fun () ->
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
