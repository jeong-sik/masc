open Masc
module Draft = Artifact_draft
module Store = Artifact_draft_store
module Live = Artifact_draft_live
module Scope = Keeper_artifact_draft_scope
let require = function Ok value -> value | Error message -> Alcotest.fail message
let stored value = value |> Result.map_error Store.error_message |> require
let turn_ref = Ids.Turn_ref.make ~trace_id:"draft-turn" ~absolute_turn:17
let member = Yojson.Safe.Util.member
let text = Yojson.Safe.Util.to_string
let with_base f =
  let base_path = Filename.temp_file "keeper_draft" "" in Sys.remove base_path; Unix.mkdir base_path 0o700;
  let rec remove path = match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> f (Unix.realpath base_path))
let publish base_path content =
  let request = Published_artifact.request_of_json (`Assoc ["title", `String "Keeper draft fixture"; "summary", `String "native";
    "format", `String "markdown"; "content", `String content]) |> require in
  Published_artifact_store.publish ~base_path ~author:"publisher" request
  |> Result.map_error Published_artifact_store.error_message |> require |> fst
let success (result : Keeper_tool_execution.t) =
  (match result.disposition with Tool_result.Completed () -> () | Deferred _ -> Alcotest.fail "deferred"
    | Failed _ -> Alcotest.fail result.raw_output);
  match result.data with Some value -> value | None -> Alcotest.fail "missing typed result"
let frame session = match Live.observe session with Some (frame, _) -> frame | None -> Alcotest.fail "observer absent"
let peers session = member "peers" (frame session) |> Yojson.Safe.Util.to_list
let target_of result = member "target" result |> Draft.target_of_json |> require
let open_args artifact_id = `Assoc ["action", `String "open"; "artifact_id", `String artifact_id; "revision", `Int 1]
let args action target = `Assoc ["action", `String action; "target", Draft.target_to_json target]
let select target anchor head = `Assoc ["action", `String "select"; "target", Draft.target_to_json target; "anchor", `Int anchor; "head", `Int head]
let edit selection expected replacement = `Assoc ["action", `String "edit"; "selection", selection; "expected", `String expected; "replacement", `String replacement]
let with_scope base_path f =
  let scope = Scope.create ~base_path ~keeper:"keeper-editor" in
  Fun.protect ~finally:(fun () -> Scope.close scope) (fun () -> f scope)
let with_observer base_path target f =
  let observer = Live.join ~source:Live.Dashboard_connection ~base_path ~actor:"human" ~target in
  Fun.protect ~finally:(fun () -> Live.leave observer) (fun () -> f observer)
let integration runner =
  let call scope base_path input = Keeper_artifact_draft.handle ~runner ~scope ~base_path ~keeper:"keeper-editor" ~turn_ref ~args:input () in
  [
  "Keeper discussion uses real actor and durable request receipts", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let artifact = publish base_path "alpha" in
    let opened = call scope base_path (open_args artifact.id) |> success in
    let target = target_of opened in
    let chosen = call scope base_path (select target 0 5) |> success in
    let position = member "position" (member "selection" chosen) |> Artifact_document_engine.selection_of_json |> require in
    let request = { Artifact_discussion.id = member "next_request_id" chosen |> text;
      command = Artifact_discussion.Comment { position; quote = "alpha"; body = "Keeper가 제안해요"; proposal = Some "함께 편집" } } in
    let input = `Assoc ["action", `String "discuss"; "target", Draft.target_to_json target;
      "request", Artifact_discussion.request_to_json request] in
    let commented = call scope base_path input |> success in
    let receipt = member "discussion_receipts" commented |> Yojson.Safe.Util.to_list |> List.hd in
    Alcotest.(check string) "actual actor" "keeper-editor" (member "actor" receipt |> text);
    Alcotest.(check string) "stable receipt" request.id (member "id" (member "request" receipt) |> text);
    Alcotest.(check string) "comment does not edit text" "alpha" (member "content" commented |> text);
    let duplicate = call scope base_path input |> success in
    Alcotest.(check int) "retry one event" 1 (member "discussion_receipts" duplicate |> Yojson.Safe.Util.to_list |> List.length);
    let accept = { Artifact_discussion.id = member "next_request_id" duplicate |> text; command = Artifact_discussion.Accept request.id } in
    let result = call scope base_path (`Assoc ["action", `String "discuss"; "target", Draft.target_to_json target;
      "request", Artifact_discussion.request_to_json accept]) |> success in
    Alcotest.(check string) "proposal applied" "함께 편집" (member "content" result |> text))));
  "selected Keeper edit follows human prefix and preserves publication", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let artifact = publish base_path "alpha\r\n한글 😀\r\n" in
    let opened = call scope base_path (open_args artifact.id) |> success in
    Alcotest.(check bool) "no CRDT state in model result" true (member "state" opened = `Null);
    let target = target_of opened in
    with_observer base_path target (fun observer ->
      let chosen = call scope base_path (select target 7 9) |> success |> member "selection" in
      let keeper_peer = List.find (fun peer -> member "actor" peer = `String "keeper-editor") (peers observer) in
      Alcotest.(check string) "real turn source" "keeper_turn" (member "kind" (member "source" keeper_peer) |> text);
      Alcotest.(check string) "exact turn identity" (Ids.Turn_ref.to_string turn_ref) (member "turn_ref" (member "source" keeper_peer) |> text);
      Alcotest.(check bool) "dashboard cannot borrow Keeper session" true
        (Result.is_error (Live.find ~base_path ~actor:"keeper-editor" ~target ~session_id:(member "session_id" keeper_peer |> text)));
      let prefix = Store.execute ~runner ~base_path ~actor:"human" (Draft.Select { target; anchor = 0; head = 0 }) |> stored in
      let selection = match prefix.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "selection absent" in
      ignore (Store.execute ~runner ~base_path ~actor:"human" (Draft.Edit { selection; expected = ""; replacement = "먼저 " }) |> stored);
      let edited = call scope base_path (edit chosen "한글" "공동 편집") |> success in
      Alcotest.(check string) "both writers retained" "먼저 alpha\r\n공동 편집 😀\r\n" (member "content" edited |> text);
      let _, _, original = Published_artifact_store.read ~base_path ~id:artifact.id ~revision:(Some 1)
        |> Result.map_error Published_artifact_store.error_message |> require in
      Alcotest.(check string) "immutable publication" "alpha\r\n한글 😀\r\n" original;
      Scope.close scope;
      Alcotest.(check int) "turn end removes Keeper peer" 1 (List.length (peers observer))))));
  "closed owner refuses new work but preserves a late committed receipt", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let artifact = publish base_path "before" in
    let target = call scope base_path (open_args artifact.id) |> success |> target_of in
    let selected = call scope base_path (select target 0 6) |> success |> member "selection" in
    with_observer base_path target (fun observer ->
      let late_runner input = Scope.close scope; runner input in
      let receipt = Keeper_artifact_draft.handle ~runner:late_runner ~scope ~base_path ~keeper:"keeper-editor" ~turn_ref
          ~args:(edit selected "before" "after") () |> success in
      Alcotest.(check string) "committed result retained" "after" (member "content" receipt |> text);
      Alcotest.(check bool) "presence ended" false (member "presence_active" receipt |> Yojson.Safe.Util.to_bool);
      Alcotest.(check int) "late result cannot rejoin" 1 (List.length (peers observer));
      let refused = call scope base_path (select target 0 1) in
      Alcotest.(check bool) "ended turn refused before effects" true
        (refused.failure_effect_disposition = Tool_result.Proven_pre_effect && match refused.disposition with Failed _ -> true | Completed () | Deferred _ -> false)))));
  "one turn advertises only its current document", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let a = publish base_path "A" and b = publish base_path "B" in
    let target_a = call scope base_path (open_args a.id) |> success |> target_of in
    with_observer base_path target_a (fun observer ->
      ignore (call scope base_path (open_args b.id) |> success);
      Alcotest.(check int) "previous document has no Keeper cursor" 1 (List.length (peers observer))))));
  "spoofed actor and changed selection are refused", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let artifact = publish base_path "before" in
    let target = call scope base_path (open_args artifact.id) |> success |> target_of in
    let chosen = call scope base_path (select target 0 6) |> success |> member "selection" in
    let human_selection = Store.execute ~runner ~base_path ~actor:"human" (Draft.Select { target; anchor = 0; head = 6 }) |> stored in
    let selected = match human_selection.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "human selection absent" in
    ignore (Store.execute ~runner ~base_path ~actor:"human" (Draft.Edit { selection = selected; expected = "before"; replacement = "human" }) |> stored);
    let refused = call scope base_path (edit chosen "before" "overwrite") in
    Alcotest.(check bool) "changed text is workflow refusal" true (refused.disposition = Tool_result.Failed Tool_result.Workflow_rejection);
    let spoofed = match args "read" target with `Assoc fields -> `Assoc (("actor", `String "other") :: fields) | _ -> Alcotest.fail "object" in
    Alcotest.(check bool) "actor is not payload" true ((call scope base_path spoofed).disposition = Tool_result.Failed Tool_result.Policy_rejection);
    Alcotest.(check string) "human text retained" "human" (Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored).content)));
  "find another author, edit together and publish the same artifact", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let artifact = publish base_path "alpha beta" in
    let found = call scope base_path (`Assoc ["action", `String "find"; "query", `String "draft fixture"]) |> success in
    let candidate = member "artifacts" found |> Yojson.Safe.Util.to_list |> List.hd in
    Alcotest.(check string) "other writer's artifact found" artifact.id (member "id" candidate |> text);
    let published = call scope base_path (`Assoc ["action", `String "published"; "artifact_id", `String artifact.id]) |> success in
    Alcotest.(check string) "published source read" "alpha beta" (member "content" published |> text);
    let target = call scope base_path (open_args artifact.id) |> success |> target_of in
    let human = Store.execute ~runner ~base_path ~actor:"human" (Draft.Select { target; anchor = 6; head = 10 }) |> stored in
    let human_selection = match human.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "human selection absent" in
    ignore (Store.execute ~runner ~base_path ~actor:"human" (Draft.Edit { selection = human_selection; expected = "beta"; replacement = "human" }) |> stored);
    let chosen = call scope base_path (select target 0 5) |> success |> member "selection" in
    let edited = call scope base_path (edit chosen "alpha" "keeper") |> success in
    let content = member "content" edited |> text in
    Alcotest.(check string) "both writers retained" "keeper human" content;
    let request = `Assoc ["id", `String artifact.id; "expected_revision", `Int 1;
      "title", `String "Keeper draft fixture"; "summary", `String "native";
      "format", `String "markdown"; "content", `String content] in
    ignore (Keeper_artifact_publish.handle ~base_path ~author:"keeper-editor" ~args:request |> success);
    let checkpoint sequence revision = `Assoc ["action", `String "checkpoint"; "target", Draft.target_to_json target;
      "expected_sequence", sequence; "revision", `Int revision] in
    let checked = call scope base_path (checkpoint (member "sequence" edited) 2) |> success in
    Alcotest.(check int) "published draft becomes new base" 2 (member "base_revision" checked |> Yojson.Safe.Util.to_int);
    let found = call scope base_path (`Assoc ["action", `String "find"; "query", `String "draft fixture"]) |> success in
    let candidates = member "artifacts" found |> Yojson.Safe.Util.to_list in
    Alcotest.(check int) "one document" 1 (List.length candidates);
    Alcotest.(check int) "version advanced" 2 (member "revision" (List.hd candidates) |> Yojson.Safe.Util.to_int);
    let _, _, original = Published_artifact_store.read ~base_path ~id:artifact.id ~revision:(Some 1)
      |> Result.map_error Published_artifact_store.error_message |> require in
    Alcotest.(check string) "original publication remains unchanged" "alpha beta" original;
    let second_scope = Scope.create ~base_path ~keeper:"second-editor" in
    Fun.protect ~finally:(fun () -> Scope.close second_scope) (fun () ->
      let call_second input = Keeper_artifact_draft.handle ~runner ~scope:second_scope ~base_path
          ~keeper:"second-editor" ~turn_ref ~args:input () in
      let reopened = call_second (`Assoc ["action", `String "open"; "artifact_id", `String artifact.id; "revision", `Int 2]) |> success in
      Alcotest.(check int) "other Keeper joins version two" 2 (member "base_revision" reopened |> Yojson.Safe.Util.to_int);
      let selected = call_second (select target 0 6) |> success |> member "selection" in
      let next = call_second (edit selected "keeper" "second") |> success in
      let next_content = member "content" next |> text in
      let request = `Assoc ["id", `String artifact.id; "expected_revision", `Int 2;
        "title", `String "Keeper draft fixture"; "summary", `String "native";
        "format", `String "markdown"; "content", `String next_content] in
      ignore (Keeper_artifact_publish.handle ~base_path ~author:"second-editor" ~args:request |> success);
      let tail = String.length next_content in
      let human = Store.execute ~runner ~base_path ~actor:"human" (Draft.Select { target; anchor = tail; head = tail }) |> stored in
      let selection = match human.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "human selection absent" in
      ignore (Store.execute ~runner ~base_path ~actor:"human" (Draft.Edit { selection; expected = ""; replacement = "!" }) |> stored);
      let refused = call_second (checkpoint (member "sequence" next) 3) in
      Alcotest.(check bool) "intervening edit blocks checkpoint" true
        (refused.disposition = Tool_result.Failed Tool_result.Workflow_rejection);
      let remaining = call_second (args "read" target) |> success in
      Alcotest.(check string) "intervening human edit remains" (next_content ^ "!") (member "content" remaining |> text);
      let request = `Assoc ["id", `String artifact.id; "expected_revision", `Int 3;
        "title", `String "Keeper draft fixture"; "summary", `String "native";
        "format", `String "markdown"; "content", member "content" remaining] in
      ignore (Keeper_artifact_publish.handle ~base_path ~author:"second-editor" ~args:request |> success);
      let checked = call_second (checkpoint (member "sequence" remaining) 4) |> success in
      Alcotest.(check int) "new checkpoint advances without losing edit" 4 (member "base_revision" checked |> Yojson.Safe.Util.to_int);
      let _, _, version_two = Published_artifact_store.read ~base_path ~id:artifact.id ~revision:(Some 2)
        |> Result.map_error Published_artifact_store.error_message |> require in
      Alcotest.(check string) "earlier collaborative version remains" "keeper human" version_two))));
  ]
