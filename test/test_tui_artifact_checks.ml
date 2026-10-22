open Alcotest
module Catalog = Masc_tui_resource_catalog
module Checks = Masc_tui_artifact_checks
module Check = Masc.Published_artifact_check
module Published = Masc.Published_artifact
module Fetched = Masc_tui_fetched
module Action = Masc_tui_artifact_check_action
module Updates = Masc_tui_resources_updates
module Types = Masc_tui_types
module Routes = Server_routes_http_routes_published_artifacts

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

let identity base_path : Masc.Tui_decode.server_identity =
  let canonical = Masc.Tui_decode.Canonical_path.of_path in
  {sid_version="test";sid_binary_commit="test";sid_binary_commit_age_s=None;
   sid_base_path=canonical base_path;sid_masc_root=canonical (Filename.concat base_path ".masc");
   sid_executable_in_worktree=None;sid_state_ready=Some true;sid_uptime=None;
   sid_sse_clients=None;sid_gc=None;sid_scheduler=None}

let refused = function Error _ -> () | Ok _ -> fail "change admitted without its precondition"

let explicit_target () =
  let report = report "body" and next = report ~number:2 "body" in
  refused (Action.prepare Fetched.initial report);
  let first = get (Action.prepare (ready (inventory [])) report) in
  let previous = confirmation report in
  let undo = get (Action.prepare (ready (inventory [previous])) report) in
  check bool "distinct explicit request owners" false (Action.same_request first undo);
  let json = Action.body ~expected_workspace:(identity "/workspace") undo in
  let fields = match json with `Assoc fields -> fields | _ -> fail "request object" in
  let operation = get (Check.request_of_json
    (`Assoc (List.remove_assoc "expected_workspace" fields))) in
  check bool "toggle reverses observed state" true (operation.state=Check.Unchecked);
  check (option string) "toggle carries actual CAS identity" (Some previous.change_id)
    operation.expected_change_id;
  check string "toggle pins report digest" report.revision.body.sha256 operation.target.body_sha256;
  let response check = `Assoc ["check", Check.to_json check] in
  ignore (get (Action.decode_response first (response previous)));
  refused (Action.decode_response first (response (confirmation ~checked:false report)));
  refused (Action.decode_response first (response (confirmation next)));
  refused (Action.decode_response undo (response (confirmation ~checked:false report)));
  let saved = get (Check.create ~actor:"tui-human" ~at:published_at
    ~change_id:("check-" ^ String.make 32 'b') operation) in
  ignore (get (Action.decode_response undo (response saved)));
  refused (Action.decode_response first (`Assoc ["check",Check.to_json previous;"extra",`Null]))

let write_ownership () =
  let report = report "body" in
  let state = Types.create_state ~workspace:"confirmations" ~port:0 ~refresh_interval:0. () in
  state.artifact_checks <- ready (inventory []);
  refused (Updates.begin_check state ~report);
  state.server_identity <- Some (identity "/workspace");
  let first = get (Updates.begin_check state ~report) in
  check bool "pending change withdraws confirmation authority" true
    (unknown (Types.resource_check_status state report));
  refused (Updates.begin_check state ~report);
  (* A manual read can finish before the pending POST. It cannot restore
     confirmation authority or survive the write's settlement as fresh. *)
  let reading, read = begin_read state.artifact_checks in
  state.artifact_checks <- reading;
  Updates.checks_loaded state read (Ok (inventory []));
  check bool "early read cannot certify pending write" true
    (unknown (Types.resource_check_status state report));
  check bool "matching write consumes owner" true (Updates.check_changed state first);
  check bool "receipt does not optimistically confirm" true
    (unknown (Types.resource_check_status state report));
  refused (Updates.begin_check state ~report);
  check bool "duplicate completion has no reread demand" false (Updates.check_changed state first);
  state.artifact_checks <- ready (inventory []);
  let second = get (Updates.begin_check state ~report) in
  check bool "late write cannot settle replacement" false (Updates.check_changed state first);
  check bool "replacement stays pending" true (Option.is_some state.artifact_check_pending);
  Types.suspend_workspace_readings state;
  check bool "withdrawn write cannot settle new view" false (Updates.check_changed state second)

let workspace_write_binding () =
  let base = Filename.temp_file "artifact-check-한글 # %" "" in
  Sys.remove base; Unix.mkdir base 0o700;
  let root = Filename.concat base ".masc" in
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> Unix.rmdir root; Unix.rmdir base) (fun () ->
    let config = Masc.Workspace.default_config base in
    let request = get (Action.prepare (ready (inventory [])) (report "body")) in
    let json = Action.body ~expected_workspace:(identity base) request in
    let decode json = Routes.decode_check_request ~config ~body:(Yojson.Safe.to_string json) in
    let valid = match decode json with Ok request -> request
      | Error _ -> fail "matching workspace refused" in
    check bool "matching workspace admits strict operation" true (valid.state=Check.Checked);
    let fields = match json with `Assoc fields -> fields | _ -> fail "request object" in
    let refusal expected json = match decode json with
      | Error (_, status) -> check int "HTTP refusal" expected (Httpun.Status.to_code status)
      | Ok _ -> fail "wrong workspace or malformed operation admitted" in
    refusal 409 (Action.body ~expected_workspace:(identity (base ^ "-foreign")) request);
    refusal 400 (`Assoc (("expected_workspace", `Null) :: List.remove_assoc "expected_workspace" fields));
    refusal 400 (`Assoc (("expected_workspace", `Null) :: fields));
    refusal 400 (`Assoc (("changed_by", `String "spoofed") :: fields));
    (* Dashboard's unbound operation keeps the same strict field contract. *)
    match decode (`Assoc (List.remove_assoc "expected_workspace" fields)) with
    | Ok _ -> () | Error _ -> fail "dashboard request contract changed")

let () = run "Shared artifact confirmation reads"
  ["state", [test_case "exact revision and explicit uncheck" `Quick exact_revision;
    test_case "uncertain and partial inventories" `Quick uncertain_inventory;
    test_case "superseded and withdrawn read replies" `Quick late_replies;
    test_case "independent source completeness" `Quick source_completeness;
    test_case "strict shared inventory" `Quick strict_inventory;
    test_case "explicit pinned toggle and receipt validation" `Quick explicit_target;
    test_case "write ownership and required reread" `Quick write_ownership;
    test_case "request-owned workspace write precondition" `Quick workspace_write_binding]]
