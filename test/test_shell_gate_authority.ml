(** RFC-0131 PR-5 — tests for the per-caller authority knob and the
    parallel facade call wiring in
    [Worker_dev_tools.validate_command_coding_with_allowlist].

    Each test resets [MASC_SHELL_GATE_AUTHORITY] before and after; tests
    that need a populated value [Unix.putenv] it directly so the
    fixture stays self-contained.  The function itself does no
    in-process caching — every call rereads the env var — so a
    [putenv] inside the test body is sufficient. *)

module Authority = Masc_mcp.Shell_gate_authority
module Worker = Masc_mcp.Worker_dev_tools
module Gate = Masc_mcp.Shell_command_gate

let env_var = "MASC_SHELL_GATE_AUTHORITY"
let unset_env () = Unix.putenv env_var ""
let set_env value = Unix.putenv env_var value

let with_env value f =
  set_env value;
  Fun.protect ~finally:unset_env f
;;

(* Three-caller cartesian helper.  Lists every caller variant so a new
   one added to [Shell_command_gate.caller] forces an update here at
   compile time via the exhaustive [match] below. *)
let all_callers : Gate.caller list =
  [ Gate.Worker_dev_tools; Gate.Tool_code_write; Gate.Keeper_shell_bash ]
;;

let caller_label : Gate.caller -> string = function
  | Worker_dev_tools -> "worker_dev_tools"
  | Tool_code_write -> "tool_code_write"
  | Keeper_shell_bash -> "keeper_shell_bash"
;;

let test_unset_disables_every_caller () =
  unset_env ();
  List.iter
    (fun c ->
      Alcotest.(check bool)
        (Printf.sprintf "caller %s disabled when env unset" (caller_label c))
        false
        (Authority.authority_enabled c))
    all_callers
;;

let test_empty_disables_every_caller () =
  with_env "" (fun () ->
    List.iter
      (fun c ->
        Alcotest.(check bool)
          (Printf.sprintf "caller %s disabled when env empty" (caller_label c))
          false
          (Authority.authority_enabled c))
      all_callers)
;;

let test_single_tag_matches_one_caller () =
  with_env "worker_dev_tools" (fun () ->
    Alcotest.(check bool) "worker enabled" true
      (Authority.authority_enabled Gate.Worker_dev_tools);
    Alcotest.(check bool) "code_write disabled" false
      (Authority.authority_enabled Gate.Tool_code_write);
    Alcotest.(check bool) "keeper_bash disabled" false
      (Authority.authority_enabled Gate.Keeper_shell_bash))
;;

let test_comma_list_matches_subset () =
  with_env "worker_dev_tools,keeper_shell_bash" (fun () ->
    Alcotest.(check bool) "worker enabled" true
      (Authority.authority_enabled Gate.Worker_dev_tools);
    Alcotest.(check bool) "code_write disabled" false
      (Authority.authority_enabled Gate.Tool_code_write);
    Alcotest.(check bool) "keeper_bash enabled" true
      (Authority.authority_enabled Gate.Keeper_shell_bash))
;;

let test_all_alias_matches_every_caller () =
  with_env "all" (fun () ->
    List.iter
      (fun c ->
        Alcotest.(check bool)
          (Printf.sprintf "caller %s enabled via all" (caller_label c))
          true
          (Authority.authority_enabled c))
      all_callers)
;;

let test_whitespace_trimmed () =
  with_env "  worker_dev_tools  ,  tool_code_write  " (fun () ->
    Alcotest.(check bool) "worker enabled despite spaces" true
      (Authority.authority_enabled Gate.Worker_dev_tools);
    Alcotest.(check bool) "code_write enabled despite spaces" true
      (Authority.authority_enabled Gate.Tool_code_write))
;;

let test_case_insensitive () =
  with_env "WORKER_DEV_TOOLS" (fun () ->
    Alcotest.(check bool) "worker enabled under uppercase tag" true
      (Authority.authority_enabled Gate.Worker_dev_tools))
;;

let test_unknown_tag_ignored () =
  with_env "worker_dev_tools,not_a_caller" (fun () ->
    Alcotest.(check bool) "worker still enabled" true
      (Authority.authority_enabled Gate.Worker_dev_tools);
    Alcotest.(check bool) "code_write still disabled" false
      (Authority.authority_enabled Gate.Tool_code_write))
;;