let discovery_tests = [
  "workspace candidates and exact published source", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let artifact = publish base_path "source by another author" in
    let call input = Keeper_artifact_draft.handle ~scope ~base_path ~keeper:"keeper-editor" ~turn_ref ~args:input () in
    let found = call (`Assoc ["action", `String "find"; "query", `String "draft fixture"]) |> success in
    let items = member "artifacts" found |> Yojson.Safe.Util.to_list in
    Alcotest.(check int) "one candidate" 1 (List.length items);
    Alcotest.(check string) "shared author" "publisher" (member "author" (List.hd items) |> text);
    Alcotest.(check string) "same ID" artifact.id (member "id" (List.hd items) |> text);
    Alcotest.(check bool) "find omits body" true (member "body" (List.hd items) = `Null);
    let latest = call (`Assoc ["action", `String "published"; "artifact_id", `String artifact.id]) |> success in
    Alcotest.(check string) "latest bytes" "source by another author" (member "content" latest |> text);
    let revision = `Assoc ["id", `String artifact.id; "expected_revision", `Int 1;
      "title", `String "Keeper draft fixture"; "summary", `String "native";
      "format", `String "markdown"; "content", `String "revised"] in
    ignore (Keeper_artifact_publish.handle ~base_path ~author:"keeper-editor" ~args:revision |> success);
    let found = call (`Assoc ["action", `String "find"; "query", `String "publisher"]) |> success in
    let candidate = member "artifacts" found |> Yojson.Safe.Util.to_list |> List.hd in
    Alcotest.(check string) "original author remains searchable" artifact.id (member "id" candidate |> text);
    Alcotest.(check int) "search returns latest revision" 2 (member "revision" candidate |> Yojson.Safe.Util.to_int);
    Scope.close scope;
    Alcotest.(check bool) "closed turn cannot enumerate" true
      ((call (`Assoc ["action", `String "find"; "query", `String ""]) ).disposition = Tool_result.Failed Tool_result.Runtime_failure))));
  "pages preserve identity and refuse stale or incomplete inventory", `Quick, (fun () -> with_base (fun base_path -> with_scope base_path (fun scope ->
    let publish_named index =
      let request = Published_artifact.request_of_json (`Assoc ["title", `String ("team " ^ string_of_int index ^ String.make 8000 'x');
        "summary", `String "shared"; "format", `String "markdown"; "content", `String "body"]) |> require in
      Published_artifact_store.publish ~base_path ~author:"another-keeper" request
      |> Result.map_error Published_artifact_store.error_message |> require |> fst in
    let expected = List.init 4 publish_named |> List.map (fun artifact -> artifact.Published_artifact.id) |> List.sort String.compare in
    let dir = Filename.concat (Common.masc_dir_from_base_path ~base_path) "published_artifacts" in
    Fs_compat.save_file (Filename.concat dir ("artifact-" ^ String.make 32 'f' ^ ".json")) "invalid json";
    let call query cursor =
      let fields = ["action", `String "find"; "query", `String query] in
      let fields = match cursor with None -> fields | Some cursor -> ("cursor", cursor) :: fields in
      Keeper_artifact_draft.handle ~scope ~base_path ~keeper:"keeper-editor" ~turn_ref ~args:(`Assoc fields) () in
    let first = call "team" None |> success in
    Alcotest.(check int) "unreadable entry is visible" 1 (member "unreadable_count" first |> Yojson.Safe.Util.to_int);
    let cursor = member "next_cursor" first in
    Alcotest.(check bool) "wire-bounded page has continuation" true (cursor <> `Null);
    let rec collect result =
      let ids = member "artifacts" result |> Yojson.Safe.Util.to_list |> List.map (fun row -> member "id" row |> text) in
      match member "next_cursor" result with
      | `Null -> ids
      | cursor -> ids @ collect (call "team" (Some cursor) |> success) in
    Alcotest.(check (list string)) "all pages contain each document once" expected (collect first);
    Alcotest.(check bool) "cursor is bound to query" true
      ((call "different" (Some cursor)).disposition = Tool_result.Failed Tool_result.Workflow_rejection);
    ignore (publish base_path "unrelated source");
    ignore (call "team" (Some cursor) |> success);
    ignore (publish_named 5);
    Alcotest.(check bool) "changed catalog invalidates cursor" true
      ((call "team" (Some cursor)).disposition = Tool_result.Failed Tool_result.Workflow_rejection))));
]
let schema_tests = ["canonical tool and sealed owner", `Quick, (fun () ->
  let descriptor = match Keeper_tool_descriptor.find_id "keeper.artifact.draft" with Some descriptor -> descriptor | None -> Alcotest.fail "missing descriptor" in
  Alcotest.(check (list string)) "model schema" [] (Keeper_tool_descriptor.model_schema_errors descriptor);
  Alcotest.(check bool) "writes serialize" true (descriptor.execution = Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial);
  let scope = Scope.create ~base_path:"/fixture" ~keeper:"keeper" in
  Fun.protect ~finally:(fun () -> Scope.close scope) (fun () ->
    ignore (Scope.admit scope ~base_path:"/fixture" ~keeper:"keeper" ~turn_ref |> Result.map_error (fun _ -> "admission") |> require);
    Alcotest.(check bool) "wrong workspace rejected" true (Result.is_error (Scope.admit scope ~base_path:"/other" ~keeper:"keeper" ~turn_ref));
    Alcotest.(check bool) "wrong turn rejected" true (Result.is_error (Scope.admit scope ~base_path:"/fixture" ~keeper:"keeper" ~turn_ref:(Ids.Turn_ref.make ~trace_id:"other" ~absolute_turn:17)));
    Scope.close scope;
    Alcotest.(check bool) "closed is terminal" true (Result.is_error (Scope.admit scope ~base_path:"/fixture" ~keeper:"keeper" ~turn_ref))))]
let () = Eio_main.run (fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let tests, argv = if Array.length Sys.argv = 3 && Sys.argv.(1) = "--transformer"
    then integration (Artifact_document_engine.default_runner ~executable:Sys.argv.(2)), [|Sys.argv.(0)|] else [], Sys.argv in
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    Alcotest.run ~argv "Keeper shared artifact draft" ["schema", schema_tests; "discovery", discovery_tests; "runtime", tests]))
