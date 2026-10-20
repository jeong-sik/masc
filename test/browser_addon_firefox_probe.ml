(* Real Firefox on an isolated profile through the installed browser Addon.
   The Python harness serves only loopback fixtures. No standalone BiDi host,
   alternate browser session or arbitrary evaluation is used by this probe. *)
open Masc
module R = Lane_addon_runtime
module Lease = Native_addon_lease
let ( let* ) = Result.bind
let require = function Ok x -> x | Error s -> failwith s
let argument flag =
  let rec find = function
    | key::value::_ when key=flag -> value
    | _::rest -> find rest
    | [] -> invalid_arg ("missing " ^ flag) in
  find (Array.to_list Sys.argv)
let write path text = Out_channel.with_open_bin path (fun ch -> output_string ch text)
let string key value = Yojson.Safe.Util.(value |> member key |> to_string_option)
let bool message value = if value then Ok `Null else Error message
let steps = ref []
let receipts = ref []
let witnesses = ref []
let output = ref ""
let flush () = write (Filename.concat !output "firefox-addon-proof.json")
  (Yojson.Safe.pretty_to_string (`Assoc [
    "steps",`List (List.rev !steps);"receipts",`List (List.rev !receipts);
    "witnesses",`Assoc (List.rev !witnesses);
    "model_outputs",`List [];"tool_hooks",`List [`String "validate_input";`String "validate_output"]]))
let record name result =
  let passed=Result.is_ok result in
  steps:=`Assoc ["step",`String name;"ok",`Bool passed;
    "error",(match result with Ok _ -> `Null | Error s -> `String s)]::!steps;
  flush ();Printf.printf "%s %s\n%!" (if passed then "ok" else "FAIL") name;
  require result
let witness name value = witnesses:=(name,value)::!witnesses;flush ()
let () =
  let firefox=Unix.realpath (argument "--firefox")
  and manifest=Unix.realpath (argument "--manifest")
  and fixture_url=argument "--fixture-url" in
  output:=Unix.realpath (argument "--out");flush ();
  let base_path=Filename.temp_dir ~perms:0o700 "browser-addon-firefox-proof-" "" |> Unix.realpath in
  write (Filename.concat !output "workspace.txt") base_path;
  let config_root=Filename.concat base_path ".masc/config" in Fs_compat.mkdir_p config_root;
  Unix.putenv Env_config_core.base_path_env_key base_path;
  Unix.putenv Env_config_core.config_dir_env_key config_root;
  let bin=Filename.concat base_path "bin" in Unix.mkdir bin 0o700;
  List.iter (fun (flag,name) -> Unix.symlink (Unix.realpath (argument flag)) (Filename.concat bin name))
    ["--launcher","masc-native-addon-launcher";"--guardian","masc-browser-process-owner";
     "--worker","masc-browser-addon-worker"];
  Unix.putenv "PATH" (bin ^ ":" ^ Option.value ~default:"" (Sys.getenv_opt "PATH"));
  let profile=Filename.concat base_path "firefox-profile" in Unix.mkdir profile 0o700;
  let sentinel=Filename.concat profile "operator-sentinel" in write sentinel "preserve-profile";
  let port =
    let socket=Unix.socket ~cloexec:true Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect ~finally:(fun () -> Unix.close socket) (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback,0));
      match Unix.getsockname socket with Unix.ADDR_INET (_,port) -> port
      | Unix.ADDR_UNIX _ -> failwith "expected loopback port") in
  Unix.mkdir (Filename.concat base_path "fixture-skills") 0o700;
  let runtime_path=Filename.concat config_root "runtime.toml" in
  write runtime_path (Exact_output_fixture.official_client_runtime_fixture ^ Printf.sprintf
    "\n[skills]\n[[skills.sources]]\nid=\"probe-local\"\nanchor=\"base-path\"\npath=\"fixture-skills\"\naccess=\"read-only\"\n[browser.automation]\nenabled=false\n[browser.stagehand]\nenabled=false\n[browser.live]\nenabled=true\n[browser.live.bidi]\nfirefox=%S\nprofile=%S\nport=%d\n"
    firefox profile port);
  require (Runtime.init_default ~config_path:runtime_path);
  Mirage_crypto_rng_unix.use_default ();
  Eio_main.run @@ fun env ->
  let clock=Eio.Stdenv.clock env and net=Eio.Stdenv.net env in
  Time_compat.set_clock clock;Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~sw ~clock ~net ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
    let config=Workspace.default_config base_path in
    let access=Lane_addon_sources.Operator_configuration in
    let principal=Lane_addon_call_context.Host_actor "firefox-addon-probe" in
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
    let attach () =
      write declaration (Printf.sprintf
        "id=\"browser\"\nrun_id=\"firefox-probe\"\nmanifest_path=%S\nexact_outputs=[]\ntool_hooks=[\"validate_input\",\"validate_output\"]\n[binding]\nsources=[]\n" manifest);
      let report=require (R.reconcile_configuration ~config ~directory) in
      let open Yojson.Safe.Util in
      if member "complete" report<>`Bool true || member "issues" report<>`List [] then
        failwith ("declaration refused: " ^ Yojson.Safe.to_string report);
      await (fun () ->
        List.iter (fun (item:R.inventory_instance) -> match item.phase with
          | Lane_addon_types.Failed s -> failwith s | Attached|Observing|Detaching|Detached -> ())
          (R.inventory ~config).instances;
        match R.browser_services ~config ~access with
        | [service] -> Some service | [] -> None
        | _::_::_ -> failwith "ambiguous browser installations") in
    let detach instance_id =
      let* _=R.dispatch ~caller:"firefox-addon-probe" ~access ~config ~operation:R.Detach
        (`Assoc ["instance_id",`String instance_id]) |> Result.map_error R.error_to_string in
      await (fun () ->
        match List.find_opt (fun (i:R.inventory_instance) -> i.instance_id=instance_id)
          (R.inventory ~config).instances with
        | Some {phase=Lane_addon_types.Detached;presence=R.Retained;_} -> Some (Ok `Null)
        | Some {phase=Failed s;_} -> Some (Error s)
        | None | Some {phase=Detached;presence=Live;_}
        | Some {phase=Attached|Observing|Detaching;_} -> None) in
    let first=attach () in
    ignore (record "attach starts the installed browser Addon" (Ok (`String first.instance_id)));
    ignore (record "the real catalog publishes the browser package Skill"
      (let* catalog=Server_skill_snapshot_runtime.lookup ~base_path
         |> Result.map_error Server_skill_snapshot_runtime.error_to_string in
       match catalog with
       | Server_skill_snapshot_runtime.Ready {snapshot;_} ->
         (match Skill_catalog_snapshot.find_effective_by_name snapshot "browser" with
          | Some entry -> bool "catalog Skill came from another source"
              (entry.directory=Filename.concat (Filename.dirname manifest) "skills/browser")
          | None -> Error "browser package Skill is absent")
       | Not_registered|Uninitialized -> Error "workspace Skill catalog is unavailable"));
    let host=require (Browser_addon_host.connect ~config ~access ~principal ~reserved:[]
      |> Result.map_error (function R.Unavailable s|Outcome_unknown s -> s
        | Host_refusal _ -> "probe principal refused")) in
    let client host =
      let* snapshot=Browser_addon_host.snapshot host |> Result.map_error (function
        Browser_addon_client.Unavailable s|Outcome_unknown s -> s) in
      match Yojson.Safe.Util.member "clients" snapshot with
      | `List [row] when string "transport" row=Some "webdriver_bidi" ->
        Option.to_result ~none:"missing BiDi clientId" (string "clientId" row)
      | _ -> Error ("expected one owned BiDi connection: " ^ Yojson.Safe.to_string snapshot) in
    let first_client=record "one owned Firefox BiDi connection is published" (client host) in
    witness "original" (`Assoc ["instance_id",`String first.instance_id;
      "client_id",`String first_client]);
    (* Inspect the original host reservation, never a PID or a page-supplied path.
       Shared profile slots intentionally survive sessions; the child slot is
       the authoritative retirement/settlement record for this allocation. *)
    let claim ()=Eio_unix.run_in_systhread (fun () ->
      let* shared=Lease.current ~directories:[Filename.concat profile ".masc-firefox-profile-claim"]
        |> Result.map_error Lease.error_to_string in
      let* saved=Lease.cleanup_context shared |> Result.map_error Lease.error_to_string in
      let* allocation=Option.bind saved (string "directory")
        |> Option.to_result ~none:"profile claim has no original allocation" in
      let* content=Fs_compat.load_owned_regular_file ~ownership_root:allocation
        (Filename.concat allocation "live-bidi.json")
        |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
      let* text=Option.to_result ~none:"missing original live configuration" content in
      let* descriptor=Browser_addon_live_bidi.configuration_of_json (Yojson.Safe.from_string text) in
      let* child=Browser_addon_live_bidi.configuration_to_json descriptor |> string "claim_directory"
        |> Option.to_result ~none:"missing original child claim" in
      Lease.current ~directories:[child] |> Result.map_error Lease.error_to_string) |> require in
    let original=claim () in
    witness "original_native_claim" (`String (Lease.instance_id original));
    let stable_lease=Filename.concat (Filename.concat profile ".masc-firefox-profile-claim") "lease" in
    let stable_stat=Unix.lstat stable_lease in
    let settled claim=Eio_unix.run_in_systhread (fun () ->
      let* status=Lease.status claim |> Result.map_error Lease.error_to_string in
      bool "original foreground owner is not settled" (status=Lease.Settled)) in
    ignore (record "Firefox holds its original native child lease"
      (Eio_unix.run_in_systhread (fun () ->
        let* status=Lease.status original |> Result.map_error Lease.error_to_string in
        bool "profile owner is not live" (match status with Lease.Live _ -> true
          | Awaiting_exec|Cleanup_pending _|Settled -> false))));
    let tool_name = function
      | Browser_capabilities.Tabs -> "BrowserTabs" | Read -> "BrowserRead"
      | Interact -> "BrowserInteract" | Act -> "BrowserAct" | Session -> "BrowserSession"
      | Goto -> "BrowserGoto" | Instruct -> "BrowserInstruct" in
    let call_result tool fields =
      let result=Browser_addon_tools.handle ~config ~access ~principal ~reserved:[] ~keeper_name:None
        ~tool ~tool_name:(tool_name tool)
        ~start_time:(Tool_timing.start ()) (`Assoc fields) in
      receipts:=Tool_result.to_json result::!receipts;flush ();result in
    let data_result (result:Tool_result.result) = match result with
      | Tool_result.Completed output -> Ok output.data
      | Deferred _ -> Error "browser call was deferred instead of completed"
      | Failed failure -> Error failure.message in
    let call tool fields = call_result tool fields |> data_result in
    let connection id=["lane",`String "live";"clientId",`String id] in
    let open_tab id url=call Browser_capabilities.Act
      (connection id @ ["action",`String "open_tab";"url",`String url]) in
    let tab_id data=match Yojson.Safe.Util.member "tabId" data with
      | `Int id -> Ok id | _ -> Error "created tab has no tabId" in
    let open_id client url=let* data=open_tab client url in tab_id data in
    ignore (record "isolated login is stored in the owned profile"
      (let* id=open_id first_client (fixture_url ^ "login") in
       let* data=call Browser_capabilities.Read (connection first_client @
         ["tabId",`Int id;"mode",`String "text"]) in
       bool "fixture cookie was not stored" (string "title" data=Some "signed in")));
    let tab=record "new tab is created on the same owned connection"
      (open_id first_client fixture_url) in
    let target=connection first_client @ ["tabId",`Int tab] in
    let read mode=call Browser_capabilities.Read (target @ ["mode",`String mode]) in
    let interact fields=call Browser_capabilities.Interact
      (target @ ["expectedUrl",`String fixture_url] @ fields) in
    let title expected=let* data=read "text" in
      bool ("fixture title is not " ^ expected) (string "title" data=Some expected) in
    ignore (record "text observation keeps the original connection"
      (let* data=read "text" in bool "read lost connection identity" (string "clientId" data=Some first_client)));
    ignore (record "scene observation is available" (read "scene"));
    let reaction_selector=record "hover reveals its control"
      (let* _=interact ["action",`String "hover";"selector",`String "#message"] in
       let* data=read "elements" in
       let controls=match Yojson.Safe.Util.member "elements" data with
         | `List rows -> List.filter (fun row -> string "tag" row=Some "button"
             && string "text" row=Some "Trusted reaction"
             && Yojson.Safe.Util.member "disabled" row=`Bool false) rows
         | _ -> [] in
       match controls with
       | [row] -> (match string "selector" row with Some selector when selector<>"" -> Ok selector
           | Some _|None -> Error "hover control has no observed selector")
       | []|_::_::_ -> Error "hover control is absent or ambiguous") in
    ignore (record "native semantic click reaches the hover control"
      (let* _=interact ["action",`String "click";"selector",`String reaction_selector] in title "trusted reaction"));
    ignore (record "native double click reaches the fixture"
      (let* _=interact ["action",`String "double_click";"selector",`String "#double"] in title "trusted double click"));
    ignore (record "native pointer-capture drag reaches its destination"
      (let* _=interact ["action",`String "drag_to";
        "source",`Assoc ["selector",`String "#source"];
        "destination",`Assoc ["selector",`String "#destination"]] in title "trusted pointer drag"));
    ignore (record "screenshot is captured by the retained Addon host"
      (let started=Mtime_clock.elapsed_ns () in
       let* receipt=Browser_addon_host.issue host
        ~preference:(Browser_selection.Exact (Browser_lane.Live_route
          (Some (require (Browser_lane.client_id_of_string first_client)))))
        (Browser_lane.Page_capture {tab_id=tab}) |> Result.map_error Tool_result.message in
       let* data=Browser_surface.capture_from ~binding:receipt.binding ~tab_id:tab ~started receipt.data
         |> Result.map_error Browser_surface.failure_message in
       let* encoded=Option.to_result ~none:"capture has no PNG" (string "data" data) in
       let* bytes=Base64.decode encoded |> Result.map_error (fun (`Msg message) -> message) in
       let* width,height=match Keeper_image_dimensions.image_dimensions bytes with
         | Some (width,height) when width>0 && height>0 -> Ok (width,height)
         | Some _ | None -> Error "capture has no positive PNG dimensions" in
       witness "screenshot" (`Assoc ["width",`Int width;"height",`Int height;
         "bytes",`Int (String.length bytes);"tab_id",`Int tab]);
       write (Filename.concat !output "firefox-addon.png") bytes;Ok `Null));
    let hold_path=Filename.concat !output "hold-requested.json"
    and release_path=Filename.concat !output "release-hold" in
    let pending=Eio.Fiber.fork_promise ~sw (fun () -> call_result Browser_capabilities.Act
      (connection first_client @ ["action",`String "open_tab";"url",`String (fixture_url ^ "hold")])) in
    await (fun () ->
      if Sys.file_exists hold_path then Some () else
      match Eio.Promise.peek pending with
      | None -> None
      | Some (Error exn) -> raise exn
      | Some (Ok (Tool_result.Failed failure)) ->
        failwith ("held navigation failed before fixture arrival: " ^ failure.message)
      | Some (Ok (Tool_result.Completed _ | Tool_result.Deferred _)) ->
        failwith "held navigation unexpectedly completed before fixture arrival");
    Fun.protect ~finally:(fun () -> write release_path "release") (fun () ->
      ignore (record "in-flight detach confirms owned cleanup" (detach first.instance_id)));
    ignore (record "interrupted creation retains its effect uncertainty"
      (match Eio.Promise.await_exn pending with
       | Tool_result.Failed {effect_disposition=Effect_outcome_unknown;_} -> Ok `Null
       | Failed {effect_disposition=Proven_post_effect;_} as result ->
         let* _=tab_id (Tool_result.data result) in Ok `Null
       | Failed {effect_disposition=Proven_pre_effect;_} ->
         Error "navigation reached the fixture but was reported as pre-effect"
       | Completed _ | Deferred _ -> Error "interrupted tab creation reported completion or deferral"));
    ignore (record "the original profile lease confirms process settlement" (settled original));
    let replacement=attach () in
    ignore (record "reattach creates a fresh worker incarnation"
      (bool "worker incarnation was reused" (replacement.instance_id<>first.instance_id)));
    let host2=require (Browser_addon_host.connect ~config ~access ~principal ~reserved:[]
      |> Result.map_error (function R.Unavailable s|Outcome_unknown s -> s | Host_refusal _ -> "principal refused")) in
    let next_client=record "replacement publishes a fresh connection" (client host2) in
    witness "replacement" (`Assoc ["instance_id",`String replacement.instance_id;
      "client_id",`String next_client]);
    ignore (record "stale host cannot reach the available replacement"
      (match Browser_addon_host.issue host ~preference:Browser_selection.Automatic Browser_lane.Tabs_list with
       | Error _ -> Ok `Null | Ok _ -> Error "retired host reached the replacement"));
    ignore (record "client identity is not reused" (bool "BiDi client ID reused" (next_client<>first_client)));
    ignore (record "old client is refused on the replacement worker"
      (match open_tab first_client (fixture_url ^ "must-not-open") with
       | Error _ -> Ok `Null | Ok _ -> Error "old client opened a tab on its replacement"));
    ignore (record "persistent cookie survives full worker reattachment"
      (let* id=open_id next_client (fixture_url ^ "session") in
       let* data=call Browser_capabilities.Read (connection next_client @ ["tabId",`Int id;"mode",`String "text"]) in
       bool "login cookie did not survive reattachment" (string "title" data=Some "signed in")));
    let next_claim=claim () in
    witness "replacement_native_claim" (`String (Lease.instance_id next_claim));
    ignore (record "replacement has a fresh native claim"
      (bool "native claim reused" (Lease.instance_id next_claim<>Lease.instance_id original)));
    ignore (record "detach confirms replacement cleanup" (detach replacement.instance_id));
    ignore (record "replacement process is settled" (settled next_claim));
    ignore (record "profile contents and stable lease inodes remain"
      (let after=Unix.lstat stable_lease in
       bool "profile contents or stable lease inode changed"
         (In_channel.with_open_bin sentinel In_channel.input_all="preserve-profile"
          && after.st_dev=stable_stat.st_dev && after.st_ino=stable_stat.st_ino)));
    ignore (record "held navigation was sent once without replay"
      (let observed=Yojson.Safe.from_file hold_path in
       bool "held navigation was replayed" (Yojson.Safe.Util.member "count" observed=`Int 1))))
