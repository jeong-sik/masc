module A = Masc.Published_artifact
module S = Masc.Published_artifact_store
module Tool_bridge = Masc.Tool_bridge

let with_base f =
  let base = Filename.temp_file "published_artifact" "" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let rec remove path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR ->
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    | Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      Unix.unlink path in
  Fun.protect ~finally:(fun () -> remove base) (fun () -> f base)

let store_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (S.error_message error)

let request_json ?id ?expected_revision ?(title = "보고서") ?(format = "markdown") content =
  let update = match id, expected_revision with
    | None, None -> []
    | Some id, Some revision -> ["id", `String id; "expected_revision", `Int revision]
    | None, Some _ | Some _, None -> Alcotest.fail "test update is incomplete" in
  `Assoc (update @ ["title", `String title; "summary", `String "작업 결과";
                   "format", `String format; "content", `String content;
                   "task_id", `String "task-123"; "goal_id", `String "goal-456"])

let request ?id ?expected_revision ?title ?format content =
  match A.request_of_json (request_json ?id ?expected_revision ?title ?format content) with
  | Ok request -> request
  | Error message -> Alcotest.fail message

let publish ~base_path request = S.publish ~base_path ~author:"keeper-연구" request |> store_ok
let masc_dir base = Common.masc_dir_from_base_path ~base_path:base
let catalog_dir base = Filename.concat (masc_dir base) "published_artifacts"
let metadata_path base id = Filename.concat (catalog_dir base) (id ^ ".json")

let check_unavailable = function
  | Error (S.Unavailable _) -> ()
  | Error ((S.Invalid _ | S.Missing | S.Conflict _ | S.Commit_uncertain _) as error) ->
    Alcotest.failf "expected unavailable, received %s" (S.error_message error)
  | Ok _ -> Alcotest.fail "unsafe storage was accepted"

let test_create_and_revise () = with_base (fun base_path ->
  let empty = S.list ~base_path |> store_ok in
  Alcotest.(check int) "fresh catalog is empty" 0 (List.length empty.artifacts);
  let original = "\239\187\191# 관찰 보고서\r\n\r\n| 항목 | 결과 |\r\n|---|---|\r\n| 보존 | ✅ |\r\n" in
  let artifact, first = publish ~base_path (request original) in
  Alcotest.(check int) "first revision" 1 first.revision;
  (* Read from durable metadata and a newly created blob store; no publisher
     object or in-memory catalog is carried across this boundary. *)
  Masc.Keeper_fs.clear_dir_cache ();
  let recovered, _, content = S.read ~base_path ~id:artifact.id ~revision:None |> store_ok in
  Alcotest.(check string) "fresh reader preserves exact source bytes" original content;
  Alcotest.(check string) "identity recovered" artifact.id recovered.id;
  Alcotest.(check bool) "new artifact is private by default" false
    (S.is_shared ~base_path ~id:artifact.id |> store_ok);
  Alcotest.(check bool) "enabling external sharing persists" true
    (S.set_shared ~base_path ~id:artifact.id ~shared:true |> store_ok);
  Alcotest.(check bool) "share state recovered" true
    (S.is_shared ~base_path ~id:artifact.id |> store_ok);
  Alcotest.(check bool) "revoking external sharing persists" false
    (S.set_shared ~base_path ~id:artifact.id ~shared:false |> store_ok);
  Alcotest.(check bool) "revoked share state recovered" false
    (S.is_shared ~base_path ~id:artifact.id |> store_ok);
  let next = "<!doctype html><html><body><h1>두 번째 보고서</h1></body></html>\n" in
  let _, second = publish ~base_path
    (request ~id:artifact.id ~expected_revision:1 ~format:"html" next) in
  Alcotest.(check int) "second revision" 2 second.revision;
  (match S.publish ~base_path ~author:"keeper-연구"
     (request ~id:artifact.id ~expected_revision:1 "stale update") with
   | Error (S.Conflict { expected = 1; actual = 2 }) -> ()
   | Error ((S.Invalid _ | S.Missing | S.Conflict _ | S.Unavailable _ | S.Commit_uncertain _) as error) ->
     Alcotest.fail (S.error_message error)
   | Ok _ -> Alcotest.fail "stale revision overwrote current report");
  let _, _, latest = S.read ~base_path ~id:artifact.id ~revision:None |> store_ok in
  let _, _, prior = S.read ~base_path ~id:artifact.id ~revision:(Some 1) |> store_ok in
  Alcotest.(check string) "latest body" next latest;
  Alcotest.(check string) "first revision remains immutable" original prior;
  let listing = S.list ~base_path |> store_ok in
  Alcotest.(check int) "one report with two revisions" 1 (List.length listing.artifacts);
  Alcotest.(check int) "healthy listing" 0 (List.length listing.diagnostics);
  let maintenance mode =
    match Tool_blob_maintenance.run ~base_path
      ~board_posts_file:Masc_board_handlers.Board_paths.posts_file ~mode with
    | Ok report -> report
    | Error error -> Alcotest.fail (Tool_blob_maintenance.error_to_string error) in
  let observed = maintenance Tool_blob_maintenance.Observe_only in
  Alcotest.(check int) "both revision blobs are roots" 2 observed.live_references;
  let swept = maintenance Tool_blob_maintenance.Delete_previous_candidates in
  Alcotest.(check int) "no published body deleted" 0 swept.deleted;
  List.iter (fun (revision, expected) ->
    let _, _, actual = S.read ~base_path ~id:artifact.id ~revision:(Some revision) |> store_ok in
    Alcotest.(check string) "revision survives offline retention" expected actual)
    [1, original; 2, next])

let test_publication_link_updates () = with_base (fun base_path ->
  let parse fields =
    match A.request_of_json (`Assoc (fields @
      ["title", `String "linked"; "summary", `String "work links";
       "format", `String "markdown"; "content", `String "body"])) with
    | Ok request -> request
    | Error error -> Alcotest.fail error in
  let update id revision fields =
    parse (["id", `String id; "expected_revision", `Int revision] @ fields) in
  let assert_links description task goal (revision : A.revision) =
    Alcotest.(check (option string)) (description ^ " task") task revision.task_id;
    Alcotest.(check (option string)) (description ^ " goal") goal revision.goal_id in
  let omitted = parse [] and clear = parse ["task_id", `Null; "goal_id", `Null] in
  Alcotest.(check bool) "omitted is preserved by request parser" true
    (omitted.task_id = A.Unspecified && omitted.goal_id = A.Unspecified);
  Alcotest.(check bool) "null is preserved by request parser" true
    (clear.task_id = A.Clear && clear.goal_id = A.Clear);
  let _, created_omitted = publish ~base_path omitted in
  let _, created_clear = publish ~base_path clear in
  assert_links "omitted creation" None None created_omitted;
  assert_links "null creation" None None created_clear;
  let artifact, first = publish ~base_path
    (parse ["task_id", `String "task-1"; "goal_id", `String "goal-1"]) in
  assert_links "creation" (Some "task-1") (Some "goal-1") first;
  let _, second = publish ~base_path (update artifact.id 1 []) in
  assert_links "omitted revision" (Some "task-1") (Some "goal-1") second;
  let _, third = publish ~base_path
    (update artifact.id 2 ["task_id", `Null; "goal_id", `String "goal-2"]) in
  assert_links "clear task and set goal" None (Some "goal-2") third;
  let _, fourth = publish ~base_path
    (update artifact.id 3 ["task_id", `String "task-2"; "goal_id", `Null]) in
  assert_links "set task and clear goal" (Some "task-2") None fourth;
  let _, recovered_first, _ = S.read ~base_path ~id:artifact.id ~revision:(Some 1) |> store_ok in
  let _, recovered_third, _ = S.read ~base_path ~id:artifact.id ~revision:(Some 3) |> store_ok in
  assert_links "old revision remains immutable" (Some "task-1") (Some "goal-1") recovered_first;
  assert_links "cleared link remains absent" None (Some "goal-2") recovered_third;
  List.iter (fun value -> match A.request_of_json (`Assoc
      ["title", `String "linked"; "summary", `String "links";
       "format", `String "markdown"; "content", `String "body"; "task_id", value]) with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "invalid link accepted")
    [`String " "; `Int 1; `String "invalid \255"])

