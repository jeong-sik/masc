open Masc
module Step = Keeper_cleanup_step
module Status = Keeper_cleanup_status

let step =
  Alcotest.testable
    (fun ppf candidate -> Format.pp_print_string ppf (Step.to_string candidate))
    Step.equal
;;

let test_step_follows_profile_and_backend () =
  let module P = Keeper_types_profile in
  let module B = Keeper_microvm_backend in
  List.iter
    (fun (label, sandbox_profile, microvm_backend, expected) ->
      Alcotest.(check (list step))
        label
        expected
        (List.filter
           (fun candidate -> Step.applies_to candidate ~sandbox_profile ~microvm_backend)
           Step.all))
    [ "microvm on Apple Container", P.Micro_vm, Some B.Apple_container, [ Step.Guest_builds ]
    ; "microvm on microsandbox", P.Micro_vm, Some B.Microsandbox, []
    ; "microvm on nerdctl kata", P.Micro_vm, Some B.Nerdctl_kata, []
    ; "microvm with no backend", P.Micro_vm, None, []
    ; "docker", P.Docker, None, []
    ; "docker with a leftover backend", P.Docker, Some B.Apple_container, []
    ; "remote_ssh", P.Remote_ssh, None, [ Step.Remote_workspace ]
    ; ( "remote_ssh with a leftover backend"
      , P.Remote_ssh
      , Some B.Apple_container
      , [ Step.Remote_workspace ] )
    ]
;;

let test_wire_names_round_trip () =
  List.iter
    (fun candidate ->
      Alcotest.(check (option step))
        (Step.to_string candidate)
        (Some candidate)
        (Step.of_string (Step.to_string candidate)))
    Step.all;
  Alcotest.(check (option step)) "a name outside the list" None (Step.of_string "no-such-step")
;;

let builds cleaned failed = Status.Guest_builds (Status.Reclaimed { Status.cleaned; failed })

let workspace =
  Status.Remote_workspace
    (Status.Reclaimed
       { Status.removed = 3; skipped = 4; failed = 0; freed_kib = -5; available_kib = 600 })
;;

let row (t : Status.t) ~keeper wanted =
  List.find_opt
    (fun (candidate : Status.row) ->
      String.equal candidate.keeper keeper && Step.equal (Status.step candidate.attempt) wanted)
    t.rows
;;

let time = Alcotest.(option (float 0.))

let test_latest_attempt_replaces_the_row_and_keeps_the_last_success () =
  let busy = Status.Guest_builds (Status.Deferred "turn busy") in
  let t =
    Status.empty
    |> Status.record_attempt ~keeper:"polisher" ~finished_at:10. (builds 2 1)
    |> Status.record_attempt ~keeper:"polisher" ~finished_at:20. busy
    |> Status.record_attempt ~keeper:"reviewer" ~finished_at:21. workspace
    |> Status.record_attempt
         ~keeper:"fresh"
         ~finished_at:22.
         (Status.Guest_builds (Status.Failed "exit=1"))
  in
  Alcotest.(check int) "one row per Keeper and step" 3 (List.length t.rows);
  (match row t ~keeper:"polisher" Step.Guest_builds with
   | None -> Alcotest.fail "polisher row missing"
   | Some (found : Status.row) ->
     Alcotest.(check bool) "the latest attempt is the row" true (found.attempt = busy);
     Alcotest.(check (float 0.)) "with its own time" 20. found.finished_at;
     Alcotest.check time "beside the last run to the end" (Some 10.) found.reclaimed_at);
  (match row t ~keeper:"reviewer" Step.Remote_workspace with
   | None -> Alcotest.fail "reviewer row missing"
   | Some (found : Status.row) ->
     Alcotest.check time "a run to the end is its own last success" (Some 21.) found.reclaimed_at);
  match row t ~keeper:"fresh" Step.Guest_builds with
  | None -> Alcotest.fail "fresh row missing"
  | Some (found : Status.row) ->
    Alcotest.check time "a step that never ran to the end has none" None found.reclaimed_at
;;

(* One Owner of every kind a pass can meet, and two unreadable ones so their
   order shows. *)
