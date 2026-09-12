open Alcotest
module Observation = Masc.Browser_observation
module Runtime = Masc.Keeper_tool_in_process_runtime
module Log = Masc.Keeper_tool_call_log
let ok = function Ok value -> value | Error detail -> fail detail
let with_base f =
  let base = Filename.temp_dir "browser-observation-" "" in
  Fun.protect ~finally:(fun () -> Log.reset_for_testing (); Fs_compat.remove_tree base)
    (fun () -> f base)
let data document text = `Assoc [
  "schema", `String "masc.browser.scene.v1"; "tabId", `Int 7;
  "documentId", `String document; "url", `String ("https://example.org/" ^ document);
  "title", `String document; "view", `String "content"; "scope", `Null;
  "viewport", `Assoc ["width", `Int 800; "height", `Int 600; "scrollX", `Int 0; "scrollY", `Int 0];
  "chars", `Int (String.length text); "truncated", `Bool false;
  "nodes", `List [`Assoc ["nodeId", `String "message"; "kind", `String "text";
    "tag", `String "p"; "text", `String text; "color", `String "rgb(0,0,0)";
    "fontSize", `Int 16; "fontWeight", `String "400"; "whiteSpace", `String "normal";
    "rects", `List [`Assoc ["x", `Int 0; "y", `Int 0; "width", `Int 600; "height", `Int 20]]]]]
let routed json = match json with
  | `Assoc fields -> `Assoc (fields @ ["source",`String "automation";"clientId",`Null])
  | _ -> fail "fixture object required"
let retained_reference result = match Tool_result.retained_artifacts result with
  | [reference] -> reference | _ -> fail "one retained observation required"
let fetch base reference =
  match Tool_blob_store.fetch (Tool_blob_store.create ~base_path:base) ~sha256:reference.Tool_output.sha256 with
  | Ok (Some bytes) -> bytes | Ok None -> fail "retained bytes missing"
  | Error error -> fail (Tool_blob_store.fetch_error_to_string error)

let test_runtime_retains_inline_scene_and_log_roots () = with_base (fun base ->
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Eio.Switch.run (fun sw ->
      let current = ref (match data "alpha" (String.make 8000 'a' ^ "한글🙂") with
        | `Assoc fields -> `Assoc (fields @ [
            "source", `String "live";
            "clientId", `String "11111111-1111-4111-8111-111111111111";
            "source", `String "backend-conflict";
            "clientId", `Null;
            "elapsed_ms", `Float (-1.); "elapsed_ms", `Float (-2.)])
        | _ -> assert false) in
      Browser_lane.install_automation_executor (Some (function
        | Browser_lane.Page_scene {tab_id=7;view;scope=None;_} ->
          let fields = match !current with `Assoc fields -> fields | _ -> fail "scene object required" in
          let data = `Assoc (("view", `String (match view with Content -> "content" | Regions -> "regions"))
            :: List.remove_assoc "view" fields) in
          Browser_lane.Answered (`Assoc ["ok",`Bool true;"data",data])
        | _ -> fail "observation used an unexpected browser action"));
      Eio.Switch.on_release sw (fun () -> Browser_lane.install_automation_executor None);
      let meta = Masc_test_deps.meta_of_json_fixture (`Assoc ["name",`String "reader"]) |> ok in
      let config = Masc.Workspace.default_config base in
      let args = `Assoc ["lane",`String "automation";"tabId",`Int 7;"mode",`String "scene"] in
      let execution = Runtime.handle_browser_read_with_outcome ~config ~meta ~args in
      check bool "actual Keeper producer completed" true (execution.disposition=Tool_result.Completed ());
      let result = Tool_result.make_ok ~tool_name:"BrowserRead" ~start_time:0.
          ?data:execution.data ?metadata:execution.metadata ()
          |> Tool_result.with_retained_artifacts execution.retained_artifacts in
      let reference = retained_reference result in
      check string "typed scene MIME" Observation.mime reference.mime;
      let original = fetch base reference in
      check string "stored bytes exactly match model data" original (Tool_result.message result);
      let fields = match Yojson.Safe.from_string original with
        | `Assoc fields -> fields | _ -> fail "retained scene must be an object" in
      List.iter (fun key -> check int (key ^ " has exactly one authoritative value") 1
        (List.length (List.filter (fun (name, _) -> name = key) fields)))
        ["source"; "clientId"; "elapsed_ms"];
      check bool "backend cannot override actual automation source" true
        (List.assoc "source" fields = `String "automation");
      check bool "backend cannot attach a live client to automation" true
        (List.assoc "clientId" fields = `Null);
      check bool "elapsed time belongs to the local read" true
        (match List.assoc "elapsed_ms" fields with `Float value -> value >= 0. | _ -> false);
      let canonical = Observation.of_json (Yojson.Safe.from_string original) |> ok in
      check bool "durable decoder sees the actual read route" true
        (canonical.source = Masc.Browser_surface.Automation && canonical.client_id = None);
      let provider = match Masc.Tool_bridge.to_agent_core_typed_result ~base_path:base
          ~model_projection:(Tool_output.Inline_up_to {maximum_bytes=100000}) result with
        | Ok value -> value | Error error -> fail error.message in
      check string "retention does not force a model artifact round trip" original provider.content;
      check bool "composition serialization does not inject model artifact references" true
        (Tool_output.normalized_artifact_refs_in_json (Tool_result.to_json result)=[]);
      let generic_read mode =
        let args = `Assoc ["lane",`String "automation";"tabId",`Int 7;"mode",`String mode] in
        match Masc.Tool_misc.dispatch
          { config; agent_name="reader"; help_schemas=[] }
          ~name:"masc_browser_read" ~args with
        | Some result -> result | None -> fail "generic MCP dispatch did not resolve browser read" in
      let generic_scene = generic_read "scene" in
      check bool "external MCP scene stays successful" true (Tool_result.is_success generic_scene);
      check int "external MCP has no ownerless reference" 0
        (List.length (Tool_result.retained_artifacts generic_scene));
      ignore (Masc.Keeper_registry.register_offline ~base_path:base meta.name meta);
      Eio.Switch.on_release sw (fun () -> Masc.Keeper_registry.For_testing.unregister ~base_path:base meta.name);
      let entry = match Masc.Keeper_registry.get ~base_path:base meta.name with
        | Some entry -> entry | None -> fail "registered Keeper missing" in
      let retain tool_name mode result = Masc.Mcp_server_eio_call_tool.retain_runtime_mcp_observation
          ~keeper_entry:(Some entry) ~tool_name ~arguments:(`Assoc ["mode",`String mode])
          ~start_time:0. result in
      check int "unknown tool remains ordinary" 0
        (List.length (Tool_result.retained_artifacts (retain "unknown" "scene" generic_scene)));
      let bound_scene = retain "masc_browser_read" "scene" generic_scene in
      check string "bound MCP retains its own exact model bytes" (Tool_result.message generic_scene)
        (fetch base (retained_reference bound_scene));
      let generic_regions = generic_read "regions" |> retain "masc_browser_read" "regions" in
      let regions = Observation.of_json
        (Yojson.Safe.from_string (fetch base (retained_reference generic_regions))) |> ok in
      check bool "bound MCP retains regions view" true (regions.scene.view=Browser_lane.Regions);
      current := data "gamma" "Later page";
      Browser_lane.install_automation_executor None;
      let historical = Observation.of_json (Yojson.Safe.from_string (fetch base reference)) |> ok in
      check string "page survives after browser moves and disconnects" "alpha" historical.scene.document_id;
      check int "same observed tab retained" 7 historical.tab_id;
      Log.reset_for_testing (); Log.init ~base_path:base ();
      let execution_id = Ids.Execution_id.generate () in
      Log.log_call ~keeper_name:"reader" ~tool_name:"BrowserRead" ~input:args
        ~output_text:(Tool_result.message result) ~success:true ~duration_ms:1.
        ~typed_result:result ~execution_id ~tool_use_id:"observed-call" ();
      Log.log_call ~keeper_name:"regions-reader" ~tool_name:"masc_browser_read" ~input:args
        ~output_text:(Tool_result.message generic_regions) ~success:true ~duration_ms:1.
        ~typed_result:generic_regions ();
      Log.log_call ~keeper_name:"mcp-reader" ~tool_name:"masc_browser_read" ~input:args
        ~output_text:(Tool_result.message bound_scene) ~success:true ~duration_ms:1.
        ~typed_result:bound_scene ();
      let row = List.hd (Log.read_recent ~keeper_name:"reader" ()) in
      let open Yojson.Safe.Util in
      check string "receipt joins original execution" (Ids.Execution_id.to_string execution_id)
        (row |> member "execution_id" |> to_string);
      let roots = row |> member "artifact_refs" |> to_list in
      check int "root is independent of truncated output" 1 (List.length roots);
      check bool "long preview is truncated" true (String.length (row |> member "output" |> to_string) < String.length original);
      let sweep = match Tool_blob_maintenance.run ~base_path:base ~mode:Observe_only with
        | Ok report -> report | Error error -> fail (Tool_blob_maintenance.error_to_string error) in
      let distinct_roots = [result; bound_scene; generic_regions]
        |> List.map (fun result -> (retained_reference result).Tool_output.sha256)
        |> List.sort_uniq String.compare in
      check int "existing tool-call registry retains every read" (List.length distinct_roots) sweep.live_references;
      check int "referenced scene is not a deletion candidate" 0 sweep.candidates_recorded)))

