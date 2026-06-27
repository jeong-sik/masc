(** Regression test for masc_bind fail-closed identity gate (RFC P3-a).

    Prior to RFC P3-a promotion, [handle_join] logged normalize errors and
    proceeded with the original [agent_name] (fail-open).  The fail-closed
    gate rejects join when [Keeper_identity.normalize_all_names] returns [Error].

    This test verifies the gate function at the unit level.  It does NOT call
    [handle_join] directly (which requires a full
    [Mcp_tool_runtime_types.context] with Eio fiber infrastructure).

    Note on persona path resolution: [normalize_all_names] uses
    [Config_dir_resolver.personas_dir_opt()] first, then falls back to
    [base_path]/.masc/personas.  The join-gate contract test clears the global
    persona override and passes an explicit temporary [base_path], so path
    expectations stay deterministic in CI. *)

open Alcotest
open Masc

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let validation_error =
  testable Keeper_identity.pp_validation_error ( = )

let normalize ~input ?base_path ?(check_persona = true) () =
  Keeper_identity.normalize_all_names
    ~input_agent_name:input
    ?base_path
    ~check_persona
    ()

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None ->
      (* This OCaml Unix module does not expose [unsetenv]. Config_dir_resolver
         normalizes empty env values to [None], so this restores the effective
         resolver state for these tests. *)
      Unix.putenv name ""

let with_empty_persona_base_path f =
  with_temp_dir "workspace-bind-base" @@ fun base_path ->
  let original = Sys.getenv_opt "MASC_PERSONAS_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_PERSONAS_DIR" original;
      Config_dir_resolver.reset ())
    (fun () ->
      Unix.putenv "MASC_PERSONAS_DIR" "";
      Config_dir_resolver.reset ();
      f base_path)

(* Same flags as handle_join uses *)
let join_normalize ~input ?base_path () =
  normalize ~input ?base_path ~check_persona:true ()

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
(* Join gate flags verification — documents the handle_join contract       *)
(* --------------------------------------------------------------------- *)

let test_join_gate_uses_persona_check () =
  with_empty_persona_base_path @@ fun base_path ->
  let input = "missing-persona" in
  begin
    match normalize ~input ~base_path ~check_persona:false () with
    | Ok _ -> ()
    | Error other ->
        fail
          (Printf.sprintf
             "plain normalize without persona check should accept valid name, got %s"
             (Keeper_identity.show_validation_error other))
  end;
  match join_normalize ~input ~base_path () with
  | Error (Keeper_identity.Persona_not_found { resolved; searched; _ }) ->
      check string "resolved persona" input resolved;
      check string "searched persona path"
        (Filename.concat
           (Filename.concat (Common.masc_dir_from_base_path ~base_path) "personas")
           input)
        searched
  | Error other ->
      fail
        (Printf.sprintf "join gate expected Persona_not_found, got %s"
           (Keeper_identity.show_validation_error other))
  | Ok _ -> fail "join gate must reject missing persona with check enabled"

(* --------------------------------------------------------------------- *)
(* Test runner                                                            *)
(* --------------------------------------------------------------------- *)

let () =
  run "workspace_bind_fail_closed"
    [
      ( "identity_rejection",
        [
          test_case "empty input rejected" `Quick test_empty_rejected;
          test_case "whitespace input rejected" `Quick test_whitespace_rejected;
          test_case "invalid chars rejected" `Quick test_invalid_chars_rejected;
        ] );
      ( "join_gate_contract",
        [
          test_case "join gate uses persona check" `Quick
            test_join_gate_uses_persona_check;
        ] );
    ]
