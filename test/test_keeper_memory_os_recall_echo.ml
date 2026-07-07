(** RFC-0285 §8 — recall echo must not refresh the truth anchor.

    The flywheel this closes: recall injects a fact into the prompt every turn
    (top-N by truth-anchor recency); the model restates it; the librarian
    re-extracts the restatement; [reobserve_fact] treated that as fresh
    evidence and advanced [last_verified_at]; the advanced anchor kept the fact
    at the top of the recency-ranked recall window — so a fact could sustain
    its own recall slot indefinitely regardless of truth (observed: keeper
    albini, 81/316 rows of self-referential inaction doctrine re-injected every
    turn for days). §8 classifies each re-observation at the write boundary:
    a claim whose identity was recall-injected into the summarized window is a
    [Recalled_echo] and inherits the row whole. *)

open Alcotest

module Types = Masc.Keeper_memory_os_types
module Policy = Masc.Keeper_memory_os_policy
module Window = Masc.Keeper_recall_injection_window

let now = 2_000_000.0

let fact ?(claim = "keeper must do zero tool calls and emit one short line")
    ?(claim_id = None) ?(claim_kind = None) ?(category = Types.Lesson)
    ?(last_verified_at = Some (now -. 3_600.0)) () : Types.fact =
  { Types.claim
  ; Types.category
  ; Types.external_ref = None
  ; Types.claim_kind
  ; Types.source = { Types.trace_id = "trace-echo"; Types.turn = 58; Types.tool_call_id = None }
  ; Types.observed_by = []
  ; Types.first_seen = now -. 86_400.0
  ; Types.valid_until = None
  ; Types.last_verified_at
  ; Types.schema_version = Types.schema_version
  ; Types.claim_id
  }
;;

(* 1. The core anchor property: an echoed re-observation of a durable claim
   inherits the row whole — [last_verified_at] does not advance — while an
   independent re-observation of the same rows still advances it. *)
let test_echo_does_not_advance_truth_anchor () =
  let stale = Some (now -. 3_600.0) in
  let existing = fact ~last_verified_at:stale () in
  let incoming = fact () in
  let echoed =
    Policy.reobserve_fact ~now ~provenance:Policy.Recalled_echo ~existing ~incoming
  in
  check (option (float 0.001)) "echo: last_verified_at unchanged" stale
    echoed.Types.last_verified_at;
  check (option (float 0.001)) "echo: valid_until unchanged" None
    echoed.Types.valid_until;
  let independent =
    Policy.reobserve_fact
      ~now
      ~provenance:Policy.Independent_observation
      ~existing
      ~incoming
  in
  check (option (float 0.001)) "independent: last_verified_at advances" (Some now)
    independent.Types.last_verified_at
;;

(* 2. Echo inheritance is uniform across claim_kinds: the arms that already
   preserved the anchor (Self_observation, External_state) keep doing so, and
   Durable_knowledge — the arm the albini flywheel ran through, because the
   librarian affirmatively mistagged inaction doctrine as durable — no longer
   advances on echo. *)
let test_echo_inherits_for_every_claim_kind () =
  let stale = Some (now -. 3_600.0) in
  List.iter
    (fun claim_kind ->
      let existing = fact ~claim_kind ~last_verified_at:stale () in
      let incoming = fact ~claim_kind () in
      let echoed =
        Policy.reobserve_fact ~now ~provenance:Policy.Recalled_echo ~existing ~incoming
      in
      check (option (float 0.001)) "echo inherits anchor for every claim_kind" stale
        echoed.Types.last_verified_at)
    [ None
    ; Some Types.Durable_knowledge
    ; Some Types.Self_observation
    ; Some Types.External_state
    ; Some Types.Diagnostic
    ]
;;

(* 3. Window membership: keys noted for a keeper are visible to that keeper
   only, and only within [window_turns]. *)
let test_window_membership_and_isolation () =
  let keeper_id = "echo-test-membership" in
  let other_id = "echo-test-membership-other" in
  Window.note ~keeper_id ~turn:100 ~keys:[ "id:self-obs-idle-loop"; "claim:zero tool calls" ];
  check bool "noted key is recently injected" true
    (Window.recently_injected ~keeper_id ~key:"id:self-obs-idle-loop");
  check bool "unknown key is not" false
    (Window.recently_injected ~keeper_id ~key:"id:something-else");
  check bool "other keeper does not see the key" false
    (Window.recently_injected ~keeper_id:other_id ~key:"id:self-obs-idle-loop")
;;

(* 4. Pruning: an entry older than [window_turns] is dropped on the next note;
   a turn-numbering reset (new turn lower than stored turns) also drops stale
   entries instead of letting a dead numbering suppress forever. *)
