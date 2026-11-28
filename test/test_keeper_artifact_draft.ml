open Masc
module Draft = Artifact_draft
module Store = Artifact_draft_store
let require = function Ok value -> value | Error message -> Alcotest.fail message
let stored value = value |> Result.map_error Store.error_message |> require
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
let target_of result = member "target" result |> Draft.target_of_json |> require
let open_args artifact_id = `Assoc ["action", `String "open"; "artifact_id", `String artifact_id; "revision", `Int 1]
let args action target = `Assoc ["action", `String action; "target", Draft.target_to_json target]
let select target anchor head = `Assoc ["action", `String "select"; "target", Draft.target_to_json target; "anchor", `Int anchor; "head", `Int head]
let edit selection expected replacement = `Assoc ["action", `String "edit"; "selection", selection; "expected", `String expected; "replacement", `String replacement]
let integration runner =
  let call base_path input = Keeper_artifact_draft.handle ~runner ~base_path ~keeper:"keeper-editor" ~args:input () in
  [
  "Keeper discussion uses real actor and durable request receipts", `Quick, (fun () -> with_base (fun base_path ->
    let artifact = publish base_path "alpha" in
    let opened = call base_path (open_args artifact.id) |> success in
    let target = target_of opened in
    let chosen = call base_path (select target 0 5) |> success in
    let position = member "position" (member "selection" chosen) |> Artifact_document_engine.selection_of_json |> require in
    let request = { Artifact_discussion.id = member "next_request_id" chosen |> text;
      command = Artifact_discussion.Comment { position; quote = "alpha"; body = "Keeper가 제안해요"; proposal = Some "함께 편집" } } in
    let input = `Assoc ["action", `String "discuss"; "target", Draft.target_to_json target;
      "request", Artifact_discussion.request_to_json request] in
    let commented = call base_path input |> success in
    let receipt = member "discussion_receipts" commented |> Yojson.Safe.Util.to_list |> List.hd in
    Alcotest.(check string) "actual actor" "keeper-editor" (member "actor" receipt |> text);
    Alcotest.(check string) "stable receipt" request.id (member "id" (member "request" receipt) |> text);
    Alcotest.(check string) "comment does not edit text" "alpha" (member "content" commented |> text);
    let duplicate = call base_path input |> success in
    Alcotest.(check int) "retry one event" 1 (member "discussion_receipts" duplicate |> Yojson.Safe.Util.to_list |> List.length);
    let accept = { Artifact_discussion.id = member "next_request_id" duplicate |> text; command = Artifact_discussion.Accept request.id } in
    let result = call base_path (`Assoc ["action", `String "discuss"; "target", Draft.target_to_json target;
      "request", Artifact_discussion.request_to_json accept]) |> success in
    Alcotest.(check string) "proposal applied" "함께 편집" (member "content" result |> text)));
  "selected Keeper edit follows human prefix and preserves publication", `Quick, (fun () -> with_base (fun base_path ->
    let artifact = publish base_path "alpha\r\n한글 😀\r\n" in
    let opened = call base_path (open_args artifact.id) |> success in
    Alcotest.(check bool) "no CRDT state in model result" true (member "state" opened = `Null);
    let target = target_of opened in
    let chosen = call base_path (select target 7 9) |> success |> member "selection" in
    let prefix = Store.execute ~runner ~base_path ~actor:"human" (Draft.Select { target; anchor = 0; head = 0 }) |> stored in
    let selection = match prefix.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "selection absent" in
    ignore (Store.execute ~runner ~base_path ~actor:"human" (Draft.Edit { selection; expected = ""; replacement = "먼저 " }) |> stored);
    let edited = call base_path (edit chosen "한글" "공동 편집") |> success in
    Alcotest.(check string) "both writers retained" "먼저 alpha\r\n공동 편집 😀\r\n" (member "content" edited |> text);
    let _, _, original = Published_artifact_store.read ~base_path ~id:artifact.id ~revision:(Some 1)
      |> Result.map_error Published_artifact_store.error_message |> require in
    Alcotest.(check string) "immutable publication" "alpha\r\n한글 😀\r\n" original));
  "spoofed actor and changed selection are refused", `Quick, (fun () -> with_base (fun base_path ->
    let artifact = publish base_path "before" in
    let target = call base_path (open_args artifact.id) |> success |> target_of in
    let chosen = call base_path (select target 0 6) |> success |> member "selection" in
    let human_selection = Store.execute ~runner ~base_path ~actor:"human" (Draft.Select { target; anchor = 0; head = 6 }) |> stored in
    let selected = match human_selection.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "human selection absent" in
    ignore (Store.execute ~runner ~base_path ~actor:"human" (Draft.Edit { selection = selected; expected = "before"; replacement = "human" }) |> stored);
    let refused = call base_path (edit chosen "before" "overwrite") in
    Alcotest.(check bool) "changed text is workflow refusal" true (refused.disposition = Tool_result.Failed Tool_result.Workflow_rejection);
    let spoofed = match args "read" target with `Assoc fields -> `Assoc (("actor", `String "other") :: fields) | _ -> Alcotest.fail "object" in
    Alcotest.(check bool) "actor is not payload" true ((call base_path spoofed).disposition = Tool_result.Failed Tool_result.Policy_rejection);
    Alcotest.(check string) "human text retained" "human" (Store.read ~runner ~base_path ~artifact_id:artifact.id () |> stored).content));
  "find another author, edit together and publish the same artifact", `Quick, (fun () -> with_base (fun base_path ->
    let artifact = publish base_path "alpha beta" in
    let found = call base_path (`Assoc ["action", `String "find"; "query", `String "draft fixture"]) |> success in
    let candidate = member "artifacts" found |> Yojson.Safe.Util.to_list |> List.hd in
    Alcotest.(check string) "other writer's artifact found" artifact.id (member "id" candidate |> text);
    let published = call base_path (`Assoc ["action", `String "published"; "artifact_id", `String artifact.id]) |> success in
    Alcotest.(check string) "published source read" "alpha beta" (member "content" published |> text);
    let target = call base_path (open_args artifact.id) |> success |> target_of in
    let human = Store.execute ~runner ~base_path ~actor:"human" (Draft.Select { target; anchor = 6; head = 10 }) |> stored in
    let human_selection = match human.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "human selection absent" in
    ignore (Store.execute ~runner ~base_path ~actor:"human" (Draft.Edit { selection = human_selection; expected = "beta"; replacement = "human" }) |> stored);
    let chosen = call base_path (select target 0 5) |> success |> member "selection" in
    let edited = call base_path (edit chosen "alpha" "keeper") |> success in
    let content = member "content" edited |> text in
    Alcotest.(check string) "both writers retained" "keeper human" content;
    let request = `Assoc ["id", `String artifact.id; "expected_revision", `Int 1;
      "title", `String "Keeper draft fixture"; "summary", `String "native";
      "format", `String "markdown"; "content", `String content] in
    ignore (Keeper_artifact_publish.handle ~base_path ~author:"keeper-editor" ~args:request |> success);
    let checkpoint sequence revision = `Assoc ["action", `String "checkpoint"; "target", Draft.target_to_json target;
      "expected_sequence", sequence; "revision", `Int revision] in
    let checked = call base_path (checkpoint (member "sequence" edited) 2) |> success in
    Alcotest.(check int) "published draft becomes new base" 2 (member "base_revision" checked |> Yojson.Safe.Util.to_int);
    let found = call base_path (`Assoc ["action", `String "find"; "query", `String "draft fixture"]) |> success in
    let candidates = member "artifacts" found |> Yojson.Safe.Util.to_list in
    Alcotest.(check int) "one document" 1 (List.length candidates);
    Alcotest.(check int) "version advanced" 2 (member "revision" (List.hd candidates) |> Yojson.Safe.Util.to_int);
    let _, _, original = Published_artifact_store.read ~base_path ~id:artifact.id ~revision:(Some 1)
      |> Result.map_error Published_artifact_store.error_message |> require in
    Alcotest.(check string) "original publication remains unchanged" "alpha beta" original;
    let call_second input = Keeper_artifact_draft.handle ~runner ~base_path
        ~keeper:"second-editor" ~args:input () in
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
    Alcotest.(check string) "earlier collaborative version remains" "keeper human" version_two));
  ]
let discovery_tests = [
  "workspace candidates and exact published source", `Quick, (fun () -> with_base (fun base_path ->
    let artifact = publish base_path "source by another author" in
    let call input = Keeper_artifact_draft.handle ~base_path ~keeper:"keeper-editor" ~args:input () in
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
    Alcotest.(check int) "search returns latest revision" 2 (member "revision" candidate |> Yojson.Safe.Util.to_int)));
  "pages preserve identity and refuse stale or incomplete inventory", `Quick, (fun () -> with_base (fun base_path ->
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
      Keeper_artifact_draft.handle ~base_path ~keeper:"keeper-editor" ~args:(`Assoc fields) () in
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
      ((call "team" (Some cursor)).disposition = Tool_result.Failed Tool_result.Workflow_rejection)));
]
(* Plain-text stand-in for the Yjs transformer, so this group runs without the
   Node binary the runtime group needs. The state is the base64 source and a
   selection is its two UTF-16 indices, one byte each. Like the real
   transformer, it refuses an edit whose selected text has changed. *)
let plain_runner input =
  let json = Yojson.Safe.from_string input in
  let field name = member name json in
  let reply code fields = Ok (Unix.WEXITED code, Yojson.Safe.to_string (`Assoc fields)) in
  let snapshot content = ["ok", `Bool true; "state", `String (Base64.encode_string content); "content", `String content] in
  let positioned content anchor head = snapshot content @ [
    "selection", `Assoc ["anchor", `List [`Int anchor]; "head", `List [`Int head]];
    "range", `Assoc ["anchor", `Int anchor; "head", `Int head]] in
  let source () = match Base64.decode (text (field "state")) with
    | Ok source -> source | Error (`Msg message) -> failwith message in
  let indices selection = match member "anchor" selection, member "head" selection with
    | `List [`Int anchor], `List [`Int head] -> anchor, head
    | _ -> failwith "plain runner takes one-byte positions" in
  match field "kind" with
  | `String "seed" -> reply 0 (snapshot (text (field "content")))
  | `String "merge" when field "updates" = `List [] -> reply 0 (snapshot (source ()))
  | `String "select" -> reply 0 (positioned (source ()) (Yojson.Safe.Util.to_int (field "anchor")) (Yojson.Safe.Util.to_int (field "head")))
  | `String "resolve" -> let anchor, head = indices (field "selection") in reply 0 (positioned (source ()) anchor head)
  | `String "edit" ->
    let content = source () in
    let anchor, head = indices (field "selection") in
    let start, stop = min anchor head, max anchor head in
    if String.sub content start (stop - start) <> text (field "expected") then
      reply 2 ["ok", `Bool false; "code", `String "changed_selection"; "message", `String "selected text changed"]
    else
      let replacement = text (field "replacement") in
      let next = String.sub content 0 start ^ replacement ^ String.sub content stop (String.length content - stop) in
      reply 0 (positioned next start (start + String.length replacement))
  | _ -> failwith "plain runner does not take this request"
(* No turn gate stands in front of the tool, so a call that arrives after the
   Keeper's turn is an ordinary call. What keeps it from corrupting the draft
   is the store: the author comes from the caller's Keeper, and an edit or a
   checkpoint built on an older observation is refused. *)
let late_call_tests = [
  "a late call writes as its Keeper and stale observations are refused", `Quick, (fun () -> with_base (fun base_path ->
    let call input = Keeper_artifact_draft.handle ~runner:plain_runner ~base_path ~keeper:"keeper-editor" ~args:input () in
    let human command = Store.execute ~runner:plain_runner ~base_path ~actor:"human" command |> stored in
    let artifact = publish base_path "alpha beta" in
    let read () = Store.read ~runner:plain_runner ~base_path ~artifact_id:artifact.id () |> stored in
    let target = call (open_args artifact.id) |> success |> target_of in
    let observed = call (select target 0 5) |> success in
    let observed_sequence = member "sequence" observed in
    let human_choice = human (Draft.Select { target; anchor = 0; head = 5 }) in
    let human_selection = match human_choice.selection with Some (selection, _, _) -> selection | None -> Alcotest.fail "human selection absent" in
    ignore (human (Draft.Edit { selection = human_selection; expected = "alpha"; replacement = "human" }));
    let stale_edit = call (edit (member "selection" observed) "alpha" "keeper") in
    Alcotest.(check bool) "stale text is a workflow refusal" true
      (stale_edit.disposition = Tool_result.Failed Tool_result.Workflow_rejection);
    let after_edit = read () in
    Alcotest.(check string) "other writer's text kept" "human beta" after_edit.content;
    Alcotest.(check string) "other writer stays the author" "human" after_edit.draft.updated_by;
    let revision = `Assoc ["id", `String artifact.id; "expected_revision", `Int 1;
      "title", `String "Keeper draft fixture"; "summary", `String "native";
      "format", `String "markdown"; "content", `String after_edit.content] in
    ignore (Keeper_artifact_publish.handle ~base_path ~author:"publisher" ~args:revision |> success);
    let stale_checkpoint = call (`Assoc ["action", `String "checkpoint"; "target", Draft.target_to_json target;
      "expected_sequence", observed_sequence; "revision", `Int 2]) in
    Alcotest.(check bool) "stale sequence is a workflow refusal" true
      (stale_checkpoint.disposition = Tool_result.Failed Tool_result.Workflow_rejection);
    let after_checkpoint = read () in
    Alcotest.(check int) "draft base stays at the first publication" 1 after_checkpoint.draft.base_revision;
    let fresh = call (select target 6 10) |> success |> member "selection" in
    let written = call (edit fresh "beta" "keeper") |> success in
    Alcotest.(check string) "fresh late edit applies" "human keeper" (member "content" written |> text);
    Alcotest.(check string) "late edit is recorded as its Keeper" "keeper-editor" (read ()).draft.updated_by));
]
let schema_tests = ["canonical tool", `Quick, (fun () ->
  let descriptor = match Keeper_tool_descriptor.find_id "keeper.artifact.draft" with Some descriptor -> descriptor | None -> Alcotest.fail "missing descriptor" in
  Alcotest.(check (list string)) "model schema" [] (Keeper_tool_descriptor.model_schema_errors descriptor);
  Alcotest.(check bool) "writes serialize" true (descriptor.execution = Keeper_tool_descriptor.Ordinary Keeper_tool_descriptor.Serial))]
let () = Eio_main.run (fun env ->
  Process_eio.init ~cwd_default:(Eio.Stdenv.fs env) ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let tests, argv = if Array.length Sys.argv = 3 && Sys.argv.(1) = "--transformer"
    then integration (Artifact_document_engine.default_runner ~executable:Sys.argv.(2)), [|Sys.argv.(0)|] else [], Sys.argv in
  Fun.protect ~finally:Process_eio.reset_for_testing (fun () ->
    Alcotest.run ~argv "Keeper shared artifact draft"
      ["schema", schema_tests; "discovery", discovery_tests; "late call", late_call_tests; "runtime", tests]))
