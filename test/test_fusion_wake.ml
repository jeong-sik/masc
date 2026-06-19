(* RFC-0266 Phase 1 — fusion async-completion wake + actionable delivery.

   The wake (Fusion_sink.wake_keeper_on_fusion_completion -> wakeup_keeper) needs
   a live registry, so it is exercised end-to-end at runtime rather than here.
   These unit checks pin the two compile-passing-but-silently-wrong failure
   modes a stub could introduce:

   1. the closed-sum helpers must classify the new [Fusion_completed] variant
      (label / is_board_signal / reaction-ledger kind); and
   2. a completed fusion must become a NON-EMPTY [pending_board_event] carrying
      the resolved answer — returning [] (like the Bootstrap/No_progress_recovery
      arms) would compile but silently drop the result, defeating the RFC. *)

open Alcotest
open Masc

(* substring check without pulling in the [str] library *)
let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.equal (String.sub haystack i nl) needle || go (i + 1)) in
  nl = 0 || go 0
;;

let make_meta ?(name = "fusion-keeper") () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ ("name", `String name)
         ; ("agent_name", `String name)
         ; ("trace_id", `String "test-trace-fusion")
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)
;;

let fusion_payload
      ?(run_id = "fus-1")
      ?(ok = true)
      ?(resolved_answer = "use approach B because it is reversible")
      ?(board_post_id = "post-77")
      ()
  : Keeper_event_queue.fusion_completion
  =
  { run_id; ok; resolved_answer; board_post_id }
;;

let fusion_stimulus ?run_id ?ok ?resolved_answer ?board_post_id () : Keeper_event_queue.stimulus =
  { post_id = "ignored-by-fusion-arm"
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = 1000.0
  ; payload =
      Keeper_event_queue.Fusion_completed
        (fusion_payload ?run_id ?ok ?resolved_answer ?board_post_id ())
  }
;;

(* (1) closed-sum helpers classify the new variant *)
let test_closed_sum_helpers () =
  let p = Keeper_event_queue.Fusion_completed (fusion_payload ()) in
  check string "payload_kind_label" "fusion_completed" (Keeper_event_queue.payload_kind_label p);
  check bool "is_board_signal is false" false (Keeper_event_queue.is_board_signal p);
  check
    string
    "reaction_ledger stimulus_kind_to_string"
    "fusion_completed"
    (Keeper_reaction_ledger.stimulus_kind_to_string Keeper_reaction_ledger.Fusion_completed)
;;

(* (2) THE behavioral guard: a completed fusion becomes a non-empty actionable
   pending_board_event that carries the resolved answer. *)
let test_fusion_completion_is_actionable () =
  let meta = make_meta () in
  let fc = fusion_payload ~resolved_answer:"ANSWER-TOKEN-xyz" ~board_post_id:"post-77" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_fusion_completion
      ~meta
      ~arrived_at:1000.0
      fc
  in
  check string "post_id correlates to the board post" "post-77" ev.post_id;
  check bool "preview carries the resolved answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview);
  (* RFC-0247: a self-authored System_post fusion result renders observationally,
     not as trusted operator instruction. *)
  check
    bool
    "provenance is Self_narrative"
    true
    (match ev.provenance with
     | Keeper_world_observation.Self_narrative -> true
     | _ -> false);
  (* the stimulus path yields Some (not None like Bootstrap/No_progress_recovery) *)
  match
    Keeper_world_observation.pending_board_event_of_stimulus
      ~continuity_summary:""
      ~meta
      (fusion_stimulus ~resolved_answer:"ANSWER-TOKEN-xyz" ())
  with
  | Some (ev : Keeper_world_observation.pending_board_event) ->
    check bool "stimulus path preview carries the answer" true (contains ~needle:"ANSWER-TOKEN-xyz" ev.preview)
  | None -> fail "Fusion_completed stimulus must produce Some pending_board_event, not None"
;;

(* (3) an empty board_post_id (sink failed to create the post) still delivers
   the answer under a synthetic, non-empty post id. *)
let test_missing_board_post_id_fallback () =
  let meta = make_meta () in
  let fc = fusion_payload ~run_id:"fus-9" ~board_post_id:"" () in
  let ev : Keeper_world_observation.pending_board_event =
    Keeper_world_observation.pending_board_event_of_fusion_completion ~meta ~arrived_at:1.0 fc
  in
  check string "synthetic fallback post id" "fusion-run:fus-9" ev.post_id
;;

let () =
  run
    "fusion_wake"
    [ ( "rfc-0266"
      , [ test_case "closed-sum helpers classify Fusion_completed" `Quick test_closed_sum_helpers
        ; test_case
            "fusion completion is actionable (non-empty, carries answer)"
            `Quick
            test_fusion_completion_is_actionable
        ; test_case
            "missing board_post_id falls back to fusion-run id"
            `Quick
            test_missing_board_post_id_fallback
        ] )
    ]
;;
