(* Cross-domain TLA literal parity.

   These checks pin TLA+ string sets to the OCaml symbol surfaces that
   own the corresponding runtime taxonomy. A constructor or spec literal
   added on only one side should fail here before it becomes operator
   documentation drift. *)

module T = Masc_test_deps

let set relpath symbol =
  T.tla_quoted_set_from_repo_file_exn ~relpath ~symbol

let assert_set ~label ~expected ~actual =
  T.assert_same_string_set ~label ~expected ~actual

let test_multimodal_artifact () =
  assert_set ~label:"MultimodalArtifact.Kinds"
    ~expected:
      (set "specs/multimodal/MultimodalArtifact.tla" "Kinds")
    ~actual:
      (List.map Multimodal.Artifact.kind_tag_to_string
         Multimodal.Artifact.all_kind_tags)

let payload_kind = function
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String kind) -> kind
      | Some _ | None -> failwith "payload JSON missing string kind field")
  | _ -> failwith "payload JSON is not an object"

let test_multimodal_payload () =
  let actual =
    [ Multimodal.Payload.Lazy_payload (fun () -> "lazy");
      Multimodal.Payload.Blob_ref "blob://probe";
      Multimodal.Payload.Streaming 42;
    ]
    |> List.map (fun payload -> payload_kind (Multimodal.Payload.to_json payload))
  in
  assert_set ~label:"MultimodalArtifact.PayloadKinds"
    ~expected:
      (set "specs/multimodal/MultimodalArtifact.tla" "PayloadKinds")
    ~actual

let test_resilience_degradation () =
  assert_set ~label:"ResilienceDegradation.Levels"
    ~expected:(set "specs/resilience/ResilienceDegradation.tla" "Levels")
    ~actual:Resilience.Degradation.all_symbols;
  assert_set ~label:"ResilienceDegradation.TerminalLevels"
    ~expected:[ "L4" ]
    ~actual:Resilience.Degradation.terminal_symbols;
  assert_set ~label:"ResilienceDegradation.ErrorModes"
    ~expected:
      (set "specs/resilience/ResilienceDegradation.tla" "ErrorModes")
    ~actual:Resilience.Recovery.all_error_mode_tla_symbols;
  assert_set ~label:"ResilienceDegradation.Strategies"
    ~expected:
      (set "specs/resilience/ResilienceDegradation.tla" "Strategies")
    ~actual:Resilience.Recovery.all_strategy_tla_symbols

let test_autonomous_phase () =
  assert_set ~label:"AutonomousPhase.Phases"
    ~expected:(set "specs/autonomous/AutonomousPhase.tla" "Phases")
    ~actual:Autonomous.Autonomous_phase.all_symbols;
  assert_set ~label:"AutonomousLoop.AutoPhases"
    ~expected:(set "specs/autonomous/AutonomousLoop.tla" "AutoPhases")
    ~actual:Autonomous.Autonomous_phase.all_symbols

let pairs_to_transition_symbols values =
  let rec loop acc = function
    | from_ :: to_ :: rest -> loop ((from_ ^ "->" ^ to_) :: acc) rest
    | [] -> List.rev acc
    | [ dangling ] ->
        failwith
          (Printf.sprintf
             "LegalTransitions has an odd quoted-string count; dangling %S"
             dangling)
  in
  loop [] values

let test_autonomous_transitions () =
  let expected =
    set "specs/autonomous/AutonomousPhase.tla" "LegalTransitions"
    |> pairs_to_transition_symbols
  in
  assert_set ~label:"AutonomousPhase.LegalTransitions"
    ~expected
    ~actual:Autonomous.Autonomous_phase.Transition.all_symbols

let test_cascade_strategy () =
  assert_set ~label:"CascadeStrategy.StrategyKindSet"
    ~expected:
      (set "specs/boundary/CascadeStrategy.tla" "StrategyKindSet")
    ~actual:Masc_mcp.Cascade_strategy.all_symbols

let test_sandbox_dispatch_profile () =
  assert_set ~label:"SandboxDispatch.ProfileSet"
    ~expected:(set "specs/boundary/SandboxDispatch.tla" "ProfileSet")
    ~actual:Masc_mcp.Keeper_types_profile.Sandbox_profile_tla.all_symbols

let () =
  test_multimodal_artifact ();
  test_multimodal_payload ();
  test_resilience_degradation ();
  test_autonomous_phase ();
  test_autonomous_transitions ();
  test_cascade_strategy ();
  test_sandbox_dispatch_profile ();
  print_endline "test_tla_literal_parity: OK"
