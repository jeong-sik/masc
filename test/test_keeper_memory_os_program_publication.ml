open Alcotest
module Memory = Masc.Keeper_memory_os_types
module Current = Masc.Keeper_memory_os_current
module Program = Masc.Keeper_memory_os_program
module Proof = Masc.Keeper_memory_os_program_publication
module Source = Masc.Keeper_librarian_unread

let require = function Ok value -> value | Error detail -> fail detail
let refused = function Ok _ -> fail "unsafe ordered publication succeeded" | Error _ -> ()
let keeper = "program-fixture"
let keeper_id = Masc_test_deps.keeper_id_fixture keeper
let turn_ref = Ids.Turn_ref.make ~trace_id:"program-source" ~absolute_turn:3
let fact claim = Memory.observed ~claim ~category:Memory.Fact ~now:10.
  ~origin:{Memory.kind=Memory.Authored;trace_id="program-origin"}
let a = fact "Original observation."
let b = fact "Intermediate conclusion."
let c = fact "Final conclusion."
let extra = fact "Concurrent unrelated fact."
let messages = List.map (fun text -> Agent_core.Types.make_message
  ~role:Agent_core.Types.User [Agent_core.Types.Text text]) ["first observation";"second observation"]
let sources = List.mapi (fun message_in_turn message ->
  Source.Official_turn {turn_ref;boundary_line=1;message_in_turn;
    message_sha256=Source.message_digest message}) messages
let range : Current.official_range_id =
  {receipt_scope="ordered-program";after_boundary_line=0;turns=[1,turn_ref];unread_messages=[]}
let source = Current.Official_program_source {range;selected_turns=[1,turn_ref,messages]}
let decision index current next : Program.decision =
  {run_id=string_of_int index;keeper_id;turn_ref;input_current=Some [current];
   sources=[List.nth sources index];input_evidence=`Null;gate_evidence=`Null;
   working_state="accepted continuation";new_claims=[next];absorbed=[];
   dropped=[{Memory.memory_id=Memory.memory_id current;reason="The next observation corrects this claim."}];
   revisions=[{Memory.superseded=Memory.memory_id current;superseded_by=Memory.memory_id next}]}
let program ?(final=c) () = Program.create ~transaction_id:"ordered-publication" ~keeper_id ~turn_ref
  ~sources ~unread:[] ~initial_current:(Some [a])
  ~decisions:[decision 0 a b;decision 1 b final] |> require
let with_store f =
  let directory=Filename.temp_file "ordered-publication-" ".dir" in
  Sys.remove directory;Unix.mkdir directory 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree directory) (fun () -> f directory)
let replace ?(expected_revision=None) ~keepers_dir facts = Current.replace ~keepers_dir ~keeper_id:keeper ~expected_revision
  ~now:20. ~source:{Current.kind=Current.Explicit_write;trace_id="explicit-writer"} ~facts () |> require
let fixture f = with_store @@ fun keepers_dir ->
  ignore (replace ~keepers_dir [a] : Current.t);
  let anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper |> require in
  f keepers_dir anchor
let publish ?on_committed ~keepers_dir ~anchor program =
  Current.apply_program ?on_committed ~keepers_dir ~keeper_id:keeper ~now:30. ~anchor ~source
    ~validate_source:(fun () -> Ok ()) program
let read ~keepers_dir = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper |> require
let rewrite ~keepers_dir facts =
  let expected_revision=Option.map (fun (snapshot : Current.t) -> snapshot.revision) (read ~keepers_dir) in
  replace ~expected_revision ~keepers_dir facts
let journal ~keepers_dir = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:keeper
let snapshot_path ~keepers_dir = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper
let pending_path ~keepers_dir = Current.publication_receipt_path ~keepers_dir ~keeper_id:keeper

