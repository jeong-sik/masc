open Alcotest
open Masc
module Context = Keeper_librarian_context
module Recall = Keeper_librarian_context_recall

let ok = function Ok value -> value | Error detail -> fail detail
let with_store f =
  Masc_test_deps.ensure_rng_initialized ();
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_path = Filename.temp_dir "context-recall" "" in
  Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree base_path);
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  Fs_compat.mkdir_p keepers_dir;
  f ~base_path ~keepers_dir

let commit ~keepers_dir ~previous text =
  let source : Context.source = {reference = "event:campaign"; content = `String "continue"} in
  let pocket : Context.pocket =
    { id = "campaign"; merge_contexts = []; sources = [source.reference]; context = text;
      next_steps = ["DO_NOT_REPEAT_DEPLOYMENT"]; completeness = Context.Current } in
  ok (Context.commit ~keepers_dir ~keeper_id:"keeper"
    ~expected_version:(Option.map Context.version previous)
    ~sources:[source] [pocket])

let artifact_of_index ~keepers_dir =
  let json = Yojson.Safe.from_file (Recall.path ~keepers_dir ~keeper_name:"keeper") in
  match Tool_output.normalized_artifact_ref_of_json (Yojson.Safe.Util.member "artifact" json) with
  | Tool_output.Decoded_normalized_artifact_ref reference -> reference
  | _ -> fail "index must contain a retention-visible typed artifact reference"

let check_notice ~base_path ~keepers_dir ~status =
  let body = Option.get (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ()) in
  check bool "explicit lifecycle status" true (String_util.contains_substring body status);
  check bool "notice does not revive an artifact pointer" false
    (String_util.contains_substring body "sha256=");
  body

let test_growth_does_not_expand_prompt () = with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "Campaign in progress" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first);
  let small = Option.get (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ()) in
  let large_text = String.make (Common.max_tool_result_wire_bytes * 4) 'x' in
  let second = commit ~keepers_dir ~previous:(Some first) large_text in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  let large = Option.get (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ()) in
  check bool "prompt growth contains only byte-count digits" true
    (String.length large - String.length small <= String.length (string_of_int (String.length large_text)));
  let reference = artifact_of_index ~keepers_dir in
  let body = match Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:reference.sha256 with
    | Ok (Some body) -> body
    | Ok None -> fail "published artifact is missing"
    | Error error -> fail (Tool_blob_store.fetch_error_to_string error) in
  check bool "full historical context retained outside prompt" true
    (String.length body > String.length large_text);
  let json_start = String.index body '[' in
  let pockets = Yojson.Safe.from_string
      (String.sub body json_start (String.length body - json_start))
      |> Yojson.Safe.Util.to_list in
  List.iter (fun pocket -> check bool "unvalidated next action is absent" true
      (Yojson.Safe.Util.member "next_steps" pocket = `Null)) pockets;
  (* The actual reader does not depend on a sandbox-visible host path. *)
  let result = Keeper_artifact_read.handle ~base_path ~args:(`Assoc
      ["sha256", `String reference.sha256; "offset", `Int 0]) in
  check bool "artifact reader returns a page" true
    (match result.Keeper_tool_execution.disposition with
     | Tool_result.Completed () -> true
     | Tool_result.Deferred () | Tool_result.Failed _ -> false);
  (* A derived index without its authoritative owner must never be injected. *)
  Sys.remove (Filename.concat keepers_dir "keeper.working-context.json");
  ignore (check_notice ~base_path ~keepers_dir ~status:"No organized working contexts")

let test_stale_publish_and_corruption () = with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "first" in
  let second = commit ~keepers_dir ~previous:(Some first) "second" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  let current = Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" () in
  check bool "older publisher cannot overwrite newer index" true
    (Result.is_error (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first));
  check (option string) "newer context stays available" current
    (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ());
  ok (Fs_compat.save_file_atomic (Recall.path ~keepers_dir ~keeper_name:"keeper") "{");
  check (option string) "recall repairs corrupt index without a new pass" current
    (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ())

let test_recovered_generation_replaces_old_index () = with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "first generation" in
  let second = commit ~keepers_dir ~previous:(Some first) "old revision two" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  ok (Fs_compat.save_file_atomic (Context.path ~keepers_dir ~keeper_id:"keeper") "{");
  check bool "invalid derived snapshot is recoverable" true
    (ok (Context.read_for_update ~keepers_dir ~keeper_id:"keeper") = None);
  let rebuilt = commit ~keepers_dir ~previous:None "recovered generation" in
  check bool "new generation has a lower revision" true (rebuilt.revision < second.revision);
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" rebuilt);
  let current = Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" () in
  check bool "old generation cannot publish over recovered snapshot" true
    (Result.is_error (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second));
  check bool "equal numeric revision from old generation is also rejected" true
    (Result.is_error (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first));
  check (option string) "recovered reference remains available" current
    (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ())

let test_committed_snapshot_invalidates_stale_projection () =
  with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "first context" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first);
  check bool "first projection is available" true
    (Option.is_some (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ()));
  let second = commit ~keepers_dir ~previous:(Some first) "second context" in
  let repaired = Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" () |> Option.get in
  check bool "recall publishes latest owner revision without a background pass" true
    (String_util.contains_substring repaired (Printf.sprintf "revision %d:" second.revision));
  check bool "authority remains unchanged" true
    (Option.map Context.version (ok (Context.read ~keepers_dir ~keeper_id:"keeper"))
     = Some (Context.version second))


let test_recall_lifecycle_retires_and_restores_held_pointer () =
  with_store @@ fun ~base_path ~keepers_dir ->
  let module Host = Keeper_official_client_host in
  let held = ref [] in
  let deliver ?(artifact_reader_available = true) () =
    let body = Option.get (Recall.render ~base_path ~artifact_reader_available ~keepers_dir ~keeper_name:"keeper" ()) in
    let composed_context : Host.composed_context =
      { carrier_sha256 = Digestif.SHA256.(digest_string body |> to_hex)
      ; blocks = [Prompt_block_id.Librarian_working_context, body] } in
    let message : Agent_core.Types.message =
      { role = System; content = [Text body]; name = None; tool_call_id = None
      ; metadata = Agent_core.Types.Extra_system_context_provenance.metadata } in
    let delivery = Host.resume_prompt ~goal:"NEXT_TICK" ~held:!held
      ~composed_context [message] in
    held := delivery.held_context;
    delivery.prompt
  in
  let first = commit ~keepers_dir ~previous:None "first context" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first);
  let original = deliver () in
  check bool "current artifact is delivered" true
    (String_util.contains_substring original "sha256=");
  check string "unchanged reference stays held" "NEXT_TICK" (deliver ());
  let reader_unavailable = deliver ~artifact_reader_available:false () in
  check bool "lost reader withdraws current artifact pointer" true
    (String_util.contains_substring reader_unavailable "working context is unavailable");
  check string "unchanged reader absence is deduplicated" "NEXT_TICK"
    (deliver ~artifact_reader_available:false ());
  check string "reader recovery restores the reference" original (deliver ());
  let index = Recall.path ~keepers_dir ~keeper_name:"keeper" in
  Sys.remove index;
  check string "missing derived index repairs to unchanged held reference" "NEXT_TICK" (deliver ());
  ok (Fs_compat.save_file_atomic index "{");
  check string "corrupt derived index repairs without repeating held context" "NEXT_TICK" (deliver ());
  let owner = Context.path ~keepers_dir ~keeper_id:"keeper" in
  let saved_owner = In_channel.with_open_bin owner In_channel.input_all in
  ok (Fs_compat.save_file_atomic owner "{");
  let unavailable = deliver () in
  check bool "corrupt authority invalidates the pointer" true
    (String_util.contains_substring unavailable "working context is unavailable");
  ok (Fs_compat.save_file_atomic owner saved_owner);
  check string "authority recovery resends reference" original (deliver ());
  let second = commit ~keepers_dir ~previous:(Some first) "second context" in
  check bool "unpublished new owner revision repairs and is delivered" true
    (String_util.contains_substring (deliver ()) (Printf.sprintf "revision %d:" second.revision));
  let empty = ok (Context.commit ~observed_sources:[] ~keepers_dir ~keeper_id:"keeper"
    ~expected_version:(Some (Context.version second)) ~sources:[] []) in
  let cleared = deliver () in
  check bool "committed empty state differs from unavailable" true
    (String_util.contains_substring cleared "No organized working contexts");
  check bool "empty state withdraws pointer" false
    (String_util.contains_substring cleared "sha256=");
  check string "unchanged empty state is not repeated" "NEXT_TICK" (deliver ());
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" empty);
  check string "publishing empty state does not revive artifact" "NEXT_TICK" (deliver ());
  Sys.remove owner;
  check string "absent owner remains confirmed empty" "NEXT_TICK" (deliver ());
  let recovered = commit ~keepers_dir ~previous:None "recovered context" in
  check bool "new generation repairs its index and re-enters recall" true
    (String_util.contains_substring (deliver ()) "sha256=");
  check bool "repaired index names recovered generation" true
    (Yojson.Safe.Util.member "generation"
       (Yojson.Safe.from_file (Recall.path ~keepers_dir ~keeper_name:"keeper"))
     = `String recovered.generation)

