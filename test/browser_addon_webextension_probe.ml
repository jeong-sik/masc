(* Actual external Firefox extension/native messaging/HTTP ingress. The Python
   driver owns browser setup and cleanup; every content operation below uses
   the installed browser Addon. No transport implementation is replaced. *)
open Masc
module R = Lane_addon_runtime
module B = Browser_lane
module Http = Http_server_eio
let ( let* ) = Result.bind
let require = function Ok value -> value | Error detail -> failwith detail
let argument flag =
  let rec find = function
    | key::value::_ when key=flag -> value
    | _::rest -> find rest
    | [] -> invalid_arg ("missing " ^ flag) in
  find (Array.to_list Sys.argv)
let write path value =
  let pending=path ^ ".pending" in
  Out_channel.with_open_bin pending (fun ch -> output_string ch value);
  Unix.rename pending path
let field key (value:Yojson.Safe.t) = match value with
  | `Assoc fields -> List.assoc_opt key fields
  | `Null|`Bool _|`Int _|`Intlit _|`Float _|`String _|`List _ -> None
let string key value = match field key value with Some (`String text) -> Some text | None|Some _ -> None
let output=ref "" and steps=ref [] and receipts=ref [] and witnesses=ref []
let flush () = write (Filename.concat !output "webextension-addon-proof.json")
  (Yojson.Safe.pretty_to_string (`Assoc ["steps",`List (List.rev !steps);
    "receipts",`List (List.rev !receipts);"witnesses",`Assoc (List.rev !witnesses);
    "tool_hooks",`List [`String "validate_input";`String "validate_output"];
    "model_outputs",`List []]))
let witness key value = witnesses:=(key,value)::!witnesses;flush ()
let record name result =
  steps:=`Assoc ["step",`String name;"ok",`Bool (Result.is_ok result);
    "error",(match result with Ok _ -> `Null|Error detail -> `String detail)]::!steps;
  flush ();Printf.printf "%s %s\n%!" (if Result.is_ok result then "ok" else "FAIL") name;
  require result
let check detail value = if value then Ok `Null else Error detail
let fixture = {|<!doctype html><meta charset="utf-8"><title>External extension fixture</title>
<h1>External Firefox extension</h1><input id="name"><button id="send">Send once</button>
<p id="answer">Waiting for input</p><div style="height:2400px">Scrollable fixture</div>
<script>document.querySelector('#send').onclick=async()=>{
 const name=document.querySelector('#name').value;
 const reply=await fetch('/fixture-click',{method:'POST',body:name});
 document.querySelector('#answer').textContent=await reply.text();
 document.title='Extension click confirmed';
};</script>|}
let () =
  let manifest=Unix.realpath (argument "--manifest")
  and native_host=Unix.realpath (argument "--native-host") in
  output:=Unix.realpath (argument "--out");flush ();
  let base_path=Filename.temp_dir ~perms:0o700 "bext-" "" |> Unix.realpath in
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
  write runtime_path (Exact_output_fixture.official_client_runtime_fixture ^
    "\n[skills]\n[[skills.sources]]\nid=\"probe-local\"\nanchor=\"base-path\"\npath=\"fixture-skills\"\naccess=\"read-only\"\n[browser.live]\nenabled=true\n[browser.automation]\nenabled=false\n[browser.stagehand]\nenabled=false\n");
  require (Runtime.init_default ~config_path:runtime_path);
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
  Time_compat.set_clock clock;Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
    let config=Workspace.default_config base_path in
    let access=Lane_addon_sources.Operator_configuration
    and principal=Lane_addon_call_context.Keeper "webextension-probe" in
    let clicks=ref [] in
    let router=Http.Router.create ()
      |> Http.Router.get "/fixture" (fun _ reqd -> Http.Response.html fixture reqd)
      |> Http.Router.post "/fixture-click" (fun _ reqd -> Http.Request.read_body_async reqd (fun body ->
          clicks:=body::!clicks;Http.Response.text ("Received " ^ body) reqd))
      |> Server_routes_http_routes_browser_lane.add_routes ~config in
    let socket=Eio.Net.listen net ~sw ~backlog:8 ~reuse_addr:true (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
    let port=match Eio.Net.listening_addr socket with `Tcp (_,port) -> port
      | `Unix _ -> failwith "fixture listener is not TCP" in
    let serve flow address = Eio.Switch.run (fun conn_sw ->
      Httpun_eio.Server.create_connection_handler ~sw:conn_sw
        ~request_handler:(fun _ wrapped ->
          let reqd=wrapped.Gluten.Reqd.reqd in
          Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
        ~error_handler:(fun _ ?request:_ _ _ -> failwith "unexpected fixture HTTP error") address flow) in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      while true do Eio.Net.accept_fork ~sw socket ~on_error:raise serve done;`Stop_daemon);
    let fixture_url=Printf.sprintf "http://127.0.0.1:%d/fixture" port in
    let workspace_port=require (Workspace_connection.port port |> Result.map_error Workspace_connection.error_message) in
    require (Workspace_connection.save ~base_path ~port:workspace_port |> Result.map_error Workspace_connection.error_message);
    let native_root=Filename.concat base_path "native-lookup" in
    let slug=match Browser_lane_setup.current_platform () with
      | Some Macos -> "NativeMessagingHosts" | Some Linux -> "native-messaging-hosts"
      | None -> failwith "unsupported native messaging fixture platform" in
    let manifest_dir=Filename.concat native_root slug in Fs_compat.mkdir_p manifest_dir;
    let installed=record "install the actual matching native host and unchanged embedded extension"
      (Browser_lane_setup.install {base_path;binary=Some native_host;token_file=None;
        extension=Some {manifest_dir;host_name=Browser_lane_setup.Host_name.default}}
       |> Result.map_error Browser_lane_setup.error_message) in
    let extension=match installed.extension with Some extension -> extension
      | None -> failwith "installer did not publish the extension" in
    let rec await work=match work () with Some result -> result
      | None -> Eio.Time.sleep clock 0.01;await work in
    ignore (record "publish the isolated Skill configuration"
      (let* observation=Runtime.load_config_observation ~runtime_config_path:runtime_path () in
       let* publication=Server_skill_snapshot_runtime.refresh_from_observation ~base_path observation
         |> Result.map_error Server_skill_snapshot_runtime.error_to_string in
       match publication with Published _|Unchanged _ -> Ok `Null
       | Workspace_retired -> Error "fixture Skill workspace retired"));
    R.register_skill_export_handler Server_skill_snapshot_runtime.publish_lane_skills;
    R.start_configuration_service ~config ~sw ~clock;
    let directory=R.configuration_directory config in Fs_compat.mkdir_p directory;
    let declaration=Filename.concat directory "browser.toml" in
    let attach () =
      write declaration (Printf.sprintf
        "id=\"browser\"\nrun_id=\"webextension-probe\"\nmanifest_path=%S\nexact_outputs=[]\ntool_hooks=[\"validate_input\",\"validate_output\"]\n[binding]\nsources=[]\n" manifest);
      let report=require (R.reconcile_configuration ~config ~directory) in
      if field "complete" report<>Some (`Bool true) || field "issues" report<>Some (`List []) then
        failwith ("declaration refused: " ^ Yojson.Safe.to_string report);
      await (fun () ->
        List.iter (fun (item:R.inventory_instance) -> match item.phase with
          | Failed detail -> failwith detail | Attached|Observing|Detaching|Detached -> ()) (R.inventory ~config).instances;
        match R.browser_services ~config ~access with [service] -> Some service
        | [] -> None | _::_::_ -> failwith "ambiguous browser Addons") in
    let connect ()=Browser_addon_host.connect ~config ~access ~principal ~reserved:[]
      |> Result.map_error (function R.Unavailable detail|Outcome_unknown detail -> detail
        | Host_refusal _ -> "fixture principal refused") |> require in
    let client host=await (fun () ->
      let snapshot=require (Browser_addon_host.snapshot host |> Result.map_error (function
        Browser_addon_client.Unavailable detail|Outcome_unknown detail -> detail)) in
      match field "clients" snapshot with
      | Some (`List []) -> None
      | Some (`List [row]) when string "transport" row=Some "web_extension" ->
        Some (require (string "clientId" row |> Option.to_result ~none:"extension has no clientId"),row)
      | None|Some _ -> failwith ("unexpected extension clients: " ^ Yojson.Safe.to_string snapshot)) in
    let first=attach () in
    witness "first_instance" (`String first.instance_id);
    write (Filename.concat !output "setup.json") (Yojson.Safe.pretty_to_string (`Assoc [
      "base_path",`String base_path;"fixture_url",`String fixture_url;
      "native_root",`String native_root;"native_manifest",`String extension.native_manifest;
      "extension",`String extension.directory;"host",`String installed.host;
      "launcher",`String installed.launcher]));
    let host=connect () in
    let first_client,client_info=record "actual native messaging registers one external extension client" (Ok (client host)) in
    witness "original_client" client_info;
    let invoke client_id tool fields =
      let name=match tool with Browser_capabilities.Tabs -> "BrowserTabs" | Read -> "BrowserRead" | Interact -> "BrowserInteract"
        | Act -> "BrowserAct" | Session -> "BrowserSession" | Goto -> "BrowserGoto" | Instruct -> "BrowserInstruct" in
      let result=Browser_addon_tools.handle ~config ~access ~principal ~reserved:[]
        ~keeper_name:(Some "webextension-probe") ~tool ~tool_name:name ~start_time:(Tool_timing.start ())
        (`Assoc (["lane",`String "live";"clientId",`String client_id] @ fields)) in
      receipts:=Tool_result.to_json result::!receipts;flush ();result in
    let call client_id tool fields = match invoke client_id tool fields with
      | Tool_result.Completed result -> Ok result.data
      | Failed failure -> Error failure.message | Deferred _ -> Error "extension command deferred" in
    let tab=record "the public Addon observes the fixture tab identity"
      (let* listed=call first_client Browser_capabilities.Tabs [] in
       match field "tabs" listed with
       | Some (`List tabs) ->
         let* row=List.find_opt (fun row -> string "url" row=Some fixture_url) tabs
           |> Option.to_result ~none:"fixture tab is absent" in
         (match field "id" row with Some (`Int id) -> Ok id | None|Some _ -> Error "tab has no ID")
       | None|Some _ -> Error "extension did not return tab inventory") in
    let target=["tabId",`Int tab] in
    let read mode=call first_client Browser_capabilities.Read (target @ ["mode",`String mode]) in
    ignore (record "external extension reads the actual page through HTTP ingress" (read "text"));
    let scene=record "external extension publishes observed document and node identities" (read "scene") in
    witness "scene" scene;
    let nodes=match field "nodes" scene with Some (`List nodes) -> nodes | None|Some _ -> failwith "scene has no nodes" in
    let node tag text = List.find_opt (fun node -> string "tag" node=Some tag
      && (match text with None -> true | Some text -> string "text" node=Some text)) nodes
      |> Option.to_result ~none:("fixture scene omitted " ^ tag) |> require in
    let control action node fields =
      call first_client Browser_capabilities.Interact (target @ ["expectedUrl",`String fixture_url;
        "action",`String action;"documentId",Yojson.Safe.Util.member "documentId" scene;
        "nodeId",Yojson.Safe.Util.member "nodeId" node] @ fields) in
    ignore (record "fill targets an observed extension node" (control "fill" (node "input" None) ["text",`String "Addon"]));
    ignore (record "DOM click targets the observed extension button" (control "click" (node "button" (Some "Send once")) []));
    ignore (record "the loopback receiver witnesses exactly one click and actual filled value"
      (await (fun () -> match !clicks with [] -> None | ["Addon"] -> Some (Ok `Null)
        | _::_ -> Some (Error "extension click payload or count differs"))));
    ignore (record "public read observes the confirmed page change"
      (await (fun () -> match read "text" with
        | Ok page when string "title" page=Some "Extension click confirmed" -> Some (Ok page)
        | Ok _ -> None | Error detail -> Some (Error detail))));
    ignore (record "extension scroll keeps the explicit tab and URL binding"
      (call first_client Browser_capabilities.Interact (target @ ["expectedUrl",`String fixture_url;
        "action",`String "scroll";"x",`Int 0;"y",`Int 100])));
    ignore (record "extension uses the actual browser zoom API"
      (call first_client Browser_capabilities.Interact (target @ ["expectedUrl",`String fixture_url;
        "action",`String "set_zoom";"factor",`Float 0.8])));
    ignore (record "unsupported trusted hover is refused before effect"
      (match invoke first_client Browser_capabilities.Interact (target @ ["expectedUrl",`String fixture_url;
          "action",`String "hover";"selector",`String "#send"]) with
       | Tool_result.Failed {effect_disposition=Proven_pre_effect;_} -> Ok `Null
       | Failed {effect_disposition=Proven_post_effect|Effect_outcome_unknown;_}|Completed _|Deferred _ ->
         Error "extension claimed trusted hover or an input effect"));
    ignore (record "external extension publishes a Keeper-scoped screenshot"
      (let* screenshot=read "screenshot" in
       let* handle=string "artifact" screenshot |> Option.to_result ~none:"screenshot has no artifact" in
       let* bytes=Keeper_vision_tool.load_artifact
         ~dir:(Keeper_vision_tool.vision_store_dir ~base_path ~keeper_name:"webextension-probe" ())
         (Multimodal.Vision_artifact_store.of_string handle)
         |> Result.map_error Multimodal.Vision_artifact_store.load_error_to_string in
       write (Filename.concat !output "webextension.png") bytes;Ok screenshot));
    let detach instance_id =
      let* _=R.dispatch ~caller:"webextension-probe" ~access ~config ~operation:R.Detach
        (`Assoc ["instance_id",`String instance_id]) |> Result.map_error R.error_to_string in
      await (fun () -> match List.find_opt (fun (item:R.inventory_instance) -> item.instance_id=instance_id)
        (R.inventory ~config).instances with
        | Some {phase=Detached;presence=Retained;_} -> Some (Ok `Null)
        | Some {phase=Failed detail;_} -> Some (Error detail)
        | None|Some {phase=Detached;presence=Live;_}|Some {phase=Attached|Observing|Detaching;_} -> None) in
    ignore (record "detach confirms the original extension queue worker retired" (detach first.instance_id));
    write (Filename.concat !output "detached.json") "{}";
    let browser=await (fun () ->
      let path=Filename.concat !output "browser-still-alive.json" in
      if Sys.file_exists path then Some (Yojson.Safe.from_file path) else None) in
    ignore (record "the fixture-owned Firefox survives Addon detach"
      (check "external Firefox ended with its borrowed queue" (field "alive" browser=Some (`Bool true))));
    let replacement=record "reattach publishes a different worker" (Ok (attach ())) in
    ignore (record "replacement does not reuse the retired incarnation"
      (check "replacement reused instance" (replacement.instance_id<>first.instance_id)));
    let replacement_host=connect () in
    let next_client,next_info=record "the actual extension reconnects with a fresh native host identity" (Ok (client replacement_host)) in
    witness "replacement_client" next_info;
    ignore (record "replacement refuses the original native identity"
      (check "extension reused clientId" (next_client<>first_client)));
    ignore (record "the retired host handle cannot issue another browser request"
      (match Browser_addon_host.issue host ~preference:(Browser_selection.Exact (B.Live_route None)) B.Tabs_list with
       | Error _ -> Ok `Null | Ok _ -> Error "retired host remained callable"));
    ignore (record "old explicit client is refused by the replacement public tool"
      (match invoke first_client Browser_capabilities.Tabs [] with
       | Tool_result.Failed {effect_disposition=Proven_pre_effect;_} -> Ok `Null
       | Failed {effect_disposition=Proven_post_effect|Effect_outcome_unknown;_}|Completed _|Deferred _ ->
         Error "old client was accepted or claimed an effect"));
    ignore (record "fresh explicit client reads the same external tab after reattachment"
      (call next_client Browser_capabilities.Read (target @ ["mode",`String "text"])));
    ignore (record "detach and reattach did not replay the witnessed click"
      (check "click was replayed" (!clicks=["Addon"])));
    ignore (record "replacement worker cleanup is confirmed" (detach replacement.instance_id)))