let test_single_commit_and_original_archive () = fixture @@ fun keepers_dir anchor ->
  let prior=Fs_compat.load_file (journal ~keepers_dir) in
  let published=publish ~keepers_dir ~anchor (program ()) |> require in
  check int "two decisions publish one revision" 2 published.snapshot.revision;
  check bool "only the final fact is durable" true (published.snapshot.facts=[c]);
  let proof=Proof.of_json (Proof.to_json published.proof) |> require in
  check int "full intermediate proof survives" 2 (List.length proof.execution.stages);
  Proof.of_json (Proof.to_json {proof with captured={proof.captured with journal_sha256=String.make 64 '0'}})
    |> refused;
  Proof.of_json (Proof.to_json {proof with captured={proof.captured with snapshot=None}}) |> refused;
  let tail=Current.read_journal_tail ~keepers_dir ~keeper_id:keeper ~limit:1 in
  let entry=match tail with
    | [entry] -> require entry
    | [] | _ :: _ -> fail "expected exactly one canonical journal row" in
  (match entry with
   | Current.Journal_committed {program;dropped;_} ->
     check bool "canonical journal carries the exact proof" true (program=Some proof);
     check bool "ordered causes remain in the program" true (dropped=None)
   | Current.Journal_failed _ | Current.Journal_quarantined _ -> fail "ordered canonical journal proof missing");
  let archived=Current.read_dropped ~keepers_dir ~keeper_id:keeper ~current_facts:[c] |> require in
  check bool "only the originally durable fact enters the archive" true
    (List.map (fun (row : Current.archived_fact) -> row.original) archived=[a]);
  check bool "original explicit drop reason survives without archiving virtual B" true
    (List.for_all (fun (row : Current.archived_fact) -> row.removal.drop_reason
      =Some "The next observation corrects this claim.") archived);
  check bool "one transaction extends rather than replaces prior journal" true
    (String.starts_with ~prefix:prior (Fs_compat.load_file (journal ~keepers_dir)));
  check bool "original whole input is consumed" true
    (Current.committed_official_coverage ~keepers_dir ~keeper_id:keeper ~receipt_scope:range.receipt_scope
      |> require = Some range)

let test_net_zero_persists_proof () = fixture @@ fun keepers_dir anchor ->
  let before=read ~keepers_dir in
  let result=publish ~keepers_dir ~anchor (program ~final:a ()) |> require in
  check int "net-zero result still writes a real revision" 2 result.snapshot.revision;
  check bool "outer facts equal their original values" true
    (Option.map (fun (snapshot : Current.t) -> snapshot.facts) before=Some result.snapshot.facts);
  check bool "outer delta does not fabricate virtual durable removals" true
    (result.snapshot.change.added=[] && result.snapshot.change.removed=[]);
  check int "both occurrence changes remain in the typed proof" 2 (List.length (Proof.touched_ids result.proof))

let test_unrelated_and_reobservation () = fixture @@ fun keepers_dir anchor ->
  let reobserved={a with Memory.last_seen=25.} in
  ignore (rewrite ~keepers_dir [extra;reobserved] : Current.t);
  let result=publish ~keepers_dir ~anchor (program ()) |> require in
  check bool "concurrent addition keeps its original payload and order" true (result.snapshot.facts=[extra;c]);
  check bool "actual locked replay retains the latest observation" true
    (result.proof.execution.initial_facts=[extra;reobserved]);
  check bool "captured and locked bases stay distinct" true
    (result.proof.captured.snapshot<>result.proof.locked_prior.snapshot)

let test_raw_replace_aba () = fixture @@ fun keepers_dir anchor ->
  ignore (rewrite ~keepers_dir [{a with Memory.first_seen=5.}] : Current.t);
  ignore (rewrite ~keepers_dir [a] : Current.t);
  let before=Fs_compat.load_file (snapshot_path ~keepers_dir) in
  publish ~keepers_dir ~anchor (program ()) |> refused;
  check string "ABA rejection leaves the locked snapshot untouched" before (Fs_compat.load_file (snapshot_path ~keepers_dir));
  check bool "rejection prepares no new publication" false (Sys.file_exists (pending_path ~keepers_dir))

