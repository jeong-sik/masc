open Alcotest
module A = Masc_tui_lane_application
module D = Masc_tui_lane_declaration
let ok = function Ok value -> value | Error detail -> fail detail
let target : A.target = {source_path="/workspace/addons/research.toml";
  installation_id="research";source_revision="on-bytes";desired_revision="worker-inputs";enabled=true}
let observation ?(target=target) state : A.observation = {target;state}
let json target application = `Assoc [
  "source_path",`String target.A.source_path;"id",`String target.installation_id;
  "source_revision",`String target.source_revision;"desired_revision",`String target.desired_revision;
  "enabled",`Bool target.enabled;"application",application]
let app kind fields = `Assoc (("kind",`String kind)::fields)
let is_tracking label expected actual = check bool label true (expected=actual)

let startup_and_cleanup () =
  List.iter (fun state ->
    is_tracking "same saved identity receives live state" (A.Observed state)
      (A.track ~target ~complete:true [observation state]))
    [A.Starting;A.Cleaning;A.Applied "worker-1"];
  let off = {target with source_revision="off-bytes";enabled=false} in
  is_tracking "same semantic revision does not prove Off" A.Different_source
    (A.track ~target:off ~complete:true [observation (A.Applied "old-worker")]);
  List.iter (fun state ->
    is_tracking "Off follows cleanup through confirmation" (A.Observed state)
      (A.track ~target:off ~complete:true [observation ~target:off state]))
    [A.Cleaning;A.Failed ["cleanup publication failed"];A.Inactive]

let changed_or_unreadable () =
  is_tracking "changed manifest cannot confirm unchanged TOML" A.Different_inputs
    (A.track ~target ~complete:true [observation ~target:{target with desired_revision="changed"} (A.Applied "worker")]);
  is_tracking "no owner cannot confirm cleanup" A.Awaiting_declaration
    (A.track ~target ~complete:true []);
  List.iter (fun observations ->
    check bool "incomplete or ambiguous read is unavailable" true
      (match A.track ~target ~complete:(List.length observations<>1) observations with
       | A.Unavailable _ -> true | _ -> false))
    [[observation A.Inactive];[observation A.Starting;observation A.Starting]];
  is_tracking "same ID at another path cannot confirm intent" A.Different_source
    (A.track ~target ~complete:true [observation ~target:{target with source_path="/elsewhere/research.toml"} A.Starting])

let strict_wire () =
  List.iter (fun (target,wire,state) ->
    check bool "wire state is retained" true ((A.decode (json target wire) |> ok).state=state))
    [target,app "starting" [],A.Starting;
     target,app "cleaning" [],A.Cleaning;
     target,app "applied" ["instance_id",`String "worker"],A.Applied "worker";
     {target with enabled=false},app "inactive" [],A.Inactive;
     target,app "failed" ["messages",`List [`String "worker failed"]],A.Failed ["worker failed"];
     target,app "unknown" ["messages",`List [`String "operator access required"]],A.Unknown ["operator access required"]];
  List.iter (fun wire -> check bool "bad wire cannot become success" true
    (Result.is_error (A.decode (json target wire))))
    [app "done" [];app "applied" [];app "inactive" [];app "unknown" ["messages",`List []]];
  check bool "source identity is mandatory" true
    (Result.is_error (A.decode (`Assoc ["id",`String "research"])))

let edits_keep_saved_identity () =
  let base : D.document = {file_name="research.toml";source_path=target.source_path;
    source_text="id = \"research\"\nenabled = true\n";source_revision=target.source_revision;
    desired_revision=Some target.desired_revision;valid=true;messages=[]} in
  let session = D.from_document base in
  let draft = D.toggle_enabled session |> ok in
  check bool "unsaved Off keeps accepted On identity" true (D.application_target draft |> ok = target);
  let current = {base with source_revision="external"} in
  let comparison = D.after_response draft (D.Read_document current) in
  check bool "comparison read preserves saved intent" true (D.application_target comparison |> ok = target);
  let adopted = D.use_current_revision comparison |> ok in
  check string "explicit adoption changes tracked file" "external" (D.application_target adopted |> ok).source_revision;
  check string "adoption keeps unsaved draft" draft.text adopted.text;
  let saved = {base with source_text=draft.text;source_revision="off-bytes"} in
  let written = D.after_response draft (D.Written {document=saved;state=D.Saved;durability=D.Durable}) in
  check bool "save receipt tracks saved Off, not the previous base" true
    (D.application_target written |> ok = {target with source_revision="off-bytes";enabled=false});
  check bool "unsaved creation has no applied identity" true
    (Result.is_error (D.application_target (D.create "new.toml" |> ok)))

let read_validation_is_not_application () =
  let read : D.document = {file_name="research.toml";source_path=target.source_path;
    source_text="id = \"research\"\nenabled = true\n";source_revision=target.source_revision;
    desired_revision=Some target.desired_revision;valid=false;
    messages=["configuration inventory is incomplete"]} in
  check bool "a read during an incomplete inventory keeps its target" true
    (D.application_target (D.from_document read) |> ok = target);
  check bool "a collision at read time leaves the outcome to the current inventory" true
    (D.application_target (D.from_document
      {read with messages=["another declaration has the same installation id"]}) |> ok = target);
  check bool "a file the server could not parse has no target" true
    (Result.is_error (D.application_target (D.from_document
      {read with desired_revision=None;messages=["manifest_path requires a string"]})))

let observation_ownership () =
  let start generation reading = match A.start ~generation reading with
    | Some result -> result | None -> fail "expected a new read" in
  let pending, old = start 1 A.empty in
  check bool "same action generation coalesces reads" true (A.start ~generation:1 pending=None);
  let next, current = start 2 pending in
  let next = A.finish ~generation:2 old (Ok "old applied") next in
  check bool "older result cannot fill or settle current read" true (A.value next=None && A.pending next);
  let next = A.finish ~generation:2 current (Error "read failed") next in
  check bool "failure is visible, never stale success" true (A.value next=Some (Error "read failed"));
  let retired = A.finish ~generation:2 current (Ok "late success") next in
  check bool "duplicate reply has no authority" true (A.value retired=A.value next);
  let reset, fresh = start 1 A.empty in
  let reset = A.finish ~generation:1 old (Ok "previous workspace") reset in
  check bool "same-number generation after reset does not restore old workspace" true
    (A.value reset=None && A.pending reset);
  let reset = A.finish ~generation:1 fresh (Ok "new workspace") reset in
  check bool "current workspace observation is accepted" true (A.value reset=Some (Ok "new workspace"));
  let pending, old = start 3 reset in
  let superseded = A.accept (Ok "foreground inventory") in
  check bool "foreground read supersedes pending observation" true
    (A.value (A.finish ~generation:3 old (Ok "stale") superseded)=Some (Ok "foreground inventory"));
  check bool "read cannot publish after explicit action generation moves" true
    (A.value (A.finish ~generation:4 old (Ok "pre-save") pending)=A.value reset)

let () = run "TUI saved Lane application" ["operator flows",[
  test_case "On startup and Off cleanup" `Quick startup_and_cleanup;
  test_case "changed and unavailable observations" `Quick changed_or_unreadable;
  test_case "strict server contract" `Quick strict_wire;
  test_case "draft, comparison, adoption and save" `Quick edits_keep_saved_identity;
  test_case "read-time validation does not decide application" `Quick read_validation_is_not_application;
  test_case "overlapping reads, save and workspace reset" `Quick observation_ownership]]
