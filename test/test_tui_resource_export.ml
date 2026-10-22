open Alcotest
module Export = Masc_tui_resource_export
module Published = Masc.Published_artifact
module Catalog = Masc_tui_resource_catalog
let get = function Ok value -> value | Error detail -> fail detail
let refused = function Error _ -> () | Ok _ -> fail "unexpected success"
let id = "artifact-0123456789abcdef0123456789abcdef"
let source = "# 원문 🎵\r\n\t값\r\n"
let document ?(format=Published.Markdown) ?(number=3) source =
  let body = get (Result.map_error Tool_output.make_error_to_string
    (Tool_output.make_artifact_ref ~sha256:Digestif.SHA256.(to_hex (digest_string source))
      ~bytes:(String.length source) ~preview:source ~mime:(Published.media_type format))) in
  let revision = { Published.revision=number; title="report"; summary="original";
    format; author="keeper"; created_at="2026-10-22T00:00:00Z"; body;
    task_id=None; goal_id=None } in
  let json = `Assoc ["artifacts", `List [Published.summary_to_json ~id revision];
    "diagnostics", `List []] in
  match get (Catalog.reports_of_json json) with
  | [Catalog.Report report], [] -> report, get (Export.create ~report ~source)
  | ([Catalog.Mcp _] | [] | _ :: _ :: _), _
  | [Catalog.Report _], _ :: _ -> fail "report fixture rejected"

let exact_source_and_link () =
  check string "path whitespace preserved" " /tmp/report  drafts/원문.md "
    (get (Export.path_input " /tmp/report  drafts/원문.md "));
  refused (Export.path_input "/tmp/report\nother.md");
  let report, original = document source in
  refused (Export.create ~report ~source:(source ^ " "));
  refused (Export.create ~report ~source:(String.mapi (fun i c -> if i=0 then '!' else c) source));
  let _, other = document ~number:4 source in
  check bool "different revision has different ownership" false (Export.same original other);
  let url = Uri.of_string (Export.dashboard_url ~host:"127.0.0.1" ~port:8935 original) in
  check (option string) "no userinfo" None (Uri.userinfo url);
  let fragment = Uri.of_string (Option.get (Uri.fragment url)) in
  check (option string) "workspace artifact surface" (Some "artifacts") (Uri.get_query_param fragment "section");
  check (option string) "original artifact" (Some id) (Uri.get_query_param fragment "artifact");
  check (option string) "explicit historical revision" (Some "3") (Uri.get_query_param fragment "revision")

(* Health observes identity without an admin receipt; the following report
   inventory still needs its original workspace receipt. Exercise the shared
   transport and real catalog decoder, including a foreign identity reading. *)
let nested_health_preserves_report_admission () = Eio_main.run (fun _ ->
  let module Read = Masc_tui_workspace_read in
  let module Decode = Masc.Tui_decode in
  let base = Unix.realpath (Filename.get_temp_dir_name ()) in
  let foreign = Filename.concat base "foreign-report-workspace" in
  let packet base ready = `Assoc [
    "paths", `Assoc ["effective_base_path", `String base;
      "effective_masc_root", `String (Filename.concat base ".masc")];
    "startup", `Assoc ["state_ready", `Bool ready]] in
  let expected = get (Decode.decode_server_identity (packet base true)) in
  let report, _ = document source in
  let inventory = `Assoc ["artifacts", `List [Published.summary_to_json ~id report.revision];
    "diagnostics", `List []] in
  let health_packet = ref (packet base true) in
  let receipts = ref [Masc.Workspace.read_precondition_admission_header] in
  let seen = ref [] in
  let host = "127.0.0.1" and port = 8935 in
  let send ~path ~headers:_ =
    seen := path :: !seen;
    let health = String.equal (Uri.path (Uri.of_string path)) "/health" in
    Ok Masc_http_client.{status=200; headers=(if health then [] else !receipts);
      body=Yojson.Safe.to_string (if health then !health_packet else inventory)} in
  let read path = Read.read_json ~kept_reads:(Masc_tui_kept_reads.create ())
      ~address_of:(fun ~path -> path) ~send ~decode:Decode.decode_json_response_body ~host ~port ~path in
  let identity () =
    Read.without_binding (fun () -> read "/health")
    |> fun result -> Result.bind result Decode.decode_server_identity in
  let matches = Masc_tui_types.server_workspace_matches ~expected:(Some expected) in
  let bound f = Read.with_binding ~host ~port ~expected ~proof:Request_precondition f in
  let reports () = Result.bind (read "/api/v1/published-artifacts") Catalog.reports_of_json in
  bound (fun () ->
    check bool "receiptless health confirms the captured workspace" true (matches (identity ()));
    let entries, notes = get (reports ()) in
    check int "admitted original report remains available" 1 (List.length entries);
    check int "no invented catalog diagnostics" 0 (List.length notes);
    check bool "catalog retains the pinned report identity" true
      (Catalog.owns_key (List.hd entries) (Catalog.Report_revision report));
    let query = Uri.query (Uri.of_string (List.hd !seen)) in
    check (option (list string)) "report GET retains the original base" (Some [base])
      (List.assoc_opt "expected_base_path" query);
    check (option (list string)) "report GET retains the original root"
      (Some [Filename.concat base ".masc"]) (List.assoc_opt "expected_masc_root" query);
    receipts := [];
    refused (reports ());
    receipts := [Masc.Workspace.read_precondition_admission_header];
    health_packet := packet foreign true;
    let observed = identity () in
    check bool "foreign identity stays a successful observation" true (Result.is_ok observed);
    check bool "foreign identity still refuses the captured workspace" false (matches observed);
    check bool "foreign identity is not replaced by the expected identity" true
      (Decode.Canonical_path.equal (get observed).sid_base_path
        (Decode.Canonical_path.of_path foreign));
    health_packet := packet base false;
    check bool "booting workspace still refuses authority" false (matches (identity ())));
  health_packet := packet foreign true;
  let observed = identity () in
  check bool "unbound health retains the actual foreign observation" true (Result.is_ok observed);
  check bool "unbound foreign observation still fails admission" false (matches observed);
  check bool "health never inherits report workspace query preconditions" true
    (List.for_all (fun path ->
      let uri = Uri.of_string path in
      not (String.equal (Uri.path uri) "/health") || Uri.query uri = []) !seen))

let read path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let exclusive_save () =
  let root = Filename.temp_file "masc-report-export-" "" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () ->
    Array.iter (fun name -> Sys.remove (Filename.concat root name)) (Sys.readdir root);
    Unix.rmdir root) (fun () ->
    Eio_main.run (fun env ->
      let _, original = document source in
      let path = Filename.concat root "선택한 원문.md" in
      ignore (get (Export.save ~fs:env#fs ~path original));
      check string "exact UTF8 and CRLF on disk" source (read path);
      check int "private mode" 0o600 ((Unix.stat path).Unix.st_perm land 0o777);
      let _, changed = document ~number:4 "other revision" in
      refused (Export.save ~fs:env#fs ~path changed);
      check string "existing file survives" source (read path);
      let link = Filename.concat root "alias.md" in
      Unix.symlink path link;
      refused (Export.save ~fs:env#fs ~path:link changed);
      check string "symlink target survives" source (read path);
      refused (Export.save ~fs:env#fs ~path:(Filename.concat root "missing/report.md") original)))

let () = run "original report export" ["source and filesystem", [
  test_case "integrity and pinned deep link" `Quick exact_source_and_link;
  test_case "exclusive private exact-byte save" `Quick exclusive_save;
  test_case "health observation restores report admission" `Quick nested_health_preserves_report_admission]]
