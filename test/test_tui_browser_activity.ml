module A = Masc_tui_browser_activity
module R = Masc_tui_runtime_config_receipt
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let some = function Some value -> value | None -> Alcotest.fail "request refused"
let rejected = function Error _ -> () | Ok _ -> Alcotest.fail "unexpectedly admitted"
let owner ?(lane=Browser_lane.Lane_name.Automation) workspace = A.{workspace=(workspace,workspace ^ "/.masc");lane}
let source = "# operator note\n[browser.automation]\n# browser paths\ngeckodriver = \"/fixture/driver\"\nbinary = \"/fixture/browser\"\nenabled = true\n\n[browser.live]\nenabled = true\n\n[providers.extra]\nvalue = \"keep\"\n"
let off = "# operator note\n[browser.automation]\n# browser paths\ngeckodriver = \"/fixture/driver\"\nbinary = \"/fixture/browser\"\nenabled = false\n\n[browser.live]\nenabled = true\n\n[providers.extra]\nvalue = \"keep\"\n"
let doc ?(path="/workspace/runtime.toml") ?(revision="original") source_text =
  {Masc_tui_runtime_config_edit.path;source_text;source_revision=revision}
let read ?(generation=1) document session =
  let pending,request=A.start_read ~generation session |> some in
  A.finish_read request (Ok document) pending
let loaded ?(lane=Browser_lane.Lane_name.Automation) document = read document (A.create (owner ~lane "A"))
let receipt ?(durability=R.Durable) ?(registry=R.Exact_output_registry_applied R.Targets_runtime_bindings) () = R.{
  source_revision="saved";order="9";durability;lock_warnings=[];
  application={operation="raw";routing_status=Routing_applied;routing_requires_restart=false;routing_applied_at=Not_applied;
    keeper_status=Keeper_not_configured;keeper_requires_restart=false;keeper_applied_at=Not_applied;
    keeper_configured_count=0;keeper_pending_keys=[];keeper_applied_keys=[];keeper_preempted_keys=[];
    skills=Skill_unchanged {input_source_revision="saved";snapshot_revision="snapshot";catalog_revision="catalog";config_state=Configured};
    exact_output_registry=registry}}
let same expected actual = Alcotest.(check string) "source" expected actual
let has needle lines = List.exists (fun line ->
  let n=String.length needle in
  let rec scan i = i+n<=String.length line && (String.sub line i n=needle || scan (i+1)) in scan 0) lines
let shows needle session = Alcotest.(check bool) needle true (has needle (A.lines session))

let draft_and_save () =
  let session=loaded (doc source) in
  rejected (A.start_save ~generation:2 session);
  let session=A.toggle session in
  shows "Activity draft: Off" session;
  let pending,request,write=A.start_save ~generation:2 session |> ok in
  same off write.source_text; same "original" write.expected_source_revision; same "/workspace/runtime.toml" write.expected_source_path;
  Alcotest.(check bool) "busy" true (A.busy pending);
  rejected (A.start_save ~generation:3 pending);
  shows "Activity draft: Off" (A.toggle pending);
  let session=A.finish_save request (A.Saved (receipt ())) pending in
  shows "File saved" session;
  rejected (A.start_save ~generation:3 session);
  let session=read ~generation:4 (doc ~revision:"saved" off) session in
  rejected (A.start_save ~generation:5 session);
  let _,_,write=A.start_save ~generation:6 (A.toggle session) |> ok in
  same source write.source_text; same "saved" write.expected_source_revision

let conflict_reapply () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let current=String.concat "" ["# someone else's change\n";source;"new_setting = 9\n"] in
  let session=A.finish_save request (A.Conflict (doc ~revision:"concurrent" current)) pending in
  shows "Activity draft: Off" session; rejected (A.start_save ~generation:3 session);
  let _,_,write=A.start_save ~generation:4 (A.reapply session) |> ok in
  same ("# someone else's change\n" ^ off ^ "new_setting = 9\n") write.source_text;
  same "concurrent" write.expected_source_revision