let test_window_prunes_old_and_reset_entries () =
  let keeper_id = "echo-test-prune" in
  Window.note ~keeper_id ~turn:10 ~keys:[ "claim:old entry" ];
  Window.note ~keeper_id ~turn:(10 + Window.window_turns) ~keys:[ "claim:new entry" ];
  check bool "entry beyond window_turns is pruned" false
    (Window.recently_injected ~keeper_id ~key:"claim:old entry");
  check bool "fresh entry survives" true
    (Window.recently_injected ~keeper_id ~key:"claim:new entry");
  let keeper_id = "echo-test-reset" in
  Window.note ~keeper_id ~turn:500 ~keys:[ "claim:pre-reset" ];
  Window.note ~keeper_id ~turn:3 ~keys:[ "claim:post-reset" ];
  check bool "entries from a reset numbering are pruned" false
    (Window.recently_injected ~keeper_id ~key:"claim:pre-reset");
  check bool "post-reset entry visible" true
    (Window.recently_injected ~keeper_id ~key:"claim:post-reset")
;;

(* 5. Empty keys are a no-op and re-noting a turn replaces that turn's entry. *)
let test_window_empty_noop_and_same_turn_replace () =
  let keeper_id = "echo-test-replace" in
  Window.note ~keeper_id ~turn:7 ~keys:[];
  check bool "empty note stores nothing" false
    (Window.recently_injected ~keeper_id ~key:"claim:anything");
  Window.note ~keeper_id ~turn:8 ~keys:[ "claim:first render" ];
  Window.note ~keeper_id ~turn:8 ~keys:[ "claim:second render" ];
  check bool "same-turn re-note replaces the entry" false
    (Window.recently_injected ~keeper_id ~key:"claim:first render");
  check bool "replacement entry visible" true
    (Window.recently_injected ~keeper_id ~key:"claim:second render")
;;

(* 6. The write-boundary composition the librarian uses: joining the incoming
   claim's identity against the window yields Recalled_echo exactly for
   injected identities, and the [claim_identity] key matches whether the
   identity comes from a producer claim_id or the normalized claim text. *)
let test_write_boundary_join () =
  let keeper_id = "echo-test-join" in
  let with_id = fact ~claim_id:(Some "self-obs-idle-loop") () in
  let by_text = fact ~claim:"board polling without new signals is waste" () in
  Window.note
    ~keeper_id
    ~turn:42
    ~keys:[ Types.claim_identity with_id; Types.claim_identity by_text ];
  let provenance_of incoming =
    if Window.recently_injected ~keeper_id ~key:(Types.claim_identity incoming)
    then Policy.Recalled_echo
    else Policy.Independent_observation
  in
  let is_echo p = match p with Policy.Recalled_echo -> true | _ -> false in
  check bool "claim_id-keyed identity joins as echo" true (is_echo (provenance_of with_id));
  check bool "text-keyed identity joins as echo" true (is_echo (provenance_of by_text));
  let fresh = fact ~claim:"dune build failed on missing module alias" () in
  check bool "un-injected claim stays independent" false (is_echo (provenance_of fresh))
;;

(* 7. Flywheel regression: simulate the inject -> restate -> re-extract loop.
   Under the echo rule the anchor never advances across N cycles, so the fact
   ages out of recency instead of self-sustaining. *)
let test_flywheel_anchor_frozen_across_cycles () =
  let keeper_id = "echo-test-flywheel" in
  let anchor = Some (now -. 7_200.0) in
  let existing = ref (fact ~claim_id:(Some "zero-tool-doctrine") ~last_verified_at:anchor ()) in
  for cycle = 1 to 5 do
    let turn = 200 + cycle in
    Window.note ~keeper_id ~turn ~keys:[ Types.claim_identity !existing ];
    let incoming = fact ~claim_id:(Some "zero-tool-doctrine") () in
    let provenance =
      if Window.recently_injected ~keeper_id ~key:(Types.claim_identity incoming)
      then Policy.Recalled_echo
      else Policy.Independent_observation
    in
    existing
    := Policy.reobserve_fact
         ~now:(now +. (60.0 *. float_of_int cycle))
         ~provenance
         ~existing:!existing
         ~incoming
  done;
  check (option (float 0.001)) "anchor frozen across 5 echo cycles" anchor
    !existing.Types.last_verified_at
;;

let () =
  run
    "keeper_memory_os_recall_echo"
    [ ( "rfc-0285-s8"
      , [ test_case "echo does not advance truth anchor" `Quick
            test_echo_does_not_advance_truth_anchor
        ; test_case "echo inherits for every claim_kind" `Quick
            test_echo_inherits_for_every_claim_kind
        ; test_case "window membership and isolation" `Quick
            test_window_membership_and_isolation
        ; test_case "window prunes old and reset entries" `Quick
            test_window_prunes_old_and_reset_entries
        ; test_case "window empty noop and same-turn replace" `Quick
            test_window_empty_noop_and_same_turn_replace
        ; test_case "write boundary join" `Quick test_write_boundary_join
        ; test_case "flywheel anchor frozen across cycles" `Quick
            test_flywheel_anchor_frozen_across_cycles
        ] )
    ]
;;