let owners =
  [ Status.Unnamed
  ; Status.Named ("no-meta", Status.Excluded Status.Without_meta)
  ; Status.Named ("broken-a", Status.Excluded (Status.Unreadable "toml: line 3"))
  ; Status.Named ("docker", Status.Excluded Status.No_step)
  ; Status.Named ("off", Status.Excluded Status.Switched_off)
  ; Status.Named ("guest", Status.Scheduled [ Step.Guest_builds ])
  ; Status.Named ("remote", Status.Scheduled [ Step.Remote_workspace ])
  ; Status.Named ("slow", Status.Still_running [ Step.Remote_workspace ])
  ; Status.Named ("broken-b", Status.Excluded (Status.Unreadable "identity mismatch"))
  ]
;;

let conclude ~enabled owners =
  Status.conclude_pass ~started_at:30. ~interval_sec:3600. ~enabled owners
;;

let every _ = true

let switches (pass : Status.pass) =
  List.map
    (fun ({ step; enabled; selected } : Status.step_pass) -> step, enabled, selected)
    pass.steps
;;

let accounted (pass : Status.pass) =
  pass.without_meta
  + List.length pass.unreadable
  + pass.no_step
  + pass.switched_off
  + pass.scheduled
  + List.length pass.still_running
;;

let test_pass_counts_every_owner_once () =
  let pass, _ = conclude ~enabled:every owners in
  Alcotest.(check int) "Owners looked at" 9 pass.owners;
  Alcotest.(check int) "the unnamed Owner and the one with no stored meta" 2 pass.without_meta;
  Alcotest.(check (list (pair string string)))
    "unreadable Keepers keep their reasons, in the order met"
    [ "broken-a", "toml: line 3"; "broken-b", "identity mismatch" ]
    (List.map (fun ({ keeper; reason } : Status.unreadable) -> keeper, reason) pass.unreadable);
  Alcotest.(check int) "no step" 1 pass.no_step;
  Alcotest.(check int) "switched off" 1 pass.switched_off;
  Alcotest.(check int) "scheduled" 2 pass.scheduled;
  Alcotest.(check (list string)) "still running" [ "slow" ] pass.still_running;
  Alcotest.(check int) "every Owner is in exactly one count" pass.owners (accounted pass);
  Alcotest.(check (list (triple step bool int)))
    "each step: its switch and the Keepers it was chosen for"
    [ Step.Guest_builds, true, 1; Step.Remote_workspace, true, 2 ]
    (switches pass);
  let nobody, _ = conclude ~enabled:every [] in
  Alcotest.(check (pair int int)) "a pass over no Owner" (0, 0) (nobody.owners, accounted nobody)
;;

let test_pass_reports_each_switch () =
  let pass, _ =
    conclude
      ~enabled:(Step.equal Step.Guest_builds)
      [ Status.Named ("off", Status.Excluded Status.Switched_off) ]
  in
  Alcotest.(check (list (triple step bool int)))
    "a switched-off step stays in the summary"
    [ Step.Guest_builds, true, 0; Step.Remote_workspace, false, 0 ]
    (switches pass)
;;

let test_pass_keeps_only_the_rows_it_chose () =
  let before =
    Status.empty
    |> Status.record_attempt ~keeper:"guest" ~finished_at:10. (builds 0 0)
    |> Status.record_attempt ~keeper:"slow" ~finished_at:11. workspace
       (* This pass chose another step for [remote]. *)
    |> Status.record_attempt ~keeper:"remote" ~finished_at:12. (builds 1 0)
       (* The pass did not meet [left]. *)
    |> Status.record_attempt ~keeper:"left" ~finished_at:13. workspace
    |> Status.record_attempt ~keeper:"off" ~finished_at:14. workspace
  in
  let pass, record = conclude ~enabled:every owners in
  let after = record before in
  Alcotest.(check bool) "the pass is recorded" true (after.pass = Some pass);
  Alcotest.(check (list (pair string step)))
    "only a Keeper and step the pass chose keeps its row"
    [ "guest", Step.Guest_builds; "slow", Step.Remote_workspace ]
    (List.sort
       compare
       (List.map (fun (found : Status.row) -> found.keeper, Status.step found.attempt) after.rows))