let test_invalid_or_unpersisted_scene_has_no_reference () = with_base (fun base ->
  let scene = routed (data "alpha" "visible") in
  let result = Tool_result.make_ok ~tool_name:"BrowserRead" ~start_time:0. ~data:scene () in
  let bad = match scene with `Assoc fields -> `Assoc (("clientId",`String "bad")::List.remove_assoc "clientId" fields) | _ -> assert false in
  check bool "unresolved automation identity is rejected" true (Result.is_error (Observation.of_json bad));
  check bool "view mismatch is rejected" true
    (Result.is_error (Observation.retain ~base_path:base ~view:Regions result));
  let root = Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:base) in
  Fs_compat.mkdir_p (Filename.dirname root); Out_channel.with_open_bin root (fun out -> output_string out "occupied");
  check bool "failed persistence cannot return a retained reference" true
    (Result.is_error (Observation.retain ~base_path:base ~view:Content result));
  check int "input result remains unmodified" 0 (List.length (Tool_result.retained_artifacts result)))

let test_duplicate_fields_never_enter_blobstore () = with_base (fun base ->
  let scene = routed (data "alpha" "visible") in
  let fields = match scene with `Assoc fields -> fields | _ -> assert false in
  let ambiguous = List.map (fun (key, value) -> `Assoc ((key, value) :: fields))
    ["source", `String "live"; "clientId", `Null; "tabId", `Int 8;
     "documentId", `String "other-document"] in
  let nested = `Assoc (("viewport", `Assoc ["width", `Int 800; "width", `Int 1;
      "height", `Int 600; "scrollX", `Int 0; "scrollY", `Int 0])
      :: List.remove_assoc "viewport" fields) in
  List.iter (fun json ->
    let result = Tool_result.make_ok ~tool_name:"BrowserRead" ~start_time:0. ~data:json () in
    check bool "ambiguous durable identity is rejected" true
      (Result.is_error (Observation.of_json json));
    check bool "ambiguity cannot publish a retained reference" true
      (Result.is_error (Observation.retain ~base_path:base ~view:Content result)))
    (nested :: ambiguous);
  let blobs = Tool_blob_store.list_all_result (Tool_blob_store.create ~base_path:base)
    |> Result.map_error (fun _ -> "blob listing failed") |> ok in
  check int "ambiguous data creates no blob" 0 (List.length blobs))

let test_generic_retention_failure_preserves_read_receipt () = with_base (fun base ->
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    let reads = ref 0 in
    Browser_lane.install_automation_executor (Some (function
      | Browser_lane.Page_scene {tab_id=7;view=Content;scope=None;_} ->
        incr reads;
        Browser_lane.Answered (`Assoc ["ok",`Bool true;"data",data "alpha" "Already read"])
      | _ -> fail "retention failure must not replay navigation or interaction"));
    Fun.protect ~finally:(fun () -> Browser_lane.install_automation_executor None) (fun () ->
      let root = Tool_blob_store.root_dir (Tool_blob_store.create ~base_path:base) in
      Fs_compat.mkdir_p (Filename.dirname root);
      Out_channel.with_open_bin root (fun out -> output_string out "occupied");
      let result = match Masc.Tool_misc.dispatch
        {config=Masc.Workspace.default_config base;agent_name="reader";help_schemas=[]}
        ~name:"masc_browser_read"
        ~args:(`Assoc ["lane",`String "automation";"tabId",`Int 7;"mode",`String "scene"]) with
        | Some result -> result | None -> fail "generic dispatch missing" in
      check bool "external read needs no blob storage" true (Tool_result.is_success result);
      let result = Masc.Tool_misc_browser_lane.retain_read_result ~base_path:base
          ~tool_name:"masc_browser_read" ~start_time:0.
          (`Assoc ["mode",`String "scene"]) result in
      (match result with
       | Tool_result.Failed failure ->
         check bool "storage failure is typed runtime failure" true
           (failure.class_=Tool_result.Runtime_failure);
         check bool "retry is read-only and proven pre-effect" true
           (failure.effect_disposition=Tool_result.Proven_pre_effect)
       | _ -> fail "storage failure must not report successful retention");
      let observed = Observation.of_json (Tool_result.data result) |> ok in
      check string "failed retention preserves observed document" "alpha" observed.scene.document_id;
      check int "failed retention publishes no reference" 0
        (List.length (Tool_result.retained_artifacts result));
      check int "exactly one browser read with no replay" 1 !reads)))