let fresh_read_keeps_draft () =
  let session=A.toggle (loaded (doc source)) in
  let current=doc ~revision:"new" (source ^ "other = true\n") in
  let session=read ~generation:2 current session in
  shows "Activity draft: Off" session; shows "File changed" session;
  rejected (A.start_save ~generation:3 session);
  let discarded=A.discard session in
  shows "Activity draft: On" discarded;
  rejected (A.start_save ~generation:4 discarded)

let clean_read_follows_changed_flag () =
  let current=off ^ "concurrent = 7\n" in
  let session=loaded (doc source) |> A.suspend |> read ~generation:2 (doc ~revision:"fresh" current) in
  shows "Activity draft: Off" session;
  Alcotest.(check bool) "clean draft has no conflict" false (has "File changed" (A.lines session));
  let _,_,write=A.start_save ~generation:3 (A.toggle session) |> ok in
  same "fresh" write.expected_source_revision;
  same (source ^ "concurrent = 7\n") write.source_text

let clean_read_follows_unrelated_edit () =
  let current=source ^ "concurrent = 9\n" in
  let session=loaded (doc source) |> read ~generation:2 (doc ~revision:"fresh" current) in
  let _,_,write=A.start_save ~generation:3 (A.toggle session) |> ok in
  same "fresh" write.expected_source_revision;
  same (off ^ "concurrent = 9\n") write.source_text

let durable_save_follows_next_file_without_losing_receipt () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let session=A.finish_save request (A.Saved (receipt ~registry:(R.Exact_output_registry_kept {reason="registry kept"}) ())) pending in
  let session=read ~generation:3 (doc ~revision:"later-writer" source) session in
  shows "Activity draft: On" session; shows "registry kept" session;
  let _,_,write=A.start_save ~generation:4 (A.toggle session) |> ok in
  same "later-writer" write.expected_source_revision; same off write.source_text

let uncertain_drafts_require_explicit_reapply () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  List.iter (fun session ->
    let reread=read ~generation:3 (doc ~revision:"observed" off) session in
    shows "Activity draft: Off" reread; shows "Based on revision: original" reread;
    shows "File changed" reread; rejected (A.start_save ~generation:4 reread);
    rejected (A.start_save ~generation:5 (A.reapply reread)))
    [A.finish_save request (A.Unconfirmed "connection lost") pending;
     A.finish_save request (A.Saved (receipt ~durability:R.Durability_unconfirmed ())) pending;
     A.suspend pending]

(* An operator note on an enabled flag stays on that line when the flag is
   toggled in an ordinary Browser table. *)
let enabled_comment_survives_toggle () =
  List.iter (fun lane ->
    let label=Browser_lane.Lane_name.to_wire lane in
    let source=Printf.sprintf "[browser.%s]\nenabled = true # temporary during rollout\n" label in
    let _,_,write=A.start_save ~generation:2 (A.toggle (loaded ~lane (doc source))) |> ok in
    same (Printf.sprintf "[browser.%s]\nenabled = false # temporary during rollout\n" label) write.source_text)
    Browser_lane.Lane_name.all

let clean_draft_does_not_adopt_different_path () =
  let session=loaded (doc source) |> read ~generation:2 (doc ~path:"/new/runtime.toml" ~revision:"fresh" off) in
  shows "Activity draft: On" session; shows "Based on revision: original" session;
  let attempted=A.toggle session in
  shows "file path changed" attempted; rejected (A.start_save ~generation:3 attempted);
  let _,_,write=A.start_save ~generation:4 (A.discard session |> A.toggle) |> ok in
  same "fresh" write.expected_source_revision; same source write.source_text

