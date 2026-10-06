module A = Masc_tui_exact_activity
module R = Masc_tui_runtime_config_receipt
let ok = function Ok value -> value | Error detail -> Alcotest.fail detail
let some = function Some value -> value | None -> Alcotest.fail "request refused"
let rejected = function Error _ -> () | Ok _ -> Alcotest.fail "unexpectedly admitted"
let owner ?(lane=Standalone_lane.Librarian) workspace = A.{workspace=(workspace,workspace ^ "/.masc");lane}
let source = "# operator note\n[runtime.exact_output_lanes.librarian_exact]\n# candidate order\nslots = [\"first\", \"second\"]\ncli_slots = [\"client\"]\nenabled = true\n\n[providers.extra]\nvalue = \"keep\"\n"
let off = "# operator note\n[runtime.exact_output_lanes.librarian_exact]\n# candidate order\nslots = [\"first\", \"second\"]\ncli_slots = [\"client\"]\nenabled = false\n\n[providers.extra]\nvalue = \"keep\"\n"
let doc ?(path="/workspace/runtime.toml") ?(revision="original") source_text =
  {Masc_tui_runtime_config_edit.path;source_text;source_revision=revision}
let read ?(generation=1) document session =
  let pending,request=A.start_read ~generation session |> some in
  A.finish_read request (Ok document) pending
let loaded ?(lane=Standalone_lane.Librarian) document = read document (A.create (owner ~lane "A"))
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
  same off write.source_text; same "original" write.expected_source_revision;
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

let required_and_empty () =
  let required="[runtime.exact_output_lanes.board_attention_exact]\nslots = [\"first\"]\n" in
  let session=loaded ~lane:Standalone_lane.Board_attention (doc required) |> A.toggle in
  shows "Required" session; shows "Activity draft: On" session;
  rejected (A.start_save ~generation:2 session);
  let empty="[runtime.exact_output_lanes.librarian_exact]\nenabled = false\nslots = []\n" in
  let session=loaded (doc empty) |> A.toggle in
  shows "Add a candidate" session; shows "Activity draft: Off" session;
  rejected (A.start_save ~generation:2 session)

let unavailable () =
  let initial=A.create (owner "A") in
  rejected (A.start_save ~generation:1 initial);
  let pending,request=A.start_read ~generation:1 initial |> some in
  let failed=A.finish_read request (Error "offline") pending in
  shows "offline" failed; rejected (A.start_save ~generation:2 (A.toggle failed));
  List.iter (fun text -> let session=loaded (doc text) |> A.toggle in
    rejected (A.start_save ~generation:2 session))
    ["[bad";"[runtime]\n";"[runtime.exact_output_lanes.librarian_exact]\nenabled=\"wrong\"\n";
     "[runtime.exact_output_lanes.librarian_exact]\nslots=\"wrong\"\n"]

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

let table_shapes () =
  let quoted="[runtime.exact_output_lanes.\"librarian_exact\"] # header\nslots = [\"one\"]\n" in
  let _,_,write=A.start_save ~generation:2 (A.toggle (loaded (doc quoted))) |> ok in
  shows "Activity draft: Off" (loaded (doc write.source_text));
  Alcotest.(check bool) "header retained" true (String.starts_with ~prefix:quoted write.source_text);
  let fake="note = '''\n[runtime.exact_output_lanes.librarian_exact]\n'''\n[runtime.exact_output_lanes]\nlibrarian_exact = { slots = [\"one\"] }\n" in
  let session=A.toggle (loaded (doc fake)) in
  shows "Inline or dotted" session; rejected (A.start_save ~generation:2 session)

let receipt_keeps_application_failure () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let session=A.finish_save request (A.Saved (receipt ~registry:(R.Exact_output_registry_kept {reason="registry refused"}) ())) pending in
  shows "registry refused" session;
  let session=read ~generation:3 (doc ~revision:"saved" off) session in
  shows "registry refused" session; shows "Current file: Off" session

(* A reread that already shows the desired activity leaves nothing for s to
   save, so reapply must not promise a save. *)
let reapply_onto_desired_activity_promises_no_save () =
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let session=A.finish_save request (A.Unconfirmed "connection lost") pending in
  let satisfied=A.reapply (read ~generation:3 (doc ~revision:"observed" off) session) in
  shows "Current settings already have this activity. Nothing to save." satisfied;
  Alcotest.(check bool) "no save promised" false (has "s saves" (A.lines satisfied));
  rejected (A.start_save ~generation:4 satisfied);
  let pending=A.reapply (read ~generation:3 (doc ~revision:"concurrent" (source ^ "other = 1\n")) session) in
  shows "Activity reapplied to current settings. s saves explicitly." pending;
  let _,_,write=A.start_save ~generation:4 pending |> ok in
  same "concurrent" write.expected_source_revision

(* An unconfirmed receipt belongs to the first attempt. A retry that is
   refused or conflicts must not show it as its own. *)
let retry_save_drops_previous_receipt () =
  let first="File written; durability unconfirmed" in
  let pending,request,_=A.start_save ~generation:2 (A.toggle (loaded (doc source))) |> ok in
  let session=A.finish_save request (A.Saved (receipt ~durability:R.Durability_unconfirmed ())) pending in
  shows first session;
  let reapplied=A.reapply (read ~generation:3 (doc ~revision:"concurrent" (source ^ "other = 1\n")) session) in
  shows first reapplied;
  let retry,request,_=A.start_save ~generation:4 reapplied |> ok in
  let absent label session = Alcotest.(check bool) label false (has first (A.lines session)) in
  absent "pending retry" retry;
  absent "refused retry" (A.finish_save request (A.Refused "preview failed") retry);
  absent "conflicting retry" (A.finish_save request (A.Conflict (doc ~revision:"third" source)) retry)

(* An operator note on an enabled flag stays on that line through a toggle
   and the save it prepares. *)
let enabled_comment_survives_toggle () =
  let table="[runtime.exact_output_lanes.librarian_exact]\nslots = [\"first\"]\n" in
  let annotated=table ^ "enabled = true # temporary during rollout\n" in
  let _,_,write=A.start_save ~generation:2 (A.toggle (loaded (doc annotated))) |> ok in
  same (table ^ "enabled = false # temporary during rollout\n") write.source_text

let () = Alcotest.run "Exact activity draft and save" ["operator flow",List.map (fun (name,f)->Alcotest.test_case name `Quick f)
  ["explicit save preserves candidates and other source",draft_and_save;
   "conflict reapplies activity only",conflict_reapply;
   "fresh read retains and discard resets",fresh_read_keeps_draft;
   "Required and empty candidate refusal",required_and_empty;
   "unavailable and malformed input",unavailable;
   "workspace roundtrip ignores old callbacks",workspace_roundtrip;
   "unconfirmed write and preview refusal",ambiguous_write_and_refusal;
   "changed file path needs discard",changed_path;
   "quoted and multiline table shapes",table_shapes;
   "stored setting does not hide application failure",receipt_keeps_application_failure;
   "reapply onto the desired activity promises no save",reapply_onto_desired_activity_promises_no_save;
   "retry save drops the previous receipt",retry_save_drops_previous_receipt;
   "enabled flag keeps its inline comment",enabled_comment_survives_toggle]]
