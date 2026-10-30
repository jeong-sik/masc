module Draft = Masc.Artifact_draft
module Store = Masc.Artifact_draft_store
module Publications = Masc.Published_artifact_store
module Engine = Artifact_document_engine
let ok = function Ok value -> value | Error message -> Alcotest.fail message
let stored result = Result.map_error Store.error_message result |> ok
let target = { Draft.artifact_id = "artifact-" ^ String.make 32 'a'; generation = "019c6e27-e55b-73d1-87d8-4e01f1f75043" }
let with_base f =
  let base = Filename.temp_file "artifact_drafts_" "" in
  Sys.remove base; Unix.mkdir base 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Eio.Switch.run (fun sw -> Eio.Switch.on_release sw (fun () -> remove base); f base)
let publish ~base_path content =
  let request = Masc.Published_artifact.request_of_json (`Assoc
    ["title", `String "shared draft fixture"; "summary", `String "native integration";
     "format", `String "markdown"; "content", `String content]) |> ok in
  Publications.publish ~base_path ~author:"publisher" request |> Result.map_error Publications.error_message |> ok
let revise ~base_path ~id ~expected_revision ~author ?(format = "markdown") content =
  let request = Masc.Published_artifact.request_of_json (`Assoc
    ["id", `String id; "expected_revision", `Int expected_revision;
     "title", `String "shared draft fixture"; "summary", `String "native integration";
     "format", `String format; "content", `String content]) |> ok in
  Publications.publish ~base_path ~author request |> Result.map_error Publications.error_message |> ok
