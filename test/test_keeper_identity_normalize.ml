(** Tests for [Keeper_identity.normalize_all_names] — RFC P1.

    Covers the input-shape × field matrix and round-trip stability across
    wrappers. *)

open Alcotest
open Masc

let () =
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok

let bundle =
  testable
    (fun fmt (b : Keeper_identity.name_bundle) ->
      Format.fprintf fmt
        "{ keeper_name=%S; agent_name=%S }"
        b.keeper_name b.agent_name)
    ( = )

let validation_error =
  testable Keeper_identity.pp_validation_error ( = )

let normalize input =
  Keeper_identity.normalize_all_names ~input_agent_name:input ()

let ok_or_fail label = function
  | Ok b -> b
  | Error e ->
      fail
        (Printf.sprintf "%s: expected Ok, got %s" label
           (Keeper_identity.show_validation_error e))

(* --------------------------------------------------------------------- *)
(* Input shape matrix                                                      *)
(* --------------------------------------------------------------------- *)

let check_bundle ~label ~input ~keeper ~agent =
  let b = ok_or_fail label (normalize input) in
  check string (label ^ ": keeper_name") keeper b.keeper_name;
  check string (label ^ ": agent_name") agent b.agent_name

let test_bare_canonical () =
  check_bundle ~label:"bare canonical" ~input:"alpha"
    ~keeper:"alpha" ~agent:"alpha"

let test_keeper_dash_agent_wrapper () =
  check_bundle ~label:"keeper-X-agent wrapper" ~input:"keeper-alpha-agent"
    ~keeper:"alpha" ~agent:"keeper-alpha-agent"

let test_keeper_underscore_agent_wrapper () =
  check_bundle ~label:"keeper_X_agent wrapper" ~input:"keeper_alpha_agent"
    ~keeper:"alpha" ~agent:"keeper_alpha_agent"

let test_ephemeral_suffix_only () =
  check_bundle ~label:"ephemeral suffix" ~input:"kappa_keeper-pale-llama"
    ~keeper:"kappa_keeper"
    ~agent:"kappa_keeper-pale-llama"

let test_wrapper_plus_ephemeral () =
  check_bundle ~label:"wrapper + suffix"
    ~input:"keeper-omega-warm-raven-agent"
    ~keeper:"omega" ~agent:"keeper-omega-warm-raven-agent"

let test_empty_input () =
  match normalize "" with
  | Ok _ -> fail "empty input should be Error"
  | Error e ->
      check validation_error "empty input maps to Empty_input"
        Keeper_identity.Empty_input e

let test_whitespace_only_input () =
  match normalize "   " with
  | Ok _ -> fail "whitespace input should be Error"
  | Error e ->
      check validation_error "whitespace input maps to Empty_input"
        Keeper_identity.Empty_input e

let test_invalid_chars_keeper_not_found () =
  match normalize "bad@name" with
  | Ok _ -> fail "invalid chars should be Error"
  | Error (Keeper_identity.Keeper_not_found _) -> ()
  | Error other ->
      fail
        (Printf.sprintf
           "invalid chars expected Keeper_not_found, got %s"
           (Keeper_identity.show_validation_error other))

(* --------------------------------------------------------------------- *)
(* Round-trip invariant: wrapping/unwrapping preserves bundle identity   *)
(* --------------------------------------------------------------------- *)

let wrappers name =
  [
    name;
    "keeper-" ^ name ^ "-agent";
    "keeper_" ^ name ^ "_agent";
    "keeper-" ^ name ^ "_agent";
    "keeper_" ^ name ^ "-agent";
  ]

let test_round_trip_for_name name () =
  let canonical_bundle = ok_or_fail ("round-trip " ^ name) (normalize name) in
  List.iter
    (fun shape ->
      let b =
        ok_or_fail ("round-trip shape " ^ shape) (normalize shape)
      in
      check string ("round-trip keeper_name for " ^ shape)
        canonical_bundle.keeper_name b.keeper_name;
      check string ("round-trip agent_name for " ^ shape) shape b.agent_name)
    (wrappers name)

(* --------------------------------------------------------------------- *)
(* Test runner                                                            *)
(* --------------------------------------------------------------------- *)

let () =
  run "keeper_identity_normalize"
    [
      ( "input_shape_matrix",
        [
          test_case "bare canonical" `Quick test_bare_canonical;
          test_case "keeper-X-agent wrapper" `Quick
            test_keeper_dash_agent_wrapper;
          test_case "keeper_X_agent wrapper" `Quick
            test_keeper_underscore_agent_wrapper;
          test_case "ephemeral suffix only" `Quick test_ephemeral_suffix_only;
          test_case "wrapper + ephemeral" `Quick test_wrapper_plus_ephemeral;
          test_case "empty input" `Quick test_empty_input;
          test_case "whitespace input" `Quick test_whitespace_only_input;
          test_case "invalid chars" `Quick
            test_invalid_chars_keeper_not_found;
        ] );
      ( "round_trip",
        [
          test_case "round-trip alpha" `Quick (test_round_trip_for_name "alpha");
          test_case "round-trip executor" `Quick
            (test_round_trip_for_name "omega");
          test_case "round-trip mu-king" `Quick
            (test_round_trip_for_name "mu-king");
          test_case "round-trip omicron-improver" `Quick
            (test_round_trip_for_name "omicron-improver");
        ] );
    ]
