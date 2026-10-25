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