let test_utf8_boundaries () = with_base (fun base_path ->
  List.iter (fun json -> match A.request_of_json json with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "malformed UTF-8 request was accepted")
    [request_json "invalid \255"; request_json ~title:"invalid \192\128" "content"];
  (match S.publish ~base_path ~author:"keeper\255" (request "valid content") with
   | Error (S.Invalid _) -> ()
   | Error ((S.Missing | S.Conflict _ | S.Unavailable _ | S.Commit_uncertain _) as error) ->
     Alcotest.fail (S.error_message error)
   | Ok _ -> Alcotest.fail "malformed UTF-8 author was accepted");
  let artifact, revision = publish ~base_path (request "valid content") in
  let bad_body = Tool_blob_store.put_durable (Tool_blob_store.create ~base_path)
    ~bytes:"invalid \255" ~mime:"text/markdown" in
  let corrupt = { artifact with A.revisions = [{ revision with A.body = bad_body }] } in
  Fs_compat.save_file (metadata_path base_path artifact.id)
    (Yojson.Safe.to_string (A.to_json corrupt));
  check_unavailable (S.read ~base_path ~id:artifact.id ~revision:None);
  let corrupt_author = { artifact with A.revisions = [{ revision with A.author = "keeper\255" }] } in
  Fs_compat.save_file (metadata_path base_path artifact.id)
    (Yojson.Safe.to_string (A.to_json corrupt_author));
  check_unavailable (S.read ~base_path ~id:artifact.id ~revision:None);
  let listing = S.list ~base_path |> store_ok in
  Alcotest.(check int) "corrupt metadata omitted" 0 (List.length listing.artifacts);
  Alcotest.(check int) "corruption remains visible" 1 (List.length listing.diagnostics))

