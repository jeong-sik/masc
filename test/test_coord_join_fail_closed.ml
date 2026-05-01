(** Regression test for masc_join fail-closed identity gate (RFC P3-a).

    Prior to RFC P3-a promotion, [handle_join] logged normalize errors and
    proceeded with the original [agent_name] (fail-open).  The fail-closed
    gate rejects join when [Keeper_identity.normalize_all_names] returns [Error].

    This test verifies the gate function at the unit level.  It does NOT call
    [handle_join] directly (which requires a full
    [Tool_inline_dispatch_types.context] with Eio fiber infrastructure).

    Note on persona path resolution: [normalize_all_names] uses
    [Config_dir_resolver.personas_dir_opt()] first, which returns the global
    config dir and ignores [base_path].  Credential checks DO use [base_path]
    directly via [Common.agents_dir_from_base_path].  Therefore:
    - Identity-level rejection tests (empty/whitespace/invalid chars) need no
      filesystem setup — they fail before filesystem checks.
    - Credential-only tests use [~check_persona:false] with temp dirs, since
      credential resolution respects [base_path].
    - Full-gate tests would require a known persona in the global config dir,
      which is machine-dependent and excluded from CI. *)

open Alcotest
open Masc_mcp

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let validation_error =
  testable Keeper_identity.pp_validation_error ( = )

let normalize ~input ?base_path ?(check_persona = true) ?(check_credential = true) () =
  Keeper_identity.normalize_all_names
    ~input_agent_name:input
    ?base_path
    ~check_persona
    ~check_credential
    ()

(* Same flags as handle_join uses *)
let join_normalize ~input ?base_path () =
  normalize ~input ?base_path ~check_persona:true ~check_credential:true ()

let credential_only_normalize ~input ?base_path () =
  normalize ~input ?base_path ~check_persona:false ~check_credential:true ()

(* --------------------------------------------------------------------- *)
(* Identity-level rejections (canonical_keeper_name returns None)         *)
(* --------------------------------------------------------------------- *)

let test_empty_rejected () =
  match join_normalize ~input:"" () with
  | Ok _ -> fail "empty input should be rejected by join gate"
  | Error e ->
      check validation_error "empty -> Empty_input"
        Keeper_identity.Empty_input e

let test_whitespace_rejected () =
  match join_normalize ~input:"   " () with
  | Ok _ -> fail "whitespace input should be rejected by join gate"
  | Error e ->
      check validation_error "whitespace -> Empty_input"
        Keeper_identity.Empty_input e

let test_invalid_chars_rejected () =
  match join_normalize ~input:"bad@name!#%" () with
  | Ok _ -> fail "invalid chars should be rejected by join gate"
  | Error (Keeper_identity.Persona_not_found _) -> ()
  | Error other ->
      fail
        (Printf.sprintf "invalid chars expected Persona_not_found, got %s"
           (Keeper_identity.show_validation_error other))

(* --------------------------------------------------------------------- *)
(* Helpers for temp-dir based credential tests                            *)
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
  let tmp_dir = Filename.temp_file "masc_join_gate" "" in
  Sys.remove tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf tmp_dir)
    (fun () -> f tmp_dir)

let credential_path base name =
  Filename.concat
    (Filename.concat
       (Filename.concat base ".masc")
       (Filename.concat "auth" "agents"))
    (name ^ ".json")

let write_json path =
  mkdir_p (Filename.dirname path);
  let ch = open_out path in
  output_string ch "{}";
  close_out ch

(* --------------------------------------------------------------------- *)
(* Credential gate (check_persona:false — uses base_path directly)        *)
(* --------------------------------------------------------------------- *)

let test_credential_missing_rejected () =
  with_tmp_base (fun base ->
      match credential_only_normalize ~input:"testagent" ~base_path:base () with
      | Ok _ -> fail "missing credential should be rejected"
      | Error (Keeper_identity.Credential_missing _) -> ()
      | Error other ->
          fail
            (Printf.sprintf
               "missing credential expected Credential_missing, got %s"
               (Keeper_identity.show_validation_error other)))

let test_credential_present_accepted () =
  with_tmp_base (fun base ->
      write_json (credential_path base "testagent");
      match credential_only_normalize ~input:"testagent" ~base_path:base () with
      | Ok bundle ->
          check string "keeper_name" "testagent" bundle.keeper_name;
          check string "credential_stem" "testagent" bundle.credential_stem
      | Error e ->
          fail
            (Printf.sprintf
               "valid agent with credential should pass, got %s"
               (Keeper_identity.show_validation_error e)))

let test_wrapper_form_resolves_credential () =
  with_tmp_base (fun base ->
      write_json (credential_path base "alice");
      match credential_only_normalize ~input:"keeper-alice-agent" ~base_path:base () with
      | Ok bundle ->
          check string "resolved keeper_name" "alice" bundle.keeper_name;
          check string "credential_stem" "alice" bundle.credential_stem
      | Error e ->
          fail
            (Printf.sprintf
               "wrapper form should resolve, got %s"
               (Keeper_identity.show_validation_error e)))

(* --------------------------------------------------------------------- *)
(* Join gate flags verification — documents the handle_join contract       *)
(* --------------------------------------------------------------------- *)

let test_join_gate_uses_both_checks () =
  (* This is a documentation test: handle_join calls normalize with
     ~check_persona:true ~check_credential:true.  The join_normalize
     wrapper mirrors this exactly.  Empty input must fail. *)
  match join_normalize ~input:"" () with
  | Error _ -> ()
  | Ok _ -> fail "join gate must reject empty input with both checks enabled"

(* --------------------------------------------------------------------- *)
(* Test runner                                                            *)
(* --------------------------------------------------------------------- *)

let () =
  run "coord_join_fail_closed"
    [
      ( "identity_rejection",
        [
          test_case "empty input rejected" `Quick test_empty_rejected;
          test_case "whitespace input rejected" `Quick test_whitespace_rejected;
          test_case "invalid chars rejected" `Quick test_invalid_chars_rejected;
        ] );
      ( "credential_gate",
        [
          test_case "missing credential rejected" `Quick
            test_credential_missing_rejected;
          test_case "credential present accepted" `Quick
            test_credential_present_accepted;
          test_case "wrapper form resolves" `Quick
            test_wrapper_form_resolves_credential;
        ] );
      ( "join_gate_contract",
        [
          test_case "join gate uses both checks" `Quick
            test_join_gate_uses_both_checks;
        ] );
    ]
