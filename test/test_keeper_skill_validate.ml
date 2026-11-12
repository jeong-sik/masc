open Alcotest
open Masc

module Service = Skill_catalog_snapshot_service

let require label = function
  | Ok value -> value
  | Error _ -> fail label
;;

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let write_file path text =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel text)
;;

let rec files path =
  if Sys.is_directory path
  then
    Sys.readdir path |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun name -> files (Filename.concat path name))
  else [ path, Digest.file path |> Digest.to_hex ]
;;

let instruction name =
  Printf.sprintf "---\nname: %s\ndescription: Inspect the lane status.\n---\nRead keeper_lane_status before reporting.\n" name
;;

let composition tool =
  Printf.sprintf
    {|---
name: proposed
description: Inspect the lane status.
---
```toml composition
[[compositions]]
name = "proposed"
description = "Inspect the lane status."
execution = "inline"
[[compositions.nodes]]
id = "lane"
tool = %S
[compositions.nodes.input]
kind = "literal"
value = {}
```
|} tool
;;

(* Same single-node shape as [composition] but with caller-chosen prose, so
   repeat-cache tests use bytes no other test in this process validates. *)
let composition_about tool blurb =
  Printf.sprintf
    {|---
name: proposed
description: %s
---
```toml composition
[[compositions]]
name = "proposed"
description = "%s"
execution = "inline"
[[compositions.nodes]]
id = "lane"
tool = %S
[compositions.nodes.input]
kind = "literal"
value = {}
```
|} blurb blurb tool
;;

(* #37493: the Keeper model reads a tool result only after
   [Tool_bridge.to_agent_core_typed_result] projects it with the workspace
   base_path. Calling the runtime handler alone never reached that projection,
   so a result the projection refused still passed here. Every call below now
   crosses it: success must stay an inline verdict and a rejection must reach
   the model as its own error code, never as a storage failure. *)
let model_sees_verdict ~base_path (result : Keeper_tool_execution.t) data =
  let tool_name = "keeper_skill_validate" in
  let start_time = Tool_timing.start () in
  let typed =
    match result.Keeper_tool_execution.disposition with
    | Tool_result.Completed () -> Tool_result.make_ok ~tool_name ~start_time ~data ()
    | Tool_result.Failed class_ ->
      Tool_result.make_err ~tool_name ~class_ ~start_time ~data
        ~effect_disposition:result.Keeper_tool_execution.failure_effect_disposition
        result.Keeper_tool_execution.raw_output
    | Tool_result.Deferred () -> fail "static validation never defers"
  in
  let storage_failure = "tool output artifact storage failed" in
  let contains text needle =
    let n = String.length needle and t = String.length text in
    let rec go i = i + n <= t && (String.sub text i n = needle || go (i + 1)) in
    go 0
  in
  match
    Tool_bridge.to_agent_core_typed_result ~base_path typed,
    result.Keeper_tool_execution.disposition
  with
  | Ok { content; _ }, Tool_result.Completed () ->
    check bool "verdict is not replaced by a blob marker" false (Tool_output.is_marker content);
    check bool "model reads ok=true inline" true (contains content {|"ok":true|})
  | Ok _, (Tool_result.Failed _ | Tool_result.Deferred ()) ->
    fail "a failed validation projected as success"
  | Error { message; _ }, Tool_result.Completed () ->
    check string "a completed validation reaches the model" "" message
  | Error { message; _ }, (Tool_result.Failed _ | Tool_result.Deferred ()) ->
    check bool "a rejection is not reported as a storage failure" false
      (String.equal message storage_failure);
    let code = Yojson.Safe.Util.(member "error" data |> to_string) in
    check bool "model reads the rejection code" true (contains message code)
;;

