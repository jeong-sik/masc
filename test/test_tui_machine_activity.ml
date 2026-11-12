module A = Masc_tui_machine_activity
module R = Masc_tui_runtime_config_receipt
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let admitted = function
  | Ok value -> value
  | Error notice -> Alcotest.fail (Masc_tui_activity_notice.text ~ko:false notice)
let some = function Some value -> value | None -> Alcotest.fail "request refused"
let rejected = function Error _ -> () | Ok _ -> Alcotest.fail "unexpectedly admitted"
let owner ?(machine=Masc.Machine_lane.Msx) workspace = A.{workspace=(workspace,workspace ^ "/.masc");machine}
let source = "# operator note\n[machines.msx]\n# MSX activity\nenabled = true # retained operator note\n\n[machines.dos]\nenabled = false\n\n[providers.extra]\nvalue = \"keep\"\n"
let off = "# operator note\n[machines.msx]\n# MSX activity\nenabled = false # retained operator note\n\n[machines.dos]\nenabled = false\n\n[providers.extra]\nvalue = \"keep\"\n"
let doc ?(path="/workspace/runtime.toml") ?(revision="original") source_text =
  {Masc_tui_runtime_config_edit.path;source_text;source_revision=revision}
let read ?(generation=1) document session =
  let pending,request=A.start_read ~generation session |> some in
  A.finish_read request (Ok A.{document=Ok document;activity=Ok Machine_configuration.Enabled}) pending
let loaded ?(machine=Masc.Machine_lane.Msx) document = read document (A.create (owner ~machine "A"))
let receipt ?(durability=R.Durable) ?(registry=R.Exact_output_registry_applied R.Targets_runtime_bindings) () = R.{
  source_revision="saved";order="9";durability;lock_warnings=[];ignored_legacy_keys=[];
  application={operation="raw";routing_status=Routing_applied;routing_requires_restart=false;routing_applied_at=Not_applied;
    keeper_status=Keeper_not_configured;keeper_requires_restart=false;keeper_applied_at=Not_applied;
    keeper_configured_count=0;keeper_pending_keys=[];keeper_applied_keys=[];keeper_preempted_keys=[];
    skills=Skill_unchanged {input_source_revision="saved";snapshot_revision="snapshot";catalog_revision="catalog";config_state=Configured};
    exact_output_registry=registry}}
let same expected actual = Alcotest.(check string) "source" expected actual
let has needle lines = List.exists (fun line ->
  let n=String.length needle in
  let rec scan i = i+n<=String.length line && (String.sub line i n=needle || scan (i+1)) in scan 0) lines
let lines session = List.map Masc_tui_page_line.text (A.lines ~ko:false session)
let shows needle session = Alcotest.(check bool) needle true (has needle (lines session))

let draft_and_save () =
  let session=loaded (doc source) in
  rejected (A.start_save ~generation:2 session);
  let session=A.toggle session in
  shows "Activity draft: Off" session;
  let pending,request,write=A.start_save ~generation:2 session |> admitted in
  same off write.source_text; same "original" write.expected_source_revision; same "/workspace/runtime.toml" write.expected_source_path;
  Alcotest.(check bool) "busy" true (A.busy pending);
  rejected (A.start_save ~generation:3 pending);
  shows "Activity draft: Off" (A.toggle pending);
  let session=A.finish_save request (A.Saved (receipt ())) pending in
  shows "File saved" session;
  rejected (A.start_save ~generation:3 session);
  let session=read ~generation:4 (doc ~revision:"saved" off) session in
  rejected (A.start_save ~generation:5 session);
  let _,_,write=A.start_save ~generation:6 (A.toggle session) |> admitted in
  same source write.source_text; same "saved" write.expected_source_revision

let conflict_reapply () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> admitted in
  let current=String.concat "" ["# someone else's change\n";source;"new_setting = 9\n"] in
  let session=A.finish_save request (A.Conflict (doc ~revision:"concurrent" current)) pending in
  shows "Activity draft: Off" session; rejected (A.start_save ~generation:3 session);
  let _,_,write=A.start_save ~generation:4 (A.reapply session) |> admitted in
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
  Alcotest.(check bool) "clean draft has no conflict" false (has "File changed" (lines session));
  let _,_,write=A.start_save ~generation:3 (A.toggle session) |> admitted in
  same "fresh" write.expected_source_revision;
  same (source ^ "concurrent = 7\n") write.source_text

let clean_read_follows_unrelated_edit () =
  let current=source ^ "concurrent = 9\n" in
  let session=loaded (doc source) |> read ~generation:2 (doc ~revision:"fresh" current) in
  let _,_,write=A.start_save ~generation:3 (A.toggle session) |> admitted in
  same "fresh" write.expected_source_revision;
  same (off ^ "concurrent = 9\n") write.source_text