let test_empty_entries_tolerated () =
  with_env ",,worker_dev_tools,," (fun () ->
    Alcotest.(check bool) "worker enabled despite empty entries" true
      (Authority.authority_enabled Gate.Worker_dev_tools))
;;

(* ─── Integration: Worker_dev_tools.validate_command_coding_with_allowlist
   exercises the parallel facade call + env-gated authority.  These
   tests do not assert on [Legendary_counters] state directly because
   PR-3 already covers that module's behaviour; they assert on the
   end-to-end verdict shape the caller sees, which is what the wire
   contract guarantees. *)

let allowed = [ "rg"; "grep"; "sort"; "head"; "wc"; "cat" ]

let block_reason = Alcotest.testable
  (fun fmt _ -> Format.pp_print_string fmt "<block_reason>") ( = )
;;

let test_authority_off_keeps_legacy_verdict () =
  unset_env ();
  let r =
    Worker.validate_command_coding_with_allowlist
      ~caller:Gate.Worker_dev_tools
      ~allow_pipes:true
      ~allowed_commands:allowed
      "rg foo lib"
  in
  Alcotest.(check (result unit block_reason))
    "rg foo lib allowed under legacy"
    (Ok ())
    r
;;

let test_authority_on_allow_admits () =
  with_env "worker_dev_tools" (fun () ->
    let r =
      Worker.validate_command_coding_with_allowlist
        ~caller:Gate.Worker_dev_tools
        ~allow_pipes:true
        ~allowed_commands:allowed
        "rg foo lib | head -20"
    in
    Alcotest.(check (result unit block_reason))
      "rg|head allowed under facade authority"
      (Ok ())
      r)
;;

let test_authority_on_reject_maps_to_block_reason () =
  with_env "worker_dev_tools" (fun () ->
    let r =
      Worker.validate_command_coding_with_allowlist
        ~caller:Gate.Worker_dev_tools
        ~allow_pipes:true
        ~allowed_commands:allowed
        "rg foo lib | sed s/a/b/"
    in
    match r with
    | Error (Worker.Command_not_allowed "sed") -> ()
    | Error _ -> Alcotest.fail "expected Command_not_allowed sed"
    | Ok () -> Alcotest.fail "expected facade reject, got Ok")
;;

let test_authority_disabled_for_other_caller () =
  with_env "tool_code_write" (fun () ->
    (* env enables tool_code_write only; worker caller stays on
       legacy.  Even an obviously bad command goes through legacy
       (and is rejected by it as well — the assertion here is that
       the env tag for another caller does not leak). *)
    Alcotest.(check bool) "worker authority off via specific tag"
      false
      (Authority.authority_enabled Gate.Worker_dev_tools);
    Alcotest.(check bool) "code_write authority on"
      true
      (Authority.authority_enabled Gate.Tool_code_write))
;;

let () =
  Alcotest.run
    "shell_gate_authority"
    [ ( "env_parser"
      , [ Alcotest.test_case "unset disables every caller" `Quick
            test_unset_disables_every_caller
        ; Alcotest.test_case "empty disables every caller" `Quick
            test_empty_disables_every_caller
        ; Alcotest.test_case "single tag matches one caller" `Quick
            test_single_tag_matches_one_caller
        ; Alcotest.test_case "comma list matches subset" `Quick
            test_comma_list_matches_subset
        ; Alcotest.test_case "all alias matches every caller" `Quick
            test_all_alias_matches_every_caller
        ; Alcotest.test_case "whitespace trimmed" `Quick test_whitespace_trimmed
        ; Alcotest.test_case "case insensitive" `Quick test_case_insensitive
        ; Alcotest.test_case "unknown tag ignored" `Quick test_unknown_tag_ignored
        ; Alcotest.test_case "empty entries tolerated" `Quick
            test_empty_entries_tolerated
        ] )
    ; ( "authority_flip"
      , [ Alcotest.test_case "authority off keeps legacy verdict" `Quick
            test_authority_off_keeps_legacy_verdict
        ; Alcotest.test_case "authority on admits via facade Allow" `Quick
            test_authority_on_allow_admits
        ; Alcotest.test_case "authority on maps facade Reject to block_reason"
            `Quick test_authority_on_reject_maps_to_block_reason
        ; Alcotest.test_case "authority tag scoped to single caller" `Quick
            test_authority_disabled_for_other_caller
        ] )
    ]
;;
