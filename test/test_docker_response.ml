(** RFC-0070 Phase 3b-iv.0 — tests for [Keeper_docker_response] typed
    transforms.

    Pins F3 (RFC §1) at the type level: every docker [State] string
    we know either becomes a typed variant or returns
    [Unknown_state s] with the raw value preserved. No catch-all,
    no permissive default. *)

open Alcotest
open Masc_mcp

let status_t = testable Keeper_docker_response.pp_ps_status Keeper_docker_response.equal_ps_status

let err_pp ppf = function
  | Keeper_docker_response.Unknown_state s -> Format.fprintf ppf "Unknown_state %S" s

let err_eq a b =
  match a, b with
  | Keeper_docker_response.Unknown_state x, Keeper_docker_response.Unknown_state y ->
      String.equal x y

let err_t = testable err_pp err_eq

(* ── Parse known states ───────────────────────────────────────── *)

let test_parse_created () =
  check (result status_t err_t) "created" (Ok Keeper_docker_response.Created)
    (Keeper_docker_response.parse_state "created")

let test_parse_running () =
  check (result status_t err_t) "running" (Ok Keeper_docker_response.Running)
    (Keeper_docker_response.parse_state "running")

let test_parse_paused () =
  check (result status_t err_t) "paused" (Ok Keeper_docker_response.Paused)
    (Keeper_docker_response.parse_state "paused")

let test_parse_restarting () =
  check (result status_t err_t) "restarting" (Ok Keeper_docker_response.Restarting)
    (Keeper_docker_response.parse_state "restarting")

let test_parse_exited () =
  check (result status_t err_t) "exited (state token only — exit code via inspect, Phase 3b-iv.2)"
    (Ok Keeper_docker_response.Exited)
    (Keeper_docker_response.parse_state "exited")

let test_parse_dead () =
  check (result status_t err_t) "dead" (Ok Keeper_docker_response.Dead)
    (Keeper_docker_response.parse_state "dead")

(* ── Case-insensitive / whitespace-tolerant ───────────────────── *)

let test_parse_uppercase () =
  check (result status_t err_t) "RUNNING" (Ok Keeper_docker_response.Running)
    (Keeper_docker_response.parse_state "RUNNING")

let test_parse_mixed_case () =
  check (result status_t err_t) "Restarting" (Ok Keeper_docker_response.Restarting)
    (Keeper_docker_response.parse_state "Restarting")

let test_parse_whitespace () =
  check (result status_t err_t) "  paused  " (Ok Keeper_docker_response.Paused)
    (Keeper_docker_response.parse_state "  paused  ")

(* ── No permissive default ────────────────────────────────────── *)

let test_unknown_state () =
  check (result status_t err_t) "unknown → Error preserves raw"
    (Error (Keeper_docker_response.Unknown_state "frobnicating"))
    (Keeper_docker_response.parse_state "frobnicating")

let test_empty_state () =
  check (result status_t err_t) "empty → Error preserves raw"
    (Error (Keeper_docker_response.Unknown_state ""))
    (Keeper_docker_response.parse_state "")

(* ── state_to_string canonical form ───────────────────────────── *)

let test_to_string_canonical () =
  check string "Running → running" "running"
    (Keeper_docker_response.state_to_string Keeper_docker_response.Running);
  check string "Created → created" "created"
    (Keeper_docker_response.state_to_string Keeper_docker_response.Created);
  check string "Paused → paused" "paused"
    (Keeper_docker_response.state_to_string Keeper_docker_response.Paused);
  check string "Restarting → restarting" "restarting"
    (Keeper_docker_response.state_to_string Keeper_docker_response.Restarting);
  check string "Exited → exited" "exited"
    (Keeper_docker_response.state_to_string Keeper_docker_response.Exited);
  check string "Dead → dead" "dead"
    (Keeper_docker_response.state_to_string Keeper_docker_response.Dead)

(* ── Round-trip: parse ∘ to_string = id (all variants, no per-variant payload) ── *)

let roundtrip_all cases =
  List.iter
    (fun s ->
      check (result status_t err_t) (Printf.sprintf "round-trip %s" s)
        (Keeper_docker_response.parse_state s)
        (Keeper_docker_response.parse_state
           (Keeper_docker_response.state_to_string
              (match Keeper_docker_response.parse_state s with
               | Ok v -> v
               | Error _ -> failwith "fixture"))))
    cases

let test_roundtrip () =
  roundtrip_all [ "created"; "running"; "paused"; "restarting"; "exited"; "dead" ]

(* ── exec_result equality + show ──────────────────────────────── *)

let test_exec_result_structural_equality () =
  let a = Keeper_docker_response.{ exit_code = 0; stdout = "hi"; stderr = "" } in
  let b = Keeper_docker_response.{ exit_code = 0; stdout = "hi"; stderr = "" } in
  let c = Keeper_docker_response.{ exit_code = 1; stdout = "hi"; stderr = "" } in
  check bool "structural equality (a ≡ b by field)" true (Keeper_docker_response.equal_exec_result a b);
  check bool "exit_code distinguishes" false (Keeper_docker_response.equal_exec_result a c)

(* ── ps_record structural equality (Phase 3b-iv.1a) ────────────── *)

let sample_name =
  Keeper_container_name.derive
    ~algo:Keeper_hash_algo.SHA_256
    ~turn_id:1
    ~attempt:0
    ~suffix:"test"

let sample_ps_record =
  Keeper_docker_response.
    { id = "abc123"
    ; name = sample_name
    ; status = Running
    ; labels = [ "masc.keeper", "test"; "masc.run_id", "42" ]
    }

let test_ps_record_structural_equality () =
  let a = sample_ps_record in
  let b = sample_ps_record in
  let c = { sample_ps_record with status = Keeper_docker_response.Dead } in
  check bool "ps_record structural equality" true (Keeper_docker_response.equal_ps_record a b);
  check bool "status field distinguishes" false (Keeper_docker_response.equal_ps_record a c)

let test_ps_record_labels_order () =
  (* Labels are an association list — order matters for structural
     equality. The parsing layer (Phase 3b-iv.2) is responsible for
     emitting them in a canonical order if order-independence is
     required. *)
  let a = sample_ps_record in
  let b =
    { sample_ps_record with
      labels = [ "masc.run_id", "42"; "masc.keeper", "test" ]
    }
  in
  check bool "label list order matters (no auto-sort)"
    false (Keeper_docker_response.equal_ps_record a b)

let () =
  run "Keeper_docker_response"
    [
      ( "parse known states",
        [
          test_case "created" `Quick test_parse_created;
          test_case "running" `Quick test_parse_running;
          test_case "paused" `Quick test_parse_paused;
          test_case "restarting" `Quick test_parse_restarting;
          test_case "exited (state token only)" `Quick test_parse_exited;
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
      ( "ps_record",
        [
          test_case "structural equality + status distinguishes"
            `Quick
            test_ps_record_structural_equality;
          test_case "label list order matters"
            `Quick
            test_ps_record_labels_order;
        ] );
    ]