let test_unsafe_directory () = with_base (fun base_path ->
  ignore (publish ~base_path (request "owned report"));
  let dir = catalog_dir base_path in
  Unix.chmod dir 0o777;
  Fun.protect ~finally:(fun () -> Unix.chmod dir 0o700) (fun () ->
    check_unavailable (S.list ~base_path);
    check_unavailable (S.publish ~base_path ~author:"keeper" (request "blocked")));
  let held = dir ^ "-held" in
  Unix.rename dir held;
  Unix.symlink held dir;
  Fun.protect ~finally:(fun () -> Unix.unlink dir; Unix.rename held dir) (fun () ->
    check_unavailable (S.list ~base_path);
    check_unavailable (S.publish ~base_path ~author:"keeper" (request "blocked")));
  let missing_root = Filename.concat base_path "nonexistent-base" in
  check_unavailable (S.list ~base_path:missing_root))

let test_metadata_symlink () = with_base (fun base_path ->
  let artifact, _ = publish ~base_path (request "owned report") in
  let path = metadata_path base_path artifact.id in
  let held = Filename.concat base_path "held.json" in
  Unix.rename path held;
  Unix.symlink held path;
  check_unavailable (S.read ~base_path ~id:artifact.id ~revision:None);
  let listing = S.list ~base_path |> store_ok in
  Alcotest.(check int) "symlink metadata omitted" 0 (List.length listing.artifacts);
  Alcotest.(check int) "symlink remains visible as diagnostic" 1 (List.length listing.diagnostics))

let json_member name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> Alcotest.failf "missing JSON field %s" name)
  | _ -> Alcotest.failf "expected JSON object for field %s" name