let durable_save_follows_next_file_without_losing_receipt () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> admitted in
  let session=A.finish_save request (A.Saved (receipt ~registry:(R.Exact_output_registry_kept {reason="registry kept"}) ())) pending in
  let session=read ~generation:3 (doc ~revision:"later-writer" source) session in
  shows "Activity draft: On" session; shows "registry kept" session;
  let _,_,write=A.start_save ~generation:4 (A.toggle session) |> admitted in
  same "later-writer" write.expected_source_revision; same off write.source_text

let uncertain_drafts_require_explicit_reapply () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> admitted in
  List.iter (fun session ->
    let reread=read ~generation:3 (doc ~revision:"observed" off) session in
    shows "Activity draft: Off" reread; shows "Based on revision: original" reread;
    shows "File changed" reread; rejected (A.start_save ~generation:4 reread);
    rejected (A.start_save ~generation:5 (A.reapply reread)))
    [A.finish_save request (A.Unconfirmed "connection lost") pending;
     A.finish_save request (A.Saved (receipt ~durability:(R.Durability_unconfirmed "fixture fsync uncertainty") ())) pending;
     A.suspend pending]

let clean_draft_does_not_adopt_different_path () =
  let session=loaded (doc source) |> read ~generation:2 (doc ~path:"/new/runtime.toml" ~revision:"fresh" off) in
  shows "Activity draft: On" session; shows "Based on revision: original" session;
  let attempted=A.toggle session in
  shows "file path changed" attempted; rejected (A.start_save ~generation:3 attempted);
  let _,_,write=A.start_save ~generation:4 (A.discard session |> A.toggle) |> admitted in
  same "fresh" write.expected_source_revision; same source write.source_text

let independent_machines () =
  List.iter (fun machine ->
    let initial=loaded ~machine (doc "[runtime]\nvalue = 1\n") in
    let _,_,write=A.start_save ~generation:2 (A.toggle initial) |> admitted in
    let config=Otoml.Parser.from_string_result write.source_text |> ok |> Machine_configuration.parse |> ok in
    let selected,other=match machine with Masc.Machine_lane.Msx -> config.msx_enabled,config.dos_enabled
      | Dos -> config.dos_enabled,config.msx_enabled in
    Alcotest.(check bool) "selected machine stops" false selected;
    Alcotest.(check bool) "other machine stays enabled" true other)
    Masc.Machine_lane.all

let observed_state_is_separate () =
  let initial=A.create (owner "A") in
  let pending,request=A.start_read ~generation:1 initial |> some in
  let session=A.finish_read request (Ok A.{document=Ok (doc source);activity=Ok Machine_configuration.Disabled}) pending in
  shows "Current file: On" session; shows "Server activity: Off" session;
  let pending,request=A.start_read ~generation:2 session |> some in
  let session=A.finish_read request (Ok A.{document=Ok (doc source);activity=Error "inventory offline"}) pending in
  shows "Server activity read failed: inventory offline" session;
  let pending,request=A.start_read ~generation:3 session |> some in
  let invalid=doc "[machines.msx\nenabled = true\n" in
  let invalid_session=A.finish_read request (Ok A.{document=Ok invalid;activity=Ok Machine_configuration.Disabled}) pending in
  shows "Current file: unverified" invalid_session;
  shows "Server activity: Off" invalid_session;
  rejected (A.start_save ~generation:4 invalid_session);
  let unavailable=A.finish_read request (Ok A.{document=Error "file unavailable";
    activity=Ok Machine_configuration.Enabled}) pending in
  shows "Current file: unverified" unavailable;
  shows "Server activity: On" unavailable;
  rejected (A.start_save ~generation:4 unavailable);
  let pending,request,_=A.start_save ~generation:3 (A.toggle session) |> admitted in
  shows "Server activity read failed: inventory offline" pending;
  let refused=A.finish_save request (A.Refused "preview rejected") pending in
  shows "Server activity read failed: inventory offline" refused;
  let saved=A.finish_save request (A.Saved (receipt ())) pending in
  shows "Server activity: not read" saved

let unavailable () =
  let initial=A.create (owner "A") in
  rejected (A.start_save ~generation:1 initial);
  let pending,request=A.start_read ~generation:1 initial |> some in
  let failed=A.finish_read request (Error "offline") pending in
  shows "offline" failed; rejected (A.start_save ~generation:2 (A.toggle failed));
  List.iter (fun text -> let session=loaded (doc text) |> A.toggle in
    rejected (A.start_save ~generation:2 session))
    ["[bad";"[machines.msx]\nenabled=\"wrong\"\n";"[machines.dos]\nunknown=true\n"]