let test_same_revision_bytes_and_prefix () =
  fixture (fun keepers_dir anchor ->
    let snapshot=match read ~keepers_dir with Some snapshot -> snapshot | None -> fail "seed missing" in
    Fs_compat.save_file (snapshot_path ~keepers_dir)
      (Yojson.Safe.to_string (Current.to_json {snapshot with updated_at=21.}));
    publish ~keepers_dir ~anchor (program ()) |> refused);
  fixture (fun keepers_dir anchor ->
    Fs_compat.save_file (journal ~keepers_dir) "";
    publish ~keepers_dir ~anchor (program ()) |> refused)

let test_source_and_keeper_binding () = fixture @@ fun keepers_dir anchor ->
  let before=Fs_compat.load_file (snapshot_path ~keepers_dir) in
  let other=Masc_test_deps.keeper_id_fixture "other-keeper" in
  publish ~keepers_dir ~anchor {(program ()) with keeper_id=other} |> refused;
  Current.apply_program ~keepers_dir ~keeper_id:keeper ~now:30. ~anchor
    ~source:(Current.Official_program_source {range;selected_turns=[1,turn_ref,List.rev messages]})
    ~validate_source:(fun () -> Ok ()) (program ()) |> refused;
  Current.apply_program ~keepers_dir ~keeper_id:keeper ~now:30. ~anchor ~source
    ~validate_source:(fun () -> Error "original cursor changed") (program ()) |> refused;
  check string "failed source admission leaves Memory unchanged" before (Fs_compat.load_file (snapshot_path ~keepers_dir))

let test_atom_original_boundary () = fixture @@ fun keepers_dir anchor ->
  let messages=match messages with
    | [opening;tool_result] -> [opening;{tool_result with Agent_core.Types.role=Agent_core.Types.Tool}]
    | [] | [_] | _ :: _ :: _ :: _ -> fail "fixture requires two messages in one atom" in
  let atom_sources=Source.sources_for_atom_range ~trace_id:"program-source"
    ~history_start_boundary_line:1 ~start_atom:0 ~end_atom:1 ~messages |> require in
  let decisions=List.mapi (fun index current ->
    {(decision index current (if index=0 then b else c)) with Program.sources=[List.nth atom_sources index]}) [a;b] in
  let program=Program.create ~transaction_id:"atom-publication" ~keeper_id ~turn_ref
    ~sources:atom_sources ~unread:[] ~initial_current:(Some [a]) ~decisions |> require in
  let last_atom_digest=match Runtime_model_input_tail_window.atom_opening_digest messages 0 with
    | Some digest -> digest | None -> fail "fixture last atom absent" in
  let range : Current.durable_range_id = {receipt_scope="original-atom-range";trace_id="program-source";
    history_start_boundary_line=1;start_atom=0;end_atom=1;last_atom_digest;
    end_boundary_line=2;boundary_lines_seen=2;unread_messages=[]} in
  let apply checkpoint=Current.apply_program ~keepers_dir ~keeper_id:keeper ~now:30. ~anchor
    ~source:(Current.Atom_program_source {range;checkpoint}) ~validate_source:(fun () -> Ok ()) program in
  apply (List.rev messages) |> refused;
  let committed=apply messages |> require in
  check int "whole atom range publishes once" 2 committed.snapshot.revision;
  check bool "atom result keeps the final ordered decision" true (committed.snapshot.facts=[c]);
  check bool "original whole atom range is consumed" true
    (Current.committed_durable_range ~keepers_dir ~keeper_id:keeper ~receipt_scope:range.receipt_scope
      |> require = Some range)

let injected ~keepers_dir ~anchor ~write_snapshot ~before_journal ~on_committed program =
  Current.For_testing.apply_program_with_publication_io ~keepers_dir ~keeper_id:keeper ~now:30. ~anchor
    ~source ~validate_source:(fun () -> Ok ()) ~write_snapshot ~sync_snapshot:(fun _ -> Error "not yet confirmed")
    ~before_journal ~on_committed program

