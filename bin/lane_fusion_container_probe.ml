(** Docker qualification, with synthetic HTTP model replies. This executable
    never installs a replacement Lane backend, control transport, or sampling
    callback. Its only provider fixture is an actual loopback HTTP server. *)
open Masc
module R = Lane_addon_runtime
module T = Lane_addon_types
module S = Mcp_protocol.Sampling
module Store = Lane_addon_store

let require = function Ok value -> value | Error detail -> failwith detail
let ensure condition detail = if not condition then failwith detail
let member = Yojson.Safe.Util.member
let text key value = member key value |> Yojson.Safe.Util.to_string
let list key value = member key value |> Yojson.Safe.Util.to_list
let write path bytes = Out_channel.with_open_bin path (fun out -> output_string out bytes)
let json_file path value = write path (Yojson.Safe.pretty_to_string value ^ "\n")
let rec remove_tree path = match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> Unix.unlink path
let dispatch ?caller config operation fields =
  R.dispatch ?caller ~access:Lane_addon_sources.Operator_configuration
    ~config ~operation (`Assoc fields)
  |> Result.map_error R.error_to_string |> require
let inspect config = dispatch config R.Inspect []
let phase value = member "phase" value |> T.phase_of_json |> require
let installation snapshot name = list "instances" snapshot |> List.find_opt (fun value ->
  match member "configuration" value with
  | `Assoc fields -> List.assoc_opt "id" fields=Some (`String name)
  | _ -> false)
let owned_instances snapshot = list "instances" snapshot |> List.map (text "instance_id")
let package root id = Lane_addon_manifest.load ~path:(Filename.concat root ("addons/" ^ id ^ "/lane.toml"))
  |> Result.map_error Lane_addon_manifest.error_to_string |> require
let model_value row = List.assoc_opt "computation" row.T.fields
let answered row = match model_value row with
  | Some (`Assoc fields) -> (match List.assoc_opt "status" fields with
      | Some (`String "answered") -> true
      | Some (`String ("host_error" | "outcome_unknown" | "invalid_response")) -> false
      | Some _ | None -> failwith "invalid computation status in retained output")
  | Some _ | None -> false

type provider = Panel_a | Panel_b | Judge
let installation_id = function Panel_a -> "panel-a" | Panel_b -> "panel-b" | Judge -> "judge"
let actual_model = function Panel_a -> "synthetic-panel-a-model" | Panel_b -> "synthetic-panel-b-model" | Judge -> "synthetic-judge-model"
let answer_text = function
  | Panel_a -> "Synthetic panel A measured comparison."
  | Panel_b -> "Synthetic panel B independent objection."
  | Judge -> "Synthetic Judge synthesis retains both panel A and panel B."
let limit = function Panel_a | Panel_b -> 37 | Judge -> 51

let run ~repo_root ~output_dir ~head_sha =
  Fs_compat.mkdir_p output_dir;
  let last_snapshot = ref `Null and cleanup_receipt = ref `Null in
  let http_receipts = ref [] and container_receipts = ref [] in
  let summary = ref [] in
  let root = Filename.temp_dir "masc-fusion-container-" "" |> Unix.realpath in
  let scope = ["scope",`String "real_docker_real_host_sampling_synthetic_http";
    "head_sha",`String head_sha; "production",`Bool false; "live_provider",`Bool false;
    "live_keeper_use",`String "not_proven"] in
  let record status error = json_file (Filename.concat output_dir "summary.json")
    (`Assoc (scope @ ["status",`String status;"error",error;
      "last_runtime_snapshot",!last_snapshot;"containers",`List (List.rev !container_receipts);
      "http_requests",`List (List.rev !http_receipts);"cleanup",!cleanup_receipt] @ !summary)) in
  try Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.base_path_env_key (Some root) (fun () ->
    Masc_test_deps.with_process_env Env_config_core.config_dir_env_key None (fun () ->
    Eio_main.run (fun env ->
      Fs_compat.set_fs env#fs;
      let old_context = Eio_context.snapshot_state () in
      let old_runtime = Runtime.For_testing.snapshot () in
      let old_startup = Runtime_startup_state.get () in
      let old_catalog = Llm_provider.Model_catalog.global () in
      Fun.protect ~finally:(fun () ->
        Eio_context.restore_state old_context;
        Runtime.For_testing.restore old_runtime;
        Runtime_startup_state.set old_startup;
        match old_catalog with None -> Llm_provider.Model_catalog.clear_global ()
          | Some catalog -> Llm_provider.Model_catalog.set_global catalog) (fun () ->
      (* Probe controls include prerequisite and release-time Docker calls, so
         they need their own qualification deadline outside the scenario bound.
         The process switch kills and reaps an interrupted CLI child; draining
         both pipes concurrently avoids an inspect/error-output pipe deadlock. *)
      let control_timeout_s = 30. in
      let command arguments =
        match Eio.Time.with_timeout env#clock control_timeout_s (fun () ->
          Eio.Switch.run (fun control_sw ->
            let stdout_r,stdout_w = Eio.Process.pipe ~sw:control_sw env#process_mgr in
            let stderr_r,stderr_w = Eio.Process.pipe ~sw:control_sw env#process_mgr in
            let child = Eio.Process.spawn ~sw:control_sw env#process_mgr
              ~stdin:(Eio.Flow.string_source "") ~stdout:stdout_w ~stderr:stderr_w arguments in
            Eio.Flow.close stdout_w; Eio.Flow.close stderr_w;
            let read flow = Eio.Buf_read.(of_flow ~max_size:4194304 flow |> take_all) in
            let stdout,stderr = Eio.Fiber.pair (fun () -> read stdout_r) (fun () -> read stderr_r) in
            match Eio.Process.await child with
            | `Exited 0 -> stdout
            | `Exited code -> failwith (Printf.sprintf "qualification control %s exited %d: %s"
                (List.hd arguments) code (String.trim stderr))
            | `Signaled signal -> failwith (Printf.sprintf "qualification control %s received signal %d: %s"
                (List.hd arguments) signal (String.trim stderr)))) with
        | Ok stdout -> stdout
        | Error `Timeout -> failwith (Printf.sprintf "qualification control %s timed out after %.0f seconds"
            (List.hd arguments) control_timeout_s) in
      let docker args = command ("docker" :: args) in
      let daemon () = let version = String.trim (docker ["info";"--format";"{{.ServerVersion}}"])
        in ensure (version<>"") "Docker daemon did not return a server version"; version in
      let images = [package repo_root "fusion-compute";package repo_root "fusion-report"] in
      let image_records = List.map (fun (package : T.package) ->
        let value = Yojson.Safe.from_string (docker ["image";"inspect";package.image])
          |> Yojson.Safe.Util.to_list |> List.hd in
        package.image, value) images in
      let daemon_version = daemon () in
      let compiled_sha = match Build_commit_generated.commit with Some sha -> sha
        | None -> failwith "probe binary has no embedded build commit" in
      ensure (compiled_sha=head_sha) "probe binary build commit differs from requested qualification head";
      let mounted_sha = command ["git";"-C";repo_root;"rev-parse";"HEAD"] |> String.trim in
      ensure (mounted_sha=head_sha) "mounted package checkout differs from the qualification head";
      ignore (command ["git";"-C";repo_root;"diff";"--exit-code";"HEAD";"--"]);
      let untracked = command ["git";"-C";repo_root;"ls-files";"--others";"--exclude-standard";"--";"addons"] in
      ensure (String.trim untracked="") "untracked package source files prevent exact-head qualification";
      summary := ["embedded_head_sha",`String compiled_sha;"mounted_head_sha",`String mounted_sha;
        "qualification_control_timeout_s",`Float control_timeout_s;
        "docker_server_version",`String daemon_version];
      let config = Workspace.default_config root in
      ignore (Workspace.init config ~agent_name:(Some "container-probe-operator"));
      let directory = R.configuration_directory config in
      Fs_compat.mkdir_p directory;
      let store = Store.create ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
      let tracked = ref [] and store_removed = ref false in
      let snapshot () = let value = inspect config in last_snapshot := value;
        tracked := List.sort_uniq String.compare (owned_instances value @ !tracked); value in
      let names_for id = docker ["container";"ls";"--all";"--no-trunc";
        "--filter";"label=masc.lane.instance=" ^ id;"--format";"{{.ID}}"]
        |> String.split_on_char '\n' |> List.filter (fun id -> id<>"") in
      let owned_container id container =
        let data = docker ["container";"inspect";container] |> Yojson.Safe.from_string
          |> Yojson.Safe.Util.to_list |> List.hd in
        ensure (text "Id" data=container) "Docker cleanup identity changed";
        ensure (text "Name" data="/masc-lane-" ^ Store.digest id) "Docker cleanup name is not owned by this worker";
        ensure ((member "Config" data |> member "Labels" |> text "masc.lane.instance") = id)
          "Docker cleanup label does not identify the exact worker";
        data in
      let cleanup () =
        let daemon_version = daemon () in
        if not !store_removed then ignore (snapshot ());
        let removed = List.concat_map (fun id ->
          List.map (fun container ->
            ignore (owned_container id container);
            ignore (docker ["container";"rm";"--force";"--volumes";container]);
            `Assoc ["instance_id",`String id;"container_id",`String container]) (names_for id)) !tracked in
        ignore (daemon ());
        List.iter (fun id -> ensure (names_for id=[])
          ("owned container remains after cleanup: " ^ id)) !tracked;
        cleanup_receipt := `Assoc ["verified",`Bool true;"daemon_version",`String daemon_version;
          "owned_instance_ids",`List (List.map (fun id -> `String id) !tracked);
          "fallback_removed",`List removed;"remaining_owned_containers",`Int 0] in
      try
        Eio.Switch.run (fun sw ->
          Eio_context.set_env (env :> Eio_unix.Stdenv.base);
          Eio_context.set_net env#net; Eio_context.set_clock env#clock;
          Eio_context.set_mono_clock env#mono_clock; Eio_context.set_switch sw;
          Time_compat.set_clock env#clock;
          (* Registered first: worker release hooks run before this final exact
             ownership check. A failed start is covered by the same check. *)
          Eio.Switch.on_release sw (fun () ->
            try cleanup () with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> cleanup_receipt := `Assoc ["verified",`Bool false;
                "error",`String (Printexc.to_string exn)]; raise exn);
          (* Qualification-only bound: a broken barrier or daemon must produce
             failed evidence, rather than leave the CI qualification running.
             This is not a Keeper or provider runtime budget. *)
          Eio.Time.with_timeout_exn env#clock 180. (fun () ->
          let seen_a = ref false and seen_b = ref false and released = ref false in
          let barrier, release = Eio.Promise.create () in
          let retained_requests () = Eio_unix.run_in_systhread (fun () ->
            let path = Filename.concat (Store.root store) "evidence" in
            if not (Sys.file_exists path) then [] else Sys.readdir path |> Array.to_list
              |> List.filter_map (fun file ->
                let bytes = In_channel.with_open_bin (Filename.concat path file) In_channel.input_all in
                let value = Yojson.Safe.from_string bytes in
                if member "kind" value=`String "model_request" then Some value else None)) in
          let callback provider _connection _request body =
            let body = Eio.Buf_read.(of_flow ~max_size:4194304 body |> take_all) |> Yojson.Safe.from_string in
            let messages = list "messages" body in
            let prompt = text "content" (List.nth messages 1) in
            let payload = Yojson.Safe.from_string prompt in
            ensure (text "analysis_id" payload="container-analysis") "provider received another analysis";
            ensure (Yojson.Safe.Util.to_int (member "max_tokens" body)=limit provider) "provider output limit was not serialized";
            ensure (Yojson.Safe.Util.to_float (member "temperature" body)=0.25) "provider temperature was not serialized";
            let name = installation_id provider in
            let current = snapshot () in
            let worker = installation current name |> Option.get in
            let worker_id = text "instance_id" worker in
            let captures = retained_requests () |> List.filter (fun value -> text "instance_id" value=worker_id) in
            let capture = List.find (fun value ->
              let params = member "params" value |> S.create_message_params_of_yojson |> require in
              match params.messages with
              | [{content=S.Text {text;_};_}] -> text=prompt
              | _ -> false) captures in
            let params = member "params" capture |> S.create_message_params_of_yojson |> require in
            ensure (params.max_tokens=limit provider) "durable request lost the requested provider output limit";
            ensure (params.temperature=Some 0.25) "durable request lost sampling temperature";
            let system = match params.system_prompt with Some system -> system
              | None -> failwith "durable model request has no system instructions" in
            ensure (text "role" (List.hd messages)="system"
              && text "content" (List.hd messages)=system) "HTTP request lost retained system instructions";
            ensure (text "task" payload="Compare the retained inputs") "HTTP request changed the installed task";
            ensure (text "route" capture=name) "durable model request lost its exact host route";
            http_receipts := `Assoc ["installation_id",`String name;"instance_id",`String worker_id;
              "request_retained_before_http",`Bool true;"request",body;
              "retained_request",capture;
              "actual_response_model",`String (actual_model provider)] :: !http_receipts;
            (match provider with
             | Panel_a -> ensure (not !seen_a) "panel A was sampled twice"; seen_a := true
             | Panel_b -> ensure (not !seen_b) "panel B was sampled twice"; seen_b := true
             | Judge ->
                 ensure !released "Judge ran before both panel HTTP calls crossed the barrier";
                 let inputs = list "untrusted_inputs" payload in
                 ensure (List.length inputs=2) "Judge did not receive two independent panel ports";
                 List.iter (fun panel ->
                   let input = List.find (fun value -> text "source_id" value=installation_id panel) inputs in
                   let observation = list "observations" input |> List.hd in
                   let producer = member "producer" observation in
                   ensure (text "installation_id" producer=installation_id panel) "Judge producer installation changed";
                   let actual = installation current (installation_id panel) |> Option.get |> text "instance_id" in
                   ensure (text "instance_id" producer=actual) "Judge producer incarnation changed";
                   let output = member "output" observation |> list "rows" |> List.hd |> member "fields" in
                   ensure ((member "computation" output |> text "text")=answer_text panel) "Judge lost the original panel answer";
                   ensure ((member "computation" output |> text "model")=actual_model panel) "Judge lost the actual panel model") [Panel_a;Panel_b]);
            if !seen_a && !seen_b && not !released then (released := true; Eio.Promise.resolve release ());
            (match provider with Panel_a | Panel_b -> Eio.Promise.await barrier | Judge -> ());
            let response = `Assoc ["id",`String ("http-" ^ name);"model",`String (actual_model provider);
              "choices",`List [`Assoc ["index",`Int 0;"message",`Assoc ["role",`String "assistant";
                "content",`String (answer_text provider)];"finish_reason",`String "stop"]]] in
            Cohttp_eio.Server.respond_string ~status:`OK ~body:(Yojson.Safe.to_string response) () in
          let listen provider =
            let socket = Eio.Net.listen env#net ~sw ~backlog:4 ~reuse_addr:true
              (`Tcp (Eio.Net.Ipaddr.V4.loopback,0)) in
            let port = match Eio.Net.listening_addr socket with `Tcp (_,port) -> port
              | `Unix _ -> failwith "provider fixture did not bind loopback TCP" in
            let server = Cohttp_eio.Server.make ~callback:(callback provider) () in
            Eio.Fiber.fork_daemon ~sw (fun () -> Cohttp_eio.Server.run socket server ~on_error:raise);
            port in
          let providers = [Panel_a;Panel_b;Judge] |> List.map (fun provider -> provider,listen provider) in
          let catalog_path = Filename.concat root "catalog.toml" in
          write catalog_path (String.concat "\n" (List.map (fun (provider,_) -> Printf.sprintf
            "[[models]]\nid_prefix=\"container-fixture\"\nprovider_name=%S\nbase=\"openai_chat\"\nmax_context_tokens=200000\nmax_output_tokens=256\nchat_output_budget_field=\"max_tokens\"\nsupports_tools=false\nsupports_system_prompt=true\nsupports_reasoning=false\nsupports_native_streaming=false\nignored_sampling_parameters=[]\n"
            (installation_id provider)) providers));
          Llm_provider.Model_catalog.load_file catalog_path |> require |> Llm_provider.Model_catalog.set_global;
          let runtime_path = Filename.concat root "runtime.toml" in
          let runtime = "[runtime]\ndefault=\"panel-a.sample\"\n"
            ^ String.concat "\n" (List.map (fun (provider,port) -> let name = installation_id provider in
                Printf.sprintf "[runtime.lanes.%s]\ncandidates=[%S]\n[providers.%s]\nprotocol=\"openai-compatible-http\"\nendpoint=\"http://127.0.0.1:%d\"\n"
                  name (name ^ ".sample") name port) providers)
            ^ "\n[models.sample]\napi-name=\"container-fixture\"\nmax-context=200000\ntools-support=false\nstreaming=false\n"
            ^ String.concat "\n" (List.map (fun (provider,_) -> "[" ^ installation_id provider ^ ".sample]\n") providers) in
          write runtime_path runtime;
          require (Runtime.init_default ~config_path:runtime_path);
          Server_lane_addon_sampling.register ~config ~net:env#net;
          (* Use the server's actual roster capture and transcript projection.
             This isolated workspace has no registered Keepers: the local
             Broadcast settles at commit without starting a retry service that
             would outlive the deliberate Lane-store removal below. *)
          ensure (Keeper_registry.all ~base_path:root () = [])
            "local Broadcast qualification requires an empty Keeper registry";
          Server_bootstrap_loops.register_lane_fleet_backend ();
          let source_path = Filename.concat root "shared-input.json" in
          json_file source_path (`Assoc ["source_id",`String "project";"incarnation",`String "shared-1";
            "cursor",`String "snapshot-1";"complete",`Bool true;"detail",`Null;
            "observations",`List [`Assoc ["id",`String "task-1";"kind",`String "research_input";
              "observed_at",`Float 100.;"actor",`Null;"evidence",`List [];
              "text",`String "Synthetic shared alternatives A and B"]]]);
          let declare name manifest binding =
            let path = Filename.concat directory (name ^ ".toml") in
            write path (Printf.sprintf "id=%S\nrun_id=\"container-analysis\"\nmanifest_path=%S\n[binding]\n%s\n"
              name (Filename.concat repo_root ("addons/" ^ manifest ^ "/lane.toml")) binding); path in
          let compute role name sources = Printf.sprintf
            "analysis_id=\"container-analysis\"\nrole=%S\nprompt=\"Compare the retained inputs\"\ninstructions=%S\nmax_tokens=%d\ntemperature=0.25\nmodel_route=%S\nsources=%s"
            role ("Qualification " ^ name ^ "; preserve the original evidence")
            (if role="judge" then 51 else 37) name sources in
          let edge source installation output = Printf.sprintf
            "{source_id=%S,kind=\"lane_output\",installation_id=%S,output_id=%S,selection=\"latest_completed\"}"
            source installation output in
          let paths = [
            declare "panel-a" "fusion-compute" (compute "panel" "panel-a" (Printf.sprintf "[{source_id=\"project\",kind=\"snapshot_file\",path=%S}]" source_path));
            declare "panel-b" "fusion-compute" (compute "panel" "panel-b" (Printf.sprintf "[{source_id=\"project\",kind=\"snapshot_file\",path=%S}]" source_path));
            declare "judge" "fusion-compute" (compute "judge" "judge" ("[" ^ edge "panel-a" "panel-a" "result" ^ "," ^ edge "panel-b" "panel-b" "result" ^ "]"));
            declare "report" "fusion-report" ("sources=[" ^ edge "judge" "judge" "result" ^ "]")] in
          ignore (require (R.reconcile_configuration ~config ~directory));
          let await f = let rec loop () = match f (snapshot ()) with
            | Some value -> value | None -> Eio.Time.sleep env#clock 0.02; loop () in loop () in
          let row = await (fun current ->
            match installation current "report" with
            | None -> None
            | Some instance ->
                let output = T.output_of_json (`Assoc ["rows",member "rows" current;"coverage",member "coverage" current]) |> require in
                List.find_opt (fun row -> row.T.lane_id=text "instance_id" instance ^ "/fusion/report"
                  && answered row && List.assoc_opt "input_complete" row.fields=Some (`Bool true)) output.rows) in
          ensure !released "two panel HTTP calls did not overlap at the barrier";
          ensure (List.length !http_receipts=3) "qualification expected two panel calls and one Judge call";
          let report_fields = `Assoc row.fields in
          ensure ((member "computation" report_fields |> text "role")="judge") "report is not the Judge result";
          ensure ((member "computation" report_fields |> text "model")=actual_model Judge) "report lost the responding Judge model";
          ensure (String_util.contains_substring (text "body" report_fields) (answer_text Judge)) "report lost the Judge free text";
          let current = snapshot () in
          ensure (List.length !tracked=4) "qualification did not create exactly four installed workers";
          List.iter (fun instance ->
            let id = text "instance_id" instance in
            let container = text "container_id" instance in
            let data = owned_container id container in
            let package_id = text "addon_id" instance in
            let package = List.find (fun (package : T.package) -> package.id=package_id) images in
            let image = List.assoc package.image image_records in
            let host = member "HostConfig" data and container_config = member "Config" data in
            ensure (text "NetworkMode" host="none") "container has network access";
            ensure (member "ReadonlyRootfs" host=`Bool true) "container root is writable";
            ensure (List.mem (`String "ALL") (list "CapDrop" host)) "container did not drop all capabilities";
            ensure (List.exists (function `String ("no-new-privileges" | "no-new-privileges:true") -> true | _ -> false)
              (list "SecurityOpt" host)) "container permits privilege escalation";
            ensure (text "User" container_config="65534:65534") "container is not the declared unprivileged image user";
            ensure (member "Env" container_config=(member "Config" image |> member "Env")) "host environment was injected into the worker";
            ensure (text "Image" data=text "Id" image) "container image differs from the qualified built image";
            let protocol_bytes = In_channel.with_open_bin (Filename.concat repo_root "addons/protocol.py") In_channel.input_all in
            let protocol_sha = docker ["container";"exec";container;"python3";"-c";
              "import hashlib; print(hashlib.sha256(open('/protocol.py','rb').read()).hexdigest())"] |> String.trim in
            ensure (protocol_sha=Store.digest protocol_bytes) "image MCP protocol bytes differ from the clean exact-head checkout";
            let int64 key = match member key host with
              | `Int value -> Int64.of_int value | `Intlit value -> Int64.of_string value
              | _ -> failwith ("Docker resource field is not an integer: " ^ key) in
            ensure (int64 "NanoCpus"=Int64.of_float (Float.round (package.resources.cpus *. 1_000_000_000.))) "Docker CPU limit differs from the installed package";
            ensure (int64 "Memory"=package.resources.memory_bytes
              && int64 "MemorySwap"=package.resources.memory_bytes
              && int64 "PidsLimit"=Int64.of_int package.resources.pids) "Docker memory or PID limits differ from the installed package";
            (match list "Mounts" data with
             | [mount] -> ensure (member "RW" mount=`Bool false
                 && text "Destination" mount="/addon" && text "Source" mount=package.directory)
                 "Docker package mount is not the exact declared read-only directory"
             | [] | _ :: _ :: _ -> failwith "Docker container has undeclared mounts");
            let keys = list "Env" container_config |> List.map (fun value ->
              Yojson.Safe.Util.to_string value |> String.split_on_char '=' |> List.hd) in
            container_receipts := `Assoc ["instance_id",`String id;"container_id",`String container;
              "installation_id",member "configuration" instance |> member "id";
              "image",`String package.image;"image_id",member "Image" data;
              "protocol_sha256",`String protocol_sha;
              "network",`String "none";"readonly_rootfs",`Bool true;"cap_drop",member "CapDrop" host;
              "security_options",member "SecurityOpt" host;"user",member "User" container_config;
              "nano_cpus",member "NanoCpus" host;"memory",member "Memory" host;
              "memory_swap",member "MemorySwap" host;"pids_limit",member "PidsLimit" host;
              "environment_keys",`List (List.map (fun key -> `String key) keys);
              "environment_matches_image",`Bool true;"mounts",member "Mounts" data] :: !container_receipts)
            (list "instances" current);
          let current_rows = T.output_of_json (`Assoc ["rows",member "rows" current;"coverage",member "coverage" current]) |> require in
          let model_refs = List.concat_map (fun provider ->
            let id = installation current (installation_id provider) |> Option.get |> text "instance_id" in
            let model_row = List.find (fun row -> row.T.lane_id=id ^ "/fusion/computation" && answered row) current_rows.rows in
            let refs = `Assoc model_row.fields |> member "model_evidence" in
            List.map (fun kind ->
              let reference = member kind refs |> T.evidence_of_json |> require in
              let bytes = Store.read_blob store reference |> require in
              let record = Yojson.Safe.from_string bytes in
              ensure (text "kind" record="model_" ^ kind) "model evidence has a different kind";
              ensure (text "instance_id" record=id) "model evidence belongs to another worker";
              if kind="outcome" then ensure (text "status" record="answered"
                && (member "response" record |> text "model")=actual_model provider) "model outcome lost the actual provider response";
              installation_id provider ^ "/" ^ kind,reference,bytes) ["request";"outcome"]) [Panel_a;Panel_b;Judge] in
          let snapshot_bytes = In_channel.with_open_bin source_path In_channel.input_all in
          let snapshot_sha = Store.digest snapshot_bytes in
          let snapshot_ref = List.concat_map (fun row -> row.T.evidence) current_rows.rows
            |> List.find (fun (reference : T.evidence) -> reference.sha256=Some snapshot_sha) in
          ensure ((Store.read_blob store snapshot_ref |> require) = snapshot_bytes) "shared snapshot evidence lost original source bytes";
          let required_evidence = ("shared_snapshot",snapshot_ref,snapshot_bytes) :: model_refs in
          let report_id = installation current "report" |> Option.get |> text "instance_id" in
          let selected = ["instance_id",`String report_id;"row_ids",`List [`String row.id]] in
          let frozen = dispatch config R.Evidence selected in
          let broadcast_request_id = "container-report:" ^ row.id in
          let published = dispatch ~caller:"container-probe-operator" config R.Evidence
            (selected @ ["broadcast",`Bool true;"request_id",`String broadcast_request_id]) in
          let delivery = member "delivery" published in
          ensure (text "destination" delivery="broadcast" && text "status" delivery="committed") "local Broadcast did not commit";
          let receipt = member "receipt" delivery in
          let broadcast_id = text "request_id" receipt in
          let sequence = member "seq" receipt |> Yojson.Safe.Util.to_int in
          let message = Workspace.get_all_messages_raw config ~since_seq:0
            |> List.find (fun (message : Masc_domain.message) -> message.request_id=broadcast_id) in
          ensure (message.seq=sequence && message.from_agent="container-probe-operator") "Broadcast receipt differs from its durable local row";
          let artifact = match Tool_output.decode_from_agent_core message.content with
            | Tool_output.Decoded artifact -> artifact
            | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> failwith "local Broadcast has no Keeper artifact reference" in
          let read sha =
            let buffer = Buffer.create 4096 in
            let rec pages offset =
              let _, page = Keeper_artifact_read.handle_with_page ~base_path:root
                ~args:(`Assoc ["sha256",`String sha;"offset",`Int offset]) in
              match page with
              | Some page when page.encoding=Keeper_artifact_read.Utf_8 ->
                  Buffer.add_string buffer page.content;
                  if not page.eof then (ensure (page.next_offset>offset) "Keeper artifact pagination stalled"; pages page.next_offset)
              | Some _ | None -> failwith "Keeper artifact reader did not return retained UTF-8 bytes" in
            pages 0; Buffer.contents buffer in
          let manifest = read artifact.sha256 in
          let artifacts = match Tool_output.artifact_manifest_of_json (Yojson.Safe.from_string manifest) with
            | Tool_output.Decoded_artifact_manifest {structured_content;_} -> list "artifacts" structured_content
            | Tool_output.Not_artifact_manifest | Tool_output.Invalid_artifact_manifest _ -> failwith "published report artifact manifest is invalid" in
          let retained = List.map (fun value ->
            let reference = member "artifact" value |> Tool_output.normalized_artifact_ref_of_json in
            match reference with
            | Tool_output.Decoded_normalized_artifact_ref reference -> text "lane_uri" value,reference.sha256,read reference.sha256
            | Tool_output.Not_normalized_artifact_ref | Tool_output.Invalid_normalized_artifact_ref _ -> failwith "published evidence has an invalid artifact reference") artifacts in
          ensure (List.exists (fun (_,_,bytes) ->
            let record = Yojson.Safe.from_string bytes in
            match member "output" record with
            | `Assoc fields -> (match List.assoc_opt "rows" fields with
                | Some (`List rows) -> List.mem (T.row_to_json row) rows
                | Some _ | None -> false)
            | _ -> false) retained) "published evidence does not contain the exact selected report row";
          List.iter (fun (label,(reference : T.evidence),expected) ->
            let _,_,bytes = List.find (fun (uri,_,_) -> uri=reference.uri) retained in
            ensure (bytes=expected) ("published artifact lost required evidence: " ^ label)) required_evidence;
          List.iter Sys.remove paths;
          ignore (require (R.reconcile_configuration ~config ~directory));
          ignore (await (fun current -> if List.for_all (fun value ->
            match phase value with T.Detached -> true | T.Attached | T.Observing | T.Detaching | T.Failed _ -> false)
            (list "instances" current) then Some () else None));
          cleanup ();
          ensure (List.length !http_receipts=3)
            "an unchanged completed input triggered an additional model call before detach";
          Fs_compat.remove_tree (Store.root store);
          store_removed := true;
          List.iter (fun (_,sha,bytes) -> ensure (read sha=bytes) "Keeper artifact bytes changed after worker detach and Lane-store removal") retained;
          List.iter (fun (label,(reference : T.evidence),expected) ->
            let _,sha,_ = List.find (fun (uri,_,_) -> uri=reference.uri) retained in
            ensure (read sha=expected) ("Keeper cannot read ancestral evidence after store removal: " ^ label)) required_evidence;
          let evidence_receipts = List.map (fun (label,(reference : T.evidence),bytes) ->
            let _,sha,_ = List.find (fun (uri,_,_) -> uri=reference.uri) retained in
            `Assoc ["label",`String label;"lane_reference",T.evidence_to_json reference;
              "keeper_artifact_sha256",`String sha;"byte_length",`Int (String.length bytes);
              "byte_sha256",`String (Store.digest bytes);
              "read_after_detach_and_lane_store_removal",`Bool true]) required_evidence in
          Fs_compat.mkdir_p (Filename.concat output_dir "artifacts");
          List.iter (fun (_,sha,bytes) -> write (Filename.concat output_dir ("artifacts/" ^ sha ^ ".json")) bytes) retained;
          write (Filename.concat output_dir "keeper-artifact-manifest.json") manifest;
          json_file (Filename.concat output_dir "report-row.json") (T.row_to_json row);
          json_file (Filename.concat output_dir "preserved-evidence.json") frozen;
          json_file (Filename.concat output_dir "broadcast-receipt.json") published;
          summary := !summary @ ["panel_http_barrier",`String "both calls arrived before either response released";
            "startup",`String "all_four_workers_in_one_reconciliation";
            "horizontal_worker_instances",`Int 2;"judge_named_input_ports",`Int 2;
            "report_row_id",`String row.id;"local_broadcast_request_id",`String broadcast_id;
            "model_request_outcome_pairs_read_after_detach",`Int 3;
            "required_evidence",`List evidence_receipts;
            "shared_snapshot_read_after_detach",`Bool true;
            "local_broadcast_sequence",`Int sequence;"keeper_artifact_read_after_detach",`Bool true;
            "qualification_timeout_s",`Int 180]));
        ensure (member "verified" !cleanup_receipt=`Bool true) "container cleanup has no successful absence evidence";
        record "passed" `Null
      with
      | Eio.Cancel.Cancelled _ as exn -> record "failed" (`String (Printexc.to_string exn)); raise exn
      | exn -> record "failed" (`String (Printexc.to_string exn)); raise exn)))))
  with
  | Eio.Cancel.Cancelled _ as exn -> record "failed" (`String (Printexc.to_string exn)); raise exn
  | exn -> record "failed" (`String (Printexc.to_string exn)); raise exn

let () =
  let repo_root = ref "" and output_dir = ref "" and head_sha = ref "" in
  Arg.parse ["--repo-root",Arg.Set_string repo_root,"Source checkout whose package images are qualified";
    "--output-dir",Arg.Set_string output_dir,"Qualification evidence directory";
    "--head-sha",Arg.Set_string head_sha,"Exact source and embedded binary commit"]
    (fun argument -> raise (Arg.Bad ("unexpected argument: " ^ argument))) "lane_fusion_container_probe";
  ensure (!repo_root<>"" && !output_dir<>"" && String.length !head_sha=40)
    "--repo-root, --output-dir and a full --head-sha are required";
  run ~repo_root:(Unix.realpath !repo_root) ~output_dir:!output_dir ~head_sha:!head_sha
