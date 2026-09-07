module View = Masc_tui_runtime_config_view
open View
let expect label value = if not value then failwith label
let success = function Ok value -> value | Error detail -> failwith detail
let replace key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> failwith "invalid fixture"
let map_field key f = function
  | `Assoc fields -> `Assoc (List.map (fun (name, value) -> name, (if name = key then f value else value)) fields)
  | _ -> failwith "invalid fixture"
let fixture () = `Assoc [
  "ok", `Bool true; "path", `String "/workspace/runtime.toml";
  "source_revision", `String "revision-a"; "source_text", `String "[keeper]\nfoo = true\n";
  "validation", `Assoc ["valid", `Bool true; "schema_version", `Int 1;
    "current_schema_version", `Int 1; "forward_schema", `Bool false; "issues", `List []];
  "application", `Assoc ["operation", `String "read";
    "routing", `Assoc ["status", `String "active"; "requires_restart", `Bool false; "applied_at", `Null];
    "keeper_overlay", `Assoc ["status", `String "applied"; "configured_count", `Int 1;
      "requires_restart", `Bool false; "pending_keys", `List []; "preempted_keys", `List [];
      "applied_keys", `List [`String "keeper.foo"]; "applied_at", `Float 1.]]]
let overlay f json = map_field "application" (map_field "keeper_overlay" f) json
let issue severity = `Assoc ["key", `String "keeper.foo"; "kind", `String "type_mismatch";
  "severity", `String severity; "detail", `String "expected a boolean"]
let test_atomic_read () =
  let read = success (decode (fixture ())) in
  expect "same response source and revision" (read.source_text = "[keeper]\nfoo = true\n" && read.metadata.source_revision = "revision-a");
  expect "three summary rows" (List.length (summary_lines read.metadata) = 3);
  expect "read has no write-only Skill receipt requirement" (read.metadata.routing = Routing_active)
let test_pending_and_preempted () =
  let read = fixture () |> overlay (fun value -> value
    |> replace "status" (`String "pending_restart") |> replace "requires_restart" (`Bool true)
    |> replace "pending_keys" (`List [`String "keeper.pending"])
    |> replace "preempted_keys" (`List [`String "keeper.environment"])) |> decode |> success in
  expect "restart remains explicit" read.metadata.keeper_requires_restart;
  let lines = detail_lines read.metadata in
  expect "every pending key visible" (List.mem (Warning, "Pending restart: keeper.pending") lines);
  expect "environment precedence visible" (List.mem (Warning, "Preempted by environment: keeper.environment") lines)
let test_invalid_source_is_readable () =
  let read = fixture () |> map_field "validation" (fun value -> value
    |> replace "valid" (`Bool false) |> replace "issues" (`List [issue "error"])) |> decode |> success in
  expect "source survives typed validation failure" (read.source_text <> "");
  expect "validation severity remains Bad" (match List.nth (summary_lines read.metadata) 1 with Bad, _ -> true | _ -> false);
  expect "issue detail retained" (List.exists (fun (_, text) -> text = "keeper.foo · type mismatch: expected a boolean") (detail_lines read.metadata))
let test_parse_failure_shape () =
  let read = fixture ()
    |> replace "validation" (`Assoc ["valid", `Bool false; "parse_error", `String "line 2: invalid TOML"; "issues", `List []])
    |> overlay (replace "status" (`String "invalid")) |> decode |> success in
  expect "parse failure carries no invented schema" (read.metadata.validation = Parse_error "line 2: invalid TOML");
  expect "invalid application remains typed" (read.metadata.keeper = Invalid_configuration)
let test_unknown_metadata_is_rejected () =
  List.iter (fun json -> expect "invalid metadata cannot publish source alone" (Result.is_error (decode json)))
    [fixture () |> replace "source_revision" `Null;
     fixture () |> overlay (replace "status" (`String "unknown"));
     fixture () |> overlay (replace "requires_restart" (`String "false"));
     fixture () |> map_field "validation" (replace "issues" (`List [issue "error"]))]
let test_warnings_are_not_successfully_hidden () =
  let read = fixture () |> map_field "validation" (replace "issues" (`List [issue "warning"])) |> decode |> success in
  expect "valid with warnings uses Warning tone" (match List.nth (summary_lines read.metadata) 1 with Warning, _ -> true | _ -> false)
let test_restart_projection_consistency () =
  List.iter (fun json -> expect "restart contradiction rejected" (Result.is_error (decode json)))
    [ fixture () |> overlay (replace "pending_keys" (`List [`String "keeper.pending"]));
      fixture () |> overlay (replace "requires_restart" (`Bool true));
      fixture () |> overlay (replace "status" (`String "pending_restart"));
      fixture () |> overlay (fun value -> value
        |> replace "requires_restart" (`Bool true)
        |> replace "pending_keys" (`List [`String "keeper.pending"])) ]
let () = List.iter (fun (name, test) -> test (); Printf.printf "PASS %s\n%!" name)
  ["atomic GET source and metadata", test_atomic_read;
   "pending and preempted settings", test_pending_and_preempted;
   "invalid source remains readable", test_invalid_source_is_readable;
   "TOML parse failure projection", test_parse_failure_shape;
   "unknown and inconsistent metadata", test_unknown_metadata_is_rejected;
   "warnings remain visible", test_warnings_are_not_successfully_hidden;
   "restart status matches pending settings", test_restart_projection_consistency]