let json_string = function
  | `String text -> text
  | _ -> Alcotest.fail "expected JSON string"

let check_json label expected actual =
  Alcotest.(check bool) label true (Yojson.Safe.equal expected actual)

let publication_data (result : Masc.Keeper_tool_execution.t) =
  (match result.disposition with
   | Tool_result.Completed () -> ()
   | Tool_result.Deferred () -> Alcotest.fail "publication was deferred"
   | Tool_result.Failed class_ ->
     Alcotest.failf "publication failed: %s" (Tool_result.tool_failure_class_to_string class_));
  match result.data with
  | Some json -> json
  | None -> Alcotest.fail "publication succeeded without typed data"

let test_keeper_publication () = with_base (fun base_path ->
  let content = "# Keeper 보고서\r\n\r\n정확한 원문 ✅\r\n" in
  let author = "keeper-authenticated-연구" in
  let result = Masc.Keeper_artifact_publish.handle ~base_path ~author
    ~args:(request_json content) in
  let data = publication_data result in
  check_json "publication schema" (`String "masc.published_artifact.v1")
    (json_member "schema" data);
  let summary = json_member "artifact" data in
  let id = json_member "id" summary |> json_string in
  Alcotest.(check bool) "generated publication identity" true (A.valid_id id);
  check_json "producer-owned author" (`String author) (json_member "author" summary);
  check_json "first version" (`Int 1) (json_member "revision" summary);
  check_json "open link" (`String (A.url id)) (json_member "url" summary);
  check_json "immutable revision link" (`String (A.url ~revision:1 id))
    (json_member "revision_url" data);
  let _, stored_revision, actual = S.read ~base_path ~id ~revision:None |> store_ok in
  Alcotest.(check string) "tool persisted exact body" content actual;
  Alcotest.(check string) "durable author identity" author stored_revision.author;
  (match result.retained_artifacts with
   | [body] -> Alcotest.(check string) "execution retains persisted body"
       stored_revision.body.sha256 body.sha256
   | [] | _ :: _ :: _ -> Alcotest.fail "tool did not retain exactly one body");
  let revised = Masc.Keeper_artifact_publish.handle ~base_path ~author
    ~args:(request_json ~id ~expected_revision:1 "updated by Keeper") in
  let second = publication_data revised |> json_member "artifact" in
  check_json "revision identity" (`String id) (json_member "id" second);
  check_json "version advances" (`Int 2) (json_member "revision" second);
  let rejected = Masc.Keeper_artifact_publish.handle ~base_path ~author
    ~args:(request_json ~id ~expected_revision:1 "stale Keeper content") in
  (match rejected.disposition with
   | Tool_result.Failed Tool_result.Workflow_rejection -> ()
   | Tool_result.Completed () | Tool_result.Deferred ()
   | Tool_result.Failed (Tool_result.Dependency_unavailable | Tool_result.Policy_rejection
                       | Tool_result.Runtime_failure | Tool_result.Operator_cancelled) ->
     Alcotest.fail "stale tool revision was not a Workflow_rejection");
  let _, latest, actual = S.read ~base_path ~id ~revision:None |> store_ok in
  Alcotest.(check int) "stale tool call created no revision" 2 latest.revision;
  Alcotest.(check string) "stale tool call preserved committed body" "updated by Keeper" actual;
  let spoofed_args = match request_json content with
    | `Assoc fields -> `Assoc (("author", `String "spoofed-author") :: fields)
    | _ -> assert false in
  let spoofed = Masc.Keeper_artifact_publish.handle ~base_path ~author ~args:spoofed_args in
  match spoofed.disposition with
  | Tool_result.Failed Tool_result.Policy_rejection -> ()
  | Tool_result.Completed () | Tool_result.Deferred ()
  | Tool_result.Failed (Tool_result.Dependency_unavailable | Tool_result.Workflow_rejection
                      | Tool_result.Runtime_failure | Tool_result.Operator_cancelled) ->
    Alcotest.fail "caller-supplied author was not refused")

let test_publication_discovery () =
  let module D = Masc.Keeper_tool_descriptor in
  let descriptor = match D.find_id "keeper.artifact.publish" with
    | Some descriptor -> descriptor
    | None -> Alcotest.fail "artifact publication descriptor is missing" in
  let canonical = Masc.Keeper_runtime_schemas_toml.artifact_publish in
  Alcotest.(check string) "canonical tool name" "keeper_artifact_publish" canonical.name;
  Alcotest.(check bool) "descriptor uses canonical registry" true
    (descriptor.input_schema_source = D.Canonical_registry);
  check_json "canonical schema preserved" canonical.input_schema descriptor.input_schema;
  Alcotest.(check (list string)) "schema is model-projectable" []
    (D.model_schema_errors descriptor);
  Alcotest.(check (list string)) "Keeper discovery exposes publish tool"
    [canonical.name] (D.keeper_model_names descriptor);
  let projected = D.model_visible_schemas () |> List.find_opt (fun (schema : Masc_domain.tool_schema) ->
    String.equal schema.name canonical.name) in
  (match projected with
   | Some schema -> check_json "model receives canonical schema"
       canonical.input_schema schema.input_schema
   | None -> Alcotest.fail "publication is absent from model-visible tools");
  let input = request_json "new report" in
  Alcotest.(check (option bool)) "publication is a mutation" (Some false)
    (D.readonly_static_hint descriptor);
  Alcotest.(check (option bool)) "real publication input is a mutation" (Some false)
    (D.readonly_for_input descriptor ~input);
  Alcotest.(check bool) "publication mutations execute serially" true
    (descriptor.execution = D.Ordinary D.Serial);
  Alcotest.(check bool) "publication dispatches to actual producer" true
    (descriptor.runtime_handler = D.Tool_artifact_publish);
  let discovery = `Assoc (D.discovery_fields descriptor) in
  check_json "discovery identifies capability" (`String "keeper.artifact.publish")
    (json_member "id" discovery);
  check_json "discovery reports mutation policy" (`Bool false)
    (json_member "policy" discovery |> json_member "readonly_hint")

let test_keeper_model_publication_receipt () = with_base (fun base_path ->
  let base_path = Unix.realpath base_path in
  Masc_test_deps.with_process_env "MASC_BASE_PATH" (Some base_path) (fun () ->
    Config_dir_resolver.reset ();
    Fun.protect ~finally:Config_dir_resolver.reset (fun () ->
      ignore (Masc_test_deps.init_unified_tool_registry ());
      let author = "published-receipt" in
      let meta = match Masc_test_deps.meta_of_json_fixture
          (`Assoc ["name", `String author]) with
        | Ok meta -> meta | Error detail -> Alcotest.fail detail in
      let descriptor = match Masc.Keeper_tool_descriptor.find_id "keeper.artifact.publish" with
        | Some descriptor -> descriptor | None -> Alcotest.fail "publication descriptor missing" in
      let publication_recovery = Masc.Keeper_publication_recovery_availability.
          {provider=non_runtime_provider; keeper_name=author} in
      let handler = Masc.Keeper_tools_agent_core_handler.make_keeper_tool_handler_from_meta
          ~name:descriptor.internal_name ~descriptor ~model_name:"keeper_artifact_publish"
          ~input_schema:descriptor.input_schema ~config:(Masc.Workspace.default_config base_path)
          ~meta ~publication_recovery
          ~ctx_snapshot:(Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"publication receipt fixture")
          ~keeper_turn_id:(fun () -> None) () in
      List.iter (fun (format, content) ->
        let result = handler (request_json ~format content) in
        let output = match Tool_bridge.to_agent_core_typed_result ~base_path
            ~model_projection:descriptor.model_output_projection result with
          | Ok output -> output | Error error -> Alcotest.fail error.message in
        let envelope = Yojson.Safe.from_string output.content in
        let data = json_member "structured_content" envelope in
        let summary = json_member "artifact" data in
        let id = json_member "id" summary |> json_string in
        check_json "model sees the immutable open link" (`String (A.url ~revision:1 id))
          (json_member "revision_url" data);
        check_json "model sees the committed version" (`Int 1) (json_member "revision" summary);
        let reference, projection = match Tool_bridge.artifact_manifest_reference result with
          | Ok value -> value | Error detail -> Alcotest.fail detail in
        Alcotest.(check bool) "publication opts into inline receipt delivery" true
          (projection = Tool_output.Inline_with_reference);
        let manifest = match Tool_blob_store.fetch (Tool_blob_store.create ~base_path)
            ~sha256:reference.sha256 with
          | Ok (Some bytes) -> Yojson.Safe.from_string bytes
          | Ok None -> Alcotest.fail "receipt manifest is missing"
          | Error error -> Alcotest.fail (Tool_blob_store.fetch_error_to_string error) in
        (match Tool_output.artifact_manifest_of_json manifest with
         | Tool_output.Decoded_artifact_manifest {structured_content; artifact_refs=[body]; _} ->
           check_json "manifest retains the exact publication receipt" data structured_content;
           Alcotest.(check string) "manifest roots the original body"
             Agent_core_sha256.(digest_string content |> to_hex) body.sha256
         | Tool_output.Decoded_artifact_manifest _ | Tool_output.Not_artifact_manifest
         | Tool_output.Invalid_artifact_manifest _ -> Alcotest.fail "invalid publication receipt manifest");
        let _, _, stored = S.read ~base_path ~id ~revision:(Some 1) |> store_ok in
        Alcotest.(check string) "model receipt points to the original content" content stored)
        ["markdown", "probe"; "html", "<!doctype html><html lang=\"ko\"><body>음악 보고서 ✅</body></html>"];
      let listing = S.list ~base_path |> store_ok in
      Alcotest.(check int) "each successful call publishes once" 2 (List.length listing.artifacts))))

let test_publication_manifest_failure_recovery () = with_base (fun base_path ->
  let content = "<!doctype html><html><body>committed report</body></html>" in
  let persist_manifest ~base_path result =
    let id = Tool_result.data result |> json_member "artifact" |> json_member "id" |> json_string in
    let _, _, stored = S.read ~base_path ~id ~revision:(Some 1) |> store_ok in
    Alcotest.(check string) "fault occurs after the actual publication" content stored;
    Error {Tool_bridge.kind=Artifact_storage_failure; message="injected receipt storage failure"} in
  let result = Masc.Keeper_artifact_publish.For_testing.handle_with_manifest
      ~persist_manifest ~base_path ~author:"published-recovery" ~args:(request_json ~format:"html" content) in
  Alcotest.(check bool) "manifest failure is a typed runtime failure" true
    (result.disposition = Tool_result.Failed Tool_result.Runtime_failure);
  Alcotest.(check bool) "producer proves that publication committed" true
    (result.failure_effect_disposition = Tool_result.Proven_post_effect);
  let data = match result.data with Some data -> data | None -> Alcotest.fail "recovery receipt missing" in
  let id = data |> json_member "artifact" |> json_member "id" |> json_string in
  let failed = Tool_result.make_err ~tool_name:"keeper_artifact_publish"
      ~start_time:(Tool_timing.start ()) ~class_:Tool_result.Runtime_failure
      ~effect_disposition:result.failure_effect_disposition ~data result.raw_output in
  (match Tool_bridge.to_agent_core_typed_result ~base_path failed with
   | Ok _ -> Alcotest.fail "receipt failure was projected as success"
   | Error error ->
     Alcotest.(check bool) "publication must not be retried automatically" false error.recoverable;
     let recovery = Yojson.Safe.from_string error.message |> json_member "data" in
     check_json "model can recover the committed publication" data recovery;
     check_json "model sees the immutable recovery link" (`String (A.url ~revision:1 id))
       (json_member "revision_url" recovery));
  let listing = S.list ~base_path |> store_ok in
  Alcotest.(check int) "a failed receipt leaves exactly one publication" 1 (List.length listing.artifacts);
  let _, revision, stored = S.read ~base_path ~id ~revision:(Some 1) |> store_ok in
  Alcotest.(check string) "publication body survives receipt failure" content stored;
  Alcotest.(check bool) "failure retains the committed body reference" true
    (result.retained_artifacts = [revision.body]))

let test_http_publication_errors () =
  let module Routes = Server_routes_http_routes_published_artifacts in
  let check_error expected_status expected_code error =
    let json, status = Routes.error_response error in
    Alcotest.(check int) "HTTP status" expected_status (Httpun.Status.to_code status);
    check_json "machine-readable error code" (`String expected_code) (json_member "code" json);
    json in
  ignore (check_error 404 "artifact_not_found" S.Missing);
  let conflict = check_error 409 "artifact_revision_conflict"
    (S.Conflict { expected = 1; actual = 2 }) in
  check_json "conflict identifies caller version" (`Int 1)
    (json_member "expected_revision" conflict);
  check_json "conflict identifies durable version" (`Int 2)
    (json_member "current_revision" conflict);
  let id = "artifact-" ^ String.make 32 'a' in
  let uncertain = check_error 503 "artifact_commit_uncertain"
    (S.Commit_uncertain { id; revision = 3; message = "parent directory sync failed" }) in
  check_json "uncertain create remains discoverable" (`String id) (json_member "id" uncertain);
  check_json "uncertain version can be reread" (`Int 3) (json_member "revision" uncertain);
  check_json "uncertain response links the exact revision" (`String (A.url ~revision:3 id))
    (json_member "url" uncertain);
  Alcotest.(check bool) "uncertain response explains reread before retry" true
    (String.trim (json_member "recovery" uncertain |> json_string) <> "");
  List.iter (fun path -> Alcotest.(check bool) "report catalog routes require private reads" false
    (Server_auth.is_public_read_path path))
    ["/api/v1/published-artifacts"; "/api/v1/published-artifacts/";
     "/api/v1/published-artifacts/not-a-valid-id"; "/api/v1/published-artifact-checks"];
  List.iter (fun path -> Alcotest.(check bool) "capability-addressed artifact reads are public" true
    (Server_auth.is_public_read_path path))
    ["/api/v1/published-artifacts/" ^ id;
     "/api/v1/published-artifacts/" ^ id ^ "?revision=3"]

(* Exercise the registered routes through Httpun so permission wrappers,
   anonymous sharing, and the checkpoint wire parser are tested together. *)
let test_workspace_http_permissions_and_checkpoint_parser () = with_base (fun base_path ->
  let module Http = Masc.Http_server_eio in
  Auth.save_auth_config base_path
    { Masc_domain.default_auth_config with enabled = true; require_token = true };
  let token role agent_name = match Auth.create_token base_path ~agent_name ~role with
    | Ok (token, _) -> token
    | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error) in
  let worker = token Masc_domain.Worker "worker" and player = token Masc_domain.Player "player"
  and admin = token Masc_domain.Admin "admin" in
  let artifact, _ = publish ~base_path (request "workspace shared document") in
  let state = Masc.Mcp_server.For_testing.create_state ~base_path in
  let router = Http.Router.create ()
    |> Server_routes_http_routes_published_artifacts.add_routes
    |> Server_routes_http_routes_artifact_drafts.add_routes
    |> Server_routes_http_routes_artifact_draft_live.add_routes in
  let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority | Error `Malformed -> Alcotest.fail "invalid test request authority" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Server_startup_state.snapshot () in
  Server_auth.publish_server_state state;
  Fun.protect ~finally:(fun () ->
    Server_auth.For_testing.restore_server_state previous_state;
    Server_startup_state.For_testing.restore previous_startup) (fun () ->
    (match Server_startup_state.mark_state_ready () with
     | Ok () -> ()
     | Error error -> Alcotest.fail (Server_startup_state.state_ready_error_to_string error));
    Server_request_authority.with_current authority (fun () ->
      let request ?(meth = "GET") ?(body = "") ?(extra_headers = "") bearer path =
        let output = Buffer.create 2048 in
        let connection = Httpun.Server_connection.create (fun reqd ->
          let request = Httpun.Reqd.request reqd in
          Server_workspace_precondition.guard_http1 ~path:(Http.Request.path request) request reqd
            ~admitted:(fun () -> Http.Router.dispatch router request reqd)) in
        let authorization = match bearer with
          | None -> "" | Some token -> "Authorization: Bearer " ^ token ^ "\r\n" in
        let wire = Printf.sprintf "%s %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\n%s%sContent-Length: %d\r\n\r\n%s"
          meth path authorization extra_headers (String.length body) body in
        let input = Bigstringaf.of_string ~off:0 ~len:(String.length wire) wire in
        ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
        let rec drain () = match Httpun.Server_connection.next_write_operation connection with
          | `Write iovecs ->
            let n = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total + iov.len) 0 iovecs in
            Httpun.Server_connection.report_write_result connection (`Ok n); drain ()
          | `Yield when Buffer.length output = 0 ->
            let ready, resolve = Eio.Promise.create () in
            Httpun.Server_connection.yield_writer connection (fun () -> Eio.Promise.resolve resolve ());
            Eio.Promise.await ready; drain ()
          | `Yield | `Close _ -> () in
        drain ();
        let response = Buffer.contents output in
        match String.split_on_char ' ' response with
        | _ :: status :: _ -> int_of_string status, response
        | _ -> Alcotest.failf "invalid HTTP response: %S" response in
      let status ?meth ?body bearer path = fst (request ?meth ?body bearer path) in
      let check label expected actual = Alcotest.(check int) label expected actual in
      let doc = "/api/v1/published-artifacts/" ^ artifact.id in
      let draft = "/api/v1/artifact-drafts/" ^ artifact.id in
      let events = "/api/v1/artifact-draft-events/" ^ artifact.id ^ "?generation=019f0000-0000-7000-8000-000000000000" in
      let list = "/api/v1/published-artifacts" in
      List.iter (fun path ->
        check "anonymous workspace listing/draft requires a token" 401 (status None path);
        check "Player cannot read workspace artifacts" 403 (status (Some player) path))
        [list; draft; "/api/v1/published-artifact-checks"; events];
      check "Worker reads artifact list" 200 (status (Some worker) list);
      check "Worker reads checks" 200 (status (Some worker) "/api/v1/published-artifact-checks");
      check "Worker can reach draft read" 404 (status (Some worker) draft);
      check "Worker can reach SSE admission" 503 (status (Some worker) events);
      let worker_status, worker_response = request (Some worker) doc in
      check "Worker reads workspace artifact" 200 worker_status;
      Alcotest.(check bool) "workspace artifact is not cached" true
        (String.lowercase_ascii worker_response |> String.split_on_char '\n'
         |> List.exists (fun line -> String.trim line = "cache-control: private, no-store"));
      check "private artifact is not anonymous" 401 (status None doc);
      check "Player cannot read even an authenticated private document" 403 (status (Some player) doc);
      let post ?(body = "{}") bearer path = status ~meth:"POST" ~body bearer path in
      List.iter (fun path ->
        check "Worker can reach workspace write parser" 400 (post (Some worker) path);
        check "Player cannot write workspace artifacts" 403 (post (Some player) path);
        check "anonymous cannot write workspace artifacts" 401 (post None path))
        [list; "/api/v1/artifact-drafts"; "/api/v1/artifact-draft-checkpoints";
         "/api/v1/artifact-draft-presence"];
      List.iter (fun path ->
        check "Worker cannot change admin-only artifact state" 403 (post (Some worker) path);
        check "Admin reaches admin-only write parser" 400 (post (Some admin) path))
        ["/api/v1/published-artifact-checks"; "/api/v1/published-artifact-shares"];
      let share_body = Yojson.Safe.to_string (`Assoc ["id", `String artifact.id; "shared", `Bool true]) in
      check "Admin enables external sharing" 200 (post ~body:share_body (Some admin) "/api/v1/published-artifact-shares");
      check "explicitly shared document is anonymously readable" 200 (status None doc);
      check "Player token does not bypass its permission even for a shared document" 403 (status (Some player) doc);
      check "invalid token does not become an anonymous shared read" 401 (status (Some "invalid") doc);
      let target = Yojson.Safe.to_string (`Assoc ["artifact_id", `String artifact.id;
        "generation", `String "019f0000-0000-7000-8000-000000000000"]) in
      let checkpoint fields = "{\"target\":" ^ target ^ "," ^ fields ^ "}" in
      let endpoint = "/api/v1/artifact-draft-checkpoints" in
      let valid_body = checkpoint "\"expected_sequence\":0,\"revision\":1" in
      check "valid checkpoint reaches store" 404
        (post ~body:valid_body (Some worker) endpoint);
      let headers base root = Printf.sprintf "X-Masc-Expected-Base-Path: %s\r\nX-Masc-Expected-Masc-Root: %s\r\n" base root in
      let served = match Server_workspace_precondition.served_workspace () with
        | Some served -> served | None -> Alcotest.fail "test workspace not available" in
      check "matching captured workspace reaches checkpoint store" 404
        (fst (request ~meth:"POST" ~body:valid_body ~extra_headers:(headers served.base_path served.masc_root) (Some worker) endpoint));
      check "checkpoint refuses a different workspace before routing" 409
        (fst (request ~meth:"POST" ~body:valid_body ~extra_headers:(headers "/different-workspace" served.masc_root) (Some worker) endpoint));
      check "checkpoint refuses an incomplete workspace precondition" 400
        (fst (request ~meth:"POST" ~body:valid_body ~extra_headers:"X-Masc-Expected-Base-Path: /different-workspace\r\n" (Some worker) endpoint));
      List.iter (fun fields ->
        check "malformed checkpoint is rejected" 400 (post ~body:(checkpoint fields) (Some worker) endpoint))
        ["\"expected_sequence\":0,\"revision\":1,\"extra\":true";
         "\"expected_sequence\":0,\"revision\":1,\"revision\":1";
         "\"expected_sequence\":-1,\"revision\":1";
         "\"expected_sequence\":0,\"revision\":0";
         "\"expected_sequence\":9007199254740992,\"revision\":1";
         "\"expected_sequence\":0,\"revision\":1.0";
         "\"expected_sequence\":0"];
      let module Live = Masc.Artifact_draft_live in
      let owner_target = { Masc.Artifact_draft.artifact_id = artifact.id; generation = "019f0000-0000-7000-8000-000000000000" } in
      let session = Live.join ~base_path ~actor:"worker" ~source:Live.Dashboard_connection ~target:owner_target in
      Fun.protect ~finally:(fun () -> Live.leave session) (fun () ->
        let body = Yojson.Safe.to_string (`Assoc ["action", `String "leave";
          "target", Masc.Artifact_draft.target_to_json owner_target; "session_id", `String (Live.id session)]) in
        let presence = "/api/v1/artifact-draft-presence" in
        check "another actor cannot end this connection" 409 (post ~body (Some admin) presence);
        check "connection owner may leave" 200 (post ~body (Some worker) presence)))))

