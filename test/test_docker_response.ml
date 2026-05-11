(** RFC-0070 Phase 3b-iv.0 — tests for [Docker_response] typed
    transforms.

    Pins F3 (RFC §1) at the type level: every docker [State] string
    we know either becomes a typed variant or returns
    [Unknown_state s] with the raw value preserved. No catch-all,
    no permissive default. *)

open Alcotest
open Masc_mcp

let status_t = testable Docker_response.pp_ps_status Docker_response.equal_ps_status

let err_pp ppf = function
  | Docker_response.Unknown_state s -> Format.fprintf ppf "Unknown_state %S" s

let err_eq a b =
  match a, b with
  | Docker_response.Unknown_state x, Docker_response.Unknown_state y ->
      String.equal x y

let err_t = testable err_pp err_eq

(* ── Parse known states ───────────────────────────────────────── *)

let test_parse_created () =
  check (result status_t err_t) "created" (Ok Docker_response.Created)
    (Docker_response.parse_state "created")

let test_parse_running () =
  check (result status_t err_t) "running" (Ok Docker_response.Running)
    (Docker_response.parse_state "running")

let test_parse_paused () =
  check (result status_t err_t) "paused" (Ok Docker_response.Paused)
    (Docker_response.parse_state "paused")

let test_parse_restarting () =
  check (result status_t err_t) "restarting" (Ok Docker_response.Restarting)
    (Docker_response.parse_state "restarting")

let test_parse_exited () =
  check (result status_t err_t) "exited (state token only — exit code via inspect, Phase 3b-iv.2)"
    (Ok Docker_response.Exited)
    (Docker_response.parse_state "exited")

let test_parse_dead () =
  check (result status_t err_t) "dead" (Ok Docker_response.Dead)
    (Docker_response.parse_state "dead")

(* ── Case-insensitive / whitespace-tolerant ───────────────────── *)

let test_parse_uppercase () =
  check (result status_t err_t) "RUNNING" (Ok Docker_response.Running)
    (Docker_response.parse_state "RUNNING")

let test_parse_mixed_case () =
  check (result status_t err_t) "Restarting" (Ok Docker_response.Restarting)
    (Docker_response.parse_state "Restarting")

let test_parse_whitespace () =
  check (result status_t err_t) "  paused  " (Ok Docker_response.Paused)
    (Docker_response.parse_state "  paused  ")

(* ── No permissive default ────────────────────────────────────── *)

let test_unknown_state () =
  check (result status_t err_t) "unknown → Error preserves raw"
    (Error (Docker_response.Unknown_state "frobnicating"))
    (Docker_response.parse_state "frobnicating")

let test_empty_state () =
  check (result status_t err_t) "empty → Error preserves raw"
    (Error (Docker_response.Unknown_state ""))
    (Docker_response.parse_state "")

(* ── state_to_string canonical form ───────────────────────────── *)

let test_to_string_canonical () =
  check string "Running → running" "running"
    (Docker_response.state_to_string Docker_response.Running);
  check string "Created → created" "created"
    (Docker_response.state_to_string Docker_response.Created);
  check string "Paused → paused" "paused"
    (Docker_response.state_to_string Docker_response.Paused);
  check string "Restarting → restarting" "restarting"
    (Docker_response.state_to_string Docker_response.Restarting);
  check string "Exited → exited" "exited"
    (Docker_response.state_to_string Docker_response.Exited);
  check string "Dead → dead" "dead"
    (Docker_response.state_to_string Docker_response.Dead)

(* ── Round-trip: parse ∘ to_string = id (all variants, no per-variant payload) ── *)

let roundtrip_all cases =
  List.iter
    (fun s ->
      check (result status_t err_t) (Printf.sprintf "round-trip %s" s)
        (Docker_response.parse_state s)
        (Docker_response.parse_state
           (Docker_response.state_to_string
              (match Docker_response.parse_state s with
               | Ok v -> v
               | Error _ -> failwith "fixture"))))
    cases

let test_roundtrip () =
  roundtrip_all [ "created"; "running"; "paused"; "restarting"; "exited"; "dead" ]

(* ── exec_result equality + show ──────────────────────────────── *)

let test_exec_result_structural_equality () =
  let a = Docker_response.{ exit_code = 0; stdout = "hi"; stderr = "" } in
  let b = Docker_response.{ exit_code = 0; stdout = "hi"; stderr = "" } in
  let c = Docker_response.{ exit_code = 1; stdout = "hi"; stderr = "" } in
  check bool "structural equality (a ≡ b by field)" true (Docker_response.equal_exec_result a b);
  check bool "exit_code distinguishes" false (Docker_response.equal_exec_result a c)

let () =
  run "Docker_response"
    [
      ( "parse known states",
        [
          test_case "created" `Quick test_parse_created;
          test_case "running" `Quick test_parse_running;
          test_case "paused" `Quick test_parse_paused;
          test_case "restarting" `Quick test_parse_restarting;
          test_case "exited (placeholder code)" `Quick test_parse_exited;
          test_case "dead" `Quick test_parse_dead;
        ] );
      ( "case + whitespace tolerance",
        [
          test_case "RUNNING" `Quick test_parse_uppercase;
          test_case "Restarting" `Quick test_parse_mixed_case;
          test_case "leading/trailing whitespace" `Quick test_parse_whitespace;
        ] );
      ( "no permissive default",
        [
          test_case "unknown state preserves raw" `Quick test_unknown_state;
          test_case "empty state preserves raw" `Quick test_empty_state;
        ] );
      ( "canonical form",
        [ test_case "state_to_string canonical" `Quick test_to_string_canonical ] );
      ( "round-trip",
        [ test_case "parse ∘ to_string = id (all variants)" `Quick test_roundtrip ] );
      ( "exec_result",
        [
          test_case "structural equality + exit_code distinguishes"
            `Quick
            test_exec_result_structural_equality;
        ] );
    ]