let test_staged_recovery () = List.iter (fun after_rename -> fixture @@ fun keepers_dir anchor ->
  let committed=ref 0 in
  let write_snapshot path bytes=Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
    ~sync_file:(fun _ -> if not after_rename then failwith "before rename")
    ~sync_parent:(fun _ -> failwith "after rename") path bytes in
  injected ~keepers_dir ~anchor ~write_snapshot ~before_journal:(fun () -> ())
    ~on_committed:(fun _ -> incr committed) (program ()) |> refused;
  check int "uncertain durability never reports a live commit" 0 !committed;
  let raw=Fs_compat.load_file (snapshot_path ~keepers_dir) in
  let recovered=read ~keepers_dir in
  check bool "recovery distinguishes a durable target from the original prefix" true
    (Option.map (fun (snapshot : Current.t) -> snapshot.facts) recovered=Some (if after_rename then [c] else [a]));
  check string "read recovery does not rewrite the snapshot" raw (Fs_compat.load_file (snapshot_path ~keepers_dir));
  check int "read recovery never replays the producer callback" 0 !committed;
  check bool "reconciled publication clears its WAL" false (Sys.file_exists (pending_path ~keepers_dir))) [false;true]

let test_committed_pending_journal_and_failed_reset () = fixture @@ fun keepers_dir anchor ->
  let path=journal ~keepers_dir in
  let prior=Fs_compat.load_file path in
  let before_journal ()=Sys.remove path;Unix.mkdir path 0o700 in
  let callbacks=ref 0 in
  let result=injected ~keepers_dir ~anchor ~write_snapshot:Fs_compat.save_file_atomic_strict_staged
    ~before_journal ~on_committed:(fun _ -> incr callbacks) (program ()) |> require in
  check int "durable target remains committed with evidence pending" 2 result.snapshot.revision;
  check int "live producer callback runs once before journal failure" 1 !callbacks;
  let old_epoch=Fs_compat.load_file (Current.epoch_path ~keepers_dir ~keeper_id:keeper) in
  Current.with_program_reset ~keepers_dir ~keeper_id:keeper (fun () -> Error "must not run") |> refused;
  check string "unrecoverable pending WAL prevents epoch rotation" old_epoch
    (Fs_compat.load_file (Current.epoch_path ~keepers_dir ~keeper_id:keeper));
  Unix.rmdir path;Fs_compat.save_file path prior;
  Current.with_program_reset ~keepers_dir ~keeper_id:keeper (fun () -> Error "cleanup fails after recovery") |> refused;
  check bool "failed cleanup still permits normal reads after recovering old proof" true (read ~keepers_dir=Some result.snapshot);
  check int "reset/read recovery never repeat live callback" 1 !callbacks;
  check bool "old anchors stay invalid after a failed destructive cleanup" true
    (Fs_compat.load_file (Current.epoch_path ~keepers_dir ~keeper_id:keeper)<>old_epoch)

