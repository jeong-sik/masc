(** RFC-0092 Phase C — tests for the [MASC_BASH_TYPED_AUTHORITY] flag
    predicate.

    Two SSOT predicates ship in this PR; both must read the same
    env var and return the same bool at any given env state:

    - [Masc_mcp.Gate_diff_types.typed_authority_enabled] (root lib)
    - [Masc_exec_command_gate.Shell_command_gate.is_authoritative]
      (facade sub-library)

    The duplicate exists because the facade sub-library cannot depend
    on the root [masc_mcp] library without a cycle; this test pins
    the two predicates to identical truthy-value semantics so silent
    divergence at the SSOT layer fails CI rather than only surfacing
    when the authority decision-arm wiring lands in a follow-up.

    No in-process caching (the predicates re-read [Sys.getenv_opt]
    each call), so each case can [Unix.putenv] inline.  The
    [Fun.protect ~finally] restore pattern matches
    [test_typed_advisor_counters.ml]'s default-off case so the test
    file does not leak env state to subsequent test executables in
    the same Alcotest sweep. *)

module Root = Masc_mcp.Gate_diff_types
module Facade = Masc_exec_command_gate.Shell_command_gate

let env_var = "MASC_BASH_TYPED_AUTHORITY"

(* Snapshot + restore so the test fixture is self-contained — the
   test runner shares the OS process with subsequent test exes when
   chained, and a leaked truthy value would silently turn authority
   on for them. *)
let with_env value f =
  let prev = Sys.getenv_opt env_var in
  Unix.putenv env_var value;
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | None -> Unix.putenv env_var ""
      | Some v -> Unix.putenv env_var v)
    f
;;

let check_both ~label ~expected =
  Alcotest.(check bool)
    (Printf.sprintf "%s — root predicate" label)
    expected
    (Root.typed_authority_enabled ());
  Alcotest.(check bool)
    (Printf.sprintf "%s — facade predicate" label)
    expected
    (Facade.is_authoritative ())
;;

let test_unset_is_off () =
  (* Saved+restored so we don't depend on the parent shell's state. *)
  let prev = Sys.getenv_opt env_var in
  Unix.putenv env_var "";
  Fun.protect
    ~finally:(fun () ->
      match prev with
      | None -> Unix.putenv env_var ""
      | Some v -> Unix.putenv env_var v)
    (fun () -> check_both ~label:"empty env" ~expected:false)
;;

let test_truthy_values_turn_on () =
  List.iter
    (fun v ->
      with_env v (fun () ->
        check_both ~label:(Printf.sprintf "env=%S" v) ~expected:true))
    [ "1"; "true"; "TRUE"; "yes"; "on" ]
;;

let test_falsy_and_arbitrary_values_stay_off () =
  (* "log" is intentionally *not* a truthy value for the authority
     flag — RFC-0092 §4.3 reserves "log" for the advisor flag only.
     Mixing them would let an operator turn decisions on while
     thinking they only enabled measurement. *)
  List.iter
    (fun v ->
      with_env v (fun () ->
        check_both ~label:(Printf.sprintf "env=%S" v) ~expected:false))
    [ "0"; "false"; "FALSE"; "no"; "off"; "log"; "2"; "anything-else"; "" ]
;;

let test_predicates_stay_in_sync_per_value () =
  (* Belt-and-suspenders: even if the two predicate impls diverge in
     a future refactor, this assertion catches drift directly. *)
  List.iter
    (fun v ->
      with_env v (fun () ->
        let root = Root.typed_authority_enabled () in
        let facade = Facade.is_authoritative () in
        Alcotest.(check bool)
          (Printf.sprintf "root/facade agree on env=%S" v)
          root
          facade))
    [ ""; "1"; "true"; "TRUE"; "yes"; "on"; "log"; "0"; "false"; "garbage" ]
;;

let () =
  Alcotest.run
    "typed_authority_flag"
    [ ( "predicate"
      , [ Alcotest.test_case
            "unset env → off"
            `Quick
            test_unset_is_off
        ; Alcotest.test_case
            "documented truthy values → on"
            `Quick
            test_truthy_values_turn_on
        ; Alcotest.test_case
            "falsy + arbitrary values → off"
            `Quick
            test_falsy_and_arbitrary_values_stay_off
        ; Alcotest.test_case
            "root and facade predicates agree"
            `Quick
            test_predicates_stay_in_sync_per_value
        ] )
    ]
;;