let test_failed_publication_recovers_on_recall () = with_store @@ fun ~base_path ~keepers_dir ->
  let snapshot = commit ~keepers_dir ~previous:None "committed before publication" in
  let index = Recall.path ~keepers_dir ~keeper_name:"keeper" in
  Unix.mkdir index 0o700;
  check bool "index publication failed" true
    (Result.is_error (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" snapshot));
  ignore (check_notice ~base_path ~keepers_dir ~status:"working context is unavailable");
  Unix.rmdir index;
  let body = Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" () |> Option.get in
  check bool "same committed snapshot re-enters recall without a model pass" true
    (String_util.contains_substring body "sha256=");
  check bool "repair does not change authority" true
    (Option.map Context.version (ok (Context.read ~keepers_dir ~keeper_id:"keeper"))
     = Some (Context.version snapshot))

let test_gc_and_missing_blob_repair () = with_store @@ fun ~base_path ~keepers_dir ->
  let store = Tool_blob_store.create ~base_path in
  let fetch reference =
    match Tool_blob_store.fetch store ~sha256:reference.Tool_output.sha256 with
    | Ok (Some body) -> body
    | Ok None -> fail "referenced working context was collected"
    | Error error -> fail (Tool_blob_store.fetch_error_to_string error) in
  let sweep mode = match Tool_blob_maintenance.run ~base_path
      ~board_posts_file:Masc_board_handlers.Board_paths.posts_file ~mode with
    | Ok _ -> ()
    | Error error -> fail (Tool_blob_maintenance.error_to_string error) in
  let first = commit ~keepers_dir ~previous:None "historical working context" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first);
  let historical = artifact_of_index ~keepers_dir in
  let historical_body = fetch historical in
  let second = commit ~keepers_dir ~previous:(Some first) "current working context" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  let current = artifact_of_index ~keepers_dir in
  let current_body = fetch current in
  (* Production config is outside the roots scanned by blob maintenance. No
     tool read or prompt capture is needed to keep either publication alive. *)
  check bool "config and runtime keeper roots differ" false
    (String.equal keepers_dir (Common.keepers_runtime_dir_of_base ~base_path));
  sweep Tool_blob_maintenance.Observe_only;
  sweep Tool_blob_maintenance.Delete_previous_candidates;
  check string "historical context survives GC" historical_body (fetch historical);
  check string "current context survives GC" current_body (fetch current);
  let before = Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" () in
  (match Tool_blob_store.delete store ~sha256:current.sha256 with
   | Ok true -> ()
   | Ok false -> fail "fixture current blob was absent"
   | Error error -> fail error.Tool_blob_store.reason);
  check (option string) "missing artifact repairs to the same prompt" before
    (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ());
  check string "repair restores exact authoritative context" current_body (fetch current);
  let blob_path = Filename.concat
      (Filename.concat (Tool_blob_store.root_dir store) (String.sub current.sha256 0 2)) current.sha256 in
  Fs_compat.save_file blob_path "damaged working context";
  check (option string) "corrupt artifact repairs to the same prompt" before
    (Recall.render ~base_path ~keepers_dir ~keeper_name:"keeper" ());
  check string "corrupt artifact restored exactly" current_body (fetch current);
  let root = Tool_blob_store.root_dir store in
  Sys.rename root (root ^ ".saved");
  Fs_compat.save_file root "not a directory";
  ignore (check_notice ~base_path ~keepers_dir ~status:"working context is unavailable");
  check bool "repair failure preserves authoritative revision" true
    (Option.map Context.version (ok (Context.read ~keepers_dir ~keeper_id:"keeper"))
     = Some (Context.version second))


let test_late_render_cannot_replace_current_pin () = with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "old context" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first);
  let current_pin = Filename.concat
      (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path) "keeper")
      "librarian-recall-current.json" in
  let new_pin = ref "" in
  let body = Recall.For_testing.render ~base_path ~keepers_dir ~keeper_name:"keeper"
      ~before_retain:(fun () ->
        let next = commit ~keepers_dir ~previous:(Some first) "new context" in
        ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" next);
        new_pin := Fs_compat.load_file current_pin) () |> Option.get in
  check bool "late render withdraws its obsolete pointer" true
    (String_util.contains_substring body "working context is unavailable");
  check string "late render cannot overwrite newer current pin" !new_pin
    (Fs_compat.load_file current_pin)


let () = run "working context recall"
  ["progress", [test_case "failed publication recovers on recall" `Quick test_failed_publication_recovers_on_recall;
    test_case "late render cannot replace newer publication pin" `Quick test_late_render_cannot_replace_current_pin;
    test_case "published context survives GC and repairs missing or corrupt bytes" `Quick test_gc_and_missing_blob_repair;
    test_case "held recall follows empty unavailable and recovered context" `Quick test_recall_lifecycle_retires_and_restores_held_pointer;
    test_case "recovered generation replaces older high revision" `Quick test_recovered_generation_replaces_old_index;
    test_case "growing context remains paged and off request path" `Quick test_growth_does_not_expand_prompt;
    test_case "stale publication and corrupt index recovery" `Quick test_stale_publish_and_corruption;
    test_case "owner commit invalidates stale projection" `Quick test_committed_snapshot_invalidates_stale_projection]]
