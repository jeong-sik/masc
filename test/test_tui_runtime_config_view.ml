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
module Line = Masc_tui_page_line
(* Every reading line of the status page, in order, without the block titles. *)
let page_lines metadata = List.concat_map snd (detail_blocks ~ko:false ~lead:[] metadata)
let issue severity = `Assoc ["key", `String "keeper.foo"; "kind", `String "type_mismatch";
  "severity", `String severity; "detail", `String "expected a boolean"]
let test_atomic_read () =
  let read = success (decode (fixture ())) in
  expect "same response source and revision" (read.source_text = "[keeper]\nfoo = true\n" && read.metadata.source_revision = "revision-a");
  expect "three summary rows" (List.length (summary_lines ~ko:false read.metadata) = 3);
  expect "read has no write-only Skill receipt requirement" (read.metadata.routing = Routing_active)
let test_pending_and_preempted () =
  let read = fixture () |> overlay (fun value -> value
    |> replace "status" (`String "pending_restart") |> replace "requires_restart" (`Bool true)
    |> replace "pending_keys" (`List [`String "keeper.pending"])
    |> replace "preempted_keys" (`List [`String "keeper.environment"])) |> decode |> success in
  expect "restart remains explicit" read.metadata.keeper_requires_restart;
  let lines = page_lines read.metadata in
  expect "every pending key visible"
    (List.mem (Line.items ~tone:Line.Attention "Pending restart" [ "keeper.pending" ]) lines);
  expect "environment precedence visible"
    (List.mem (Line.items ~tone:Line.Attention "Preempted by environment" [ "keeper.environment" ]) lines)
let test_invalid_source_is_readable () =
  let read = fixture () |> map_field "validation" (fun value -> value
    |> replace "valid" (`Bool false) |> replace "issues" (`List [issue "error"])) |> decode |> success in
  expect "source survives typed validation failure" (read.source_text <> "");
  expect "validation severity remains Bad" (match List.nth (summary_lines ~ko:false read.metadata) 1 with Bad, _ -> true | _ -> false);
  expect "issue detail retained"
    (List.mem (Line.note ~tone:Line.Failure "keeper.foo · type mismatch: expected a boolean") (page_lines read.metadata))
let test_status_page_carries_the_verdict () =
  let clean = success (decode (fixture ())) in
  expect "a clean read is a success" (List.mem (Line.fact ~tone:Line.Success "Validation" "valid") (page_lines clean.metadata));
  expect "routing and keeper state are two facts"
    (List.mem (Line.fact "Routing" "active") (page_lines clean.metadata)
     && List.mem (Line.fact "Keeper" "applied") (page_lines clean.metadata));
  expect "applied keys are one list" (List.mem (Line.items "Applied" [ "keeper.foo" ]) (page_lines clean.metadata));
  expect "three blocks while keys exist" (List.length (detail_blocks ~ko:false ~lead:[] clean.metadata) = 3);
  let keyless = fixture () |> overlay (replace "applied_keys" (`List [])) |> decode |> success in
  expect "no key block without keys" (List.length (detail_blocks ~ko:false ~lead:[] keyless.metadata) = 2);
  let failed = fixture () |> map_field "validation" (fun value -> value
    |> replace "valid" (`Bool false) |> replace "issues" (`List [issue "error"])) |> decode |> success in
  expect "an invalid read is a failure"
    (List.mem (Line.fact ~tone:Line.Failure "Validation" "invalid · 1 error") (page_lines failed.metadata))
let test_summary_and_page_agree_on_warnings () =
  let summary_tone metadata = match List.nth (summary_lines ~ko:false metadata) 2 with tone, _ -> tone in
  let routing_pending = fixture ()
    |> map_field "application" (map_field "routing" (replace "requires_restart" (`Bool true)))
    |> decode |> success in
  expect "a routing restart is a summary warning" (summary_tone routing_pending.metadata = Warning);
  expect "the page puts the warning on the routing side only"
    (List.mem (Line.fact ~tone:Line.Attention "Routing" "active, pending restart") (page_lines routing_pending.metadata)
     && List.mem (Line.fact "Keeper" "applied") (page_lines routing_pending.metadata));
  let preempted = fixture ()
    |> overlay (fun value -> value
      |> replace "status" (`String "preempted_by_env")
      |> replace "preempted_keys" (`List [`String "keeper.environment"])) |> decode |> success in
  expect "a preempted key is a summary warning" (summary_tone preempted.metadata = Warning);
  expect "the page puts the warning on the keeper side only"
    (List.mem (Line.fact ~tone:Line.Attention "Keeper" "preempted by environment") (page_lines preempted.metadata)
     && List.mem (Line.fact "Routing" "active") (page_lines preempted.metadata));
  expect "a clean read is no summary warning"
    (summary_tone (success (decode (fixture ()))).metadata = Neutral)
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
let test_restart_projection_consistency () =
  List.iter (fun json -> expect "restart contradiction rejected" (Result.is_error (decode json)))
    [ fixture () |> overlay (replace "pending_keys" (`List [`String "keeper.pending"]));
      fixture () |> overlay (replace "requires_restart" (`Bool true));
      fixture () |> overlay (replace "status" (`String "pending_restart"));
      fixture () |> overlay (fun value -> value
        |> replace "requires_restart" (`Bool true)
        |> replace "pending_keys" (`List [`String "keeper.pending"])) ]
let test_account_groups () =
  let group ids = `Assoc ["integration_ids", `List (List.map (fun id -> `String id) ids)] in
  let read groups = fixture () |> replace "account_groups" groups |> decode |> success in
  expect "server grouping retained with source"
    ((read (`List [group ["codex_a"; "codex_b"]; group ["claude"]])).account_groups
      = Ok [["codex_a"; "codex_b"]; ["claude"]]);
  List.iter (fun groups -> expect "bad membership remains unavailable"
    (Result.is_error (read groups).account_groups))
    [`Null; `List [group ["a"]; group ["a"]]; `List [group []]; `List [group [""]]];
  expect "absent evidence is not an empty successful read"
    (Result.is_error (success (decode (fixture ()))).account_groups)
let test_source_account_emails () =
  let email = `Assoc ["integration_id", `String "codex_a";
    "state", `String "read"; "email", `String "source-b@example.org"] in
  let read rows = fixture () |> replace "account_emails" rows |> decode |> success in
  expect "email belongs to the source response"
    ((read (`List [email])).account_emails = Ok (Masc_tui_account_login.Email_rows {rows=["codex_a", Email "source-b@example.org"]; unattributed=0}));
  expect "missing email evidence stays failed"
    (Result.is_error (success (decode (fixture ()))).account_emails);
  List.iter (fun rows -> expect "unavailable email evidence stays unrecognized"
    ((read rows).account_emails = Ok Masc_tui_account_login.Email_list_unrecognized)) [`Null; `String "bad"];
  expect "malformed rows preserve partial evidence"
    ((read (`List [email; `Null])).account_emails = Ok (Masc_tui_account_login.Email_rows {rows=["codex_a", Email "source-b@example.org"]; unattributed=1}));
  let unavailable = `Assoc ["integration_id", `String "codex_b";
    "state", `String "not_read"; "cause", `String "source_unavailable"] in
  expect "source decoder retains typed provider failure beside successful email"
    ((read (`List [email; unavailable])).account_emails =
      Ok (Masc_tui_account_login.Email_rows {
        rows=["codex_a", Email "source-b@example.org";
              "codex_b", Not_read Login_file_unreadable]; unattributed=0}))

let test_source_model_projection () =
  let source = {|[models.shared]
max-context = 8192
[providers.local]
protocol = "openai-compatible-http"
kind = "openai_compat"
endpoint = "http://localhost:9000/v1"
[local.shared]
|} in
  let config = match Runtime_toml.parse_string source with
    | Ok config -> config | Error _ -> failwith "invalid synthetic source" in
  let projection = Runtime_config_models.of_config config |> success in
  let wire = Runtime_config_models.to_json ~path:"/workspace/runtime.toml"
    ~source_revision:"revision-a" (Ok projection) in
  let original = fixture () |> replace "source_text" (`String source)
    |> replace "account_groups" (`List []) in
  let observed = original |> replace "model_bindings" wire |> decode |> success in
  expect "same-source model projection accepted" (observed.model_bindings = Ok projection);
  expect "model result does not hide missing email evidence" (Result.is_error observed.account_emails);
  List.iter (fun response ->
    let observed = response |> decode |> success in
    expect "failed projection retains original repairable source" (observed.source_text = source);
    expect "failed model evidence is not reparsed locally" (Result.is_error observed.model_bindings);
    expect "model failure does not suppress account membership" (observed.account_groups = Ok []))
    [original;
     original |> replace "model_bindings" (wire |> replace "path" (`String "/foreign/runtime.toml"));
     original |> replace "model_bindings" (wire |> replace "source_revision" (`String "older"));
     original |> replace "model_bindings" (Runtime_config_models.to_json
       ~path:"/workspace/runtime.toml" ~source_revision:"revision-a" (Error "Runtime validation failed"));
     original |> replace "model_bindings" `Null]

let () = List.iter (fun (name, test) -> test (); Printf.printf "PASS %s\n%!" name)
  ["same-source model evidence and independent failures", test_source_model_projection;
   "source-owned account email evidence", test_source_account_emails;
   "server-owned account group evidence", test_account_groups;
   "atomic GET source and metadata", test_atomic_read;
   "pending and preempted settings", test_pending_and_preempted;
   "invalid source remains readable", test_invalid_source_is_readable;
   "status page carries the verdict", test_status_page_carries_the_verdict;
   "summary and page agree on warnings", test_summary_and_page_agree_on_warnings;
   "TOML parse failure projection", test_parse_failure_shape;
   "unknown and inconsistent metadata", test_unknown_metadata_is_rejected;
   "restart status matches pending settings", test_restart_projection_consistency]