let boundary_tests = [
  "strict request actor and target boundaries", `Quick, (fun () ->
    let good = ["action", `String "select"; "target", Draft.target_to_json target; "anchor", `Int 0; "head", `Int 0] in
    ignore (Draft.command_of_json (`Assoc good) |> ok);
    List.iter (fun json -> match Draft.command_of_json json with Error _ -> () | Ok _ -> Alcotest.fail "invalid command accepted")
      [`Assoc (("actor", `String "spoof") :: good); `Assoc (("action", `String "edit") :: good);
       `Assoc (List.remove_assoc "target" good);
       `Assoc ["action", `String "edit"; "selection", `Assoc ["position", `Assoc ["anchor", `List []; "head", `List []]];
         "expected", `String ""; "replacement", `String "text"]]);
  "stored state schema and generation", `Quick, (fun () ->
    let draft = Draft.create ~target ~base_revision:1 ~base_sha256:(String.make 64 'a') ~state:"AAA=" ~actor:"server" ~at:"2026-10-25T13:00:00Z" |> ok in
    let restored = Draft.of_json (Draft.to_json draft) |> ok in
    Alcotest.(check string) "generation" target.generation restored.target.generation;
    let fields = match Draft.to_json draft with `Assoc fields -> fields | _ -> Alcotest.fail "object fixture" in
    List.iter (fun json -> match Draft.of_json json with Error _ -> () | Ok _ -> Alcotest.fail "invalid durable state accepted")
      [`Assoc (("schema", `String "unknown") :: List.remove_assoc "schema" fields);
       `Assoc (("state", `String "AB==") :: List.remove_assoc "state" fields);
       `Assoc (("sequence", `Int 1) :: fields)]);
  "catalog preserves earlier authors without changing the ordinary list", `Quick, (fun () -> with_base (fun base_path ->
    let artifact, _ = publish ~base_path "one" in
    ignore (revise ~base_path ~id:artifact.id ~expected_revision:1 ~author:"other" "two");
    let ordinary = Publications.list ~base_path |> Result.map_error Publications.error_message |> ok in
    let expanded = Publications.list_with_authors ~base_path |> Result.map_error Publications.error_message |> ok in
    let member = Yojson.Safe.Util.member in
    let normal = List.hd ordinary.artifacts and detailed = List.hd expanded.artifacts in
    Alcotest.(check bool) "ordinary list shape unchanged" true (member "authors" normal = `Null);
    Alcotest.(check bool) "all revision authors retained" true
      (member "authors" detailed = `List [`String "other"; `String "publisher"]);
    Alcotest.(check int) "latest revision" 2 (member "revision" detailed |> Yojson.Safe.Util.to_int)));
  "revising preserves omitted Task and Goal links", `Quick, (fun () -> with_base (fun base_path ->
    let make fields = Masc.Published_artifact.request_of_json (`Assoc
      (fields @ ["title", `String "linked report"; "summary", `String "work links";
        "format", `String "markdown"; "content", `String "body"])) |> ok in
    let artifact, _ = Publications.publish ~base_path ~author:"one"
      (make ["task_id", `String "task-1"; "goal_id", `String "goal-1"])
      |> Result.map_error Publications.error_message |> ok in
    let _, next = Publications.publish ~base_path ~author:"two"
      (make ["id", `String artifact.id; "expected_revision", `Int 1])
      |> Result.map_error Publications.error_message |> ok in
    Alcotest.(check (option string)) "task inherited" (Some "task-1") next.task_id;
    Alcotest.(check (option string)) "goal inherited" (Some "goal-1") next.goal_id;
    let _, replaced = Publications.publish ~base_path ~author:"three"
      (make ["id", `String artifact.id; "expected_revision", `Int 2;
        "task_id", `String "task-2"; "goal_id", `Null])
      |> Result.map_error Publications.error_message |> ok in
    Alcotest.(check (option string)) "explicit task replaces" (Some "task-2") replaced.task_id;
    Alcotest.(check (option string)) "null explicitly clears" None replaced.goal_id));
  "publication lock propagates callback exceptions", `Quick, (fun () -> with_base (fun base_path ->
    let artifact, _ = publish ~base_path "one" in
    let propagated =
      match Publications.with_latest_locked ~base_path ~id:artifact.id ~expected_revision:1
        ~f:(fun _ _ -> raise (Sys_error "callback sentinel")) with
      | _ -> false
      | exception Sys_error message -> String.equal message "callback sentinel" in
    Alcotest.(check bool) "callback exception preserved" true propagated;
    ignore (revise ~base_path ~id:artifact.id ~expected_revision:1 ~author:"other" "two")));
]
let integration_tests runner =
  let execute base_path actor command = Store.execute ~runner ~base_path ~actor command |> stored in
  let open_draft base_path artifact_id = execute base_path "human" (Draft.Open { artifact_id; revision = 1 }) in
  let selection base_path target anchor head =
    match (execute base_path "reader" (Draft.Select { target; anchor; head })).selection with
    | Some (selection, _, _) -> selection | None -> Alcotest.fail "selection absent" in
  let edit base_path actor selection expected replacement = execute base_path actor (Draft.Edit { selection; expected; replacement }) in
  [
    "durable shared edit preserves publication", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "before\n가나다\nend" in
      let original = open_draft base_path artifact.id in
      let selected = selection base_path original.draft.target 7 10 in
      let prefix = selection base_path original.draft.target 0 0 in
      ignore (edit base_path "human" prefix "" "새 줄\n");
      let edited = edit base_path "keeper" selected "가나다" "함께 편집" in
      Masc.Keeper_fs.clear_dir_cache ();
      let recovered = Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored in
      Alcotest.(check string) "source" "새 줄\nbefore\n함께 편집\nend" recovered.content;
      Alcotest.(check int) "sequence" 2 recovered.draft.sequence;
      Alcotest.(check string) "authenticated actor" "keeper" recovered.draft.updated_by;
      Alcotest.(check string) "same generation" edited.draft.target.generation recovered.draft.target.generation;
      let _, revision, body = Publications.read ~base_path ~id:artifact.id ~revision:None |> Result.map_error Publications.error_message |> ok in
      Alcotest.(check int) "publication revision" 1 revision.revision;
      Alcotest.(check string) "publication unchanged" "before\n가나다\nend" body;
      let unchanged = execute base_path "idle reader" (Draft.Merge { target = recovered.draft.target; updates = [] }) in
      Alcotest.(check int) "no-op does not advance" 2 unchanged.draft.sequence;
      Alcotest.(check string) "no-op does not claim editing" "keeper" unchanged.draft.updated_by));
    "publication checkpoint preserves edits and discussion across versions", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "alpha beta" in
      let opened = open_draft base_path artifact.id in
      let left = selection base_path opened.draft.target 0 5 and right = selection base_path opened.draft.target 6 10 in
      ignore (edit base_path "human" left "alpha" "ALPHA");
      let edited = edit base_path "keeper" right "beta" "BETA" in
      let chosen = selection base_path opened.draft.target 0 5 in
      let request = { Masc.Artifact_discussion.id = Random_id.uuid_v7 ();
        command = Masc.Artifact_discussion.Comment { position = chosen.position; quote = "ALPHA";
          body = "shared comment"; proposal = None } } in
      let discussed = execute base_path "human" (Draft.Discuss { target = opened.draft.target; request }) in
      let prior_state = discussed.draft.state and prior_discussion = discussed.draft.discussion in
      ignore (revise ~base_path ~id:artifact.id ~expected_revision:1 ~author:"keeper" edited.content);
      let checkpoint = Store.checkpoint ~runner ~base_path ~actor:"keeper" ~target:opened.draft.target
        ~expected_sequence:discussed.draft.sequence ~revision:2 () in
      let settled = match checkpoint with
        | Ok (Store.Checkpointed view) -> view
        | Ok (Store.Already_current _) -> Alcotest.fail "new base was not committed"
        | Error error -> Alcotest.fail (Store.checkpoint_error_message error) in
      Alcotest.(check int) "base advanced" 2 settled.draft.base_revision;
      Alcotest.(check int) "sequence advanced" (discussed.draft.sequence + 1) settled.draft.sequence;
      Alcotest.(check string) "CRDT state unchanged" prior_state settled.draft.state;
      Alcotest.(check bool) "discussion retained" true (prior_discussion = settled.draft.discussion);
      let replay = Store.checkpoint ~runner ~base_path ~actor:"keeper" ~target:opened.draft.target
        ~expected_sequence:discussed.draft.sequence ~revision:2 () in
      (match replay with Ok (Store.Already_current view) ->
        Alcotest.(check int) "repeat is observation only" settled.draft.sequence view.draft.sequence
       | Ok (Store.Checkpointed _) -> Alcotest.fail "repeat committed another checkpoint"
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error));
      let prefix = selection base_path opened.draft.target 0 0 in
      let continued = edit base_path "other-keeper" prefix "" "next " in
      let replay = Store.checkpoint ~runner ~base_path ~actor:"keeper" ~target:opened.draft.target
        ~expected_sequence:discussed.draft.sequence ~revision:2 () in
      (match replay with Ok (Store.Already_current view) ->
        Alcotest.(check string) "later edit remains" "next ALPHA BETA" view.content
       | Ok (Store.Checkpointed _) -> Alcotest.fail "repeat replaced later edit"
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error));
      ignore (revise ~base_path ~id:artifact.id ~expected_revision:2 ~author:"other-keeper" continued.content);
      (match Store.checkpoint ~runner ~base_path ~actor:"other-keeper" ~target:opened.draft.target
          ~expected_sequence:continued.draft.sequence ~revision:3 () with
       | Ok (Store.Checkpointed view) ->
         Alcotest.(check int) "next base" 3 view.draft.base_revision;
         Alcotest.(check string) "next source" "next ALPHA BETA" view.content;
         Alcotest.(check bool) "discussion survives" true (prior_discussion = view.draft.discussion)
       | Ok (Store.Already_current _) -> Alcotest.fail "third publication not checkpointed"
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error));
      List.iter (fun (revision, expected) ->
        let _, _, content = Publications.read ~base_path ~id:artifact.id ~revision:(Some revision)
          |> Result.map_error Publications.error_message |> ok in
        Alcotest.(check string) "immutable publication" expected content)
        [1, "alpha beta"; 2, "ALPHA BETA"; 3, "next ALPHA BETA"]));
    "checkpoint refuses stale sequence, changed publication and changed format", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "source" in
      let draft = open_draft base_path artifact.id in
      ignore (revise ~base_path ~id:artifact.id ~expected_revision:1 ~author:"other" "different");
      (match Store.checkpoint ~runner ~base_path ~actor:"keeper" ~target:draft.draft.target
          ~expected_sequence:1 ~revision:2 () with
       | Error (Store.Sequence_conflict { expected = 1; actual = 0 }) -> ()
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error)
       | Ok _ -> Alcotest.fail "wrong draft sequence accepted");
      (match Store.checkpoint ~runner ~base_path ~actor:"keeper" ~target:draft.draft.target
          ~expected_sequence:0 ~revision:2 () with
       | Error Store.Published_content_mismatch -> ()
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error)
       | Ok _ -> Alcotest.fail "different publication accepted");
      ignore (revise ~base_path ~id:artifact.id ~expected_revision:2 ~author:"other" ~format:"html" "source");
      (match Store.checkpoint ~runner ~base_path ~actor:"keeper" ~target:draft.draft.target
          ~expected_sequence:0 ~revision:2 () with
       | Error (Store.Draft_error (Store.Artifact_error (Publications.Conflict { expected = 2; actual = 3 }))) -> ()
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error)
       | Ok _ -> Alcotest.fail "older publication accepted");
      (match Store.checkpoint ~runner ~base_path ~actor:"keeper" ~target:draft.draft.target
          ~expected_sequence:0 ~revision:3 () with
       | Error Store.Published_format_mismatch -> ()
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error)
       | Ok _ -> Alcotest.fail "changed format accepted");
      let current = Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored in
      Alcotest.(check int) "old base retained" 1 current.draft.base_revision;
      Alcotest.(check string) "draft source retained" "source" current.content));
    "checkpoint detects an edit between observation and commit", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "source" in
      let draft = open_draft base_path artifact.id in
      ignore (revise ~base_path ~id:artifact.id ~expected_revision:1 ~author:"other" "source");
      let prefix = selection base_path draft.draft.target 0 0 in
      let once = ref false in
      let interleaved input =
        let result = runner input in
        if not !once then begin
          once := true;
          ignore (edit base_path "human" prefix "" "new ")
        end;
        result in
      (match Store.checkpoint ~runner:interleaved ~base_path ~actor:"keeper" ~target:draft.draft.target
          ~expected_sequence:0 ~revision:2 () with
       | Error Store.Draft_snapshot_changed -> ()
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error)
       | Ok _ -> Alcotest.fail "interleaved edit overwritten");
      let current = Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored in
      Alcotest.(check int) "base unchanged" 1 current.draft.base_revision;
      Alcotest.(check string) "interleaved edit retained" "new source" current.content));
    "checkpoint detects a publication after draft observation", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "source" in
      let draft = open_draft base_path artifact.id in
      ignore (revise ~base_path ~id:artifact.id ~expected_revision:1 ~author:"other" "source");
      let once = ref false in
      let interleaved input =
        let result = runner input in
        if not !once then begin
          once := true;
          ignore (revise ~base_path ~id:artifact.id ~expected_revision:2 ~author:"other" "newer")
        end;
        result in
      (match Store.checkpoint ~runner:interleaved ~base_path ~actor:"keeper" ~target:draft.draft.target
          ~expected_sequence:0 ~revision:2 () with
       | Error (Store.Draft_error (Store.Artifact_error (Publications.Conflict { expected = 2; actual = 3 }))) -> ()
       | Error error -> Alcotest.fail (Store.checkpoint_error_message error)
       | Ok _ -> Alcotest.fail "interleaved publication ignored");
      let current = Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored in
      Alcotest.(check int) "base unchanged" 1 current.draft.base_revision;
      let _, latest, content = Publications.read ~base_path ~id:artifact.id ~revision:None
        |> Result.map_error Publications.error_message |> ok in
      Alcotest.(check int) "new publication retained" 3 latest.revision;
      Alcotest.(check string) "new publication content retained" "newer" content));
    "concurrent distinct edits recompute after CAS", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "alpha beta" in
      let draft = open_draft base_path artifact.id in
      let left = selection base_path draft.draft.target 0 5 and right = selection base_path draft.draft.target 6 10 in
      let a, b = Eio.Fiber.pair (fun () -> edit base_path "human" left "alpha" "ALPHA") (fun () -> edit base_path "keeper" right "beta" "BETA") in
      let recovered = Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored in
      Alcotest.(check string) "both writers retained" "ALPHA BETA" recovered.content;
      Alcotest.(check int) "two commits" 2 recovered.draft.sequence;
      Alcotest.(check bool) "distinct durable sequence" true (a.draft.sequence <> b.draft.sequence)));
    "stale selected text and generation cannot overwrite", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "original" in let draft = open_draft base_path artifact.id in
      let selected = selection base_path draft.draft.target 0 8 in
      ignore (edit base_path "human" selected "original" "changed");
      (match Store.execute ~runner ~base_path ~actor:"keeper" (Draft.Edit { selection = selected; expected = "original"; replacement = "overwrite" }) with
       | Error (Store.Transform_error { kind = Engine.Changed_selection; _ }) -> ()
       | Error error -> Alcotest.fail (Store.error_message error) | Ok _ -> Alcotest.fail "stale edit accepted");
      let other = { draft.draft.target with Draft.generation = Random_id.uuid_v7 () } in
      (match Store.execute ~runner ~base_path ~actor:"keeper" (Draft.Merge { target = other; updates = [] }) with
       | Error (Store.Generation_conflict _) -> () | Error error -> Alcotest.fail (Store.error_message error) | Ok _ -> Alcotest.fail "generation ignored");
      Alcotest.(check string) "prior edit retained" "changed" (Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored).content));
    "bound end selection edits its own document", `Quick, (fun () -> with_base (fun base_path ->
      let a, _ = publish ~base_path "ABC" and b, _ = publish ~base_path "OTHER" in
      let first = open_draft base_path a.id in ignore (open_draft base_path b.id);
      let selected = selection base_path first.draft.target 3 3 in
      ignore (edit base_path "keeper" selected "" "X");
      Alcotest.(check string) "selected document" "ABCX" (Store.read ~runner ~base_path ~artifact_id:a.id () |> stored).content;
      Alcotest.(check string) "other document" "OTHER" (Store.read ~runner ~base_path ~artifact_id:b.id () |> stored).content));
    "corruption cannot silently reseed", `Quick, (fun () -> with_base (fun base_path ->
      let artifact, _ = publish ~base_path "publication" in ignore (open_draft base_path artifact.id);
      let file = Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "artifact_drafts") (artifact.id ^ ".json") in
      Fs_compat.save_file file "{corrupt";
      (match Store.execute ~runner ~base_path ~actor:"human" (Draft.Open { artifact_id = artifact.id; revision = 1 }) with
       | Error (Store.Unavailable _) -> () | Error error -> Alcotest.fail (Store.error_message error) | Ok _ -> Alcotest.fail "corruption overwritten");
      Alcotest.(check string) "corrupt bytes retained" "{corrupt" (Fs_compat.load_file file)));
  ]
let () = Eio_main.run (fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let integration, argv = if Array.length Sys.argv = 3 && Sys.argv.(1) = "--transformer"
    then integration_tests (Engine.default_runner ~executable:Sys.argv.(2)), [|Sys.argv.(0)|] else [], Sys.argv in
  Eio.Switch.run (fun sw -> Eio.Switch.on_release sw Process_eio.reset_for_testing;
    Alcotest.run ~argv "Artifact shared drafts" ["schema", boundary_tests; "durable", integration]))
