(** RFC keeper-memory-consolidation Stage 1 regression test.

    Pins the kill-switch contract for the memory_bank long-term inject:
    [Keeper_memory_bank_env.bank_longterm_inject_enabled]. keeper_turn.ml's
    durable_text guard ([keeper_turn.ml] ~:575) calls this exact function, so
    the test and the production guard share one key + one default (SSOT).

    What this fixes-in-place against:
    - default flip: unset MUST stay ON, so Stage 1 is a behavior-zero change.
    - key rename/typo: a renamed env key would silently make the guard dead
      code (always ON); this test goes red if the wired key changes.

    Not covered here (honest scope): that build_turn_prompt actually gates
    durable_text on this function. That is a large closure (ctx/meta/messages
    captured) and is verified by compile (the guard type-checks) + live sanity
    per RFC §5, not by unit isolation. *)

open Alcotest

module Env = Masc.Keeper_memory_bank_env

let key = "MASC_KEEPER_BANK_LONGTERM_INJECT"

(* Temporarily set [name]=[value] (or unset when value=None) around [f].
   Mirrors the with_env idiom used across test/ (Unix.putenv "" ~= unset). *)
let with_env_opt name value f =
  let previous = Sys.getenv_opt name in
  (match value with Some v -> Unix.putenv name v | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f
;;

let check_flag label env expected =
  with_env_opt key env (fun () ->
      check bool label expected (Env.bank_longterm_inject_enabled ()))
;;

let test_default_on_when_unset () =
  (* Stage 1 promise: no env → inject stays ON → zero behavior change. *)
  check_flag "unset → default ON" None true
;;

let test_off_values () =
  List.iter
    (fun v -> check_flag (Printf.sprintf "%S → off" v) (Some v) false)
    [ "false"; "off"; "0"; "no"; "disabled"; "FALSE"; "Off" ]
;;

let test_on_values () =
  List.iter
    (fun v -> check_flag (Printf.sprintf "%S → on" v) (Some v) true)
    [ "true"; "on"; "1"; "yes"; "enabled"; "TRUE" ]
;;

let test_invalid_falls_back_to_default_on () =
  (* Unparseable value must not silently disable inject; default=true wins. *)
  check_flag "garbage → default ON" (Some "garbage") true;
  check_flag "empty → default ON" (Some "") true
;;

let () =
  run
    "keeper_bank_longterm_inject_flag"
    [ ( "kill_switch_contract",
        [ test_case "default ON when unset" `Quick test_default_on_when_unset;
          test_case "off values disable" `Quick test_off_values;
          test_case "on values enable" `Quick test_on_values;
          test_case "invalid falls back to default ON" `Quick
            test_invalid_falls_back_to_default_on ] ) ]
;;
