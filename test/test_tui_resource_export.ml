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
  test_case "exclusive private exact-byte save" `Quick exclusive_save]]