let flat_paths_preserve_operator_comments () =
  let source = "[browser] # deployment\n# managed driver\n  'geckodriver' = '/fixture/driver' # pinned driver\n# custom browser\nbinary = '/fixture/browser' # operator build\nstagehand = { chrome = '/fixture/chrome', extension = '/fixture/extension' }\n" in
  let _,_,write=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let lines=String.split_on_char '\n' write.source_text in
  List.iter (fun comment -> Alcotest.(check bool) comment true (has comment lines))
    ["# deployment";"# managed driver";"# pinned driver";"# custom browser";"# operator build"];
  let config=Otoml.Parser.from_string_result write.source_text |> ok |> Browser_configuration.parse |> ok in
  Alcotest.(check bool) "only Automation activity changes" true
    (not config.automation_enabled && config.live_enabled && config.stagehand_enabled);
  Alcotest.(check bool) "backend paths remain configured" true
    (config.automation = Some {Browser_configuration.driver="/fixture/driver";binary=Some "/fixture/browser"});
  let before_comment needle key =
    let rec adjacent = function
      | comment :: assignment :: _ when String.trim comment=needle -> has key [assignment]
      | _ :: rest -> adjacent rest
      | [] -> false in
    Alcotest.(check bool) "operator comment remains beside its setting" true (adjacent lines) in
  before_comment "# managed driver" "geckodriver";
  before_comment "# custom browser" "binary";
  let _,_,again=A.start_save ~generation:3 (A.toggle (loaded (doc write.source_text))) |> ok in
  let config=Otoml.Parser.from_string_result again.source_text |> ok |> Browser_configuration.parse |> ok in
  Alcotest.(check bool) "migrated source can be toggled back on" true config.automation_enabled;
  Alcotest.(check bool) "dotted table is not redeclared on a later toggle" false
    (has "[browser.automation]" (String.split_on_char '\n' again.source_text));
  Alcotest.(check bool) "repeated toggle retains inline comment" true
    (has "# pinned driver" (String.split_on_char '\n' again.source_text))

let backend_flags_and_flat_paths () =
  let flat = "# paths\n[browser]\ngeckodriver = '/fixture/driver'\nbinary = '/fixture/browser'\nstagehand = { chrome = '/fixture/chrome', extension = '/fixture/extension' }\n\n[browser.live]\nenabled = false\n" in
  let _,_,write=A.start_save ~generation:2 (A.toggle (loaded (doc flat))) |> ok in
  let toml=Otoml.Parser.from_string_result write.source_text |> ok in
  let config=Browser_configuration.parse toml |> ok in
  Alcotest.(check bool) "automation changed while live stays off and stagehand on" true
    (not config.automation_enabled && not config.live_enabled && config.stagehand_enabled);
  Alcotest.(check bool) "root driver moved" true
    (Otoml.find_opt toml Fun.id ["browser";"geckodriver"] = None);
  Alcotest.(check (option string)) "driver remains configured" (Some "/fixture/driver")
    (Option.map (fun (a : Browser_configuration.automation) -> a.driver) config.automation);
  Alcotest.(check bool) "stagehand inline configuration retained" true (Option.is_some config.stagehand);
  List.iter (fun lane ->
    let _,_,write=A.start_save ~generation:2 (A.toggle (loaded ~lane (doc "[runtime]\nvalue = 1\n"))) |> ok in
    let config=Otoml.Parser.from_string_result write.source_text |> ok |> Browser_configuration.parse |> ok in
    let actual=match lane with Browser_lane.Lane_name.Live -> config.live_enabled
      | Automation -> config.automation_enabled | Stagehand -> config.stagehand_enabled in
    Alcotest.(check bool) "absent backend can retain explicit off intent" false actual)
    Browser_lane.Lane_name.all

(* CR5408758179: root dotted keys spell the same flat Browser paths as a
   [browser] table. They move under automation like the table form instead of
   leaving a root path beside the nested flag, which the parser refuses. *)