let with_fixture ?(tool_deny = []) ?(damage_exports = false) f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-skill-validate-" "" in
  let workspace = Service.workspace_of_base_path ~base_path |> require "workspace" in
  Fun.protect
    ~finally:(fun () -> Service.retire ~workspace; remove_tree base_path)
    (fun () ->
      let root = Filename.concat base_path "skills" in
      Unix.mkdir root 0o700;
      let package = Filename.concat root "installed" in
      Unix.mkdir package 0o700;
      write_file (Filename.concat package "SKILL.md") (instruction "installed");
      let config_text =
        "[skills]\n[[skills.sources]]\nid = \"workspace\"\nanchor = \"base-path\"\npath = \"skills\"\naccess = \"read-write\"\n"
      in
      (match Service.refresh ~workspace ~user_home:None
        ~read_config:(fun () -> { Service.path = "/fixture/runtime.toml"; source_text = config_text }) with
       | Service.Published _ | Unchanged _ -> ()
       | Workspace_retired -> fail "fixture snapshot retired");
      let config = Workspace.default_config base_path in
      Masc_test_deps.init_unified_tool_registry ();
      let meta = Masc_test_deps.meta_of_json_fixture
          (`Assoc [ "name", `String "skill-author" ]) |> require "Keeper fixture" in
      let skill_snapshot = Skill_catalog_snapshot.config_unreadable ~detail:"fixture" in
      let surface = Keeper_capability_surface.create
        ~tool_deny ~sandbox_profile:meta.sandbox_profile ~skill_names:None
        ~global_skill_catalog:Keeper_skill_catalog.empty
        ~skill_inventory:(Keeper_skill_inventory.of_snapshot skill_snapshot)
        ~task_skills:[] in
      let context : Keeper_tool_runtime.context =
        { config; meta
        ; publication_recovery =
            { provider = Keeper_publication_recovery_availability.non_runtime_provider
            ; keeper_name = meta.name }
        ; ctx_work = Keeper_context_runtime.create ~eio:true ~system_prompt:"fixture"
        ; source_context = None
        ; owned_job_replay = None
        ; execution_scope = None
        ; artifact_draft_scope = None; turn_sandbox_factory = None; sw = None; clock = None; proc_mgr = None
        ; net = None; mcp_session_id = None; continuation_channel = None
        ; gate_context = None; turn_ref = None; gate_grant = None; tool_use_id = None; trace_id = None
        ; result_projection = None
        ; capability_authority = Keeper_tool_runtime.Frozen_surface surface }
      in
      let descriptor =
        match Keeper_tool_runtime.descriptor_for_internal "keeper_skill_validate" with
        | Some descriptor -> descriptor
        | None -> fail "public validation descriptor missing"
      in
      check bool "model can discover validation" true
        (List.mem "keeper_skill_validate" (Keeper_tool_descriptor.keeper_model_names descriptor));
      let store = Tool_blob_store.create ~base_path in
      let artifact source_text =
        (* The actual durable export producer and exact exported reference shape.
           These are synthetic bytes, not a claim that a Keeper generated them. *)
        let blob : Tool_output.artifact_ref = Tool_blob_store.put_durable store ~bytes:source_text
            ~mime:"application/octet-stream" in
        (* A damaged export keeps its address but holds other bytes. *)
        if damage_exports then begin
          let file = Filename.concat (Filename.concat (Tool_blob_store.root_dir store)
              (String.sub blob.sha256 0 2)) blob.sha256 in
          Unix.unlink file;
          Out_channel.with_open_bin file (fun channel -> Out_channel.output_string channel "damaged")
        end;
        Keeper_peer_artifact_ref.(to_json (of_blob blob))
      in
      let call args =
        let before_files = files base_path in
        let before_snapshot = Service.current ~workspace in
        let result =
          match Keeper_tool_runtime.handle context ~descriptor ~args with
          | Some result -> result
          | None -> fail "public validation did not dispatch"
        in
        check (list (pair string string)) "no source or blob was changed"
          before_files (files base_path);
        check bool "no snapshot was published" true
          (match before_snapshot, Service.current ~workspace with
           | Some before, Some after -> before == after
           | _ -> false);
        let data = match result.data with Some data -> data | None -> fail "missing typed result" in
        check bool "no published reference is fabricated" true
          (Yojson.Safe.Util.member "reference" data = `Null);
        model_sees_verdict ~base_path result data;
        result, data
      in
      f artifact call)
;;

let args ?(package_id = "proposed") artifact =
  `Assoc [ "artifact", artifact; "package_id", `String package_id ]
;;

let string_field name data = Yojson.Safe.Util.(member name data |> to_string)

(* Absent on a full parse (and on every verdict before the repeat cache);
   [true] only when the verdict reused a previous parse of identical bytes. *)
let cached_flag data =
  match Yojson.Safe.Util.member "cached" data with
  | `Bool cached -> cached
  | `Null -> false
  | _ -> fail "cached flag is not a bool"
;;

let failed code (result, data) =
  check bool "validation failed" true
    (match result.Keeper_tool_execution.disposition with Tool_result.Failed _ -> true | _ -> false);
  check string "exact error kind" code (string_field "error" data);
  check bool "reason is preserved" true (String.length (string_field "message" data) > 0)
;;

let valid kind ~source artifact (result, data) =
  check bool "completed static validation" true
    (result.Keeper_tool_execution.disposition = Tool_result.Completed ());
  let identity = Yojson.Safe.Util.member "source" data in
  check string "verdict names the exact source digest"
    (Yojson.Safe.Util.to_string artifact)
    Yojson.Safe.Util.(member "sha256" identity |> to_string);
  check int "verdict names the exact source size"
    (String.length source)
    Yojson.Safe.Util.(member "bytes" identity |> to_int);
  check bool "no artifact reference is echoed" true
    (Yojson.Safe.Util.member "artifact" data = `Null);
  check string "static only" "static" (string_field "validation" data);
  check string "kind" kind (string_field "kind" data);
  check string "package identity" "proposed" (string_field "package_id" data);
  check string "document name" "proposed" (string_field "name" data)
;;

let test_instruction () = with_fixture @@ fun artifact call ->
  let source = instruction "proposed" in
  let exported = artifact source in
  call (args exported) |> valid "instruction" ~source exported
;;

let test_composition () = with_fixture @@ fun artifact call ->
  let source = composition "keeper_lane_status" in
  let exported = artifact source in
  call (args exported) |> valid "composition" ~source exported;
  artifact (composition "nonexistent_tool") |> args |> call |> failed "composition_rejected"
;;

let test_denied_node () =
  with_fixture ~tool_deny:["keeper_lane_status"] @@ fun artifact call ->
  artifact (composition "keeper_lane_status") |> args |> call |> failed "composition_rejected"
;;

let test_invalid_document () = with_fixture @@ fun artifact call ->
  artifact "---\ndescription: Name is required.\n---\nBody\n" |> args |> call
  |> failed "definition_rejected";
  artifact (instruction "another-package") |> args |> call |> failed "definition_rejected"
;;

let test_invalid_request () = with_fixture @@ fun artifact call ->
  let exported = artifact (instruction "proposed") in
  call (args ~package_id:"../proposed" exported) |> failed "invalid_skill_validation_request";
  call (args (`Assoc [])) |> failed "invalid_skill_validation_request"
;;

let test_size_limit () = with_fixture @@ fun artifact call ->
  let source = instruction "proposed" ^ String.make 1_048_576 'x' in
  let result, data = artifact source |> args |> call in
  failed "source_too_large" (result, data);
  check int "shared authoring size limit" 1_048_576 Yojson.Safe.Util.(member "max_bytes" data |> to_int);
  check int "actual source size" (String.length source) Yojson.Safe.Util.(member "bytes" data |> to_int)
;;

(* The reference is the sha256 alone, so it cannot claim a wrong size. What
   is left to refuse is an address the store does not hold and a string that
   is not an address. *)
let test_reference_integrity () = with_fixture @@ fun artifact call ->
  let exported = artifact (instruction "proposed") in
  let sha256 = String.make 64 '0' in
  let absent = call (args (`String sha256)) in
  failed "artifact_not_found" absent;
  check bool "an absent artifact is a workflow rejection" true
    ((fst absent).Keeper_tool_execution.disposition = Tool_result.Failed Tool_result.Workflow_rejection);
  check bool "the refusal names the absent sha256" true
    (String_util.contains_substring (string_field "message" (snd absent)) sha256);
  call (args (`String (String.uppercase_ascii (Yojson.Safe.Util.to_string exported))))
  |> failed "invalid_skill_validation_request"
;;

let test_unreadable_artifact () = with_fixture ~damage_exports:true @@ fun artifact call ->
  let damaged = call (args (artifact (instruction "proposed"))) in
  failed "artifact_read_failed" damaged;
  check bool "a damaged artifact is a runtime failure" true
    ((fst damaged).Keeper_tool_execution.disposition = Tool_result.Failed Tool_result.Runtime_failure)
;;

(* #49177: the same bytes validated three times parse once; the repeats
   reuse the first verdict with identical fields. *)
let test_repeated_success_cached () = with_fixture @@ fun artifact call ->
  let source = composition_about "keeper_lane_status" "Inspect the lane status on repeat" in
  let exported = artifact source in
  let first = call (args exported) in
  let second = call (args exported) in
  let third = call (args exported) in
  valid "composition" ~source exported first;
  valid "composition" ~source exported second;
  valid "composition" ~source exported third;
  check bool "first validation parses" false (cached_flag (snd first));
  check bool "second validation reuses the parse" true (cached_flag (snd second));
  check bool "third validation reuses the parse" true (cached_flag (snd third))
;;

let test_repeated_failure_cached () = with_fixture @@ fun artifact call ->
  let source = composition_about "nonexistent_tool" "Name a tool nothing owns, repeatedly" in
  let exported = artifact source in
  let first = call (args exported) in
  let second = call (args exported) in
  failed "composition_rejected" first;
  failed "composition_rejected" second;
  check string "cached failure repeats the message"
    (string_field "message" (snd first)) (string_field "message" (snd second));
  check bool "first failure parses" false (cached_flag (snd first));
  check bool "second failure reuses the parse" true (cached_flag (snd second))
;;

(* Same bytes, different descriptor surfaces: the allowed surface and the
   denying surface must not share a verdict. Each test below runs in its own
   fixture; whichever runs first, its entries never satisfy the other
   surface, so both first calls parse and both second calls hit their own. *)
let shared_surface_source =
  composition_about "keeper_lane_status" "Shared bytes across two surfaces"
;;

let test_cache_allows_on_default_surface () = with_fixture @@ fun artifact call ->
  let exported = artifact shared_surface_source in
  let first = call (args exported) in
  let second = call (args exported) in
  valid "composition" ~source:shared_surface_source exported first;
  valid "composition" ~source:shared_surface_source exported second;
  check bool "allowed surface parses first" false (cached_flag (snd first));
  check bool "allowed surface reuses its parse" true (cached_flag (snd second))
;;

let test_cache_denies_on_deny_surface () =
  with_fixture ~tool_deny:[ "keeper_lane_status" ] @@ fun artifact call ->
  let exported = artifact shared_surface_source in
  let first = call (args exported) in
  let second = call (args exported) in
  failed "composition_rejected" first;
  failed "composition_rejected" second;
  check bool "denied surface parses instead of reusing the success" false
    (cached_flag (snd first));
  check bool "denied surface reuses its own parse" true (cached_flag (snd second))
;;

let () =
  Mirage_crypto_rng_unix.use_default ();
  run "Keeper Skill validation"
    [ "public artifact validation",
      [ test_case "instruction without publication" `Quick test_instruction
      ; test_case "composition uses the canonical plan validator" `Quick test_composition
      ; test_case "denied node cannot validate" `Quick test_denied_node
      ; test_case "invalid document and package mismatch" `Quick test_invalid_document
      ; test_case "invalid request" `Quick test_invalid_request
      ; test_case "shared authoring size limit" `Quick test_size_limit
      ; test_case "artifact reference integrity" `Quick test_reference_integrity
      ; test_case "damaged artifact is a runtime failure" `Quick test_unreadable_artifact
      ; test_case "repeated success reuses the parse" `Quick test_repeated_success_cached
      ; test_case "repeated failure reuses the parse" `Quick test_repeated_failure_cached
      ; test_case "repeat cache allows on the default surface" `Quick test_cache_allows_on_default_surface
      ; test_case "repeat cache denies on the deny surface" `Quick test_cache_denies_on_deny_surface
      ] ]