let test_external_read_creates_no_hidden_blob () = with_base (fun base ->
  Eio_main.run (fun env ->
    Time_compat.set_clock (Eio.Stdenv.clock env);
    Browser_lane.install_automation_executor (Some (function
      | Browser_lane.Page_scene _ ->
          Browser_lane.Answered (`Assoc ["ok",`Bool true;"data",data "external" "visible"])
      | _ -> fail "unexpected external action"));
    Fun.protect ~finally:(fun () -> Browser_lane.install_automation_executor None) (fun () ->
      let args = `Assoc ["lane",`String "automation";"tabId",`Int 7;"mode",`String "scene"] in
      let result = match Masc.Tool_misc.dispatch
          {config=Masc.Workspace.default_config base;agent_name="reader";help_schemas=[]}
          ~name:"masc_browser_read" ~args with
        | Some result -> result | None -> fail "browser read not dispatched" in
      let result = Masc.Mcp_server_eio_call_tool.retain_runtime_mcp_observation
          ~keeper_entry:None ~tool_name:"masc_browser_read" ~arguments:args ~start_time:0. result in
      check bool "external observation succeeds" true (Tool_result.is_success result);
      check int "no hidden reference" 0 (List.length (Tool_result.retained_artifacts result));
      let blobs = Tool_blob_store.list_all_result (Tool_blob_store.create ~base_path:base)
          |> Result.map_error (fun _ -> "blob listing failed") |> ok in
      check int "external read creates no unrooted blob" 0 (List.length blobs))))

let () = run "browser observation retention" ["shared scene",[
  test_case "duplicate fields are rejected before durable storage" `Quick test_duplicate_fields_never_enter_blobstore;
  test_case "external read creates no hidden blob" `Quick test_external_read_creates_no_hidden_blob;
  test_case "actual Keeper read stays inline and survives through the log" `Quick test_runtime_retains_inline_scene_and_log_roots;
  test_case "generic retention failure preserves read receipt" `Quick test_generic_retention_failure_preserves_read_receipt;
  test_case "invalid identity and storage failure publish no reference" `Quick test_invalid_or_unpersisted_scene_has_no_reference]]
