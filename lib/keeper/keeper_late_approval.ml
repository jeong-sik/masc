module Registry = Keeper_tool_approval_registry

(* What one timed-out ask was about. The wait itself is gone — the registry
   does not hold it (registry.mli: a call whose waiter is gone is not held
   for later) — but the question's description is kept so an answer that
   arrives late can still be attributed to the exact call it was shown
   for. [expired_noted_at] bounds that courtesy: an ask older than [ttl_sec]
   is reaped before it can be answered, because an answer that late is not
   about the moment the operator was shown. *)

type expired_ask =
  { expired_base_path : string
  ; expired_keeper_name : string
  ; expired_tool_call_id : string
  ; expired_tool_name : string
  ; expired_args_fingerprint : string
  ; expired_noted_at : float
  }

(* An operator's answer to an expired ask, keyed by the call rather than the
   call id: the retry carries a fresh tool_call_id, so identity here is
   (keeper, tool, canonical-args fingerprint) — the same fingerprint the
   durable approval rules use
   ({!Keeper_approval_request_fingerprint.request_fingerprint}).

   [remembered_answered_at] is what keeps a 180-second-window human decision
   from becoming a permanent credential: past [ttl_sec] the entry is stale
   and treated as no memory. *)

type remembered = {
  remembered_base_path : string
; remembered_keeper_name : string
; remembered_tool_name : string
; remembered_args_fingerprint : string
; remembered_decision : Registry.decision
  (* The authenticated caller who made the decision, recorded at the HTTP
     boundary (task-1662). *)
; remembered_decision_actor : string
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

type journal_error = Corrupt_journal of string | Journal_unavailable of string
type uncertain_attempt =
  { consume_id : string; base_path : string; keeper_name : string
  ; tool_name : string; args_fingerprint : string; consumed_at : float }
let journal_schema = "masc.late_approval.v2"

type t =
  { mutable expired : expired_ask list
  ; mutable remembered : remembered list
  ; mutable uncertain : uncertain_attempt list
  ; mutable journal_error : journal_error option
  ; mutable journal_path : string option
  ; mutex : Stdlib.Mutex.t
  }

let create () =
  { expired = []
  ; remembered = []
  ; uncertain = []
  ; journal_error = None
  ; journal_path = None
  ; mutex = Stdlib.Mutex.create ()
  }

(* The entire blocking lock and file transaction runs off the scheduler.
   Nested Fs/Eio_guard calls execute inline in this non-Eio worker. *)
let with_store t f = Eio_guard.run_in_systhread ~label:"late-approval-store" (fun () ->
  Stdlib.Mutex.protect t.mutex f)

(* Created at load, so there is no moment where a timeout or a late answer
   arrives before the store exists — the same argument the registry makes
   for its own [shared]. *)
let shared_store = create ()
let shared () = shared_store

let fingerprint_of (args : Yojson.Safe.t) =
  Keeper_approval_request_fingerprint.request_fingerprint args

(* Journal plumbing (design D2). The store itself stays the in-memory
   authority it was; the journal is the crash boundary under it. [bind] is
   synchronous at boot, before any turn can reach [take], so a restored
   remembered answer is already standing when the first identical retry
   arrives — a restore that happened lazily on first use could answer an
   ask the operator already settled. All file work goes through
   [Eio_guard.run_in_systhread], the same blocking-I/O pattern the approval
   queue uses, so the call is correct from an Eio fiber and from tests
   outside the runtime alike. An unbound store keeps the pre-journal
   behavior: the server binds the shared store at boot, and tests that
   exercise durability bind their own temp-dir store. *)

let validate_records records =
  let attempts = Hashtbl.create 16 in
  let bad detail = raise (Yojson.Json_error detail) in
  List.iter (fun fields ->
    let string name = match List.assoc_opt name fields with
      | Some (`String value) when value <> "" -> value
      | _ -> bad ("missing or invalid " ^ name) in
    let op = string "op" in
    let names = ["schema";"op";"base_path";"keeper";"tool";"fingerprint";"at"] @
      (match op with
       | "note_timed_out" -> ["tool_call_id"]
       | "remember_late" -> ["tool_call_id";"decision";"actor"]
       | "consume" | "deliver" | "ack_uncertain" -> ["consume_id"]
       | _ -> bad "unknown late approval operation") in
    if List.sort String.compare (List.map fst fields) <> List.sort String.compare names then
      bad "missing, duplicate or unknown journal fields";
    if string "schema" <> journal_schema then bad "unknown journal schema";
    let identity = string "base_path", string "keeper", string "tool", string "fingerprint" in
    (match List.assoc "at" fields with
     | `Float value when Float.is_finite value -> ()
     | `Int _ -> () | _ -> bad "invalid journal timestamp");
    match op with
    | "note_timed_out" -> ignore (string "tool_call_id")
    | "remember_late" ->
        ignore (string "tool_call_id"); ignore (string "actor");
        if Option.is_none (Registry.decision_of_string (string "decision")) then bad "invalid decision"
    | "consume" ->
        let id = string "consume_id" in
        if Hashtbl.mem attempts id then bad "duplicate consume attempt";
        Hashtbl.add attempts id (identity, false)
    | "deliver" | "ack_uncertain" ->
        let id = string "consume_id" in
        (match Hashtbl.find_opt attempts id with
         | Some (expected, false) when expected = identity -> Hashtbl.replace attempts id (identity, true)
         | _ -> bad "closure does not name an open exact consume")
    | _ -> bad "unknown journal operation") records

(* Entries older than the TTL leave on every write and every read, so the
   lists cannot grow on nothing but time: an unattended keeper whose asks
   keep timing out leaves entries that the next operation reaps, and a
   remembered answer nobody's retry ever claims does not outlive its
   moment. The journal is deliberately left alone: it is the crash
   history, and the store re-derives its view from it at boot (the design's
   "the journal is never cleaned"). Under the mutex; callers already hold
   it. *)
let reap_locked t ~now =
  let fresh noted_at = now -. noted_at <= ttl_sec in
  t.expired <-
    List.filter
      (fun ask -> fresh ask.expired_noted_at)
      t.expired;
  t.remembered <-
    List.filter (fun entry -> fresh entry.remembered_answered_at) t.remembered

let bind_to_journal ?now ~base_path t =
  let path = Keeper_gate_path.late_approval_log ~base_path in
  let now = match now with Some now -> now | None -> Unix.gettimeofday () in
  let restore () =
    match Fs_compat.recover_private_jsonl_durable_locked_result path with
    | Error error -> t.journal_error <- Some (Journal_unavailable
        (Fs_compat.private_jsonl_transaction_error_to_string error))
    | Ok snapshot when snapshot.Fs_compat.bytes = "" -> ()
    | Ok snapshot ->
        (* Oldest-first replay, the order the rows were appended in: the
           view is re-derived by letting the same rules that produced the
           rows act on them again, so the store cannot disagree with its
           own history. Only complete rows are returned; a torn tail was
           already cut by the recovery read. *)
        let records =
          snapshot.Fs_compat.bytes
          |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "")
          |> List.filter_map (fun line ->
                 match Yojson.Safe.from_string line with
                 | `Assoc fields ->
                     if List.assoc_opt "schema" fields <> Some (`String journal_schema) then
                       raise (Yojson.Json_error "unknown late approval journal schema");
                     (match List.assoc_opt "op" fields with
                      | Some (`String ("consume" | "deliver" | "ack_uncertain")) ->
                          (match List.assoc_opt "consume_id" fields with
                           | Some (`String id) when id <> "" -> ()
                           | _ -> raise (Yojson.Json_error "missing consume attempt identity"))
                      | _ -> ());
                     Some fields
                 | _ -> raise (Yojson.Json_error "expected journal object"))
        in
        validate_records records;
        let read_field fields name =
          match List.assoc_opt name fields with
          | Some (`String s) -> Some s
          | _ -> None
        in
        let read_float fields name =
          match List.assoc_opt name fields with
          | Some (`Float f) -> Some f
          | Some (`Int i) -> Some (float_of_int i)
          | _ -> None
        in
        (* The replay state: live asks (recorded, not yet answered or
           consumed), remembered answers, the consumed identities whose
           deliver row has not closed them, and the consume-only tails an
           operator has already acknowledged. *)
        let live_asks = ref [] in
        let remembered = ref [] in
        let consumed = ref [] in
        let acked = ref [] in
        List.iter
          (fun fields ->
            let op = read_field fields "op" in
            let row_base_path = read_field fields "base_path" in
            let keeper = read_field fields "keeper" in
            let call_id = read_field fields "tool_call_id" in
            let tool = read_field fields "tool" in
            let fingerprint = read_field fields "fingerprint" in
            let at = read_float fields "at" in
            let consume_id = read_field fields "consume_id" in
            match op with
            | Some "note_timed_out" -> (
                match (row_base_path, keeper, call_id, tool, fingerprint, at)
                with
                | Some bp, Some k, Some c, Some tl, Some f, Some at ->
                    live_asks :=
                      { expired_base_path = bp
                      ; expired_keeper_name = k
                      ; expired_tool_call_id = c
                      ; expired_tool_name = tl
                      ; expired_args_fingerprint = f
                      ; expired_noted_at = at
                      }
                      :: !live_asks
                | _ -> ())
            | Some "remember_late" -> (
                match (row_base_path, keeper, tool, fingerprint, at) with
                | Some bp, Some k, Some tl, Some f, Some at -> (
                    (* The ask leaves [live] — it was answered — and any
                       earlier memory of the same identity is the operator's
                       superseded answer, exactly what [remember_late]
                       replaces in memory. *)
                    let row_call_id =
                      Option.value call_id ~default:"" in
                    live_asks :=
                      List.filter
                        (fun ask ->
                          not
                            (String.equal ask.expired_base_path bp
                            && String.equal ask.expired_keeper_name k
                            && String.equal ask.expired_tool_call_id
                                 row_call_id))
                        !live_asks;
                    match
                      ( read_field fields "decision"
                      , read_field fields "actor" )
                    with
                    | Some decision, Some actor -> (
                        match Registry.decision_of_string decision with
                        | Some decision ->
                            remembered :=
                              { remembered_base_path = bp
                              ; remembered_keeper_name = k
                              ; remembered_tool_name = tl
                              ; remembered_args_fingerprint = f
                              ; remembered_decision = decision
                              ; remembered_decision_actor = actor
                              ; remembered_answered_at = at
                              }
                              :: List.filter
                                   (fun existing ->
                                     not
                                       (String.equal
                                          existing.remembered_base_path bp
                                       && String.equal
                                            existing.remembered_keeper_name k
                                       && String.equal
                                            existing.remembered_tool_name tl
                                       && String.equal
                                            existing.remembered_args_fingerprint
                                            f))
                                   !remembered
                        | None -> ())
                    | _ -> ())
                | _ -> ())
            | Some "consume" -> (
                match (consume_id, row_base_path, keeper, tool, fingerprint, at) with
                | Some id, Some bp, Some k, Some tl, Some f, Some at ->
                    (* The remembered answer is durably spent: dropping it
                       here mirrors the in-memory path, so a replayed
                       consume can never hand the same decision to a second
                       call. A later [deliver] closes the window; a crash
                       before it leaves this consume uncertain. Not yet
                       TTL-reaped here — the bound-time reap below decides
                       what still counts. *)
                    remembered :=
                      List.filter
                        (fun existing ->
                          not
                            (String.equal existing.remembered_base_path bp
                            && String.equal existing.remembered_keeper_name k
                            && String.equal existing.remembered_tool_name tl
                            && String.equal
                                 existing.remembered_args_fingerprint f))
                        !remembered;
                    consumed := (id, bp, k, tl, f, at) :: !consumed
                | _ -> ())
            | Some "deliver" -> (
                match (consume_id, row_base_path, keeper, tool, fingerprint, at) with
                | Some id, Some bp, Some k, Some tl, Some f, Some at ->
                    consumed :=
                      List.filter
                        (fun (cid, cbp, ck, ctl, cf, _) ->
                          not
                            (String.equal cbp bp
                            && String.equal ck k
                            && String.equal ctl tl
                            && String.equal cf f
                            && String.equal cid id))
                        !consumed
                | _ -> ())
            | Some "ack_uncertain" -> (
                (* The operator's acknowledgement that they have seen this
                   consume-only tail (design D4/§7): a warning
                   acknowledgement, never a re-authorization — nothing is
                   re-applied, no memory is restored, and no new attempt is
                   authorized. The acked consume leaves the count. *)
                match (consume_id, row_base_path, keeper, tool, fingerprint, at) with
                | Some id, Some bp, Some k, Some tl, Some f, Some at ->
                    acked :=
                      (id, bp, k, tl, f, at) :: !acked
                | _ -> ())
            | _ -> ())
          records;
        (* An ack closes only its exact consume attempt under the same scope.
           Its timestamp cannot settle another attempt of the same input. *)
        let acked_consumes =
          List.filter
            (fun (cid, cbp, ck, ctl, cf, _) ->
               List.exists
                 (fun (aid, abp, ak, atl, af, _) ->
                    String.equal cbp abp
                    && String.equal ck ak
                    && String.equal ctl atl
                    && String.equal cf af
                    && String.equal cid aid)
                 !acked)
            !consumed
        in
        let open_consumes =
          List.filter
            (fun consume -> not (List.mem consume acked_consumes))
            !consumed
        in
        (* A consume without a later deliver is the outcome-unknown window
           the design names: the decision may have returned to its caller, so the
           tool may have dispatched already — the journal alone cannot
           separate "never delivered" from "delivered, outcome unwritten".
           It is surfaced as [late_uncertain] until its exact attempt is
           acknowledged. Authorization TTL does not expire uncertain evidence. *)
        t.uncertain <- List.map (fun (consume_id, base_path, keeper_name, tool_name, args_fingerprint, consumed_at) ->
          {consume_id; base_path; keeper_name; tool_name; args_fingerprint; consumed_at}) open_consumes;
        (* Newest-first, matching the order [note_timed_out] and
           [remember_late] keep in memory. *)
        t.expired <- !live_asks;
        t.remembered <- !remembered
  in
  with_store t (fun () ->
      t.expired <- []; t.remembered <- []; t.uncertain <- []; t.journal_error <- None;
      (try Eio_guard.run_in_systhread ~label:"late-approval-journal-restore" restore
       with Yojson.Json_error detail -> t.journal_error <- Some (Corrupt_journal detail));
      (* Bound after restore the way every other operation reaps: a record
         older than the authorization ceiling is restored as nothing, not
         as a credential. *)
      reap_locked t ~now;
      t.journal_path <- Some path)

let journal_uncertain t = with_store t (fun () -> List.length t.uncertain)
let journal_error t = with_store t (fun () -> t.journal_error)
let uncertain_attempts t ~base_path = with_store t (fun () ->
  match t.journal_error with
  | Some error -> Error error
  | None -> Ok (List.filter (fun entry -> String.equal entry.base_path base_path) t.uncertain))

let append_record_locked t record =
  if Option.is_some t.journal_error then Error ()
  else match t.journal_path with
  (* An unbound store keeps the pre-journal behavior (the same contract
     [bind_to_journal] documents): there is no crash boundary to
     acknowledge, so nothing has to stand or fall with a file and the
     in-memory state is the whole authority. *)
  | None -> Ok ()
  | Some path -> (
      let line = Yojson.Safe.to_string (`Assoc (("schema", `String journal_schema) :: record)) ^ "\n" in
      match
        Eio_guard.run_in_systhread
          ~label:"late-approval-journal-append"
          (fun () ->
            Fs_compat.append_private_jsonl_durable_stable_result path line
            |> Fs_compat.private_jsonl_cursor_success_receipt)
      with
      | Ok receipt ->
          (* Settlement can fail after the append has durably committed. Its
             success receipt is authoritative; adding another closure would
             corrupt the exact-attempt history. *)
          Option.iter (fun error -> Log.Keeper.warn
            "late_approval_journal: committed append cleanup failed: %s"
            (Fs_compat.private_jsonl_transaction_error_to_string error))
            receipt.Fs_compat.settlement_error;
          Ok ()
      | Error error ->
          (* No known commit receipt: refuse further mutations until an
             explicit restore re-establishes the durable history. *)
          t.journal_error <- Some (Journal_unavailable
            (Fs_compat.private_jsonl_transaction_error_to_string error));
          Error ())

(* NDT-OK: wall-clock default at this boundary; the gate passes its own
   clock's reading so ages are measured against the same clock family the
   wait ran on, and tests inject [~now]. *)
let note_timed_out t ?(now = Unix.gettimeofday ()) ~base_path ~keeper_name
    ~tool_call_id ~tool_name ~args () =
  let entry =
    { expired_base_path = base_path
    ; expired_keeper_name = keeper_name
    ; expired_tool_call_id = tool_call_id
    ; expired_tool_name = tool_name
    ; expired_args_fingerprint = fingerprint_of args
    ; expired_noted_at = now
    }
  in
  with_store t (fun () ->
      reap_locked t ~now;
      let appended =
        append_record_locked t
          [ ("op", `String "note_timed_out")
          ; ("base_path", `String base_path)
          ; ("keeper", `String keeper_name)
          ; ("tool_call_id", `String tool_call_id)
          ; ("tool", `String tool_name)
          ; ("fingerprint", `String entry.expired_args_fingerprint)
          ; ("at", `Float now)
          ]
      in
      (* The memory holds only what the journal acknowledged: a failed
         append means the ask survives restarts as nothing, so the retry is
         asked about again — losing a re-ask is the cheap failure, keeping
         an unjournaled one is not (a crash could then resurrect an ask the
         journal never acknowledged). *)
      if appended = Ok () then t.expired <- entry :: t.expired)

type remember_outcome =
  | Remembered of { tool_name : string }
  | No_matching_ask

let same_ask (ask : expired_ask) ~base_path ~keeper_name ~tool_call_id =
  String.equal ask.expired_base_path base_path
  && String.equal ask.expired_keeper_name keeper_name
  && String.equal ask.expired_tool_call_id tool_call_id

let same_identity (left : remembered) ~base_path ~keeper_name ~tool_name
    ~args_fingerprint =
  String.equal left.remembered_base_path base_path
  && String.equal left.remembered_keeper_name keeper_name
  && String.equal left.remembered_tool_name tool_name
  && String.equal left.remembered_args_fingerprint args_fingerprint

let remember_late t ?(now = Unix.gettimeofday ()) ~base_path ~keeper_name
    ~tool_call_id ~actor decision () =
  with_store t (fun () ->
      reap_locked t ~now;
      (* [expired] is newest-first, and so is this match: if a provider ever
         recycles a call id, the answer attaches to the newest ask that
         carried it. That is the safe direction — it is the prompt the
         operator was shown most recently, and the older entry with the same
         id describes an ask its own timeout already ended. Workspace
         identity is part of the match (design D2): workspaces that share
         this gate root cannot have their asks answered by each other's
         operators. *)
      match
        List.find_opt
          (fun ask -> same_ask ask ~base_path ~keeper_name ~tool_call_id)
          t.expired
      with
      | None -> No_matching_ask
      | Some ask -> (
          let record =
            [ ("op", `String "remember_late")
            ; ("base_path", `String base_path)
            ; ("keeper", `String keeper_name)
            ; ("tool_call_id", `String tool_call_id)
            ; ("tool", `String ask.expired_tool_name)
            ; ("fingerprint", `String ask.expired_args_fingerprint)
            ; ("decision", `String (Registry.decision_to_string decision))
            ; ("actor", `String actor)
            ; ("at", `Float now)
            ]
          in
          match append_record_locked t record with
          | Error () ->
              (* Nothing stands without its journal row: the operator's
                 answer is lost across a restart, but a remembered entry
                 the journal never acknowledged could not be told apart
                 from one that survived. The ask is kept so a retry re-asks
                 instead of silently consuming an unwritten answer. *)
              No_matching_ask
          | Ok () ->
              t.expired <-
                List.filter
                  (fun expired ->
                    not
                      (same_ask expired ~base_path ~keeper_name ~tool_call_id))
                  t.expired;
              let entry =
                { remembered_base_path = base_path
                ; remembered_keeper_name = ask.expired_keeper_name
                ; remembered_tool_name = ask.expired_tool_name
                ; remembered_args_fingerprint = ask.expired_args_fingerprint
                ; remembered_decision = decision
                ; remembered_decision_actor = actor
                ; remembered_answered_at = now
                }
              in
              (* One identity keeps one standing answer, the operator's
                 latest: answering twice is a change of mind, not two
                 answers. *)
              t.remembered <-
                entry
                :: List.filter
                     (fun existing ->
                       not
                         (same_identity existing ~base_path
                            ~keeper_name:entry.remembered_keeper_name
                            ~tool_name:entry.remembered_tool_name
                            ~args_fingerprint:entry.remembered_args_fingerprint))
                     t.remembered;
              Remembered { tool_name = ask.expired_tool_name }))

let take t ?(now = Unix.gettimeofday ()) ~base_path ~keeper_name ~tool_name
    ~args () =
  let args_fingerprint = fingerprint_of args in
  with_store t (fun () ->
      (* A stale entry is reaped before the lookup, so an aged memory reads
         as no memory and the call is asked about again. *)
      reap_locked t ~now;
      match
        if Option.is_some t.journal_error then None else List.find_opt
          (fun entry ->
            same_identity entry ~base_path ~keeper_name ~tool_name
              ~args_fingerprint)
          t.remembered
      with
      | None -> None
      | Some entry -> (
          let consume_id = Random_id.uuid_v7 () in
          (* Consume-before-return (design D2, reviewer boundary 2): the
             decision is durably spent before it reaches the caller. If the
             append fails, nothing changes in memory — the restart
             re-offers this decision instead of silently dropping it, and
             the call is asked about live. *)
          match
            append_record_locked t
              [ ("op", `String "consume")
              ; ("consume_id", `String consume_id)
              ; ("base_path", `String base_path)
              ; ("keeper", `String keeper_name)
              ; ("tool", `String entry.remembered_tool_name)
              ; ("fingerprint", `String args_fingerprint)
              ; ("at", `Float now)
              ]
          with
          | Error () -> None
          | Ok () ->
              (* Consumed by the one call it settles: the next identical
                 call is asked about again, because the operator said yes
                 to this call, not to every call that looks like it. The
                 actor stamp is the only consumer-visible trace of who made
                 the decision, so it is read here rather than left to rot
                 unread in the record. *)
              Log.Keeper.info
                "keeper_late_approval: consumed remembered decision workspace=%s keeper=%s tool=%s decision=%s actor=%s"
                base_path keeper_name entry.remembered_tool_name
                (Registry.decision_to_string entry.remembered_decision)
                entry.remembered_decision_actor;
              t.remembered <-
                List.filter
                  (fun existing ->
                    not
                      (same_identity existing ~base_path ~keeper_name
                         ~tool_name ~args_fingerprint))
                  t.remembered;
              (* Record delivery intent before returning. This is not external
                 effect completion. If this append fails the decision still
                 returns, so the exact consume remains outcome-unknown. *)
              (match
                 append_record_locked t
                   [ ("op", `String "deliver")
                   ; ("consume_id", `String consume_id)
                   ; ("base_path", `String base_path)
                   ; ("keeper", `String keeper_name)
                   ; ("tool", `String entry.remembered_tool_name)
                   ; ("fingerprint", `String args_fingerprint)
                   ; ("at", `Float now)
                   ]
               with
              | Ok () -> ()
              | Error () -> t.uncertain <-
                  {consume_id; base_path; keeper_name; tool_name; args_fingerprint; consumed_at=now}
                  :: t.uncertain);
              Some entry.remembered_decision))