let dotted_root_paths () =
  List.iter (fun (label, dotted) ->
    let source = "# deployment paths\n" ^ dotted
      ^ "\n[providers.extra]\nvalue = \"keep\"\n" in
    let _,_,write=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
    let lines=String.split_on_char '\n' write.source_text in
    let toml=Otoml.Parser.from_string_result write.source_text |> ok in
    let config=Browser_configuration.parse toml |> ok in
    Alcotest.(check bool) (label ^ ": only Automation activity changes") true
      (not config.automation_enabled && config.live_enabled && config.stagehand_enabled);
    Alcotest.(check bool) (label ^ ": paths remain configured") true
      (config.automation = Some {Browser_configuration.driver="/fixture/driver";binary=Some "/fixture/browser"});
    Alcotest.(check bool) (label ^ ": root driver moved") true
      (Otoml.find_opt toml Fun.id ["browser";"geckodriver"] = None);
    List.iter (fun comment -> Alcotest.(check bool) (label ^ ": " ^ comment) true (has comment lines))
      ["# deployment paths";"# pinned driver";"value = \"keep\""];
    Alcotest.(check bool) (label ^ ": no table header added") false (has "[browser" lines);
    let _,_,again=A.start_save ~generation:3 (A.toggle (loaded (doc write.source_text))) |> ok in
    let config=Otoml.Parser.from_string_result again.source_text |> ok |> Browser_configuration.parse |> ok in
    Alcotest.(check bool) (label ^ ": toggled back on") true config.automation_enabled;
    Alcotest.(check bool) (label ^ ": still no table header") false
      (has "[browser" (String.split_on_char '\n' again.source_text)))
    [ "bare dotted keys",
      "browser.geckodriver = '/fixture/driver' # pinned driver\nbrowser.binary = '/fixture/browser'\n";
      "quoted dotted keys",
      "\"browser\" . 'geckodriver' = '/fixture/driver' # pinned driver\n  browser.\"binary\" = '/fixture/browser'\n" ]

let unavailable () =
  let initial=A.create (owner "A") in
  rejected (A.start_save ~generation:1 initial);
  let pending,request=A.start_read ~generation:1 initial |> some in
  let failed=A.finish_read request (Error "offline") pending in
  shows "offline" failed; rejected (A.start_save ~generation:2 (A.toggle failed));
  List.iter (fun text -> let session=loaded (doc text) |> A.toggle in
    rejected (A.start_save ~generation:2 session))
    ["[bad";"[browser.automation]\nenabled=\"wrong\"\n";"[browser.stagehand]\nchrome=\"relative\"\n"]

let workspace_roundtrip () =
  let pending,old_read=A.start_read ~generation:2 (A.toggle (loaded (doc source))) |> some in
  let suspended=A.suspend pending in
  let pending,new_read=A.start_read ~generation:3 suspended |> some in
  let ignored=A.finish_read old_read (Ok (doc ~revision:"old" off)) pending in
  Alcotest.(check bool) "old read ignored" true (A.matches new_read ignored);
  let session=A.finish_read new_read (Ok (doc source)) ignored in
  shows "Activity draft: Off" session;
  let pending,old_save,_=A.start_save ~generation:4 session |> ok in
  let pending,new_read=A.start_read ~generation:5 (A.suspend pending) |> some in
  let ignored=A.finish_save old_save (A.Saved (receipt ())) pending in
  Alcotest.(check bool) "old save ignored" true (A.matches new_read ignored);
  let other=A.create (owner "B") in
  Alcotest.(check bool) "workspace identity differs" false (A.same_owner (A.owner other) (A.owner ignored));
  shows "Current file: unverified" (A.finish_read new_read (Ok (doc source)) other)

let ambiguous_write_and_refusal () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let unanswered=A.finish_save request (A.Unconfirmed "connection lost") pending in
  shows "Activity draft: Off" unanswered; rejected (A.start_save ~generation:3 unanswered);
  let uncertain=A.finish_save request (A.Saved (receipt ~durability:R.Durability_unconfirmed ())) pending in
  shows "Activity draft: Off" uncertain; rejected (A.start_save ~generation:3 uncertain);
  let reread=read ~generation:4 (doc ~revision:"saved" off) uncertain in
  shows "File changed" reread;
  rejected (A.start_save ~generation:5 reread);
  rejected (A.start_save ~generation:6 (A.reapply reread));
  let refused=A.finish_save request (A.Refused "preview failed") pending in
  shows "preview failed" refused;
  let _,_,write=A.start_save ~generation:3 refused |> ok in same "original" write.expected_source_revision

