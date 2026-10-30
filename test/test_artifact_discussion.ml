module Discussion = Masc.Artifact_discussion
module Draft = Masc.Artifact_draft
module Store = Masc.Artifact_draft_store
module Publications = Masc.Published_artifact_store
module Engine = Artifact_document_engine
let ok = function Ok value -> value | Error message -> Alcotest.fail message
let stored result = Result.map_error Store.error_message result |> ok
let request command : Discussion.request = { id = Random_id.uuid_v7 (); command }
let threads view = Discussion.threads view.Store.draft.discussion |> ok
let with_base f =
  let base = Filename.temp_file "artifact_discussion_" "" in Sys.remove base; Unix.mkdir base 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Eio.Switch.run (fun sw -> Eio.Switch.on_release sw (fun () -> remove base); f base)
let fixture runner content f = with_base (fun base_path ->
  let publication = Masc.Published_artifact.request_of_json (`Assoc ["title", `String "discussion QA";
    "summary", `String "isolated"; "format", `String "markdown"; "content", `String content]) |> ok in
  let artifact, _ = Publications.publish ~base_path ~author:"publisher" publication |> Result.map_error Publications.error_message |> ok in
  let execute actor command = Store.execute ~runner ~base_path ~actor command in
  let original = execute "human" (Draft.Open { artifact_id = artifact.id; revision = 1 }) |> stored in
  let target = original.draft.target in
  let select anchor head = match (execute "human" (Draft.Select { target; anchor; head }) |> stored).selection with
    | Some (selection, _, _) -> selection | None -> Alcotest.fail "selection missing" in
  let discuss actor request = execute actor (Draft.Discuss { target; request }) in
  let read () = Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored in
  f base_path artifact original execute select discuss read)
let pure_tests = [
  "strict event decoding and immutable operation identity", `Quick, (fun () ->
    let position = { Engine.anchor = [0]; head = [0] } in
    let first = request (Discussion.Comment { position; quote = "alpha"; body = "comment"; proposal = Some "new" }) in
    let events = Discussion.append [] ~actor:"human" ~at:"now" first ~applied:None |> ok in
    ignore (Discussion.events_of_json (Discussion.events_to_json events) |> ok);
    Alcotest.(check int) "same request deduplicates" 1 (List.length (Discussion.append events ~actor:"human" ~at:"later" first ~applied:None |> ok));
    (match Discussion.check events ~actor:"other" first with Error _ -> () | Ok _ -> Alcotest.fail "author collision accepted");
    let invalid = match Discussion.events_to_json events with
      | `List [event] -> [`List [event; event]; `List [`Assoc ["request", Discussion.request_to_json first; "actor", `String "human"; "at", `String "now"]]]
      | _ -> Alcotest.fail "event fixture" in
    List.iter (fun json -> match Discussion.events_of_json json with Error _ -> () | Ok _ -> Alcotest.fail "invalid event history accepted") invalid;
    (match Discussion.append [] ~actor:"human" ~at:"now" (request (Discussion.Resolve first.id)) ~applied:None with
      | Error _ -> () | Ok _ -> Alcotest.fail "orphan thread event accepted"));
  "selection UTF-16 boundaries preserve emoji and CRLF", `Quick, (fun () ->
    let positioned anchor head = { Engine.snapshot = { state = "AAA="; content = "A😀\r\n한글" };
      selection = { anchor = []; head = [] }; anchor; head } in
    Alcotest.(check string) "emoji with CRLF" "😀\r\n" (Engine.selected_text (positioned 1 5) |> Result.map_error Engine.error_message |> ok);
    (match Engine.selected_text (positioned 2 3) with Error _ -> () | Ok _ -> Alcotest.fail "surrogate boundary accepted"));
]
let integration_tests runner = [
  "comments replies and reopen persist without changing text state", `Quick, (fun () -> fixture runner "alpha 😀\r\n한글" (fun _ _ original _ select discuss read ->
    let selection = select 6 8 in
    let first = request (Discussion.Comment { position = selection.position; quote = "😀"; body = "확인 부탁해요"; proposal = None }) in
    let added = discuss "human" first |> stored in
    Alcotest.(check string) "no CRDT text mutation" original.draft.state added.draft.state;
    let reply = request (Discussion.Reply { thread_id = first.id; body = "Keeper가 확인했어요" }) in
    ignore (discuss "keeper" reply |> stored);
    ignore (discuss "human" (request (Discussion.Resolve first.id)) |> stored);
    ignore (discuss "human" (request (Discussion.Reopen first.id)) |> stored);
    Masc.Keeper_fs.clear_dir_cache ();
    let recovered = read () in let thread = List.hd (threads recovered) in
    Alcotest.(check int) "four atomic events" 4 recovered.draft.sequence;
    Alcotest.(check int) "two messages" 2 (List.length thread.messages);
    Alcotest.(check string) "actual reply actor" "keeper" (List.nth thread.messages 1).actor;
    Alcotest.(check bool) "reopened" false thread.resolved;
    Alcotest.(check string) "source remains" original.content recovered.content;
    let duplicate = discuss "keeper" reply |> stored in
    Alcotest.(check int) "reply retry is unchanged" recovered.draft.sequence duplicate.draft.sequence;
    (match discuss "spoof" reply with Error (Store.Discussion_conflict _) -> () | _ -> Alcotest.fail "request author not checked")));
  "accept atomically commits proposal and durable receipt after another prefix edit", `Quick, (fun () -> fixture runner "alpha beta\r\n한글 😀\r\n" (fun base_path artifact _ execute select discuss read ->
    let selection = select 0 5 in
    let first = request (Discussion.Comment { position = selection.position; quote = "alpha"; body = "이렇게 바꾸면 어떨까요?"; proposal = Some "함께 편집" }) in
    ignore (discuss "keeper" first |> stored);
    ignore (execute "human" (Draft.Edit { selection = select 0 0; expected = ""; replacement = "사람: " }) |> stored);
    let accept = request (Discussion.Accept first.id) in
    let applied = discuss "human" accept |> stored in
    Alcotest.(check string) "both edits" "사람: 함께 편집 beta\r\n한글 😀\r\n" applied.content;
    Masc.Keeper_fs.clear_dir_cache ();
    let recovered = read () in
    let thread = List.hd (threads recovered) in
    (match thread.decision with
     | Discussion.Applied event -> Alcotest.(check string) "durable operation receipt" accept.id event.request.id
     | Pending | Rejected _ -> Alcotest.fail "applied text has no applied receipt");
    Alcotest.(check int) "comment prefix accept" 3 recovered.draft.sequence;
    Alcotest.(check int) "exact retry not another replacement" 3 (discuss "human" accept |> stored).draft.sequence;
    (match discuss "keeper" (request (Discussion.Accept first.id)) with Error (Store.Discussion_conflict _) -> () | _ -> Alcotest.fail "decided proposal applied again");
    let _, publication, body = Publications.read ~base_path ~id:artifact.id ~revision:None |> Result.map_error Publications.error_message |> ok in
    Alcotest.(check int) "immutable revision" 1 publication.revision;
    Alcotest.(check string) "immutable content" "alpha beta\r\n한글 😀\r\n" body));
  "changed quote refuses both comment creation and proposal acceptance", `Quick, (fun () -> fixture runner "alpha" (fun _ _ _ execute select discuss read ->
    let selection = select 0 5 in
    let first = request (Discussion.Comment { position = selection.position; quote = "alpha"; body = "proposal"; proposal = Some "new" }) in
    ignore (discuss "human" first |> stored);
    ignore (execute "keeper" (Draft.Edit { selection; expected = "alpha"; replacement = "changed" }) |> stored);
    let assert_changed = function Error (Store.Transform_error { kind = Engine.Changed_selection; _ }) -> () | _ -> Alcotest.fail "changed text was not refused" in
    assert_changed (discuss "human" (request (Discussion.Accept first.id)));
    assert_changed (discuss "human" (request (Discussion.Comment { position = selection.position; quote = "alpha"; body = "stale comment"; proposal = None })));
    let recovered = read () in
    Alcotest.(check string) "changed text kept" "changed" recovered.content;
    Alcotest.(check int) "no failed event appended" 1 (List.length recovered.draft.discussion);
    match (List.hd (threads recovered)).decision with Pending -> () | Applied _ | Rejected _ -> Alcotest.fail "failed accept changed status"));
  "concurrent accepts commit at most once", `Quick, (fun () -> fixture runner "alpha" (fun _ _ _ _ select discuss read ->
    let selection = select 0 5 in
    let first = request (Discussion.Comment { position = selection.position; quote = "alpha"; body = "proposal"; proposal = Some "new" }) in
    ignore (discuss "human" first |> stored);
    let a,b = Eio.Fiber.pair (fun () -> discuss "human" (request (Discussion.Accept first.id))) (fun () -> discuss "human" (request (Discussion.Accept first.id))) in
    let successes = List.filter Result.is_ok [a;b] in
    Alcotest.(check int) "one winner" 1 (List.length successes);
    let recovered = read () in Alcotest.(check int) "one accept event" 2 recovered.draft.sequence;
    Alcotest.(check string) "single replacement" "new" recovered.content));
  "empty replacement proposal and reject lifecycle", `Quick, (fun () -> fixture runner "alpha beta" (fun _ _ _ _ select discuss read ->
    let position = (select 0 5).position in
    let first = request (Discussion.Comment { position; quote = "alpha"; body = "delete"; proposal = Some "" }) in
    ignore (discuss "keeper" first |> stored); ignore (discuss "human" (request (Discussion.Accept first.id)) |> stored);
    Alcotest.(check string) "deletion is a proposal" " beta" (read ()).content;
    let second = request (Discussion.Comment { position = (select 1 5).position; quote = "beta"; body = "reject"; proposal = Some "next" }) in
    ignore (discuss "keeper" second |> stored); ignore (discuss "human" (request (Discussion.Reject second.id)) |> stored);
    (match discuss "human" (request (Discussion.Accept second.id)) with Error (Store.Discussion_conflict _) -> () | _ -> Alcotest.fail "rejected proposal applied");
    Alcotest.(check string) "rejection keeps text" " beta" (read ()).content));
]
let () = Eio_main.run (fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let integration, argv = if Array.length Sys.argv = 3 && Sys.argv.(1) = "--transformer"
    then integration_tests (Engine.default_runner ~executable:Sys.argv.(2)), [|Sys.argv.(0)|] else [], Sys.argv in
  Eio.Switch.run (fun sw -> Eio.Switch.on_release sw Process_eio.reset_for_testing;
    Alcotest.run ~argv "artifact discussion" ["contract", pure_tests; "durable", integration]))
