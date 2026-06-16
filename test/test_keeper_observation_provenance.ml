(* test/test_keeper_observation_provenance.ml

   RFC-0247: pins the typed observation-provenance classifier
   [Keeper_world_observation.provenance_of] and the trust tier
   [should_quarantine]. The renderer (keeper_unified_prompt Board_activity arm)
   partitions on this — fleet narrative (Self/Peer/Automation/Unknown) is
   quarantined inside the observational-data envelope, human direction and
   explicit @mentions stay trusted — so the classification is the load-bearing
   contract that closes the board-confabulation root. *)

open Alcotest

module WO = Masc.Keeper_world_observation
module Kid = Masc.Keeper_identity.Keeper_id
module B = Masc.Board

(* Local variant->string so the test compares plain strings (no need to expose
   ppx-derived pp/equal through the mli). Ordering mirrors the type decl. *)
let pstr : WO.observation_provenance -> string = function
  | Self_narrative -> "self"
  | Peer_keeper -> "peer"
  | Human_direct -> "human"
  | Automation -> "automation"
  | Unknown -> "unknown"

(* self_ids holds the "alice" keeper; [Option.get] is safe on the golden
   inputs from test_keeper_identity_id ("alice"/"keeper-alice-agent"). *)
let self_ids =
  [ Option.get (Kid.of_string "alice") ]
;;

let provenance_str ~post_kind ~author =
  pstr (WO.provenance_of ~self_ids post_kind ~author)
;;

let test_self_narrative () =
  (* Own author is Self_narrative regardless of post_kind (a keeper's own prior
     post is the highest confabulation risk). *)
  check string "self author + automation post" "self"
    (provenance_str ~post_kind:B.Automation_post ~author:"keeper-alice-agent");
  check string "self author + system post" "self"
    (provenance_str ~post_kind:B.System_post ~author:"alice");
  check string "self author + human post (drift, still self first)" "self"
    (provenance_str ~post_kind:B.Human_post ~author:"keeper-alice-agent")
;;

let test_peer_keeper () =
  (* Another keeper (typed keeper identity, not self) posting as automation. *)
  check string "peer keeper + automation post" "peer"
    (provenance_str ~post_kind:B.Automation_post ~author:"keeper-ramarama-agent");
  check string "peer keeper + system post" "peer"
    (provenance_str ~post_kind:B.System_post ~author:"keeper-ramarama-agent")
;;

let test_human_direct () =
  (* A human author (not a typed keeper identity) with Human_post stays trusted. *)
  check string "human author + human post" "human"
    (provenance_str ~post_kind:B.Human_post ~author:"vincent")
;;

let test_automation () =
  (* Non-keeper automation author (harness/qa/probe) with automation post. *)
  check string "automation author + automation post" "automation"
    (provenance_str ~post_kind:B.Automation_post ~author:"harness")
;;

let test_unknown_drift () =
  (* Classification drift: a Human_post whose author is nevertheless a typed
     keeper identity. Quarantined as Unknown rather than trusted as human. *)
  check string "keeper author + human post = drift -> Unknown" "unknown"
    (provenance_str ~post_kind:B.Human_post ~author:"keeper-ramarama-agent")
;;

let test_should_quarantine () =
  (* Unknown defaults to quarantine (defense-in-depth: unclassifiable = untrusted
     fleet output, never trusted direction). *)
  check bool "Self_narrative quarantined" true (WO.should_quarantine Self_narrative);
  check bool "Peer_keeper quarantined" true (WO.should_quarantine Peer_keeper);
  check bool "Automation quarantined" true (WO.should_quarantine Automation);
  check bool "Unknown quarantined" true (WO.should_quarantine Unknown);
  check bool "Human_direct NOT quarantined" false (WO.should_quarantine Human_direct)
;;

let () =
  Alcotest.run "keeper_observation_provenance"
    [
      ( "provenance_of",
        [
          ("self narrative", `Quick, test_self_narrative);
          ("peer keeper", `Quick, test_peer_keeper);
          ("human direct", `Quick, test_human_direct);
          ("automation", `Quick, test_automation);
          ("unknown drift", `Quick, test_unknown_drift);
        ] );
      ( "should_quarantine",
        [ ("trust tier", `Quick, test_should_quarantine) ] );
    ]
;;
