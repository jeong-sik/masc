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
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
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

let test_growth_does_not_expand_prompt () = with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "Campaign in progress" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first);
  let small = Option.get (Recall.render ~keepers_dir ~keeper_name:"keeper") in
  let large_text = String.make (Common.max_tool_result_wire_bytes * 4) 'x' in
  let second = commit ~keepers_dir ~previous:(Some first) large_text in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  let large = Option.get (Recall.render ~keepers_dir ~keeper_name:"keeper") in
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
  check (option string) "index recall fails closed without its owner snapshot"
    None (Recall.render ~keepers_dir ~keeper_name:"keeper")

let test_stale_publish_and_corruption () = with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "first" in
  let second = commit ~keepers_dir ~previous:(Some first) "second" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  let current = Recall.render ~keepers_dir ~keeper_name:"keeper" in
  check bool "older publisher cannot overwrite newer index" true
    (Result.is_error (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first));
  check (option string) "newer context stays available" current
    (Recall.render ~keepers_dir ~keeper_name:"keeper");
  ok (Fs_compat.save_file_atomic (Recall.path ~keepers_dir ~keeper_name:"keeper") "{");
  check (option string) "broken advisory index cannot prevent input admission" None
    (Recall.render ~keepers_dir ~keeper_name:"keeper");
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  check (option string) "next background publication repairs advisory index" current
    (Recall.render ~keepers_dir ~keeper_name:"keeper")

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
  let current = Recall.render ~keepers_dir ~keeper_name:"keeper" in
  check bool "old generation cannot publish over recovered snapshot" true
    (Result.is_error (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second));
  check bool "equal numeric revision from old generation is also rejected" true
    (Result.is_error (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first));
  check (option string) "recovered reference remains available" current
    (Recall.render ~keepers_dir ~keeper_name:"keeper")

let test_committed_snapshot_invalidates_stale_projection () =
  with_store @@ fun ~base_path ~keepers_dir ->
  let first = commit ~keepers_dir ~previous:None "first context" in
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" first);
  check bool "first projection is available" true
    (Option.is_some (Recall.render ~keepers_dir ~keeper_name:"keeper"));
  let second = commit ~keepers_dir ~previous:(Some first) "second context" in
  check (option string) "older projection is not consumed after owner commit" None
    (Recall.render ~keepers_dir ~keeper_name:"keeper");
  ok (Recall.publish ~base_path ~keepers_dir ~keeper_name:"keeper" second);
  check bool "matching replacement projection is available" true
    (Option.is_some (Recall.render ~keepers_dir ~keeper_name:"keeper"))

let () = run "working context recall"
  ["progress", [test_case "recovered generation replaces older high revision" `Quick test_recovered_generation_replaces_old_index;
    test_case "growing context remains paged and off request path" `Quick test_growth_does_not_expand_prompt;
    test_case "stale publication and corrupt index recovery" `Quick test_stale_publish_and_corruption;
    test_case "owner commit invalidates stale projection" `Quick test_committed_snapshot_invalidates_stale_projection]]