;;

let json = Alcotest.testable (Yojson.Safe.pretty_print ~std:true) Yojson.Safe.equal

let test_envelope_json () =
  Alcotest.check
    json
    "before the first pass"
    (Yojson.Safe.from_string {|{"pass":null,"rows":[]}|})
    (Status.to_json Status.empty);
  let pass, _ = conclude ~enabled:every owners in
  let value =
    { Status.pass = Some pass
    ; rows =
        [ { Status.keeper = "a"; attempt = builds 2 1; finished_at = 10.5; reclaimed_at = Some 10.5 }
        ; { Status.keeper = "b"
          ; attempt = Status.Guest_builds (Status.Deferred "turn busy")
          ; finished_at = 11.
          ; reclaimed_at = Some 3.
          }
        ; { Status.keeper = "c"
          ; attempt = Status.Guest_builds Status.Not_running
          ; finished_at = 12.
          ; reclaimed_at = None
          }
        ; { Status.keeper = "d"; attempt = workspace; finished_at = 14.; reclaimed_at = Some 14. }
        ; { Status.keeper = "e"
          ; attempt = Status.Remote_workspace (Status.Failed "exit=1: traceback")
          ; finished_at = 15.
          ; reclaimed_at = None
          }
        ]
    }
  in
  Alcotest.check
    json
    "a pass and every outcome"
    (Yojson.Safe.from_string
       {|{
  "pass": {
    "started_at": 30.0,
    "interval_sec": 3600.0,
    "owners": 9,
    "without_meta": 2,
    "unreadable": [
      { "keeper": "broken-a", "reason": "toml: line 3" },
      { "keeper": "broken-b", "reason": "identity mismatch" }
    ],
    "no_step": 1,
    "switched_off": 1,
    "scheduled": 2,
    "still_running": [ "slow" ],
    "steps": [
      { "step": "guest_builds", "enabled": true, "selected": 1 },
      { "step": "remote_workspace", "enabled": true, "selected": 2 }
    ]
  },
  "rows": [
    { "keeper": "a", "step": "guest_builds", "finished_at": 10.5, "reclaimed_at": 10.5,
      "outcome": "reclaimed", "report": { "cleaned": 2, "failed": 1 } },
    { "keeper": "b", "step": "guest_builds", "finished_at": 11.0, "reclaimed_at": 3.0,
      "outcome": "deferred", "reason": "turn busy" },
    { "keeper": "c", "step": "guest_builds", "finished_at": 12.0, "reclaimed_at": null,
      "outcome": "not_running" },
    { "keeper": "d", "step": "remote_workspace", "finished_at": 14.0, "reclaimed_at": 14.0,
      "outcome": "reclaimed",
      "report": { "removed": 3, "skipped": 4, "failed": 0, "freed_kib": -5, "available_kib": 600 } },
    { "keeper": "e", "step": "remote_workspace", "finished_at": 15.0, "reclaimed_at": null,
      "outcome": "failed", "reason": "exit=1: traceback" }
  ]
}|})
    (Status.to_json value)
;;

let () =
  Alcotest.run
    "Keeper cleanup steps and results"
    [ ( "steps"
      , [ Alcotest.test_case
            "A step follows the declared profile and backend"
            `Quick
            test_step_follows_profile_and_backend
        ; Alcotest.test_case "Wire names round trip" `Quick test_wire_names_round_trip
        ] )
    ; ( "results"
      , [ Alcotest.test_case
            "The latest attempt replaces the row and keeps the last success"
            `Quick
            test_latest_attempt_replaces_the_row_and_keeps_the_last_success
        ; Alcotest.test_case
            "A pass counts every Owner once"
            `Quick
            test_pass_counts_every_owner_once
        ; Alcotest.test_case "A pass reports each switch" `Quick test_pass_reports_each_switch
        ; Alcotest.test_case
            "A pass keeps only the rows it chose"
            `Quick
            test_pass_keeps_only_the_rows_it_chose
        ] )
    ; "json", [ Alcotest.test_case "The envelope field" `Quick test_envelope_json ]
    ]
;;
