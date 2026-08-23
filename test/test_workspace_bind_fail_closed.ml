(** Regression test for masc_bind fail-closed identity gate (RFC P3-a).

    Prior to RFC P3-a promotion, [handle_join] logged normalize errors and
    proceeded with the original [agent_name] (fail-open).  The fail-closed
    gate rejects join when [Keeper_identity.normalize_all_names] returns [Error].

    This test verifies the gate function at the unit level.  It does NOT call
    [handle_join] directly (which requires a full
    [Mcp_tool_runtime_types.context] with Eio fiber infrastructure).

    The join gate validates the Keeper-owned
    [<base_path>/.masc/config/keepers/<name>.toml] declaration. *)

open Alcotest
open Masc

let () =
  Server_startup_state.mark_state_ready ()
  |> Result.get_ok

let validation_error =
  testable Keeper_identity.pp_validation_error ( = )

let normalize ~input ?base_path ?(check_keeper = true) () =
  Keeper_identity.normalize_all_names
    ~input_agent_name:input
    ?base_path
    ~check_keeper
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

(* Same flags as handle_join uses *)
let join_normalize ~input ?base_path () =
  normalize ~input ?base_path ~check_keeper:true ()

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
  | Error (Keeper_identity.Keeper_not_found _) -> ()
  | Error other ->
      fail
        (Printf.sprintf "invalid chars expected Keeper_not_found, got %s"
           (Keeper_identity.show_validation_error other))

(* --------------------------------------------------------------------- *)
(* Join gate flags verification — documents the handle_join contract       *)
(* --------------------------------------------------------------------- *)

let test_join_gate_uses_keeper_check () =
  with_temp_dir "workspace-bind-keeper" @@ fun base_path ->
  let input = "missing-keeper" in
  begin
    match normalize ~input ~base_path ~check_keeper:false () with
    | Ok _ -> ()
    | Error other ->
        fail
          (Printf.sprintf
             "plain normalize without Keeper check should accept valid name, got %s"
             (Keeper_identity.show_validation_error other))
  end;
  match join_normalize ~input ~base_path () with
  | Error (Keeper_identity.Keeper_not_found { resolved; searched; _ }) ->
      check string "resolved Keeper" input resolved;
      check string "searched Keeper prompt path"
        (Filename.concat
           (Filename.concat base_path ".masc/config/keepers")
           (input ^ ".toml"))
        searched
  | Error other ->
      fail
        (Printf.sprintf "join gate expected Keeper_not_found, got %s"
           (Keeper_identity.show_validation_error other))
  | Ok _ -> fail "join gate must reject missing Keeper prompt with check enabled"

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
          test_case "join gate uses Keeper check" `Quick
            test_join_gate_uses_keeper_check;
        ] );
    ]