let changed_path () =
  let session=A.toggle (loaded (doc source)) |> read ~generation:2 (doc ~path:"/new/runtime.toml" source) in
  rejected (A.start_save ~generation:3 (A.reapply session));
  let _,_,write=A.start_save ~generation:4 (A.toggle (A.discard session)) |> ok in
  same off write.source_text

(* CR5410456308: a 409 naming another path with the same bytes and revision
   is another document. The panel says so, points to x rather than u, and a
   discard starts over on the new file. *)
let same_bytes_conflict_on_another_path () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let session=A.finish_save request (A.Conflict (doc ~path:"/new/runtime.toml" source)) pending in
  shows "file path changed" session;
  shows "x discards this draft" session;
  Alcotest.(check bool) "no reapply promise across files" false
    (has "u reapplies" (A.lines session));
  rejected (A.start_save ~generation:3 session);
  let _,_,write=A.start_save ~generation:4 (A.toggle (A.discard session)) |> ok in
  same "/new/runtime.toml" write.expected_source_path

let table_shapes () =
  let quoted="[browser.\"automation\"] # header\ngeckodriver = '/fixture/driver'\n" in
  let _,_,write=A.start_save ~generation:2 (A.toggle (loaded (doc quoted))) |> ok in
  shows "Activity draft: Off" (loaded (doc write.source_text));
  Alcotest.(check bool) "header retained" true (String.starts_with ~prefix:quoted write.source_text);
  let fake="note = '''\n[browser.automation]\n'''\n[browser]\nautomation = { geckodriver = '/fixture/driver' }\n" in
  let session=A.toggle (loaded (doc fake)) in
  shows "Inline or dotted" session; rejected (A.start_save ~generation:2 session)

let receipt_keeps_application_failure () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let session=A.finish_save request (A.Saved (receipt ~registry:(R.Exact_output_registry_kept {reason="registry refused"}) ())) pending in
  shows "registry refused" session;
  let session=read ~generation:3 (doc ~revision:"saved" off) session in
  shows "registry refused" session; shows "Current file: Off" session

let live_guidance () =
  let lines = A.lines (loaded ~lane:Browser_lane.Lane_name.Live (doc source)) in
  Alcotest.(check bool) "Live does not promise server session controls" false
    (has "Server session status and close remain available" lines);
  shows "Server session status and close remain available" (loaded (doc source));
  shows "Server session status and close remain available" (loaded ~lane:Browser_lane.Lane_name.Stagehand (doc source))

let () = Alcotest.run "Browser activity draft and save" ["operator flow",List.map (fun (name,f)->Alcotest.test_case name `Quick f)
  ["Live guidance respects client-owned sessions",live_guidance;
   "explicit save preserves paths, other backend and source",draft_and_save;
   "conflict reapplies activity only",conflict_reapply;
   "fresh read retains and discard resets",fresh_read_keeps_draft;
   "clean draft follows external activity and workspace return",clean_read_follows_changed_flag;
   "clean draft preserves latest unrelated edits",clean_read_follows_unrelated_edit;
   "durable draft follows next file while receipt stays",durable_save_follows_next_file_without_losing_receipt;
   "uncertain drafts need explicit reapply",uncertain_drafts_require_explicit_reapply;
   "enabled flag keeps its inline comment",enabled_comment_survives_toggle;
   "clean draft keeps changed-path boundary",clean_draft_does_not_adopt_different_path;
   "backend flags and flat automation migration",backend_flags_and_flat_paths;
   "flat paths retain operator comments",flat_paths_preserve_operator_comments;
   "root dotted paths migrate like the browser table",dotted_root_paths;
   "unavailable and malformed input",unavailable;
   "workspace roundtrip ignores old callbacks",workspace_roundtrip;
   "unconfirmed write and preview refusal",ambiguous_write_and_refusal;
   "changed file path needs discard",changed_path;
   "same bytes on another path need discard",same_bytes_conflict_on_another_path;
   "quoted and multiline table shapes",table_shapes;
   "stored setting does not hide application failure",receipt_keeps_application_failure]]
