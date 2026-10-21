open Alcotest
module Catalog = Masc_tui_resource_catalog
module Checks = Masc_tui_artifact_checks
module Check = Masc.Published_artifact_check
module Published = Masc.Published_artifact
module Fetched = Masc_tui_fetched

let get = function Ok value -> value | Error detail -> fail detail
let id = "artifact-0123456789abcdef0123456789abcdef"
let published_at = "2026-10-21T00:00:00Z"
let day = Catalog.local_day (match Time_codec.parse_rfc3339 published_at with
  | Ok seconds -> seconds | Error Time_codec.Invalid_rfc3339 -> fail "fixture date")

let report ?(number=1) content =
  let body = get (Result.map_error Tool_output.make_error_to_string
    (Tool_output.make_artifact_ref
      ~sha256:Digestif.SHA256.(to_hex (digest_string content))
      ~bytes:(String.length content) ~preview:content ~mime:"text/markdown")) in
  let revision = { Published.revision=number; title="report"; summary="fixture";
    format=Published.Markdown; author="keeper"; created_at=published_at; body;
    task_id=None; goal_id=None } in
  match get (Catalog.reports_of_json (`Assoc ["artifacts", `List
    [Published.summary_to_json ~id revision]; "diagnostics", `List []])) with
  | [Catalog.Report report], [] -> report
  | ([Catalog.Mcp _] | [] | _ :: _ :: _), _ | [_], _ :: _ -> fail "fixture report"

let confirmation ?(checked=true) ?sha (report : Catalog.report) =
  Check.of_json (`Assoc ["id", `String report.id;
    "revision", `Int report.revision.revision;
    "body_sha256", `String (match sha with Some sha -> sha | None -> report.revision.body.sha256);
    "checked", `Bool checked; "change_id", `String ("check-" ^ String.make 32 'a');
    "changed_by", `String "dashboard-human"; "changed_at", `String published_at]) |> get

let inventory ?(diagnostics=[]) checks =
  Checks.of_json ~received_at:42. (`Assoc
    ["checks", `List (List.map Check.to_json checks); "diagnostics", `List diagnostics]) |> get

let begin_read reading = match Fetched.refresh ~equal:Unit.equal reading ~key:() with
  | Started (reading, request) -> reading, request
  | Already_loading -> fail "refresh must allocate a new request"
let settle reading request result = Fetched.complete ~equal:Unit.equal reading request result
let ready inventory = let reading, request = begin_read Fetched.initial in
  settle reading request (Ok inventory)
let unknown = function Checks.Unknown _ -> true | Known _ -> false
let count ?(complete=true) entries reading =
  Checks.unchecked_on_day ~reports_complete:complete ~day ~entries reading

let exact_revision () =
  let first = report "same bytes" and second = report ~number:2 "same bytes" in
  let checked = confirmation first in
  let reading = ready (inventory [checked]) in
  (match Checks.resolve reading first with
   | Known (Some actual) -> check string "shared actor retained" "dashboard-human" actual.changed_by
   | Known None | Unknown _ -> fail "old revision lost confirmation");
  check bool "new revision absent despite same bytes" true
    (Checks.resolve reading second = Known None);
  check (option int) "new revision is unchecked" (Some 1) (count [Catalog.Report second] reading);
  let unchecked = ready (inventory [confirmation ~checked:false first]) in
  check (option int) "explicit uncheck counted" (Some 1) (count [Catalog.Report first] unchecked);
  check (option int) "checked exact revision excluded" (Some 0) (count [Catalog.Report first] reading)

let uncertain_inventory () =
  let report = report "body" in
  let entries = [Catalog.Report report] in
  let partial = ready (inventory ~diagnostics:[`Assoc
    ["file", `String "damaged.json"; "error", `String "invalid record"]] []) in
  let mismatch = ready (inventory [confirmation ~sha:(String.make 64 '0') report]) in
  List.iter (fun reading ->
    check bool "no invented state" true (unknown (Checks.resolve reading report));
    check (option int) "no invented count" None (count entries reading))
    [Fetched.initial; partial; mismatch];
  check (option int) "empty unknown inventory stays unknown" None (count [] Fetched.initial);
  check (option int) "complete empty inventory is zero" (Some 0) (count [] (ready (inventory [])));
  check (option int) "incomplete reports cannot establish count" None
    (count ~complete:false entries (ready (inventory [])))

let late_replies () =
  let report = report "body" in
  let unchecked = inventory [] and checked = inventory [confirmation report] in
  let reading = ready checked in
  let reading, old = begin_read reading in
  check bool "refresh is unknown pending" true (unknown (Checks.resolve reading report));
  let reading, current = begin_read reading in
  let reading = settle reading old (Ok unchecked) in
  check bool "superseded completion cannot settle replacement" true (Fetched.in_flight reading);
  let reading = settle reading current (Error "403") in
  check bool "failed refresh cannot certify cached check" true (unknown (Checks.resolve reading report));
  let reading, pending = begin_read reading in
  let suspended = settle (Fetched.suspend reading) pending (Ok unchecked) in
  check bool "suspended completion stays unknown" true (unknown (Checks.resolve suspended report));
  let reading, pending = begin_read (Fetched.clear reading) in
  let cleared = settle (Fetched.clear reading) pending (Ok checked) in
  check bool "withdrawn workspace completion cannot restore check" true
    (unknown (Checks.resolve cleared report))

let source_completeness () =
  let report = Catalog.Report (report "body") in
  let reading = ready (inventory []) in
  let list = get (Catalog.combine (Error "MCP unavailable") (Ok ([report], []))) in
  check (option int) "MCP failure does not corrupt report count" (Some 1)
    (count ~complete:list.reports_complete list.entries reading);
  let list = get (Catalog.combine (Ok ([], `Complete)) (Error "report inventory failed")) in
  check (option int) "report refusal is unknown, not empty" None
    (count ~complete:list.reports_complete list.entries reading);
  let list = get (Catalog.combine (Ok ([], `Complete)) (Ok ([report], ["unreadable report"]))) in
  check (option int) "partial report inventory is unknown" None
    (count ~complete:list.reports_complete list.entries reading)

let strict_inventory () =
  let check = confirmation (report "body") |> Check.to_json in
  let refused json = match Checks.of_json ~received_at:42. json with
    | Error _ -> () | Ok _ -> fail "untrusted inventory admitted" in
  List.iter refused
    [`Assoc ["checks", `List [check;check]; "diagnostics", `List []];
     `Assoc ["checks", `List []; "checks", `List []; "diagnostics", `List []];
     `Assoc ["checks", `List []; "diagnostics", `List []; "extra", `Null];
     `Assoc ["checks", `List []; "diagnostics", `List [`Assoc ["file", `String "broken"]]]]

let () = run "Shared artifact confirmation reads"
  ["state", [test_case "exact revision and explicit uncheck" `Quick exact_revision;
    test_case "uncertain and partial inventories" `Quick uncertain_inventory;
    test_case "superseded and withdrawn read replies" `Quick late_replies;
    test_case "independent source completeness" `Quick source_completeness;
    test_case "strict shared inventory" `Quick strict_inventory]]
