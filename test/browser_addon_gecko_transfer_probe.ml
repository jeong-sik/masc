(* Real owned Gecko transfers through the installed Addon. The payload reader
   below is the fixture's explicit host authority, not a Keeper sandbox probe. *)
open Masc
module R = Lane_addon_runtime
module B = Browser_lane
module F = Exact_output_fixture
let ( let* ) = Result.bind
let require = function Ok value -> value | Error message -> failwith message
let argument flag =
  let rec find = function
    | key::value::_ when key=flag -> value
    | _::rest -> find rest
    | [] -> invalid_arg ("missing " ^ flag) in
  find (Array.to_list Sys.argv)
let write path value = Out_channel.with_open_bin path (fun ch -> output_string ch value)
let field key (value:Yojson.Safe.t) = match value with
  | `Assoc fields -> List.assoc_opt key fields
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> None
let string key value = match field key value with
  | Some (`String text) -> Some text | None|Some _ -> None
let steps=ref [] and receipts=ref [] and witnesses=ref []
let model_requests=ref [] and model_responses=ref []
let output=ref ""
let flush () = write (Filename.concat !output "gecko-transfer-proof.json")
  (Yojson.Safe.pretty_to_string (`Assoc ["steps",`List (List.rev !steps);
    "receipts",`List (List.rev !receipts);"witnesses",`Assoc (List.rev !witnesses);
    "tool_hooks",`List [`String "validate_input";`String "validate_output"];
    "model_outputs",`List [`String "locate"];
    "model_requests",`List (List.rev !model_requests);
    "model_responses",`List (List.rev !model_responses)]))
let record name result =
  steps:=`Assoc ["step",`String name;"ok",`Bool (Result.is_ok result);
    "error",(match result with Ok _ -> `Null | Error detail -> `String detail)]::!steps;
  flush (); Printf.printf "%s %s\n%!" (if Result.is_ok result then "ok" else "FAIL") name;
  require result
let witness key value = witnesses:=(key,value)::!witnesses;flush ()
let check message value = if value then Ok `Null else Error message
let locate_reply ~schema ~fixture_url body =
  try
    let request=Yojson.Safe.from_string body in
    let open Yojson.Safe.Util in
    let requirement=Agent_core.Exact_output.make_output_requirement ~schema
      ~minimum_guarantee:Agent_core.Exact_output.Json_syntax in
    let* ()=if (request |> member "response_format" |> member "type") = `String "json_object"
      then Ok () else Error "locate request did not use the shared JSON mode" in
    match request |> member "messages" |> to_list |> List.rev with
    | instruction::context::_ when string "role" instruction=Some "user"
        && string "content" instruction=Some (Agent_core.Exact_output.schema_instruction_text requirement)
        && string "role" context=Some "user" ->
      let scene=context |> member "content" |> to_string |> Yojson.Safe.from_string in
      let* ()=if string "instruction" scene=Some "Find the Download binary link"
          && string "url" scene=Some fixture_url && string "title" scene=Some "Gecko transfer fixture"
        then Ok () else Error "the actual fixture observation did not reach locate" in
      let nodes=scene |> member "nodes" |> to_list in
      (match List.filter (fun node -> string "tag" node=Some "a"
          && string "text" node=Some "Download binary"
          && string "href" (member "kind" node)=Some (fixture_url ^ "download")) nodes with
       | [node] ->
         let* node_id=string "nodeId" node |> Option.to_result ~none:"observed download link has no nodeId" in
         let output=`Assoc ["matches",`List [`Assoc ["nodeId",`String node_id;
           "description",`String "The observed binary download link"]]] in
         Ok (scene,node,output)
       | []|_::_ -> Error "locate did not receive exactly one observed download link")
    | []|_::_ -> Error "locate did not receive the canonical schema and observation turns"
  with Yojson.Json_error _|Yojson.Safe.Util.Type_error _ -> Error "invalid locate provider request"
let () =
  let firefox=Unix.realpath (argument "--firefox")
  and driver=Unix.realpath (argument "--driver")
  and manifest=Unix.realpath (argument "--manifest")
  and payload=Unix.realpath (argument "--payload")
  and fixture_url=argument "--fixture-url" in
  let expected_skill_revision=In_channel.with_open_bin
      (Filename.concat (Filename.dirname manifest) "skills/browser/SKILL.md") In_channel.input_all
    |> Skill_reference.content_revision_of_source_text in
  output:=Unix.realpath (argument "--out");flush ();
  let expected=In_channel.with_open_bin payload In_channel.input_all in
  let base_path=Filename.temp_dir ~perms:0o700 "browser-addon-gecko-transfer-" "" |> Unix.realpath in
  write (Filename.concat !output "workspace.txt") base_path;
  let config_root=Filename.concat base_path ".masc/config" in Fs_compat.mkdir_p config_root;
  Unix.putenv Env_config_core.base_path_env_key base_path;
  Unix.putenv Env_config_core.config_dir_env_key config_root;
  let bin=Filename.concat base_path "bin" in Unix.mkdir bin 0o700;
  List.iter (fun (flag,name) -> Unix.symlink (Unix.realpath (argument flag)) (Filename.concat bin name))
    ["--launcher","masc-native-addon-launcher";"--guardian","masc-browser-process-owner";
     "--worker","masc-browser-addon-worker"];
  Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"" (Sys.getenv_opt "PATH"));
  Unix.mkdir (Filename.concat base_path "fixture-skills") 0o700;
  let runtime_path=Filename.concat config_root "runtime.toml" in
  write runtime_path (Exact_output_fixture.official_client_runtime_fixture ^ Printf.sprintf
    "\n[skills]\n[[skills.sources]]\nid=\"probe-local\"\nanchor=\"base-path\"\npath=\"fixture-skills\"\naccess=\"read-only\"\n[browser.live]\nenabled=false\n[browser.stagehand]\nenabled=false\n[browser.automation]\nenabled=true\ngeckodriver=%S\nbinary=%S\n" driver firefox);
  require (Runtime.init_default ~config_path:runtime_path);
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
  Time_compat.set_clock clock;Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
    let config=Workspace.default_config base_path in
    let locate_schema=Yojson.Safe.from_file (Filename.concat (Filename.dirname manifest) "schemas/locate.json") in
    let selected=ref None in
    let provider=F.start_server ~sw ~net ~clock (F.Reply_with (fun index body ->
      model_requests:=`Assoc ["request_index",`Int index;"body",`String body]::!model_requests;
      let status,response=match locate_reply ~schema:locate_schema ~fixture_url body with
        | Ok (scene,node,answer) ->
          selected:=Some (scene,node);witness "locate_model_output" answer;
          `OK,F.openai_response answer
        | Error message -> `Bad_request,Yojson.Safe.to_string (`Assoc ["error",`Assoc ["message",`String message]]) in
      model_responses:=`Assoc ["request_index",`Int index;"status",`Int (Cohttp.Code.code_of_status status);
        "body",`String response]::!model_responses;flush ();status,response)) in
    ignore (F.publish_registry ~lane_id:"browser/locate" ~slot_ids:["probe"]
      (F.resolver_snapshot ~source:base_path [{F.id="probe";base_url=provider.base_url}]) : Runtime_exact_output_registry.t);
    R.register_exact_runner (Server_lane_addon_exact.runner ~base_path);
    let access=Lane_addon_sources.Operator_configuration in
    let principal=Lane_addon_call_context.Keeper "gecko-transfer-probe" in
    let directory=R.configuration_directory config in Fs_compat.mkdir_p directory;
    let declaration=Filename.concat directory "browser.toml" in
    let rec await work=match work () with Some result -> result
      | None -> Eio.Time.sleep clock 0.01;await work in
    ignore (record "publish the isolated workspace Skill configuration"
      (let* observation=Runtime.load_config_observation ~runtime_config_path:runtime_path () in
       let* publication=Server_skill_snapshot_runtime.refresh_from_observation ~base_path observation
         |> Result.map_error Server_skill_snapshot_runtime.error_to_string in
       match publication with
       | Skill_catalog_snapshot_service.Published _|Unchanged _ -> Ok `Null
       | Workspace_retired -> Error "fixture Skill workspace was retired"));
    R.register_skill_export_handler Server_skill_snapshot_runtime.publish_lane_skills;
    R.start_configuration_service ~config ~sw ~clock;
    write declaration (Printf.sprintf
      "id=\"browser\"\nrun_id=\"gecko-transfer-probe\"\nmanifest_path=%S\nexact_outputs=[\"locate\"]\ntool_hooks=[\"validate_input\",\"validate_output\"]\n[binding]\nsources=[]\n" manifest);
    let report=require (R.reconcile_configuration ~config ~directory) in
    if Yojson.Safe.Util.member "complete" report<>`Bool true
      || Yojson.Safe.Util.member "issues" report<>`List [] then
      failwith ("declaration refused: " ^ Yojson.Safe.to_string report);
    let service=await (fun () ->
      List.iter (fun (item:R.inventory_instance) -> match item.phase with
        | Lane_addon_types.Failed message -> failwith message
        | Attached|Observing|Detaching|Detached -> ()) (R.inventory ~config).instances;
      match R.browser_services ~config ~access with [service] -> Some service
      | [] -> None | _::_::_ -> failwith "ambiguous browser installations") in
    witness "instance_id" (`String service.instance_id);
    ignore (record "the real catalog publishes the browser package Skill"
      (let* catalog=Server_skill_snapshot_runtime.lookup ~base_path
         |> Result.map_error Server_skill_snapshot_runtime.error_to_string in
       match catalog with
       | Server_skill_snapshot_runtime.Ready {snapshot;_} ->
         (match Skill_catalog_snapshot.find_effective_by_name snapshot "browser" with
          | Some entry -> check
              ("catalog Skill has unexpected identity or content: " ^
               Yojson.Safe.to_string (Skill_reference.to_yojson (Skill_catalog_snapshot.entry_reference entry)))
              (Skill_reference.identity_source_id_to_string entry.identity=R.skill_source_id (R.Declaration "browser")
               && Skill_reference.identity_package_id_to_string entry.identity="browser"
               && entry.identity.name="browser"
               && entry.directory="browser"
               && Skill_reference.equal_content_revision entry.content_revision expected_skill_revision)
          | None -> Error "browser package Skill is absent")
       | Not_registered|Uninitialized -> Error "workspace Skill catalog is unavailable"));
    let invoke ?upload_paths tool fields =
      let tool_name=match tool with
        | Browser_capabilities.Tabs -> "BrowserTabs" | Read -> "BrowserRead"
        | Interact -> "BrowserInteract" | Act -> "BrowserAct" | Session -> "BrowserSession"
        | Goto -> "BrowserGoto" | Instruct -> "BrowserInstruct" in
      let result=Browser_addon_tools.handle ?upload_paths ~config ~access ~principal ~reserved:[]
        ~keeper_name:(Some "gecko-transfer-probe") ~tool ~tool_name
        ~start_time:(Tool_timing.start ()) (`Assoc (("lane",`String "automation")::fields)) in
      receipts:=Tool_result.to_json result::!receipts;flush ();result in
    let data (result:Tool_result.result) = match result with
      | Tool_result.Completed output -> Ok output.data
      | Deferred _ -> Error "browser transfer was deferred"
      | Failed failure -> Error failure.message in
    let call tool fields = invoke tool fields |> data in
    ignore (record "attach and open an owned Gecko session"
      (call Browser_capabilities.Session ["action",`String "open";"headless",`Bool true]));
    ignore (record "owned session has its download event connection"
      (let* status=call Browser_capabilities.Session ["action",`String "status"] in
       witness "session" status;
       check "owned download connection is not ready"
         (Yojson.Safe.Util.member "open" status=`Bool true && string "downloads" status=Some "ready")));
    ignore (record "navigate the owned session to the controlled fixture"
      (call Browser_capabilities.Goto ["url",`String fixture_url]));
    let tab=record "the controlled fixture has one observed tab identity"
      (let* listed=call Browser_capabilities.Tabs [] in
       match Yojson.Safe.Util.member "tabs" listed with
       | `List [row] when string "url" row=Some fixture_url ->
         (match Yojson.Safe.Util.member "id" row with `Int id -> Ok id | _ -> Error "tab has no ID")
       | _ -> Error ("unexpected fixture inventory: " ^ Yojson.Safe.to_string listed)) in
    witness "tab_id" (`Int tab);
    let target=["tabId",`Int tab] in
    let read mode=call Browser_capabilities.Read (target @ ["mode",`String mode]) in
    let title expected=await (fun () -> match read "text" with
      | Error detail -> Some (Error detail)
      | Ok value when string "title" value=Some expected -> Some (Ok value)
      | Ok _ -> None) in
    let act fields=call Browser_capabilities.Act (target @ fields) in
    let located=record "real Gecko locate uses the selected host Exact Output route"
      (call Browser_capabilities.Instruct (target @ ["action",`String "observe";
        "instruction",`String "Find the Download binary link"])) in
    witness "locate" located;
    ignore (record "locate returns the model-selected observed identity and browser geometry"
      (match !selected,field "matches" located with
       | Some (scene,node),Some (`List [matched]) ->
         let open Yojson.Safe.Util in
         let reference=member "target" matched and observation=member "observation" matched in
         check "locate result lost its observed document, node, text, geometry or inference"
           (string "documentId" located=string "documentId" scene
            && string "documentId" reference=string "documentId" scene
            && string "nodeId" reference=string "nodeId" node
            && string "nodeId" observation=string "nodeId" node
            && string "text" observation=Some "Download binary"
            && string "href" observation=Some (fixture_url ^ "download")
            && (match field "rects" observation with Some (`List (_::_)) -> true | None|Some _ -> false)
            && string "description" (member "inference" matched)=Some "The observed binary download link")
       | (None|Some _),(None|Some _) -> Error "locate has no single model-selected observation"));
    ignore (record "locate performs one model request and no upload or download"
      (let* page=read "text" in
       check "read-only locate changed the fixture or replayed a model request"
         (F.post_count provider=1 && string "title" page=Some "Gecko transfer fixture"
          && not (Sys.file_exists (Filename.concat !output "upload.json"))
          && not (Sys.file_exists (Filename.concat !output "download.json")))));
    ignore (record "an arbitrary host path is refused before file selection"
      (match invoke ~upload_paths:[payload] Browser_capabilities.Act
        (target @ ["action",`String "upload";"selector",`String "#file";
          "paths",`List [`String payload]]) with
       | Tool_result.Failed {effect_disposition=Proven_pre_effect;_} -> Ok `Null
       | Failed {effect_disposition=Proven_post_effect|Effect_outcome_unknown;_}
       | Completed _|Deferred _ -> Error "unregistered host path was not a pre-effect refusal"));
    ignore (record "refused upload leaves the file-selection fixture unchanged"
      (let* page=read "text" in
       check "refused host path changed the file input"
         (string "title" page=Some "Gecko transfer fixture")));
    let host_paths=ref [] in
    ignore (record "the registered host snapshot selects the file once"
      (let* result=B.Upload_lease.with_staged_files
        ~files:[Filename.basename payload,(fun () -> Ok expected)] (fun paths ->
          host_paths:=paths;
          invoke ~upload_paths:paths Browser_capabilities.Act
            (target @ ["action",`String "upload";"selector",`String "#file";
              "paths",`List (List.map (fun path -> `String path) paths)]))
        |> Result.map_error (function B.Upload_lease.Read_failed message|Snapshot_failed message -> message) in
       data result));
    ignore (record "host snapshot scope is released before the page reads the file"
      (check "host snapshot escaped its scope" (!host_paths<>[] && List.for_all (fun path -> not (Sys.file_exists path)) !host_paths)));
    ignore (record "the actual file input has the selected file" (title "file selected"));
    ignore (record "a later native click submits the retained worker copy"
      (let* _=act ["action",`String "click";"selector",`String "#submit"] in title "upload confirmed"));
    ignore (record "loopback receiver obtained the exact binary payload once"
      (let received=Filename.concat !output "uploaded.bin"
       and receipt=Yojson.Safe.from_file (Filename.concat !output "upload.json") in
       check "uploaded bytes, original basename or request count differ"
         (In_channel.with_open_bin received In_channel.input_all=expected
          && string "filename" receipt=Some (Filename.basename payload)
          && Yojson.Safe.Util.member "count" receipt=`Int 1)));
    let screenshot=record "the Keeper-scoped screenshot is published through the public tool"
      (read "screenshot") in
    witness "screenshot" screenshot;
    let image=record "the original Keeper can load the hash-verified PNG"
      (let* handle=string "artifact" screenshot |> Option.to_result ~none:"screenshot has no handle" in
       let* bytes=Keeper_vision_tool.load_artifact
         ~dir:(Keeper_vision_tool.vision_store_dir ~base_path ~keeper_name:"gecko-transfer-probe" ())
         (Multimodal.Vision_artifact_store.of_string handle)
         |> Result.map_error Multimodal.Vision_artifact_store.load_error_to_string in
       let* _=check "screenshot has no positive pixel dimensions"
         (match Keeper_image_dimensions.image_dimensions bytes with
          | Some (width,height) -> width>0 && height>0 | None -> false) in
       write (Filename.concat !output "gecko-transfer.png") bytes;Ok bytes) in
    ignore (record "a native click starts the actual binary download"
      (act ["action",`String "click";"selector",`String "#download"]));
    let download=record "BiDi completion is exported as a durable scoped artifact"
      (await (fun () -> match read "downloads" with
       | Error message -> Some (Error message)
       | Ok value -> match Yojson.Safe.Util.member "downloads" value with
         | `List [] -> None
         | `List [row] when string "url" row=Some (fixture_url ^ "download") ->
           (match string "status" row with
            | Some "pending" -> None
            | Some "completed" ->
              witness "download" row;
              Some (match field "artifactError" row with
                | Some reason -> Error ("download artifact publication refused: " ^ Yojson.Safe.to_string reason)
                | None ->
                  let* artifact=field "artifact" row |> Option.to_result ~none:"completed download has no artifact" in
                  let* claim=Browser_addon_downloads.claim_of_json
                    (`Assoc ["kind",`String "published";"receipt",artifact]) in
                  match claim with
                  | Published _ -> Ok row
                  | Snapshot _ -> Error "completed download returned a private snapshot")
            | Some _|None -> Some (Error ("download did not complete: " ^ Yojson.Safe.to_string row)))
         | _ -> Some (Error ("unexpected downloads: " ^ Yojson.Safe.to_string value)))) in
    let artifact=Yojson.Safe.Util.member "artifact" download in
    witness "download" download;
    let digest=record "download receipt names a host artifact without a worker path"
      (let* arguments=field "arguments" artifact |> Option.to_result ~none:"download has no artifact arguments" in
       let* digest=string "sha256" arguments |> Option.to_result ~none:"download has no artifact digest" in
       let* _=check "download leaked its worker path or omitted the artifact reader"
         (Yojson.Safe.Util.member "path" download=`Null && string "reader" artifact=Some "keeper_artifact_read") in
       Ok digest) in
    let retained ()=let* bytes=Tool_blob_store.fetch (Tool_blob_store.create ~base_path) ~sha256:digest
        |> Result.map_error Tool_blob_store.fetch_error_to_string in
      check "durable downloaded bytes differ from the fixture" (bytes=Some expected) in
    ignore (record "durable artifact restores the original binary bytes" (retained ()));
    let host=require (Browser_addon_host.connect ~config ~access ~principal ~reserved:[]
      |> Result.map_error (function R.Unavailable s|Outcome_unknown s -> s | Host_refusal _ -> "host refused fixture authority")) in
    ignore (record "detach confirms the original worker and owned session cleanup"
      (let* _=R.dispatch ~caller:"gecko-transfer-probe" ~access ~config ~operation:R.Detach
        (`Assoc ["instance_id",`String service.instance_id]) |> Result.map_error R.error_to_string in
       await (fun () -> match List.find_opt (fun (item:R.inventory_instance) -> item.instance_id=service.instance_id)
         (R.inventory ~config).instances with
         | Some {phase=Lane_addon_types.Detached;presence=Retained;_} -> Some (Ok `Null)
         | Some {phase=Failed detail;_} -> Some (Error detail)
         | None|Some {phase=Detached;presence=Live;_}|Some {phase=Attached|Observing|Detaching;_} -> None)));
    ignore (record "the retired transfer host is no longer callable"
      (match Browser_addon_host.issue host ~preference:(Browser_selection.Exact B.Automation_route) B.Tabs_list with
       | Error _ -> Ok `Null | Ok _ -> Error "retired transfer host remained callable"));
    ignore (record "published download survives confirmed worker cleanup" (retained ()));
    ignore (record "the original screenshot survives worker cleanup in its Keeper scope"
      (let* handle=string "artifact" screenshot |> Option.to_result ~none:"missing screenshot handle" in
       let* bytes=Keeper_vision_tool.load_artifact
         ~dir:(Keeper_vision_tool.vision_store_dir ~base_path ~keeper_name:"gecko-transfer-probe" ())
         (Multimodal.Vision_artifact_store.of_string handle)
         |> Result.map_error Multimodal.Vision_artifact_store.load_error_to_string in
       check "screenshot changed across retirement" (bytes=image))))
