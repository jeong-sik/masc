(** Tests for [Keeper_identity.normalize_all_names] — RFC P1.

    Covers the input-shape × field matrix, round-trip stability across
    wrappers, and filesystem checks gated by [?check_credential]. *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let bundle =
  testable
    (fun fmt (b : Keeper_identity.name_bundle) ->
      Format.fprintf fmt
        "{ persona_name=%S; keeper_name=%S; agent_name=%S; credential_stem=%S }"
        b.persona_name b.keeper_name b.agent_name b.credential_stem)
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
(* 6 input shapes × 4 field matrix                                        *)
(* --------------------------------------------------------------------- *)

let check_bundle ~label ~input ~persona ~keeper ~agent ~credential =
  let b = ok_or_fail label (normalize input) in
  check string (label ^ ": persona_name") persona b.persona_name;
  check string (label ^ ": keeper_name") keeper b.keeper_name;
  check string (label ^ ": agent_name") agent b.agent_name;
  check string (label ^ ": credential_stem") credential b.credential_stem

let test_bare_canonical () =
  check_bundle ~label:"bare canonical" ~input:"sangsu" ~persona:"sangsu"
    ~keeper:"sangsu" ~agent:"sangsu" ~credential:"sangsu"

let test_keeper_dash_agent_wrapper () =
  check_bundle ~label:"keeper-X-agent wrapper" ~input:"keeper-sangsu-agent"
    ~persona:"sangsu" ~keeper:"sangsu" ~agent:"keeper-sangsu-agent"
    ~credential:"sangsu"

let test_keeper_underscore_agent_wrapper () =
  check_bundle ~label:"keeper_X_agent wrapper" ~input:"keeper_sangsu_agent"
    ~persona:"sangsu" ~keeper:"sangsu" ~agent:"keeper_sangsu_agent"
    ~credential:"sangsu"

let test_ephemeral_suffix_only () =
  check_bundle ~label:"ephemeral suffix" ~input:"issue_king-pale-llama"
    ~persona:"issue_king" ~keeper:"issue_king"
    ~agent:"issue_king-pale-llama" ~credential:"issue_king"

let test_wrapper_plus_ephemeral () =
  check_bundle ~label:"wrapper + suffix"
    ~input:"keeper-executor-warm-raven-agent" ~persona:"executor"
    ~keeper:"executor" ~agent:"keeper-executor-warm-raven-agent"
    ~credential:"executor"

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

let test_invalid_chars_persona_not_found () =
  match normalize "bad@name" with
  | Ok _ -> fail "invalid chars should be Error"
  | Error (Keeper_identity.Persona_not_found _) -> ()
  | Error other ->
      fail
        (Printf.sprintf
           "invalid chars expected Persona_not_found, got %s"
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
      check string ("round-trip persona_name for " ^ shape)
        canonical_bundle.persona_name b.persona_name;
      check string ("round-trip keeper_name for " ^ shape)
        canonical_bundle.keeper_name b.keeper_name;
      check string ("round-trip credential_stem for " ^ shape)
        canonical_bundle.credential_stem b.credential_stem)
    (wrappers name)

(* --------------------------------------------------------------------- *)
(* Fixture-based credential check (?check_credential:true)                *)
(* --------------------------------------------------------------------- *)

let mkdir_p path =
  let rec ensure p =
    if p = "" || p = "/" || Sys.file_exists p then ()
    else (
      ensure (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  ensure path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter
        (fun entry -> rm_rf (Filename.concat path entry))
        (Sys.readdir path);
      try Unix.rmdir path with Unix.Unix_error _ -> ())
    else try Sys.remove path with Sys_error _ -> ()

let with_tmp_base f =
  let tmp_dir = Filename.temp_file "masc_id_p1" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf tmp_dir)
    (fun () -> f tmp_dir)

let credential_path base stem =
  Filename.concat base
    (Filename.concat ".masc" (Filename.concat "auth" (Filename.concat "agents" (stem ^ ".json"))))

let test_check_credential_present () =
  with_tmp_base (fun base ->
      let path = credential_path base "sangsu" in
      mkdir_p (Filename.dirname path);
      let ch = open_out path in
      output_string ch "{}";
      close_out ch;
      match
        Keeper_identity.normalize_all_names ~input_agent_name:"sangsu"
          ~base_path:base ~check_credential:true ()
      with
      | Ok b -> check string "credential_stem" "sangsu" b.credential_stem
      | Error e ->
          fail
            (Printf.sprintf "expected Ok with credential present, got %s"
               (Keeper_identity.show_validation_error e)))

let test_check_credential_missing () =
  with_tmp_base (fun base ->
      let expected_path = credential_path base "sangsu" in
      match
        Keeper_identity.normalize_all_names ~input_agent_name:"sangsu"
          ~base_path:base ~check_credential:true ()
      with
      | Ok _ -> fail "expected Credential_missing when file absent"
      | Error
          (Keeper_identity.Credential_missing { searched; resolved; input }) ->
          check string "searched path" expected_path searched;
          check string "resolved" "sangsu" resolved;
          check string "input" "sangsu" input
      | Error other ->
          fail
            (Printf.sprintf "expected Credential_missing, got %s"
               (Keeper_identity.show_validation_error other)))

let test_check_credential_wrapper_input () =
  (* Caller passes wrapper form; credential file under canonical stem. *)
  with_tmp_base (fun base ->
      let path = credential_path base "sangsu" in
      mkdir_p (Filename.dirname path);
      let ch = open_out path in
      output_string ch "{}";
      close_out ch;
      match
        Keeper_identity.normalize_all_names
          ~input_agent_name:"keeper-sangsu-agent" ~base_path:base
          ~check_credential:true ()
      with
      | Ok b ->
          check string "credential resolves to canonical stem" "sangsu"
            b.credential_stem;
          check string "agent_name preserved" "keeper-sangsu-agent" b.agent_name
      | Error e ->
          fail
            (Printf.sprintf
               "wrapper input with present credential should Ok, got %s"
               (Keeper_identity.show_validation_error e)))

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
            test_invalid_chars_persona_not_found;
        ] );
      ( "round_trip",
        [
          test_case "round-trip sangsu" `Quick (test_round_trip_for_name "sangsu");
          test_case "round-trip executor" `Quick
            (test_round_trip_for_name "executor");
          test_case "round-trip qa-king" `Quick
            (test_round_trip_for_name "qa-king");
          test_case "round-trip masc-improver" `Quick
            (test_round_trip_for_name "masc-improver");
        ] );
      ( "credential_check",
        [
          test_case "credential present" `Quick test_check_credential_present;
          test_case "credential missing" `Quick test_check_credential_missing;
          test_case "wrapper input → canonical stem" `Quick
            test_check_credential_wrapper_input;
        ] );
    ]