let workspace_roundtrip () =
  let pending,old_read=A.start_read ~generation:2 (A.toggle (loaded (doc source))) |> some in
  let suspended=A.suspend pending in
  let pending,new_read=A.start_read ~generation:3 suspended |> some in
  let ignored=A.finish_read old_read (Ok A.{document=Ok (doc ~revision:"old" off);activity=Ok Machine_configuration.Disabled}) pending in
  Alcotest.(check bool) "old read ignored" true (A.matches new_read ignored);
  let session=A.finish_read new_read (Ok A.{document=Ok (doc source);activity=Ok Machine_configuration.Enabled}) ignored in
  shows "Activity draft: Off" session;
  let pending,old_save,_=A.start_save ~generation:4 session |> admitted in
  let pending,new_read=A.start_read ~generation:5 (A.suspend pending) |> some in
  let ignored=A.finish_save old_save (A.Saved (receipt ())) pending in
  Alcotest.(check bool) "old save ignored" true (A.matches new_read ignored);
  let other=A.create (owner "B") in
  Alcotest.(check bool) "workspace identity differs" false (A.same_owner (A.owner other) (A.owner ignored));
  shows "Current file: unverified" (A.finish_read new_read (Ok A.{document=Ok (doc source);activity=Ok Machine_configuration.Enabled}) other)

let ambiguous_write_and_refusal () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> admitted in
  let unanswered=A.finish_save request (A.Unconfirmed "connection lost") pending in
  shows "Activity draft: Off" unanswered; rejected (A.start_save ~generation:3 unanswered);
  let uncertain=A.finish_save request (A.Saved (receipt ~durability:(R.Durability_unconfirmed "fixture fsync uncertainty") ())) pending in
  shows "Activity draft: Off" uncertain; rejected (A.start_save ~generation:3 uncertain);
  let reread=read ~generation:4 (doc ~revision:"saved" off) uncertain in
  shows "File changed" reread;
  rejected (A.start_save ~generation:5 reread);
  rejected (A.start_save ~generation:6 (A.reapply reread));
  let refused=A.finish_save request (A.Refused "preview failed") pending in
  shows "preview failed" refused;
  let _,_,write=A.start_save ~generation:3 refused |> admitted in same "original" write.expected_source_revision

let changed_path () =
  let session=A.toggle (loaded (doc source)) |> read ~generation:2 (doc ~path:"/new/runtime.toml" source) in
  rejected (A.start_save ~generation:3 (A.reapply session));
  let _,_,write=A.start_save ~generation:4 (A.toggle (A.discard session)) |> admitted in
  same off write.source_text

let table_shapes () =
  let quoted="[machines.\"msx\"] # header\n# retained comment\n" in
  let _,_,write=A.start_save ~generation:2 (A.toggle (loaded (doc quoted))) |> admitted in
  shows "Activity draft: Off" (loaded (doc write.source_text));
  Alcotest.(check bool) "header retained" true (String.starts_with ~prefix:quoted write.source_text);
  let fake="note = '''\n[machines.msx]\n'''\n[machines]\nmsx = { enabled = true }\n" in
  let session=A.toggle (loaded (doc fake)) in
  shows "Inline or dotted" session; rejected (A.start_save ~generation:2 session)

let draft_tone session =
  List.find_map
    (function
      | Masc_tui_page_line.Fact { label = "Activity draft"; tone; _ } -> Some tone
      | Masc_tui_page_line.Fact _ | Masc_tui_page_line.Title _ | Masc_tui_page_line.Note _
      | Masc_tui_page_line.Items _ -> None)
    (A.lines ~ko:false session)

let unsaved_draft_is_marked () =
  let session=loaded (doc source) in
  Alcotest.(check bool) "a draft equal to the file is plain" true
    (draft_tone session = Some Masc_tui_page_line.Plain);
  let toggled=A.toggle session in
  Alcotest.(check bool) "a draft that differs from the file needs attention" true
    (draft_tone toggled = Some Masc_tui_page_line.Attention);
  Alcotest.(check bool) "discarding returns it to plain" true
    (draft_tone (A.discard toggled) = Some Masc_tui_page_line.Plain)

let () = Alcotest.run "Machine activity draft and save" ["operator flow",List.map (fun (name,f)->Alcotest.test_case name `Quick f)
  ["explicit save preserves other machine and source",draft_and_save;
   "a draft that differs from the file needs attention",unsaved_draft_is_marked;
   "conflict reapplies activity only",conflict_reapply;
   "fresh read retains and discard resets",fresh_read_keeps_draft;
   "clean draft follows external activity and workspace return",clean_read_follows_changed_flag;
   "clean draft preserves latest unrelated edits",clean_read_follows_unrelated_edit;
   "durable draft follows next file while receipt stays",durable_save_follows_next_file_without_losing_receipt;
   "uncertain drafts need explicit reapply",uncertain_drafts_require_explicit_reapply;
   "clean draft keeps changed-path boundary",clean_draft_does_not_adopt_different_path;
   "independent machine flags and defaults",independent_machines;
   "server reading is separate from file and receipt",observed_state_is_separate;
   "unavailable and malformed input",unavailable;
   "workspace roundtrip ignores old callbacks",workspace_roundtrip;
   "unconfirmed write and preview refusal",ambiguous_write_and_refusal;
   "changed file path needs discard",changed_path;
   "quoted and multiline table shapes",table_shapes;]]
