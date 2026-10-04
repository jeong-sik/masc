open Alcotest
module Evidence = Masc_tui_runtime_evidence
let row id ~cached = `Assoc [
  "runtime_id", `String id; "entry_count", `Int 2; "success_count", `Int 1;
  "error_count", `Int 1; "usage_sample_count", `Int 1; "telemetry_sample_count", `Int 0;
  "cached_input", cached; "total_cost_usd", `Null;
  "recent_entries", `List [`Assoc ["ts_unix", `Float 1000.; "outcome", `String "success";
    "input_tokens", `Int 100; "output_tokens", `Null]]]
let cache = `Assoc ["input_tokens", `Int 100; "cache_read_tokens", `Int 0; "sample_count", `Int 1]
let payload rows = `Assoc [
  "specifications", `List [`Assoc ["runtime_id", `String "account-one.model";
    "catalog_context", `Null; "catalog_max_output", `Null; "model_context", `Int 272000;
    "provider_context", `Null; "binding_context", `Int 500000]];
  "history", `Assoc ["state", `String "ready"; "window_minutes", `Int 1440; "observed_at", `Float 1234.;
    "unattributed_entries", `Int 7; "runtimes", `List rows;
    "cache", `Assoc ["state", `String "stale_refreshing"; "generated_at", `Float 1234.];
    "cost_read", `Assoc ["state", `String "unavailable"]]]
let read json = match Evidence.decode json with Ok value -> value | Error detail -> fail detail
let value label lines = List.assoc label lines
let contains text part =
  let length = String.length part in
  let rec loop at = at + length <= String.length text
    && (String.sub text at length = part || loop (at + 1)) in loop 0
let attributed_view () =
  let snapshot = read (payload [row "account-one.model" ~cached:cache;
    row "account-two.model" ~cached:`Null]) in
  let one = Evidence.lines snapshot ~runtime_id:"account-one.model" in
  let two = Evidence.lines snapshot ~runtime_id:"account-two.model" in
  check bool "reported zero cache is measured" true (contains (value "Cache hit" one) "0.0%");
  check bool "missing cache stays unknown" true (contains (value "Cache hit" two) "not reported");
  check string "missing billed cost is not zero dollars" "not reported" (value "Recorded cost" one);
  check string "original catalog is not a copied override" "not reported" (value "Catalog context" one);
  check bool "declarations remain separately visible" true (contains (value "Declared context" one) "272000");
  check bool "binding override remains visible" true (contains (value "Declared context" one) "500000");
  check bool "stale reading is explicit" true (contains (value "History window" one) "stale");
  check string "cost store failure is visible" "cost store unavailable; decision records only" (value "Store coverage" one);
  check bool "global unknown attribution remains visible" true (contains (value "Attribution" one) "7 records");
  check string "no unrelated account samples" "none attributed in this window"
    (value "Runtime samples" (Evidence.lines snapshot ~runtime_id:"account-three.model"))
let reject_bad_coverage () =
  let bad = `Assoc ["input_tokens", `Int 100; "cache_read_tokens", `Int 101; "sample_count", `Int 1] in
  check bool "cache cannot exceed inclusive input" true (Result.is_error (Evidence.decode (payload [row "one" ~cached:bad])));
  check bool "duplicate runtime identity is refused" true
    (Result.is_error (Evidence.decode (payload [row "one" ~cached:cache; row "one" ~cached:cache])))
let cold_failure () =
  let snapshot = read (`Assoc ["specifications", `List [];
    "history", `Assoc ["state", `String "loading";
      "cache", `Assoc ["state", `String "warming"; "last_error", `String "refresh failed"]]]) in
  check string "failed cold read does not masquerade as loading"
    "snapshot refresh failed; no history available"
    (value "Runtime history" (Evidence.lines snapshot ~runtime_id:"one"))
let decision_store_failure () =
  List.iter (fun (diagnostic, expected) ->
    let snapshot = read (`Assoc ["specifications", `List [];
      "history", `Assoc ["state", `String "unavailable";
        "decision_read", `Assoc diagnostic; "cache", `Assoc ["state", `String "fresh"]]]) in
    let lines = Evidence.lines snapshot ~runtime_id:"one" in
    check bool "decision read failure remains visible" true (contains (value "Runtime history" lines) expected);
    check bool "an unread file never claims no attributed samples" false (List.mem_assoc "Runtime samples" lines);
    check bool "an unread file never claims no recent success" false (List.mem_assoc "Last non-error turn" lines))
    [["cause", `String "directory_unavailable"], "directory could not be read";
     ["cause", `String "files_unreadable"; "unreadable_files", `Int 2], "2 decision log files could not be read";
     ["cause", `String "rows_invalid"; "malformed_rows", `Int 1; "schema_violation_rows", `Int 2],
       "1 malformed and 2 schema-invalid decision rows"]
let replace_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> fail "expected object fixture"
let map_field key f json = replace_field key (f (Yojson.Safe.Util.member key json)) json
let recent_outcomes () =
  List.iter (fun (outcome, label) ->
    let runtime = row "one" ~cached:cache |> map_field "recent_entries" (function
      | `List entries -> `List (List.map (replace_field "outcome" (`String outcome)) entries)
      | _ -> fail "expected recent entries") in
    let lines = Evidence.lines (read (payload [runtime])) ~runtime_id:"one" in
    check bool "non-error outcome is shown without claiming completion" true
      (contains (value "Last non-error turn" lines) label);
    check bool "recent entry retains its outcome" true
      (contains (value "Recent non-error turn" lines) label))
    ["success", "completed"; "checkpoint", "checkpoint"; "input_required", "input required"];
  let bad = row "one" ~cached:cache |> map_field "recent_entries" (function
    | `List entries -> `List (List.map (replace_field "outcome" (`String "error")) entries)
    | _ -> fail "expected recent entries") in
  check bool "error is not accepted as a recent non-error turn" true
    (Result.is_error (Evidence.decode (payload [bad])))
let invalid_dates () =
  let baseline = payload [row "one" ~cached:cache] in
  let bad_recent = row "one" ~cached:cache |> map_field "recent_entries" (function
    | `List entries -> `List (List.map (replace_field "ts_unix" (`Float 1e300)) entries)
    | _ -> fail "expected recent entries") in
  List.iter (fun json ->
    check bool "platform-unrenderable dates fail before rendering" true
      (Result.is_error (Evidence.decode json)))
    [payload [bad_recent]; baseline |> map_field "history" (replace_field "observed_at" (`Float 1e300))]

let () = run "TUI runtime evidence" ["operator reading", [
  test_case "checkpoint and input-required outcomes retain their meaning" `Quick recent_outcomes;
  test_case "unrenderable timestamps fail decoding" `Quick invalid_dates;
  test_case "attribution, missing evidence and specification" `Quick attributed_view;
  test_case "failed cold snapshot" `Quick cold_failure;
  test_case "unavailable decision store is never empty activity" `Quick decision_store_failure;
  test_case "invalid sample coverage" `Quick reject_bad_coverage]]
