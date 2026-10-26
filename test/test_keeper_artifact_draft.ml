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
    Alcotest.run ~argv "Keeper shared artifact draft" ["schema", schema_tests; "runtime", tests]))
