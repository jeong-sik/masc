(** Golden test pinning judge-route intent in [config/cascade.toml].

    The four judge routes (governance_judge, operator_judge,
    cross_verifier, verifier) must target [tier-group.governance],
    not [tier-group.primary] or any other production lane.

    Regression bar for PR #18695 — a re-introduction of the mis-route
    that caused governance_judge to time out at 45s every refresh cycle
    by routing advisory dashboards through full-size code-gen models.

    Out of scope: capability-driven semantic checking. That is
    RFC-0181 territory and deferred per §9. This test only guards the
    *string equality* of route targets against an architect-pinned
    map. *)

open Alcotest

let cascade_toml_path = "config/cascade.toml"

let expected_judge_routes : (string * string) list =
  [ "governance_judge", "tier-group.governance"
  ; "operator_judge", "tier-group.governance"
  ; "cross_verifier", "tier-group.governance"
  ; "verifier", "tier-group.governance"
  ]

let read_route_target ~route_key (toml : Otoml.t) : string option =
  match Otoml.find_opt toml Fun.id [ "routes"; route_key; "target" ] with
  | Some node ->
    (match Otoml.get_string node with
     | exception Otoml.Type_error _ -> None
     | s -> Some s)
  | None -> None

let test_judge_routes_target_governance_tier_group () =
  let toml = Otoml.Parser.from_file cascade_toml_path in
  List.iter
    (fun (route_key, expected_target) ->
      match read_route_target ~route_key toml with
      | None ->
        Alcotest.failf
          "[routes.%s] missing or has no [target] in %s — judge routes \
           must be present"
          route_key
          cascade_toml_path
      | Some actual ->
        check
          string
          (Printf.sprintf
             "[routes.%s].target must equal %S (PR #18695 regression bar)"
             route_key
             expected_target)
          expected_target
          actual)
    expected_judge_routes

let () =
  Alcotest.run
    "cascade_judge_route_intent_golden"
    [ ( "judge_route_targets"
      , [ test_case
            "all four judge routes target tier-group.governance"
            `Quick
            test_judge_routes_target_governance_tier_group
        ] )
    ]