(* The D4/§7 operator acknowledgement of one consume-only tail. Nothing is
   re-applied and nothing is restored — the ack only closes the warning, so
   the count it drops is a count of acknowledged warnings, not of
   re-authorized calls. The ack row is durably appended before the count
   drops, so it survives restarts the same way the consume it answers
   does. *)
type ack_outcome =
  | Acked
  | Ack_not_journaled
  | Not_uncertain

let ack_uncertain t ?(now = Unix.gettimeofday ()) ~base_path ~keeper_name
    ~consume_id () : ack_outcome =
  let matches entry = entry.consume_id = consume_id && entry.base_path = base_path
    && entry.keeper_name = keeper_name in
  with_store t (fun () ->
    if Option.is_some t.journal_error then Ack_not_journaled
    else match List.find_opt matches t.uncertain with
    | None -> Not_uncertain
    | Some entry ->
        match append_record_locked t
          ["op", `String "ack_uncertain"; "consume_id", `String consume_id;
           "base_path", `String base_path; "keeper", `String keeper_name;
           "tool", `String entry.tool_name; "fingerprint", `String entry.args_fingerprint;
           "at", `Float now] with
        | Error () -> Ack_not_journaled
        | Ok () ->
            t.uncertain <- List.filter (fun attempt -> not (matches attempt)) t.uncertain;
            Acked)
