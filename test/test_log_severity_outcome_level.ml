(** Regression tests for outcome-derived log severity
    (docs/spec/18-log-severity-taxonomy.md § 3.6).

    This pins the pure level-selection helper introduced to stop an
    outcome-carrying line from being emitted at a static [Info] level:

    - {!Mcp_server_eio_helpers.mcp_exn_level_and_tag} — the MCP exception logger.
      An [UNEXPECTED]-tagged exception was previously emitted at [Info].

    The taxonomy is enforced structurally by
    [scripts/ci/check-log-severity-anti-patterns.sh] (rule L6); these tests pin
    the {e mapping} itself so a future edit cannot silently demote an error back
    to [Info] while still satisfying the regex lint. *)

open Masc

(* Compare [Log.level] values structurally; the printer uses the public
   [level_to_string] so a mismatch reports readable severities. *)
let level = Alcotest.testable (fun fmt l -> Format.pp_print_string fmt (Log.level_to_string l)) ( = )

exception Surprise_exn

let mcp_exn_cases () =
  let f = Mcp_server_eio_helpers.mcp_exn_level_and_tag in
  let pair = Alcotest.(pair level string) in
  (* Recognised I/O / parse / control-flow exceptions stay at Info, no tag. *)
  Alcotest.check pair "Failure → Info" (Log.Info, "") (f (Failure "boom"));
  Alcotest.check pair "Not_found → Info" (Log.Info, "") (f Not_found);
  Alcotest.check pair "Sys_error → Info" (Log.Info, "") (f (Sys_error "fd"));
  Alcotest.check pair "End_of_file → Info" (Log.Info, "") (f End_of_file);
  (* Anything else is unrecognised: tagged + raised to Warn (not Error — the
     side channel still recovers). *)
  Alcotest.check pair "unrecognised → Warn + [UNEXPECTED]"
    (Log.Warn, "[UNEXPECTED] ") (f Surprise_exn)

let () =
  Alcotest.run "log_severity_outcome_level"
    [ "mcp_exn_level_and_tag", [ Alcotest.test_case "level + tag mapping" `Quick mcp_exn_cases ] ]