let () = Eio_main.run (fun _ ->
  Alcotest.run "published reports"
    ["durable catalog", [
      Alcotest.test_case "create, reread, CAS revise and retain history" `Quick test_create_and_revise;
      Alcotest.test_case "omitted, cleared and replaced work links" `Quick test_publication_link_updates;
      Alcotest.test_case "reject malformed UTF-8 at publication and read" `Quick test_utf8_boundaries;
      Alcotest.test_case "unsafe directory is unavailable, not empty" `Quick test_unsafe_directory;
      Alcotest.test_case "metadata symlink is unavailable" `Quick test_metadata_symlink];
     "Keeper and HTTP publication", [
      Alcotest.test_case "producer persists exact content, identity and CAS" `Quick test_keeper_publication;
      Alcotest.test_case "model-facing receipt preserves links and durable manifests" `Quick test_keeper_model_publication_receipt;
      Alcotest.test_case "manifest failure preserves committed publication recovery" `Quick test_publication_manifest_failure_recovery;
      Alcotest.test_case "publish discovery preserves schema and mutation policy" `Quick test_publication_discovery;
      Alcotest.test_case "HTTP errors carry status and recovery identity" `Quick test_http_publication_errors;
      Alcotest.test_case "workspace HTTP permissions and checkpoint parsing" `Quick test_workspace_http_permissions_and_checkpoint_parser]])