let test_pending_boundary_conflict_preserves_stores () = fixture @@ fun keepers_dir anchor ->
  let path=journal ~keepers_dir in
  let prior=Fs_compat.load_file path in
  ignore (injected ~keepers_dir ~anchor ~write_snapshot:Fs_compat.save_file_atomic_strict_staged
    ~before_journal:(fun () -> Sys.remove path;Unix.mkdir path 0o700)
    ~on_committed:(fun _ -> ()) (program ()) |> require);
  Unix.rmdir path;Fs_compat.save_file path prior;
  let pending=Fs_compat.load_file (pending_path ~keepers_dir) in
  let map_field key update = function
    | `Assoc fields -> `Assoc (List.map (fun (name,value) -> name,if name=key then update value else value) fields)
    | _ -> fail "publication fixture expected an object" in
  let altered=Yojson.Safe.from_string pending
    |> map_field "journal" (map_field "ordered_program"
      (map_field "boundary" (map_field "receipt_scope" (fun _ -> `String "another-reader"))))
    |> Yojson.Safe.to_string in
  Fs_compat.save_file (pending_path ~keepers_dir) altered;
  let snapshot=Fs_compat.load_file (snapshot_path ~keepers_dir) in
  Current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper |> refused;
  check string "conflicting proof never rewrites the durable target" snapshot
    (Fs_compat.load_file (snapshot_path ~keepers_dir));
  check string "conflicting proof stays available for diagnosis" altered
    (Fs_compat.load_file (pending_path ~keepers_dir));
  Fs_compat.save_file (pending_path ~keepers_dir) pending;
  let recovered=read ~keepers_dir in
  check bool "restoring the exact proof permits ordinary recovery" true
    (Option.map (fun (snapshot : Current.t) -> snapshot.facts) recovered=Some [c])

let test_quarantine_and_empty_incarnation () =
  fixture (fun keepers_dir anchor ->
    Fs_compat.save_file (snapshot_path ~keepers_dir) "{broken snapshot";
    ignore (replace ~keepers_dir [a] : Current.t);
    publish ~keepers_dir ~anchor (program ()) |> refused);
  with_store (fun keepers_dir ->
    let anchor=Current.capture_program_anchor ~keepers_dir ~keeper_id:keeper |> require in
    Current.with_program_reset ~keepers_dir ~keeper_id:keeper (fun () -> Ok ()) |> require;
    let initial={ (decision 0 a b) with Program.input_current=None;dropped=[];revisions=[] } in
    let empty_program=Program.create ~transaction_id:"absent-incarnation" ~keeper_id ~turn_ref
      ~sources:[List.hd sources] ~unread:[] ~initial_current:None ~decisions:[initial] |> require in
    let single=Current.Official_program_source {range;selected_turns=[1,turn_ref,[List.hd messages]]} in
    Current.apply_program ~keepers_dir ~keeper_id:keeper ~now:30. ~anchor ~source:single
      ~validate_source:(fun () -> Ok ()) empty_program |> refused)

type hole_boundary = Hole_atom | Hole_official
type hole_publication_fault =
  | Hole_before_rename
  | Hole_after_rename
  | Hole_journal_blocked
  | Hole_ledger_corrupt

(* The accepted decisions and typed hole are supplied here. This exercises
   real program publication, recovery and external acknowledgement together;
   it does not establish provider exhaustion or source-owner serialization. *)
let test_hole_publication_recovers_external_cursor boundary fault () =
  fixture @@ fun keepers_dir anchor ->
  let module Cursor = Masc.Keeper_external_read_cursor in
  let original = [List.hd messages;
    Agent_core.Types.make_message ~role:Agent_core.Types.User
      [Agent_core.Types.Text "The exact refused original remains explicitly unread."];
    List.nth messages 1] in
  let reasons = [Masc.Keeper_librarian_input_refusal.Input_capacity;
    Masc.Keeper_librarian_input_refusal.Request_body_refused] in
  let atom,official,source,manifest,hole = match boundary with
    | Hole_atom ->
      let manifest=Source.sources_for_atom_range ~trace_id:"program-source"
        ~history_start_boundary_line:1 ~start_atom:0 ~end_atom:3 ~messages:original |> require in
      let hole=Source.for_atom ~trace_id:"program-source" ~history_start_boundary_line:1
        ~atom:1 ~message_in_atom:0 ~messages:original ~reasons |> require in
      let last_atom_digest=match Runtime_model_input_tail_window.atom_opening_digest original 2 with
        | Some digest -> digest | None -> fail "original final atom missing" in
      let range : Current.durable_range_id =
        {receipt_scope="hole-program-atoms";trace_id="program-source";
         history_start_boundary_line=1;start_atom=0;end_atom=3;last_atom_digest;
         end_boundary_line=2;boundary_lines_seen=2;unread_messages=[hole]} in
      Some range,None,Current.Atom_program_source {range;checkpoint=original},manifest,hole
    | Hole_official ->
      let manifest=List.mapi (fun message_in_turn message -> Source.Official_turn
        {turn_ref;boundary_line=1;message_in_turn;message_sha256=Source.message_digest message}) original in
      let hole=Source.for_official_turn ~turn_ref ~boundary_line:1 ~message_in_turn:1
        ~messages:original ~reasons |> require in
      let range={range with unread_messages=[hole]} in
      None,Some range,Current.Official_program_source {range;selected_turns=[1,turn_ref,original]},manifest,hole in
  let program=Program.create ~transaction_id:"hole-recovery-publication" ~keeper_id ~turn_ref
    ~sources:manifest ~unread:[hole] ~initial_current:(Some [a])
    ~decisions:[{(decision 0 a b) with Program.sources=[List.nth manifest 0]};
      {(decision 1 b c) with Program.sources=[List.nth manifest 2]}] |> require in
  let runtime_keepers_dir=Filename.concat keepers_dir "external-runtime" in
  let cursor_path=Cursor.path_for_keepers_dir ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper in
  let cursor ()=Cursor.read ~memory_keepers_dir:keepers_dir ~runtime_keepers_dir ~keeper_name:keeper in
  Cursor.prepare ~memory_keepers_dir:keepers_dir ~runtime_keepers_dir ~keeper_name:keeper
    (cursor () |> require) ~through:1 ~atom ~official |> require;
  let pending=Fs_compat.load_file cursor_path in
  let prior_snapshot=Fs_compat.load_file (snapshot_path ~keepers_dir) in
  let prior_journal=Fs_compat.load_file (journal ~keepers_dir) in
  let ledger_path=Current.unread_ledger_path ~keepers_dir ~keeper_id:keeper in
  let prior_ledger=Fs_compat.load_file_opt ledger_path in
  let callbacks=ref [] in
  let on_committed (committed : Current.program_commit)=callbacks:=committed.proof :: !callbacks in
  let write_snapshot = match fault with
    | Hole_before_rename -> Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_file:(fun _ -> failwith "before hole snapshot rename") ~sync_parent:(fun _ -> ())
    | Hole_after_rename -> Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_file:(fun _ -> ()) ~sync_parent:(fun _ -> failwith "after hole snapshot rename")
    | Hole_journal_blocked | Hole_ledger_corrupt -> Fs_compat.save_file_atomic_strict_staged in
  let before_journal ()=match fault with
    | Hole_journal_blocked ->
      Fs_compat.invalidate_cached_writer (journal ~keepers_dir);
      Sys.remove (journal ~keepers_dir);Unix.mkdir (journal ~keepers_dir) 0o700
    | Hole_ledger_corrupt -> Fs_compat.save_file ledger_path "{"
    | Hole_before_rename | Hole_after_rename -> () in
  let attempted=Current.For_testing.apply_program_with_publication_io
    ~keepers_dir ~keeper_id:keeper ~now:30. ~anchor ~source ~validate_source:(fun () -> Ok ())
    ~write_snapshot ~sync_snapshot:(fun _ -> Error "snapshot durability deliberately unconfirmed")
    ~before_journal ~on_committed program in
  let callbacks_before_recovery=match fault with
    | Hole_before_rename | Hole_after_rename -> refused attempted;0
    | Hole_journal_blocked | Hole_ledger_corrupt ->
      let committed=require attempted in
      check bool "secondary I/O failure preserves the final durable program" true
        (committed.snapshot.facts=[c] && committed.proof.execution.program=program);
      1 in
  check int "only confirmed live publication invokes its producer callback"
    callbacks_before_recovery (List.length !callbacks);
  check string "publication itself does not acknowledge external input" pending (Fs_compat.load_file cursor_path);
  (match fault with
   | Hole_journal_blocked | Hole_ledger_corrupt ->
     let snapshot_bytes=Fs_compat.load_file (snapshot_path ~keepers_dir) in
     let publication_bytes=Fs_compat.load_file_opt (pending_path ~keepers_dir) in
     let receipt_path=Current.durable_range_receipt_path ~keepers_dir ~keeper_id:keeper in
     let receipt_bytes=Fs_compat.load_file receipt_path in
     cursor () |> refused;
     check string "failed recovery preserves the complete pending external identity" pending (Fs_compat.load_file cursor_path);
     check string "failed recovery preserves the already durable target" snapshot_bytes
       (Fs_compat.load_file (snapshot_path ~keepers_dir));
     check bool "failed recovery retains its exact publication evidence" true
       (Fs_compat.load_file_opt (pending_path ~keepers_dir)=publication_bytes);
     check string "failed recovery cannot replace the source receipt" receipt_bytes (Fs_compat.load_file receipt_path);
     (match fault with
      | Hole_journal_blocked -> Unix.rmdir (journal ~keepers_dir);Fs_compat.save_file (journal ~keepers_dir) prior_journal
      | Hole_ledger_corrupt ->
        check string "corrupt unread evidence remains available for repair" "{" (Fs_compat.load_file ledger_path);
        (match prior_ledger with Some bytes -> Fs_compat.save_file ledger_path bytes | None -> Sys.remove ledger_path)
      | Hole_before_rename | Hole_after_rename -> fail "not a secondary I/O fault")
   | Hole_before_rename | Hole_after_rename -> ());
  (match fault with
   | Hole_before_rename ->
     check int "a rolled-back target grants no external acknowledgement" 0 (Cursor.offset (cursor () |> require));
     check string "pre-rename recovery leaves the complete prior snapshot" prior_snapshot
       (Fs_compat.load_file (snapshot_path ~keepers_dir));
     check string "pre-rename recovery leaves the prior canonical history" prior_journal
       (Fs_compat.load_file (journal ~keepers_dir));
     check bool "pre-rename rollback invents no cumulative unread authority" true
       (Current.read_unread_messages ~keepers_dir ~keeper_id:keeper |> require=[]);
     check string "an uncommitted program leaves its external range pending" pending (Fs_compat.load_file cursor_path);
     check int "rollback recovery never invokes the producer" 0 (List.length !callbacks);
     ignore (Current.apply_program ~on_committed ~keepers_dir ~keeper_id:keeper ~now:30.
       ~anchor ~source ~validate_source:(fun () -> Ok ()) program |> require : Current.program_commit)
   | Hole_after_rename | Hole_journal_blocked | Hole_ledger_corrupt -> ());
  check int "ordinary recovery acknowledges only the exact complete program boundary" 1
    (Cursor.offset (cursor () |> require));
  (* Read persisted evidence before any Current API that could archive it. *)
  let archived=Current.read_unread_messages ~keepers_dir ~keeper_id:keeper |> require in
  check bool "external acknowledgement leaves the exact source and both named causes durable" true (archived=[hole]);
  let committed=match read ~keepers_dir with Some snapshot -> snapshot | None -> fail "recovered snapshot absent" in
  check bool "the two accepted decisions have one actual final revision" true
    (committed.revision=2 && committed.facts=[c]);
  (match atom,official with
   | Some expected,None ->
     check bool "atom accounted coverage retains the exact hole-bearing range" true
       (Current.committed_durable_coverage ~keepers_dir ~keeper_id:keeper ~receipt_scope:expected.receipt_scope |> require=Some expected);
     check bool "accounted atoms never become fully read evidence" true
       (Current.committed_durable_range ~keepers_dir ~keeper_id:keeper ~receipt_scope:expected.receipt_scope |> require=None)
   | None,Some expected ->
     check bool "official accounted coverage retains the exact hole-bearing range" true
       (Current.committed_official_coverage ~keepers_dir ~keeper_id:keeper ~receipt_scope:expected.receipt_scope |> require=Some expected);
     check bool "accounted official messages never become fully read evidence" true
       (Current.committed_official_range ~keepers_dir ~keeper_id:keeper ~receipt_scope:expected.receipt_scope |> require=None)
   | None,None | Some _,Some _ -> fail "fixture must own exactly one original boundary");
  let journal_rows=Fs_compat.load_jsonl (journal ~keepers_dir) in
  let proofs=Current.read_journal_tail ~keepers_dir ~keeper_id:keeper ~limit:(List.length journal_rows)
    |> List.filter_map (fun row -> match require row with
    | Current.Journal_committed {program=Some proof;_} -> Some proof
    | Current.Journal_committed {program=None;_} | Current.Journal_failed _ | Current.Journal_quarantined _ -> None) in
  let proof=match proofs with [proof] -> proof | [] | _::_ -> fail "expected exactly one canonical ordered publication" in
  check bool "recovered journal retains exact ordered judgments and the unread original" true
    (proof.execution.program=program && proof.execution.program.unread=[hole]);
  check bool "completed recovery clears its publication WAL" false (Sys.file_exists (pending_path ~keepers_dir));
  let settled=List.map Fs_compat.load_file [snapshot_path ~keepers_dir;journal ~keepers_dir;ledger_path;cursor_path] in
  check int "a repeated wake retains the acknowledged external boundary" 1 (Cursor.offset (cursor () |> require));
  ignore (read ~keepers_dir);
  check (list string) "repeated recovery preserves snapshot, journal, exact holes and external cursor" settled
    (List.map Fs_compat.load_file [snapshot_path ~keepers_dir;journal ~keepers_dir;ledger_path;cursor_path]);
  let expected_callbacks=match fault with Hole_after_rename -> 0
    | Hole_before_rename | Hole_journal_blocked | Hole_ledger_corrupt -> 1 in
  check int "recovery never repeats a live producer callback" expected_callbacks (List.length !callbacks)

let () = run "keeper_memory_os_program_publication"
  ["atomic ordered publication",[
    test_case "one real revision, exact proof and original-only archive" `Quick test_single_commit_and_original_archive;
    test_case "net-zero outer facts still publish their ordered proof" `Quick test_net_zero_persists_proof;
    test_case "unrelated addition and genuine reobservation survive" `Quick test_unrelated_and_reobservation;
    test_case "raw replacement restore cannot evade the anchor" `Quick test_raw_replace_aba;
    test_case "same-revision edits and missing journal prefix reject" `Quick test_same_revision_bytes_and_prefix;
    test_case "original boundary, source admission and Keeper must match" `Quick test_source_and_keeper_binding;
    test_case "atom source bytes bind the original whole range" `Quick test_atom_original_boundary;
    test_case "before and after rename recover the exact proof" `Quick test_staged_recovery;
    test_case "committed journal failure and failed reset remain recoverable" `Quick test_committed_pending_journal_and_failed_reset;
    test_case "conflicting original-boundary proof preserves pending stores" `Quick test_pending_boundary_conflict_preserves_stores;
    test_case "quarantine and absent-Memory reset invalidate captures" `Quick test_quarantine_and_empty_incarnation];
   "hole publication and external recovery",[
    test_case "atom holes survive rollback before snapshot rename" `Quick
      (test_hole_publication_recovers_external_cursor Hole_atom Hole_before_rename);
    test_case "atom holes recover after an unconfirmed snapshot rename" `Quick
      (test_hole_publication_recovers_external_cursor Hole_atom Hole_after_rename);
    test_case "atom holes hold external acknowledgement until journal recovery" `Quick
      (test_hole_publication_recovers_external_cursor Hole_atom Hole_journal_blocked);
    test_case "atom hole ledger corruption blocks external acknowledgement" `Quick
      (test_hole_publication_recovers_external_cursor Hole_atom Hole_ledger_corrupt);
    test_case "official holes survive rollback before snapshot rename" `Quick
      (test_hole_publication_recovers_external_cursor Hole_official Hole_before_rename);
    test_case "official holes recover after an unconfirmed snapshot rename" `Quick
      (test_hole_publication_recovers_external_cursor Hole_official Hole_after_rename);
    test_case "official holes hold external acknowledgement until journal recovery" `Quick
      (test_hole_publication_recovers_external_cursor Hole_official Hole_journal_blocked);
    test_case "official hole ledger corruption blocks external acknowledgement" `Quick
      (test_hole_publication_recovers_external_cursor Hole_official Hole_ledger_corrupt)]]
