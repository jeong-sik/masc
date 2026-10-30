(* A provider process fixture, not a VM. Production CLI capture, durable
   identity storage, boot/adoption, shim framing and process boundaries are
   real; the provider independently renders inspect from received run argv. *)
open Alcotest
open Masc
module Turn = Keeper_turn_sandbox_runtime
module Microvm = Keeper_sandbox_microvm
module Backend = Keeper_microvm_backend
module Profile = Keeper_types_profile_sandbox

let write path content = Out_channel.with_open_bin path (fun output -> output_string output content)
let read path = In_channel.with_open_bin path In_channel.input_all
let json path = Yojson.Safe.from_string (read path)
let save_json path value = write path (Yojson.Safe.to_string value)
let append path value =
  let output = open_out_gen [Open_creat; Open_append; Open_text] 0o600 path in
  Fun.protect ~finally:(fun () -> close_out output)
    (fun () -> output_string output (Yojson.Safe.to_string value ^ "\n"))
let strings values = `List (List.map (fun value -> `String value) values)
let field key = function `Assoc fields -> List.assoc key fields | _ -> fail "expected object"
let text = function `String value -> value | _ -> fail "expected string"
let value = function Ok value -> value | Error detail -> fail detail
(* Snapshots are 0500. Moving one to another parent on Linux would require
   write permission to update its [..] entry; a sibling keeps it immutable. *)
let held_snapshot_path snapshot name = Filename.concat (Filename.dirname snapshot) name
let replace key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> fail "fixture replacement requires an object"

let foreign_guest row ~state =
  let config = field "configuration" row in
  let labels = field "labels" config
    |> replace Keeper_sandbox_runtime_setup.sandbox_base_path_hash_label_key
         (`String "ff1829ae702ebee4ebcf998baaf17734")
    |> replace Keeper_microvm_boot_plan.label_key (`String "different") in
  row
  |> replace "configuration" (replace "labels" labels config)
  |> replace "status" (`Assoc ["state", `String state])

let guest_with_labels row change =
  let config = field "configuration" row in
  let labels = change (field "labels" config) in
  replace "configuration" (replace "labels" labels config) row

let keeper = "guest-survival-fixture"
let backend = Backend.Apple_container
let network_mode = Profile.Network_none
let fixture_effect_stderr = "fixture-private-helper-stderr"

let image_digest = "sha256:" ^ String.make 64 'a'
let image_platform = `Assoc ["architecture", `String "arm64"; "os", `String "linux"]
let image_entrypoint root =
  let path = Filename.concat root "image-entrypoint" in
  if Sys.file_exists path then
    match json path with
    | `List values -> List.map text values
    | _ -> fail "fixture image entrypoint must be an argv array"
  else []

let image_inspect root reference =
  `List [`Assoc ["id", `String (String.make 64 'a');
    "configuration", `Assoc ["name", `String reference;
      "descriptor", `Assoc ["digest", `String image_digest]];
    "variants", `List [`Assoc ["platform", image_platform;
      "digest", `String ("sha256:" ^ String.make 64 'b');
      "config", `Assoc ["architecture", `String "arm64"; "os", `String "linux";
        "config", `Assoc ["Entrypoint", strings (image_entrypoint root);
                          "Cmd", strings ["/bin/bash"]]]]]]]

let inspect_from_run root arguments =
  let one = Hashtbl.create 16 and repeated = Hashtbl.create 8 in
  let add key v = Hashtbl.replace repeated key (v :: Option.value ~default:[] (Hashtbl.find_opt repeated key)) in
  let rec flags = function
    | ("-d" | "--read-only" | "--rm" | "--no-dns") as key :: rest -> Hashtbl.replace one key "true"; flags rest
    | ("--name" | "--user" | "--memory" | "--cpus" | "--workdir" | "--network" | "--dns" | "--entrypoint") as key :: v :: rest ->
      Hashtbl.replace one key v; flags rest
    | ("--label" | "--env" | "-e" | "-v" | "--volume" | "--tmpfs" | "--cap-drop" | "--cap-add") as key :: v :: rest ->
      add key v; flags rest
    | image :: command -> image, command
    | [] -> fail "provider did not receive an image"
  in
  let image, explicit_command = flags arguments in
  (* Apple's entrypoint option replaces the image entrypoint; the arguments
     after the image replace its Cmd. Without an override, use the image's
     entrypoint as the prefix. *)
  let command =
    match Hashtbl.find_opt one "--entrypoint" with
    | Some executable -> executable :: explicit_command
    | None -> image_entrypoint root @ explicit_command in
  let all key = Option.value ~default:[] (Hashtbl.find_opt repeated key) |> List.rev in
  let get key = Hashtbl.find one key in
  let mount kind source destination options = `Assoc
    ["type", kind; "source", `String source; "destination", `String destination; "options", strings options] in
  let host raw = match String.split_on_char ':' raw with
    | [source; destination; "ro"] -> mount (`Assoc ["virtiofs", `Assoc []]) source destination ["ro"]
    | [source; destination] -> mount (`Assoc ["virtiofs", `Assoc []]) source destination []
    | _ -> fail "provider received invalid host mount" in
  let volume raw = match String.split_on_char ':' raw with
    | [name; destination] -> mount (`Assoc ["volume", `Assoc ["name", `String name]])
        ("/provider/" ^ name ^ ".img") destination []
    | _ -> fail "provider received invalid volume" in
  let label raw = match String.index_opt raw '=' with
    | Some at -> String.sub raw 0 at, `String (String.sub raw (at + 1) (String.length raw - at - 1))
    | None -> fail "provider received invalid label" in
  let memory = value (Keeper_microvm_guest_size.memory_of_string (get "--memory")) in
  let name = get "--name" in
  let executable, args = match command with first :: rest -> first, rest | [] -> fail "provider got no command" in
  let memory_bytes = Int64.mul (Int64.of_int (Keeper_microvm_guest_size.memory_mib memory)) 1_048_576L in
  let mounts = List.map host (all "-v") @ List.map volume (all "--volume")
      @ List.map (fun destination -> mount (`Assoc ["tmpfs", `Assoc []]) "tmpfs" destination []) (all "--tmpfs") in
  `Assoc ["id", `String name; "status", `Assoc ["state", `String "running"];
    "configuration", `Assoc ["id", `String name;
      "image", `Assoc ["reference", `String image;
        "descriptor", `Assoc ["digest", `String image_digest]];
      "platform", image_platform;
      "resources", `Assoc ["cpus", `Int (int_of_string (get "--cpus")); "memoryInBytes", `Intlit (Int64.to_string memory_bytes)];
      "initProcess", `Assoc ["user", `Assoc ["raw", `Assoc ["userString", `String (get "--user")]];
        "workingDirectory", `String (get "--workdir"); "executable", `String executable;
        "arguments", strings args; "environment", strings ("PATH=/fixture/image/bin" :: all "--env")];
      "mounts", `List mounts; "readOnly", `Bool (Hashtbl.mem one "--read-only");
      "capDrop", strings (all "--cap-drop"); "capAdd", strings (all "--cap-add");
      "networks", `List (match Hashtbl.find_opt one "--network" with
        | Some "none" -> []
        | Some name -> [`Assoc ["network", `String name]]
        | None -> [`Assoc ["network", `String "default"]]); "labels", `Assoc (List.map label (all "--label"))]]

let read_exact fd length =
  let buffer = Bytes.create length in
  let rec loop offset = if offset < length then
      let count = Unix.read fd buffer offset (length - offset) in
      if count = 0 then fail "truncated actual shim frame" else loop (offset + count) in
  loop 0; Bytes.to_string buffer

(* The provider fixture models the guest's mount observation from the mounts
   its own run parser recorded. It can also simulate an absent mount or an
   incomplete observation without claiming either is a successful mount. *)
let fixture_work_mount_response ~root guest =
  let marker name = Sys.file_exists (Filename.concat root name) in
  if marker "work-mount-unverified" then ""
  else if marker "work-mount-absent" then "not_mounted\n"
  else
    let mounts = match field "configuration" guest |> field "mounts" with
      | `List mounts -> mounts
      | _ -> fail "fixture guest mounts are not an array" in
    let work_mounts = List.filter (fun mount ->
      field "destination" mount = `String Microvm.work_volume_guest_root) mounts in
    match work_mounts with
    | [] -> "not_mounted\n"
    | [mount] ->
      let expected = value (Microvm.work_volume_name ~keeper_name:keeper) in
      let volume_name = match field "type" mount with
        | `Assoc ["volume", `Assoc volume] ->
          (match List.assoc_opt "name" volume with
           | Some (`String name) -> Some name
           | Some _ | None -> None)
        | _ -> None in
      let volume_exists name =
        match Unix.lstat (Filename.concat root (name ^ ".img")) with
        | { Unix.st_kind = Unix.S_REG; _ } -> true
        | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ }
        | exception Unix.Unix_error _ -> false in
      (match volume_name with
       | Some name when name = expected && volume_exists name ->
         "mounted\n"
       | Some _ | None -> "")
    | _ :: _ :: _ -> fail "fixture has duplicate work mount destinations"

let provider root args =
  let file name = Filename.concat root name in
  append (file "calls") (strings args);
  let answer value = print_string (Yojson.Safe.to_string value); flush stdout in
  let guest_rows () = if Sys.file_exists (file "guest.json") then [json (file "guest.json")] else [] in
  let hold ~marker ~started ~released =
    if Sys.file_exists (file marker) then (
      Unix.unlink (file marker);
      write (file started) "";
      let deadline = Unix.gettimeofday () +. 10. in
      while not (Sys.file_exists (file released)) && Unix.gettimeofday () < deadline do
        Unix.sleepf 0.01
      done;
      if not (Sys.file_exists (file released)) then fail (marker ^ " timed out")) in
  match args with
  | "inspect" :: name :: _ ->
    if Sys.file_exists (file "inspect-fails-after-run") && guest_rows () <> [] then exit 1;
    (match guest_rows () with
     | [row] when field "id" row = `String name ->
       let output = if Sys.file_exists (file "inspect-override") then read (file "inspect-override")
         else Yojson.Safe.to_string (`List [row]) in
       hold ~marker:"hold-inspect" ~started:"inspect-held" ~released:"release-inspect";
       print_string output; flush stdout
     | [] | [_] -> exit 1 | _ -> fail "provider invalid rows")
  | ["list"; "--all"; "--format"; "json"] ->
    if Sys.file_exists (file "inventory-fails-after-run") && guest_rows () <> [] then exit 1;
    if Sys.file_exists (file "list-override") then print_string (read (file "list-override"))
    else if Sys.file_exists (file "helper-after-run") && guest_rows () <> [] then
      answer (`List (guest_rows () @
        [`Assoc ["id", `String (Microvm.work_volume_trim_name ~keeper_name:keeper)]]))
    else answer (`List (guest_rows ()))
  | "image" :: "inspect" :: reference :: _ ->
    if Sys.file_exists (file "image-inspect-fails") then exit 1;
    if Sys.file_exists (file "image-inspect-override") then print_string (read (file "image-inspect-override"))
    else answer (image_inspect root reference)
  | "volume" :: "inspect" :: name :: _ ->
    if Sys.file_exists (file (name ^ ".img")) then
      answer (`List [`Assoc ["configuration", `Assoc ["name", `String name;
        "format", `String "ext4"; "source", `String (file (name ^ ".img"))]]])
    else exit 1
  | ["volume"; "list"; "--format"; "json"] ->
    answer (`List (Sys.readdir root |> Array.to_list |> List.filter_map (fun leaf ->
      if Filename.check_suffix leaf ".img" then Some (`Assoc ["id", `String (Filename.chop_suffix leaf ".img")]) else None)))
  | ["volume"; "delete"; name] -> if Sys.file_exists (file (name ^ ".img")) then Unix.unlink (file (name ^ ".img"))
  | "volume" :: "create" :: rest ->
    let name = List.hd (List.rev rest) in
    let bytes = Bytes.make 2048 '\000' in
    Bytes.set_uint16_le bytes (1024 + 0x38) 0xEF53;
    Bytes.set_int32_le bytes (1024 + 0x100)
      (if Sys.file_exists (file "discard-absent") then 0l else 0x0400l);
    write (file (name ^ ".img")) (Bytes.to_string bytes)
  | "run" :: rest ->
    if not (List.mem "-d" rest) then fail "discard-set volume must never start a helper";
    save_json (file "guest.json") (inspect_from_run root rest)
  | "stop" :: _ ->
    if Sys.file_exists (file "replacement-keep-guest") then exit 19
  | "delete" :: rest ->
    if Sys.file_exists (file "replacement-keep-guest") then exit 19;
    (match guest_rows () with
     | [row] when List.mem (text (field "id" row)) rest -> Unix.unlink (file "guest.json")
     | [] | [_] -> () | _ -> fail "provider invalid rows")
  | "exec" :: rest ->
    let work_mount_probe = match guest_rows () with
      | [guest] ->
        let name = text (field "id" guest) in
        if "container" :: args = Microvm.work_volume_mounted_probe_argv_for backend ~container_name:name
        then Some guest else None
      | [] -> None
      | _ :: _ :: _ -> fail "provider invalid rows" in
    let build_scan = match guest_rows () with
      | [guest] ->
        let name = text (field "id" guest) in
        "container" :: args = Microvm.build_scan_argv_for backend ~container_name:name
          ~keeper_work_root:(Microvm.keeper_work_root ~keeper_name:keeper)
          ~uid:(Unix.getuid ()) ~gid:(Unix.getgid ())
      | [] -> false
      | _ :: _ :: _ -> fail "provider invalid rows" in
    (match work_mount_probe with
    | Some guest ->
      print_string (fixture_work_mount_response ~root guest);
      flush stdout
    | None -> if build_scan then (
      if Sys.file_exists (file "scan-fail-first") && not (Sys.file_exists (file "scan-failed")) then (
        write (file "scan-failed") ""; prerr_endline "fixture scan failure"; exit 13);
      if Sys.file_exists (file "scan-output") then print_string (read (file "scan-output"));
      flush stdout)
    else if List.mem "masc-build-mkdir" rest || List.mem "masc-build-link" rest then (
      if not (List.mem "-i" rest) then fail "build input was not attached";
      let input = In_channel.input_all stdin in
      let kind = if List.mem "masc-build-mkdir" rest then "mkdir" else "link" in
      append (file "build-inputs") (`Assoc [
        "kind", `String kind;
        "bytes", `Int (String.length input);
        "sha256", `String Agent_core_sha256.(digest_string input |> to_hex)]);
      List.iter (fun status ->
        if Sys.file_exists (file (Printf.sprintf "build-effect-status-%d-%s" status kind)) then (
          prerr_endline fixture_effect_stderr;
          exit status)) [127; 2];
      if kind = "mkdir" && Sys.file_exists (file "build-mkdir-fails") then exit 19)
    else if List.mem "--probe" rest then (
      print_string (Exec_ssh_protocol.render_probe {name="masc-exec-shim"; version="3.0.0"; capabilities=[]; release=None; boot_id=None});
      flush stdout)
    else if List.mem "masc-mount-probe" rest then (
      print_string "mounted\n";
      flush stdout)
    else if List.mem Microvm.shim_guest_path rest then (
      let header = read_exact Unix.stdin 8 in
      let length = Bytes.get_int64_be (Bytes.of_string header) 0 |> Int64.to_int in
      let request, _ = value (Exec_ssh_protocol.decode_request (header ^ read_exact Unix.stdin length)) in
      append (file "requests") (`Assoc ["argv", strings request.argv;
        "environment", `Assoc (List.map (fun (key,v) -> key, `String v) request.env)]);
      (match request.argv with
       | "python3" :: "-c" :: _ -> print_string "{\"entries\":[],\"checkouts\":[],\"limit\":null}"; flush stdout
       | _ -> ());
      let execution_receipt : Exec_ssh_protocol.execution_receipt = {mode=request.mode; boundary=Sandbox_applied} in
      output_string stderr (Exec_ssh_protocol.render_trailer ~execution_receipt
        {v=request.v; exit=Some 0; signal=None; timed_out=false; shim_error=None; observed_syscalls=[]});
      flush stderr))
  | _ -> fail ("unsupported provider command " ^ String.concat " " args)

let meta () =
  let meta = value (Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String keeper; "trace_id", `String "survival-process-fixture"])) in
  {meta with sandbox_profile=Profile.Micro_vm; microvm_backend=Some backend; network_mode}

(* Generate an actual shortened-name collision under this test-owned root. *)
let colliding_fixture_bases root =
  let seen = Hashtbl.create 131_071 in
  let rec find index =
    if index = 1_000_000 then fail "fixture could not find a workspace hash collision";
    let path = Filename.concat root ("authority-workspace-" ^ string_of_int index) in
    let hash = Digest.to_hex (Digest.string path) in
    let prefix = String.sub hash 0 8 in
    match Hashtbl.find_opt seen prefix with
    | Some first -> first, path
    | None -> Hashtbl.add seen prefix path; find (index + 1) in
  find 0

let process_step root operation =
  (* This provider fixture opens no network. Declare its resolver explicitly
     instead of inheriting a host-only systemd resolver in Linux CI. *)
  Unix.putenv "MASC_KEEPER_MICROVM_DNS" "192.0.2.53";
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Process_eio.init ~cwd_default:Eio.Path.(fs / root)
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let base, other_base =
    if operation = "authority-collision" then
      let first, second = colliding_fixture_bases root in first, Some second
    else root, None in
  Option.iter (fun other ->
    List.iter (fun base_path ->
      let shim = Config_dir_resolver.microvm_shim_dir ~base_path in
      Fs_compat.mkdir_p shim;
      let binary = Filename.concat shim Microvm.shim_binary_name in
      write binary "#!/bin/sh\nexit 0\n"; Unix.chmod binary 0o700) [base; other]) other_base;
  let config = Workspace.default_config base in
  value (Keeper_microvm_shim_readiness.initialize ~fs ~base_path:base ~payload_path:"/usr/bin:/bin"
    |> Result.map_error Keeper_microvm_shim_readiness.error_message);
  Option.iter (fun other ->
    value (Keeper_microvm_shim_readiness.initialize ~fs ~base_path:other ~payload_path:"/usr/bin:/bin"
      |> Result.map_error Keeper_microvm_shim_readiness.error_message);
    Fs_compat.mkdir_p (Workspace.keepers_runtime_dir config);
    let directory = value (Keeper_github_identity.ensure_config_dir ~config ~keeper_name:keeper) in
    let hosts = Filename.concat directory "hosts.yml" in
    write hosts "github.com:\n    user: fixture\n    oauth_token: first-fixture-token\n    git_protocol: https\n";
    Unix.chmod hosts 0o600) other_base;
  let effective_network = if operation = "override" then Profile.Network_inherit else network_mode in
  let runtime = Turn.create ~config ~meta:(meta ()) ~image:(Ok "fixture:image") ~network_mode:effective_network () in
  if operation = "teardown" then (
    match Turn.teardown_keeper_sandbox_by_name ~timeout_sec:10. ~config ~keeper_name:keeper
        ~backend:Keeper_sandbox.Micro_vm ~microvm_backend:backend () with
    | Ok () -> exit 0
    | Error detail -> prerr_endline detail; exit 2);
  if operation = "cleanup-attached" then (
    match Turn.cleanup_attached_builds ~config ~meta:(meta ()) ~retention_sec:0. () with
    | Ok _ -> exit 0
    | Error detail -> prerr_endline detail; exit 2);
  (* The error text names which side of the typed split failed, so a test
     can tell a guest failure from an identity failure. *)
  let prepare_identity () =
    Turn.prepare_github_identity_secret_files ~timeout_sec:10. runtime
    |> Result.map_error (fun error ->
         let side = match error with
           | Turn.Sandbox_unavailable _ -> "sandbox_unavailable"
           | Turn.Identity_unavailable _ -> "identity_unavailable" in
         side ^ ": " ^ Turn.github_identity_preparation_error_message error) in
  let initialize_review_fixture () =
    let prompts = Filename.concat (Masc_test_deps.find_project_root ()) "config/prompts" in
    Prompt_registry.set_markdown_dir prompts;
    Prompt_registry.load_prompts_from_directory prompts;
    Masc_test_deps.init_unified_tool_registry ();
    let local_config = Filename.concat (Workspace.masc_dir config) "config" in
    Fs_compat.mkdir_p local_config;
    Unix.putenv Env_config_core.config_dir_env_key local_config;
    Config_dir_resolver.reset ();
    let declaration = Config_dir_resolver.keeper_toml_path_for_base_path ~base_path:base keeper in
    Fs_compat.mkdir_p (Filename.dirname declaration);
    write declaration (Printf.sprintf
      "[keeper]\nname = %S\ninstructions = \"fixture\"\nsandbox_profile = \"microvm\"\nsandbox_image = \"base\"\nmicrovm_backend = \"apple_container\"\nnetwork_mode = \"none\"\n" keeper);
    value (Keeper_meta_store.replace_snapshot config (meta ())) in
  let endpoint = match operation with
    | "attached" -> Turn.microvm_attached_endpoint ~config ~meta:(meta ()) ()
    | "prepare-identity" ->
      Result.bind (prepare_identity ())
        (fun _ -> Turn.microvm_remote_endpoint ~timeout_sec:10. runtime)
    | "authority-revision" ->
      let module A = Verification_authority_tools in
      let module AR = Task.Anti_rationalization in
      let module V = Verifier_review_original in
      let module O = Verifier_review_owner in
      let module W = Verifier_review_worker in
      initialize_review_fixture ();
      Result.bind (prepare_identity ()) (fun _ ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun first_endpoint ->
        let verification_id = "vrf-apple-identity" and task_id = "task-apple-identity" in
        let installation_id = "masc.verifier" and package_id = "masc.verifier.review" in
        let request_header : Workspace_verification_store.request_header =
          {id=verification_id; task_id; worker=keeper; created_at=1.} in
        let evidence_access = Workspace_verification_store.Evidence_available
            {request=request_header; items=[]} in
        let authority () = value (A.create_task_review ~config ~verification_id ~task_id
            ~producer:keeper ~evidence_access) in
        let projection () =
          match Keeper_sandbox_remote_lane.capture_read_authority ~config ~meta:(meta ()) () with
          | Ok (Some authority) -> Keeper_sandbox_remote_lane.read_authority_identity authority
          | Ok None -> fail "Apple authority was missing"
          | Error detail -> fail detail in
        let first_projection = projection () in
        let argv = strings (Keeper_sandbox_remote.transport_argv first_endpoint) in
        let remote_root = Keeper_sandbox_remote.workspace_root first_endpoint in
        (* This is the exact pre-change projection. Credential and route
           revalidation are process-local and must not rewrite old originals. *)
        let legacy_identity = `Assoc ["workspace", `String base; "keeper", `String keeper;
          "profile", `String "microvm"; "workspace_root", `String remote_root;
          "transport_argv", argv; "declaration", `Null] in
        check string "Apple authority preserves the legacy identity bytes"
          (Yojson.Safe.to_string legacy_identity) (Yojson.Safe.to_string first_projection);
        let old = authority () in
        let ownership_root = match A.task_review_root old with
          | AR.Producer_namespace {root} -> root
          | AR.Producer_tree _ | AR.Producer_root_absent _ -> fail "unexpected review namespace" in
        let legacy_route = `Assoc ["kind", `String "keeper"; "name", `String keeper;
          "profile", `String "microvm"; "network", `String "none";
          "route", `Assoc ["kind", `String "microvm"; "argv", argv; "root", `String remote_root]] in
        let schema_json (schema : Types_core.tool_schema) =
          `Assoc ["name", `String schema.name; "description", `String schema.description;
            "input_schema", schema.input_schema] in
        let legacy_review = `Assoc ["purpose", `String "task_review";
          "subject", Workspace_verification_store.request_header_to_yojson request_header;
          "base_path", `String base; "ownership_root", `String ownership_root;
          "route", legacy_route; "read_authority", legacy_identity;
          "schemas", `List (List.map schema_json (A.schemas (A.task_review_tools old)));
          "submitted_evidence", `List []] in
        let legacy_binding = value (Lane_addon_action.canonical legacy_review)
          |> Yojson.Safe.to_string |> Lane_addon_store.digest in
        check string "review binding matches the pre-change projection"
          legacy_binding (A.task_review_binding old);
        let request : AR.review_request =
          {task_title="T"; task_description="D"; completion_notes="N"; agent_name=keeper;
           task_id; evidence_refs=[]; evidence_images=[]} in
        let question : AR.verdict_question =
          {completion_contract=None; required_evidence=[]; evidence_posture=AR.Note_only; few_shot_block=""} in
        let original = value (V.prepare ~generator_runtime:None ~verification_id ~attempt:0
            ~question ~lookup_root:(A.task_review_root old)
            ~lookup_binding:legacy_binding
            ~lookup_schemas:(List.map (fun (schema : Types_core.tool_schema) -> schema.name)
              (A.schemas (A.task_review_tools old))) request) in
        let store = Lane_addon_store.create
            ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
        (match O.retain ~store ~verification_id ~attempt:0 ~installation_id ~package_id original with
         | Ok () -> () | Error _ -> fail "failed to retain review original");
        let reviewer_calls = ref 0 in
        let previous = Atomic.get AR.run_llm_reviewer_fn in
        let previous_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
        Fun.protect ~finally:(fun () ->
          Atomic.set AR.run_llm_reviewer_fn previous;
          Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn previous_slots) (fun () ->
          Atomic.set AR.run_llm_reviewer_fn
            (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt:_
                 ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup:_ ~on_tool_result:_
                 ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
              incr reviewer_calls;
              Ok {AR.selected_runtime_id="fixture-reviewer"; evaluator_execution=None;
                verdict=Some (AR.Approve "legacy original admitted")});
          let run () = W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
              ~prepare_notes:(fun _ -> "fixture review notes") ~base_path:base
              ~prepare_authority:(fun () -> Ok old) ~provider_rest:(fun _ -> AR.No_stated_rest) ()
              |> Result.map snd in
          Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
            (fun () -> Error "fixture admission unavailable");
          (match run () with Ok {AR.verdict=None; _} -> ()
           | Ok _ | Error _ -> fail "legacy captured original could not enter admission wait");
          let retained = match O.load_retained ~store ~verification_id ~attempt:0 ~installation_id ~package_id with
            | Ok retained -> retained | Error _ -> fail "legacy original could not be loaded" in
          (match Lane_addon_request_progress.phase (O.progress retained) with
           | Admission_wait _ -> () | _ -> fail "legacy original did not retain admission wait");
          Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
            (fun () -> Ok ["fixture-reviewer", Types_core.Catalog_slot]);
          (match run () with Ok {AR.verdict=Some (Approve "legacy original admitted"); _} -> ()
           | Ok _ | Error _ -> fail "legacy original could not re-enter after admission wait");
          check int "legacy original reached its reviewer exactly once" 1 !reviewer_calls);
        let directory = value (Keeper_github_identity.ensure_config_dir ~config ~keeper_name:keeper) in
        write (Filename.concat directory "hosts.yml")
          "github.com:\n    user: fixture\n    oauth_token: second-fixture-token\n    git_protocol: https\n";
        Result.bind (prepare_identity ()) (fun _ ->
        Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun endpoint ->
          let second_projection = projection () in
          check string "credential refresh does not change the legacy projection"
            (Yojson.Safe.to_string first_projection) (Yojson.Safe.to_string second_projection);
          let second = authority () in
          check string "reconstructed authority retains the legacy binding"
            (A.task_review_binding old) (A.task_review_binding second);
          (* Equality here does not establish which revision the original
             carried; that durable binding gap is tracked separately. *)
          List.iter (fun bytes -> List.iter (fun secret ->
            check bool "durable identity contains no credential bytes" false
              (Astring.String.is_infix ~affix:secret bytes))
            ["first-fixture-token"; "second-fixture-token"])
            [Yojson.Safe.to_string first_projection; Yojson.Safe.to_string second_projection;
             Yojson.Safe.to_string (V.to_json original)];
          (match A.validate_task_review old with
           | Ok () -> () | Error detail -> fail detail);
          let request_count () = read (Filename.concat root "requests") |> String.split_on_char '\n'
            |> List.filter (fun line -> line <> "") |> List.length in
          let before_lookup = request_count () in
          let lookup = A.task_review_lookup old in
          (match lookup.AR.dispatch ~name:"tool_read_file" ~args:(`Assoc ["file_path", `String "fixture.txt"]) with
           | Tool_result.Failed _ as refusal ->
             check bool "old lookup reports its revised credentials" true
               (Astring.String.is_infix
                  ~affix:"captured Apple read authority credential snapshot or route changed"
                  (Tool_result.message refusal))
           | Tool_result.Completed _ | Tool_result.Deferred _ -> fail "old lookup was not refused");
          check int "old lookup sends no guest frame" before_lookup (request_count ());
          (match O.load ~store ~verification_id ~attempt:0 with
           | Ok loaded -> check string "retained original is unchanged"
               (Yojson.Safe.to_string (V.to_json original)) (Yojson.Safe.to_string (V.to_json loaded))
           | Error _ -> fail "retained original could not be reloaded");
          Ok endpoint))))
    | ("review-stopped" | "review-inspect-unavailable") as unavailable ->
      let module A = Verification_authority_tools in
      let module AR = Task.Anti_rationalization in
      let module V = Verifier_review_original in
      let module O = Verifier_review_owner in
      let module W = Verifier_review_worker in
      initialize_review_fixture ();
      Result.bind (prepare_identity ()) (fun _ ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun endpoint ->
        let verification_id = "vrf-offline-guest" and task_id = "task-offline-guest" in
        let installation_id = "masc.verifier" and package_id = "masc.verifier.review" in
        let source = {|{"source":"fusion","run_id":"fixture-run","proof":"frozen-source-evidence"}|} in
        let item = Workspace_verification_store.Evidence_collaboration
            {reference="fusion:fixture-run"; content=source;
             sha256=Agent_core_sha256.(to_hex (digest_string source))} in
        let request_header : Workspace_verification_store.request_header =
          {id=verification_id; task_id; worker=keeper; created_at=1.} in
        let evidence_access = Workspace_verification_store.Evidence_available
            {request=request_header; items=[item]} in
        let authority () = value (A.create_task_review ~config ~verification_id ~task_id
            ~producer:keeper ~evidence_access) in
        let old = authority () in
        let request : AR.review_request =
          {task_title="T"; task_description="D"; completion_notes="frozen-review-note";
           agent_name=keeper; task_id; evidence_refs=["fusion:fixture-run"]; evidence_images=[]} in
        let question : AR.verdict_question =
          {completion_contract=None; required_evidence=[]; evidence_posture=AR.Note_only; few_shot_block=""} in
        let original = value (V.prepare ~generator_runtime:None ~verification_id ~attempt:0
            ~question ~lookup_root:(A.task_review_root old)
            ~lookup_binding:(A.task_review_binding old)
            ~lookup_schemas:(List.map (fun (schema : Types_core.tool_schema) -> schema.name)
              (A.schemas (A.task_review_tools old))) request) in
        let store = Lane_addon_store.create
            ~root:(Filename.concat (Workspace.masc_dir config) "lane-addons") in
        (match O.retain ~store ~verification_id ~attempt:0 ~installation_id ~package_id original with
         | Ok () -> () | Error _ -> fail "failed to retain review original");
        let guest_path = Filename.concat root "guest.json" in
        let guest = text (field "id" (json guest_path)) in
        if unavailable = "review-stopped" then
          save_json guest_path (replace "status" (`Assoc ["state", `String "stopped"]) (json guest_path))
        else write (Filename.concat root "inspect-fails-after-run") "";
        let lines name = read (Filename.concat root name) |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "") in
        let calls_since before = lines "calls" |> List.drop before |> List.map Yojson.Safe.from_string in
        let call_count () = List.length (lines "calls") in
        let request_count () = List.length (lines "requests") in
        let before_capture = call_count () in
        let before_requests = request_count () in
        let prepared = authority () in
        check string "guest availability does not change a retained binding"
          (A.task_review_binding old) (A.task_review_binding prepared);
        value (A.validate_task_review old);
        value (A.validate_task_review prepared);
        check int "capture and review admission do not inspect the guest" before_capture (call_count ());
        let check_guest_refusal label before =
          let calls = calls_since before in
          check bool (label ^ " inspected the named guest") true
            (List.mem (strings ["inspect"; guest]) calls);
          check bool (label ^ " sent no guest exec") false
            (List.exists (function `List (`String "exec" :: _) -> true | _ -> false) calls) in
        let calls = ref 0 in
        let previous = Atomic.get AR.run_llm_reviewer_fn in
        let previous_slots = Atomic.get Workspace_hooks.get_verifier_exact_lane_slots_fn in
        Fun.protect ~finally:(fun () ->
          Atomic.set AR.run_llm_reviewer_fn previous;
          Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn previous_slots) (fun () ->
          Atomic.set Workspace_hooks.get_verifier_exact_lane_slots_fn
            (fun () -> Ok ["fixture-reviewer", Types_core.Catalog_slot]);
          Atomic.set AR.run_llm_reviewer_fn
            (fun ~base_path:_ ?sw:_ ?execution_owner:_ ~evaluator_runtime:_ ~candidate_kind:_ ~prompt
                 ?system_prompt:_ ?goal_blocks:_ ~report_tool_schema:_ ~lookup ~on_tool_result:_
                 ~attempt_continuation:_ ~on_runtime_attempt_error:_ () ->
              incr calls;
              check bool "reviewer receives the frozen note" true
                (Astring.String.is_infix ~affix:"frozen-review-note" prompt);
              let before_source = call_count () in
              (match lookup.AR.dispatch ~name:"masc_fusion_status"
                  ~args:(`Assoc ["run_id", `String "fixture-run"]) with
               | Tool_result.Completed _ as result ->
                 check bool "reviewer receives the submitted Fusion snapshot" true
                   (Astring.String.is_infix ~affix:"frozen-source-evidence" (Tool_result.message result))
               | Tool_result.Failed _ | Tool_result.Deferred _ -> fail "submitted non-guest source was unavailable");
              check int "non-guest lookup does not inspect the guest" before_source (call_count ());
              let before_read = call_count () in
              (match lookup.AR.dispatch ~name:"tool_read_file"
                  ~args:(`Assoc ["file_path", `String "fixture.txt"]) with
               | Tool_result.Failed _ -> ()
               | Tool_result.Completed _ | Tool_result.Deferred _ -> fail "unavailable guest Read was accepted");
              check_guest_refusal "Read" before_read;
              let before_grep = call_count () in
              (match lookup.AR.dispatch ~name:"tool_search_files"
                  ~args:(`Assoc ["pattern", `String "fixture"]) with
               | Tool_result.Failed _ -> ()
               | Tool_result.Completed _ | Tool_result.Deferred _ -> fail "unavailable guest Grep was accepted");
              check_guest_refusal "Grep" before_grep;
              Ok {AR.selected_runtime_id="fixture-reviewer"; evaluator_execution=None;
                verdict=Some (AR.Approve "submitted evidence inspected")});
          match W.run_attempt ~store ~verification_id ~attempt:0 ~installation_id ~package_id
              ~prepare_notes:(fun _ -> "fixture review notes") ~base_path:base
              ~prepare_authority:(fun () -> Ok prepared) ~provider_rest:(fun _ -> AR.No_stated_rest) ()
              |> Result.map snd with
          | Ok {AR.verdict=Some (Approve "submitted evidence inspected"); _} -> ()
          | Ok _ | Error _ -> fail "reviewer did not complete with submitted evidence");
        check int "reviewer ran once" 1 !calls;
        let captured = match Keeper_sandbox_remote_lane.capture_read_authority ~config ~meta:(meta ()) () with
          | Ok (Some captured) -> captured | Ok None -> fail "Apple authority was missing"
          | Error detail -> fail detail in
        let before_layout = call_count () in
        (match Keeper_sandbox_remote_checkouts.discover_layout ~read_authority:captured
            ~timeout_sec:10. ~config ~meta:(meta ()) () with
         | Error (Keeper_playground_checkouts.Root_missing _) when unavailable = "review-stopped" -> ()
         | Error (Keeper_playground_checkouts.Root_unreadable _) when unavailable = "review-inspect-unavailable" -> ()
         | _ -> fail "unavailable guest layout was accepted");
        check_guest_refusal "layout" before_layout;
        check int "unavailable guest lookups send no framed request" before_requests (request_count ());
        let snapshot = Keeper_microvm_github_identity.host_path
            ~base_path:base ~keeper_name:keeper ~backend ~network_mode in
        let held_snapshot = held_snapshot_path snapshot "review-held-snapshot" in
        Unix.rename snapshot held_snapshot;
        Fun.protect ~finally:(fun () -> Unix.rename held_snapshot snapshot) (fun () ->
          let before_missing = call_count () in
          (match A.create_task_review ~config ~verification_id ~task_id ~producer:keeper ~evidence_access with
           | Error detail -> check bool "missing host snapshot refuses a fresh authority" true
               (Astring.String.is_infix ~affix:"host credential snapshot is missing" detail)
           | Ok _ -> fail "fresh authority accepted a missing host snapshot");
          (match A.validate_task_review prepared with
           | Error detail -> check bool "missing host snapshot refuses retained admission" true
               (Astring.String.is_infix ~affix:"host credential snapshot is missing" detail)
           | Ok () -> fail "retained admission accepted a missing host snapshot");
          check int "missing snapshot is rejected before a guest probe" before_missing (call_count ()));
        Ok endpoint))
    | "identity-helper-race" ->
      Result.bind (prepare_identity ()) (fun _ ->
        let directory = value (Keeper_github_identity.ensure_config_dir ~config ~keeper_name:keeper) in
        write (Filename.concat directory "hosts.yml")
          "github.com:\n    user: fixture\n    oauth_token: second-fixture-token\n    git_protocol: https\n";
        save_json (Filename.concat root "list-override")
          (`List [json (Filename.concat root "guest.json");
            `Assoc ["id", `String (Microvm.work_volume_trim_name ~keeper_name:keeper)]]);
        Result.bind (prepare_identity ())
          (fun _ -> Turn.microvm_remote_endpoint ~timeout_sec:10. runtime))
    | "scan-retry" ->
      let next_turn () =
        let next = Turn.create ~config ~meta:(meta ()) ~image:(Ok "fixture:image")
            ~network_mode:effective_network () in
        Fun.protect ~finally:(fun () -> Turn.cleanup next) (fun () ->
          Turn.microvm_remote_endpoint ~timeout_sec:10. next) in
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun _ ->
        Result.bind (next_turn ()) (fun _ -> next_turn ()))
    | "replace-failed-after-uncertain-build" ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun _ ->
        (* End the first turn without stopping its persistent guest. The build
           effect was sent but its outcome was not confirmed. *)
        Turn.cleanup runtime;
        let guest_path = Filename.concat root "guest.json" in
        let original = read guest_path in
        let run_turn image =
          let next = Turn.create ~config ~meta:(meta ()) ~image:(Ok image)
              ~network_mode:effective_network () in
          Fun.protect ~finally:(fun () -> Turn.cleanup next) (fun () ->
            Turn.microvm_remote_endpoint ~timeout_sec:10. next) in
        let marker = Filename.concat root "replacement-keep-guest" in
        write marker "";
        let replacement = Fun.protect ~finally:(fun () -> Sys.remove marker) (fun () ->
          run_turn "fixture:replacement") in
        (match replacement with
         | Error detail ->
           check bool "replacement reached the failed guest removal" true
             (Astring.String.is_infix ~affix:"microvm_teardown_failed" detail)
         | Ok _ -> fail "replacement unexpectedly removed the guest");
        check string "failed replacement kept the original guest" original (read guest_path);
        run_turn "fixture:image")
    | "identity-foreign" ->
      Result.bind (prepare_identity ()) (fun _ ->
        let directory = value (Keeper_github_identity.ensure_config_dir ~config ~keeper_name:keeper) in
        write (Filename.concat directory "hosts.yml")
          "github.com:\n    user: fixture\n    oauth_token: second-fixture-token\n    git_protocol: https\n";
        let guest_path = Filename.concat root "guest.json" in
        save_json guest_path (foreign_guest (json guest_path) ~state:"running");
        write (Filename.concat root "foreign-expected") (read guest_path);
        let call_count = read (Filename.concat root "calls") |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "") |> List.length in
        write (Filename.concat root "foreign-refresh-start-index") (string_of_int call_count);
        Result.bind (prepare_identity ())
          (fun _ -> Turn.microvm_remote_endpoint ~timeout_sec:10. runtime))
    | "running-foreign" ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun _ ->
        check bool "the first endpoint prepared this guest" true
          (Turn.is_microvm_guest_booted ~config ~meta:(meta ()) ());
        let guest_path = Filename.concat root "guest.json" in
        save_json guest_path (foreign_guest (json guest_path) ~state:"running");
        write (Filename.concat root "foreign-expected") (read guest_path);
        let call_count = read (Filename.concat root "calls") |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "") |> List.length in
        write (Filename.concat root "foreign-running-start-index") (string_of_int call_count);
        Turn.microvm_remote_endpoint ~timeout_sec:10. runtime)
    | "authority-collision" ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun endpoint_a ->
        let other = match other_base with Some base -> base | None -> fail "missing second workspace" in
        let config_b = Workspace.default_config other in
        let apple_meta = meta () in
        let name config = Turn.For_testing_microvm.microvm_container_name
            ~config ~keeper_name:keeper ~network_mode in
        let guest = name config in
        check string "actual shortened guest names collide" guest (name config_b);
        check bool "full workspace hashes differ" true
          (Keeper_sandbox_runtime_setup.base_path_hash base <> Keeper_sandbox_runtime_setup.base_path_hash other);
        let authority config = match Keeper_sandbox_remote_lane.capture_read_authority ~config ~meta:apple_meta () with
          | Ok (Some authority) -> authority
          | Ok None -> fail "Apple read authority was missing"
          | Error detail -> fail detail in
        let authority_a = authority config in
        let read_guest authority config meta = Keeper_sandbox_read_backend.run_command_with_status
            ~read_authority:authority ~config ~meta ~command_argv:["/bin/true"]
            ~max_bytes:1024 ~timeout_sec:10. () in
        let layout authority config = Keeper_sandbox_remote_checkouts.discover_layout
            ~read_authority:authority ~timeout_sec:10. ~config ~meta:apple_meta () in
        ignore (value (read_guest authority_a config apple_meta));
        (match layout authority_a config with
         | Ok _ -> ()
         | Error error -> fail (Keeper_playground_checkouts.scan_error_to_string error));
        let call_count () = read (Filename.concat root "calls") |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "") |> List.length in
        let requests () = read (Filename.concat root "requests") |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "") |> List.length in
        let before_drift = call_count () in
        List.iter (fun changed ->
          match read_guest authority_a config changed with
          | Error detail -> check bool "metadata drift is refused" true
              (Astring.String.is_infix ~affix:"captured read authority microVM backend or network changed" detail)
          | Ok _ -> fail "changed backend or network reused captured authority")
          [{apple_meta with microvm_backend=Some Backend.Nerdctl_kata};
           {apple_meta with network_mode=Profile.Network_inherit}];
        check int "metadata drift sends no provider command" before_drift (call_count ());
        let snapshot = Keeper_microvm_github_identity.host_path ~base_path:base ~keeper_name:keeper ~backend ~network_mode in
        let snapshot_files = Sys.readdir snapshot |> Array.to_list
          |> List.map (fun leaf -> leaf, read (Filename.concat snapshot leaf)) in
        let hosts = Filename.concat snapshot "hosts.yml" in
        let original_hosts = read hosts in
        let replace_hosts bytes =
          Unix.chmod snapshot 0o700; Unix.chmod hosts 0o600;
          write hosts bytes; Unix.chmod hosts 0o400; Unix.chmod snapshot 0o500 in
        replace_hosts "github.com:\n    user: fixture\n    oauth_token: second-fixture-token\n    git_protocol: https\n";
        let before_revision = requests () in
        (match read_guest authority_a config apple_meta with
         | Error detail -> check bool "changed identity revision is refused" true
             (Astring.String.is_infix ~affix:"captured Apple read authority credential snapshot or route changed" detail)
         | Ok _ -> fail "changed snapshot reused captured authority");
        check int "changed snapshot sends no frame" before_revision (requests ());
        replace_hosts original_hosts;
        ignore (value (read_guest authority_a config apple_meta));
        value (Turn.teardown_keeper_sandbox_by_name ~timeout_sec:10. ~config ~keeper_name:keeper
            ~backend:Keeper_sandbox.Micro_vm ~microvm_backend:backend ());
        check bool "normal A teardown removed its snapshot" false (Sys.file_exists snapshot);
        let runtime_b = Turn.create ~config:config_b ~meta:apple_meta ~image:(Ok "fixture:image") ~network_mode () in
        let result_b = Turn.microvm_remote_endpoint ~timeout_sec:10. runtime_b in
        Result.bind result_b (fun _ ->
          let before_old = requests () in
          (match read_guest authority_a config apple_meta with
           | Error _ -> () | Ok _ -> fail "A authority read B after normal teardown");
          check int "A with removed snapshot sends no B frame" before_old (requests ());
          Unix.mkdir snapshot 0o700;
          List.iter (fun (leaf, bytes) -> let path = Filename.concat snapshot leaf in
            write path bytes; Unix.chmod path 0o400) snapshot_files;
          Unix.chmod snapshot 0o500;
          let before_owner_check = call_count () in
          (match read_guest authority_a config apple_meta with
           | Error detail -> check bool "A rejects the observed B owner" true
               (Astring.String.is_infix ~affix:"microvm_guest_ownership_unverified" detail)
           | Ok _ -> fail "A authority read B with a retained A snapshot");
          let owner_calls = read (Filename.concat root "calls") |> String.split_on_char '\n'
            |> List.filter (fun line -> line <> "") |> List.drop before_owner_check |> List.map Yojson.Safe.from_string in
          check bool "retained A authority inspected the actual B slot" true
            (List.mem (strings ["inspect"; guest]) owner_calls);
          (match layout authority_a config with
           | Error (Keeper_playground_checkouts.Root_unreadable _) -> ()
           | _ -> fail "A checkout authority accessed or misclassified B");
          let guest_path = Filename.concat root "guest.json" in
          let saved_b = read guest_path in
          save_json guest_path (replace "status" (`Assoc ["state", `String "stopped"]) (json guest_path));
          (* Inspect mode normally requires a prior process-local handoff.
             Model a stale marker so that both checkout modes reach the
             endpoint and the subsequent absence observation. *)
          Turn.For_testing_microvm.mark_microvm_work_root_ready
            ~base_path:base ~backend ~container_name:guest;
          let check_observations label before =
            let after = read (Filename.concat root "calls") |> String.split_on_char '\n'
              |> List.filter (fun line -> line <> "") |> List.drop before |> List.map Yojson.Safe.from_string in
            check bool (label ^ " performs both endpoint and absence inspection") true
              (List.length (List.filter ((=) (strings ["inspect"; guest])) after) >= 2);
            check bool (label ^ " sends no guest exec") false
              (List.exists (function `List (`String "exec" :: _) -> true | _ -> false) after) in
          let before_read = call_count () in
          (match Keeper_sandbox_read_backend.run_command_with_status ~config ~meta:apple_meta
              ~command_argv:["/bin/true"] ~max_bytes:1024 ~timeout_sec:10. () with
           | Error detail -> check bool "plain read preserves stopped foreign ownership refusal" true
               (Astring.String.is_infix ~affix:"microvm_guest_ownership_unverified" detail)
           | Ok _ -> fail "plain read accepted a stopped foreign guest");
          check_observations "foreign stopped read" before_read;
          let before_layout = call_count () in
          (match Keeper_sandbox_remote_checkouts.discover_layout ~timeout_sec:10. ~config ~meta:apple_meta () with
           | Error (Keeper_playground_checkouts.Root_unreadable {detail; _}) ->
             check bool "checkout preserves stopped foreign ownership refusal" true
               (Astring.String.is_infix ~affix:"microvm_guest_ownership_unverified" detail)
           | _ -> fail "checkout accepted or hid a stopped foreign guest");
          check_observations "foreign stopped checkout layout" before_layout;
          let before_inspect = call_count () in
          (match Keeper_sandbox_remote_checkouts.discover_and_inspect ~timeout_sec:10.
              ~config ~meta:apple_meta ~catalog:(Ok []) () with
           | Error (Keeper_playground_checkouts.Root_unreadable {detail; _}) ->
             check bool "checkout inspection preserves stopped foreign ownership refusal" true
               (Astring.String.is_infix ~affix:"microvm_guest_ownership_unverified" detail)
           | _ -> fail "checkout inspection accepted or hid a stopped foreign guest");
          check_observations "foreign stopped checkout inspection" before_inspect;
          check bool "foreign observation does not clear A's stale marker" true
            (Turn.is_microvm_guest_booted ~config ~meta:apple_meta ());
          check bool "foreign observation does not clear B's readiness" true
            (Turn.is_microvm_guest_booted ~config:config_b ~meta:apple_meta ());
          write guest_path saved_b;
          check int "retained A snapshot still sends no B frame" before_old (requests ());
          let authority_b = authority config_b in
          ignore (value (read_guest authority_b config_b apple_meta));
          (match layout authority_b config_b with
           | Ok _ -> ()
           | Error error -> fail (Keeper_playground_checkouts.scan_error_to_string error));
          check int "B authority reads and lists the B guest" (before_old + 2) (requests ());
          Turn.cleanup runtime_b;
          Ok endpoint_a))
    | "checkout-race" ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun _ ->
        let guest_path = Filename.concat root "guest.json" in
        let saved_guest = read guest_path in
        let snapshot = Keeper_microvm_github_identity.host_path ~base_path:root ~keeper_name:keeper ~backend ~network_mode in
        let held_snapshot = held_snapshot_path snapshot "race-held-snapshot" in
        save_json guest_path (replace "status" (`Assoc ["state", `String "stopped"]) (json guest_path));
        Unix.rename snapshot held_snapshot;
        write (Filename.concat root "hold-inspect") "";
        Eio.Switch.run (fun sw ->
          let await promise = Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 15.
              (fun () -> Eio.Promise.await promise) in
          let probe_done, resolve_probe = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
            let outcome = Keeper_sandbox_remote_checkouts.discover_and_inspect ~timeout_sec:10.
                ~config ~meta:(meta ()) ~catalog:(Ok []) () in
            Eio.Promise.resolve resolve_probe outcome);
          let rec await_held remaining =
            if Sys.file_exists (Filename.concat root "inspect-held") then ()
            else if remaining = 0 then fail "checkout did not reach the held inspect"
            else (Eio.Time.sleep (Eio.Stdenv.clock env) 0.01; await_held (remaining - 1)) in
          await_held 500;
          (* The fake provider captured a stopped guest. Make the replacement
             available before a same-process handoff can acquire the owner. *)
          write guest_path saved_guest;
          Unix.rename held_snapshot snapshot;
          let started, signal_started = Eio.Promise.create () in
          let turn_done, resolve_turn = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve signal_started ();
            Eio.Promise.resolve resolve_turn (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime));
          await started;
          write (Filename.concat root "release-inspect") "";
          (match await probe_done with
           | Error (Keeper_playground_checkouts.Root_missing _) -> ()
           | _ -> fail "the stopped observation was not reported");
          match await turn_done with
          | Ok endpoint ->
            check bool "successful turn has fresh readiness" true
              (Turn.is_microvm_guest_booted ~config ~meta:(meta ()) ());
            Ok endpoint
          | Error detail ->
            check bool "racing turn fails closed" true
              (Astring.String.is_infix ~affix:"microvm guest readiness changed" detail);
            Turn.microvm_remote_endpoint ~timeout_sec:10. runtime))
    | "checkout-absent" | "checkout-stopped" | "checkout-unknown" | "read-stopped" ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun _ ->
        let apple_meta = meta () in
        let kata_meta = {apple_meta with microvm_backend=Some Backend.Nerdctl_kata} in
        let guest = Turn.For_testing_microvm.microvm_container_name ~config ~keeper_name:keeper ~network_mode in
        let guest_path = Filename.concat root "guest.json" in
        let saved_guest = read guest_path in
        let snapshot = Keeper_microvm_github_identity.host_path ~base_path:root ~keeper_name:keeper ~backend ~network_mode in
        let held_snapshot = held_snapshot_path snapshot "checkout-held-snapshot" in
        let other_base = Filename.concat root "checkout-other-workspace" in
        let other_shim = Config_dir_resolver.microvm_shim_dir ~base_path:other_base in
        Fs_compat.mkdir_p other_shim;
        let other_binary = Filename.concat other_shim Microvm.shim_binary_name in
        write other_binary "#!/bin/sh\nexit 0\n"; Unix.chmod other_binary 0o700;
        value (Keeper_microvm_shim_readiness.initialize ~fs ~base_path:other_base ~payload_path:"/usr/bin:/bin"
          |> Result.map_error Keeper_microvm_shim_readiness.error_message);
        let verify ~base_path ~backend = Keeper_microvm_shim_readiness.verify ~fs ~base_path ~backend ~guest_name:guest in
        value (verify ~base_path:other_base ~backend |> Result.map_error Keeper_microvm_shim_readiness.error_message);
        value (verify ~base_path:root ~backend:Backend.Nerdctl_kata
          |> Result.map_error Keeper_microvm_shim_readiness.error_message);
        Turn.For_testing_microvm.mark_microvm_work_root_ready ~base_path:other_base ~backend ~container_name:guest;
        Turn.For_testing_microvm.mark_microvm_guest_booted ~config ~meta:kata_meta ();
        let size : Keeper_microvm_guest_size.t =
          {memory=value (Keeper_microvm_guest_size.memory_of_string "512m");
           cpus=value (Keeper_microvm_guest_size.cpus_of_int 1)} in
        let kata_boot : Turn.microvm_boot = {policy_port=None; image="kata-fixture"; guest_size=size} in
        Turn.For_testing_microvm.record_process_boot ~container_name:guest kata_boot;
        let kata_identity_cleaned = ref false in
        check bool "Kata identity fixture is registered" true
          (Turn.For_testing_microvm.register_process_identity ~container_name:guest
             ~cleanup:(fun () -> kata_identity_cleaned := true));
        if operation = "checkout-stopped" || operation = "read-stopped" then
          save_json guest_path (replace "status" (`Assoc ["state", `String "stopped"]) (json guest_path))
        else (
          Unix.rename snapshot held_snapshot;
          if operation = "checkout-absent" then Unix.unlink guest_path
          else (
            write (Filename.concat root "inspect-fails-after-run") "";
            write (Filename.concat root "list-override") "[{}]"));
        let before = read (Filename.concat root "calls") |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "") |> List.length in
        if operation = "read-stopped" then (
          match Keeper_sandbox_read_backend.run_command_with_status ~config ~meta:apple_meta
              ~command_argv:["/bin/true"] ~max_bytes:1024 ~timeout_sec:10. () with
          | Error detail -> check bool "read backend names stopped guest" true
              (Astring.String.is_infix ~affix:"microvm_guest_not_running" detail)
          | Ok _ -> fail "read backend accepted a stopped guest")
        else (
          let outcome = Keeper_sandbox_remote_checkouts.discover_and_inspect ~timeout_sec:10.
              ~config ~meta:apple_meta ~catalog:(Ok []) () in
          match operation, outcome with
          | ("checkout-absent" | "checkout-stopped"), Error (Keeper_playground_checkouts.Root_missing _) -> ()
          | "checkout-unknown", Error (Keeper_playground_checkouts.Root_unreadable _) -> ()
          | _ -> fail "checkout did not preserve the observed absence boundary");
        let expected_ready = operation = "checkout-unknown" in
        check bool "Apple readiness follows confirmed observation" expected_ready
          (Turn.is_microvm_guest_booted ~config ~meta:apple_meta ());
        check bool "colliding workspace follows confirmed observation" expected_ready
          (Turn.For_testing_microvm.microvm_work_root_ready ~base_path:other_base ~backend ~container_name:guest);
        check bool "Kata readiness survives" true (Turn.is_microvm_guest_booted ~config ~meta:kata_meta ());
        check bool "Kata process boot survives" true
          (Turn.For_testing_microvm.process_boot ~container_name:guest = Some kata_boot);
        check bool "Kata identity registration survives" true
          (Turn.For_testing_microvm.microvm_identity_snapshot_registered ~container_name:guest);
        check bool "Kata identity cleanup was not called" false !kata_identity_cleaned;
        let binary = Filename.concat (Config_dir_resolver.microvm_shim_dir ~base_path:root) Microvm.shim_binary_name in
        Unix.chmod binary 0o600; Unix.chmod other_binary 0o600;
        check bool "Apple shim follows confirmed observation" expected_ready (Result.is_ok (verify ~base_path:root ~backend));
        check bool "colliding shim follows confirmed observation" expected_ready (Result.is_ok (verify ~base_path:other_base ~backend));
        check bool "Kata shim survives" true (Result.is_ok (verify ~base_path:root ~backend:Backend.Nerdctl_kata));
        Unix.chmod binary 0o700; Unix.chmod other_binary 0o700;
        let after = read (Filename.concat root "calls") |> String.split_on_char '\n'
          |> List.filter (fun line -> line <> "") |> List.drop before |> List.map Yojson.Safe.from_string in
        check bool "checkout observation has no guest or volume effect" true
          (List.for_all (function `List (`String ("run" | "stop" | "delete" | "exec" | "volume") :: _) -> false
            | _ -> true) after);
        if operation <> "checkout-stopped" && operation <> "read-stopped" then Unix.rename held_snapshot snapshot;
        write guest_path saved_guest;
        if operation = "checkout-unknown" then (
          Unix.unlink (Filename.concat root "inspect-fails-after-run");
          Unix.unlink (Filename.concat root "list-override"));
        Turn.microvm_remote_endpoint ~timeout_sec:10. runtime)
    | "absent-reacquire" ->
      Result.bind (Turn.microvm_remote_endpoint ~timeout_sec:10. runtime) (fun _ ->
        let apple_meta = meta () in
        let kata_meta = {apple_meta with microvm_backend=Some Backend.Nerdctl_kata} in
        let guest = Turn.For_testing_microvm.microvm_container_name ~config ~keeper_name:keeper ~network_mode in
        let size : Keeper_microvm_guest_size.t =
          { memory=value (Keeper_microvm_guest_size.memory_of_string "512m");
            cpus=value (Keeper_microvm_guest_size.cpus_of_int 1) } in
        let kata_boot : Turn.microvm_boot = {policy_port=None; image="kata-fixture"; guest_size=size} in
        Turn.For_testing_microvm.record_process_boot ~container_name:guest kata_boot;
        let kata_identity_cleaned = ref false in
        check bool "same-name Kata identity fixture is registered" true
          (Turn.For_testing_microvm.register_process_identity ~container_name:guest
             ~cleanup:(fun () -> kata_identity_cleaned := true));
        Turn.For_testing_microvm.mark_microvm_guest_booted ~config ~meta:kata_meta ();
        let other_base = Filename.concat root "other-workspace" in
        let ready base_path backend container_name =
          Turn.For_testing_microvm.microvm_work_root_ready ~base_path ~backend ~container_name in
        let mark base_path backend container_name =
          Turn.For_testing_microvm.mark_microvm_work_root_ready ~base_path ~backend ~container_name in
        let other_guest = guest ^ "-other" in
        mark other_base backend guest;
        mark other_base backend other_guest;
        check bool "colliding Apple workspace has stale readiness" true (ready other_base backend guest);
        let other_shim = Config_dir_resolver.microvm_shim_dir ~base_path:other_base in
        Fs_compat.mkdir_p other_shim;
        let other_binary = Filename.concat other_shim Microvm.shim_binary_name in
        write other_binary "#!/bin/sh\nexit 0\n"; Unix.chmod other_binary 0o700;
        let verify_name ~base_path ~backend ~guest_name =
          Keeper_microvm_shim_readiness.verify ~fs ~base_path ~backend ~guest_name in
        let verify ~base_path ~backend = verify_name ~base_path ~backend ~guest_name:guest in
        value (Keeper_microvm_shim_readiness.initialize ~fs ~base_path:other_base ~payload_path:"/usr/bin:/bin"
          |> Result.map_error Keeper_microvm_shim_readiness.error_message);
        value (verify ~base_path:other_base ~backend |> Result.map_error Keeper_microvm_shim_readiness.error_message);
        value (verify_name ~base_path:other_base ~backend ~guest_name:other_guest
          |> Result.map_error Keeper_microvm_shim_readiness.error_message);
        value (verify ~base_path:root ~backend:Backend.Nerdctl_kata
          |> Result.map_error Keeper_microvm_shim_readiness.error_message);
        let guest_path = Filename.concat root "guest.json" in
        let saved_guest = read guest_path in
        let snapshot = Keeper_microvm_github_identity.host_path ~base_path:root ~keeper_name:keeper ~backend ~network_mode in
        let held_snapshot = held_snapshot_path snapshot "held-snapshot" in
        Unix.rename snapshot held_snapshot;
        Unix.unlink guest_path;
        let result = Turn.teardown_keeper_sandbox_by_name ~timeout_sec:10. ~config ~keeper_name:keeper
            ~backend:Keeper_sandbox.Micro_vm ~microvm_backend:backend () in
        Result.bind result (fun () ->
          check bool "absent Apple guest loses readiness" false
            (Turn.is_microvm_guest_booted ~config ~meta:apple_meta ());
          check bool "colliding Apple workspace loses readiness" false (ready other_base backend guest);
          check bool "another Apple guest keeps readiness" true (ready other_base backend other_guest);
          check bool "same-name Kata readiness survives" true
            (Turn.is_microvm_guest_booted ~config ~meta:kata_meta ());
          check bool "same-name Kata boot record survives" true
            (Turn.For_testing_microvm.process_boot ~container_name:guest = Some kata_boot);
          check bool "same-name Kata identity survives" true
            (Turn.For_testing_microvm.microvm_identity_snapshot_registered ~container_name:guest);
          check bool "same-name Kata identity cleanup is not called" false !kata_identity_cleaned;
          let binary = Filename.concat (Config_dir_resolver.microvm_shim_dir ~base_path:root) Microvm.shim_binary_name in
          Unix.chmod binary 0o600;
          Unix.chmod other_binary 0o600;
          check bool "Apple shim readiness was invalidated" true
            (Result.is_error (verify ~base_path:root ~backend));
          check bool "same-name Kata shim readiness survives" true
            (Result.is_ok (verify ~base_path:root ~backend:Backend.Nerdctl_kata));
          check bool "colliding workspace shim readiness was invalidated" true
            (Result.is_error (verify ~base_path:other_base ~backend));
          check bool "another Apple guest keeps shim readiness" true
            (Result.is_ok (verify_name ~base_path:other_base ~backend ~guest_name:other_guest));
          Unix.chmod binary 0o700;
          Unix.chmod other_binary 0o700;
          value (verify ~base_path:other_base ~backend
            |> Result.map_error Keeper_microvm_shim_readiness.error_message);
          Unix.rename held_snapshot snapshot;
          write guest_path saved_guest;
          Turn.microvm_remote_endpoint ~timeout_sec:10. runtime))
    | "turn" | "override" -> Turn.microvm_remote_endpoint ~timeout_sec:10. runtime
    | _ -> fail "unknown fixture step" in
  (match endpoint with
   | Error detail -> write (Filename.concat root "step-error") detail; prerr_endline detail; exit 2
   | Ok endpoint ->
     if operation = "attached" then (
       let runner = Keeper_sandbox_remote.runner ~timeout_sec:10. endpoint in
       match runner ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:None
           ~env:[||] ~cwd:None ~argv:["/bin/true"] with
       | Masc_exec.Sandbox_target.Ran {status=Unix.WEXITED 0; _} -> ()
       | _ -> fail "attached endpoint did not deliver the actual frame"));
  Turn.cleanup runtime

let rec writable path = match (Unix.lstat path).st_kind with
  | Unix.S_DIR -> Unix.chmod path 0o700; Sys.readdir path |> Array.iter (fun leaf -> writable (Filename.concat path leaf))
  | Unix.S_REG | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK | Unix.S_CHR | Unix.S_BLK -> ()

let with_fixture use =
  let root = Filename.temp_dir "masc-guest-survival-" "" in
  let previous_path = Sys.getenv "PATH" in
  Fun.protect ~finally:(fun () -> Unix.putenv "PATH" previous_path; writable root; Fs_compat.remove_tree root)
  (fun () ->
    let mkdir path = Unix.mkdir path 0o700 in
    let masc = Config_dir_resolver.masc_root ~base_path:root in mkdir masc;
    let microvm = Filename.concat masc "microvm" in mkdir microvm;
    let shim = Config_dir_resolver.microvm_shim_dir ~base_path:root in mkdir shim;
    write (Filename.concat shim Microvm.shim_binary_name) "#!/bin/sh\nexit 0\n";
    Unix.chmod (Filename.concat shim Microvm.shim_binary_name) 0o700;
    let bin = Filename.concat root "bin" in mkdir bin;
    write (Filename.concat bin "container") (Printf.sprintf "#!/bin/sh\nexec %s --provider %s \"$@\"\n"
      (Filename.quote (Unix.realpath Sys.executable_name)) (Filename.quote root));
    Unix.chmod (Filename.concat bin "container") 0o700;
    Unix.putenv "PATH" (bin ^ ":" ^ previous_path);
    write (Filename.concat root "calls") ""; write (Filename.concat root "requests") "";
    use root)

let step root operation =
  let input = Unix.open_process_args_in (Unix.realpath Sys.executable_name)
      [|Sys.executable_name; "--step"; root; operation|] in
  ignore (In_channel.input_all input);
  Unix.close_process_in input

let step_captured root operation =
  let error_path = Filename.temp_file ~temp_dir:root "step-stderr-" ".txt" in
  Fun.protect ~finally:(fun () -> Sys.remove error_path) (fun () ->
    let output = Unix.openfile "/dev/null" [Unix.O_WRONLY] 0 in
    let errors = Unix.openfile error_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let executable = Unix.realpath Sys.executable_name in
    let pid = Fun.protect ~finally:(fun () -> Unix.close output; Unix.close errors) (fun () ->
      Unix.create_process executable [|Sys.executable_name; "--step"; root; operation|]
        Unix.stdin output errors) in
    let deadline = Unix.gettimeofday () +. 45. in
    let rec wait () =
      match Unix.waitpid [Unix.WNOHANG] pid with
      | 0, _ when Unix.gettimeofday () < deadline -> Unix.sleepf 0.05; wait ()
      | 0, _ ->
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
        let rec reap () =
          match Unix.waitpid [] pid with
          | _, status -> status
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap () in
        let status = reap () in
        status, "\nfixture process exceeded its 45-second deadline and was killed\n"
      | _, status -> status, ""
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
    let status, timeout = wait () in
    status, read error_path ^ timeout)
let entries root name = read (Filename.concat root name) |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string
let calls root = entries root "calls" |> List.map (function
  | `List items -> List.map text items | _ -> fail "bad provider log")
let count operation root = calls root |> List.filter (function first :: _ -> first = operation | [] -> false) |> List.length
let boot root = check bool "cold process completed real boot path against provider fixture" true (step root "turn" = Unix.WEXITED 0)
let snapshot_path root = Keeper_microvm_github_identity.host_path ~base_path:root ~keeper_name:keeper ~backend ~network_mode
let adoption_read = function
  | ["image"; "inspect"; "fixture:image"] -> true
  | ["list"; "--all"; "--format"; "json"] -> true
  | ("inspect" | "exec") :: _ -> true
  | _ -> false

let test_absent_discard_never_runs_the_legacy_helper () = with_fixture @@ fun root ->
  write (Filename.concat root "discard-absent") "";
  boot root;
  let operations = calls root in
  let runs = List.filter (function "run" :: _ -> true | _ -> false) operations in
  check int "only the guest starts" 1 (List.length runs);
  check bool "the run is the persistent guest" true
    (List.for_all (function "run" :: "-d" :: _ -> true | _ -> false) runs);
  let trim = Microvm.work_volume_trim_name ~keeper_name:keeper in
  check bool "no name-scoped trim helper is deleted" false
    (List.mem ["delete"; "--force"; trim] operations)

let test_postboot_helper_refusal_preserves_the_new_guest () = with_fixture @@ fun root ->
  let marker = Filename.concat root "helper-after-run" in
  write marker "";
  let status, stderr = step_captured root "turn" in
  check bool "postboot helper refuses the first handoff" true (status = Unix.WEXITED 2);
  check bool "the postboot helper gate supplied the refusal" true
    (Astring.String.is_infix ~affix:"microvm_volume_helper_ownership_unverified" stderr);
  let original = read (Filename.concat root "guest.json") in
  let inode = (Unix.lstat (snapshot_path root)).st_ino in
  check int "the guest was started once" 1 (count "run" root);
  check int "no first handoff ran before refusal" 0 (List.length (entries root "requests"));
  check int "the guest was not stopped" 0 (count "stop" root);
  check int "the guest or helper was not deleted" 0 (count "delete" root);
  Sys.remove marker;
  check bool "a later process adopts after helper absence is observed" true
    (step root "turn" = Unix.WEXITED 0);
  check string "the same guest is retained" original (read (Filename.concat root "guest.json"));
  check int "the same credential snapshot is retained" inode (Unix.lstat (snapshot_path root)).st_ino;
  check int "the guest is not booted again" 1 (count "run" root)

let test_fresh_process_adopts_without_boot_effects () = with_fixture @@ fun root ->
  boot root;
  let original = read (Filename.concat root "guest.json") in
  let inode = (Unix.lstat (snapshot_path root)).st_ino in
  let before = calls root in
  check bool "second independent process reconnects" true (step root "turn" = Unix.WEXITED 0);
  check string "provider guest creation is retained" original (read (Filename.concat root "guest.json"));
  check int "durable snapshot inode retained" inode (Unix.lstat (snapshot_path root)).st_ino;
  let after = calls root |> List.drop (List.length before) in
  check bool "adoption performs only guest/image observation and exec" true
    (List.for_all adoption_read after);
  check int "one cold run total" 1 (count "run" root);
  check int "one first-handoff frame per process" 2 (List.length (entries root "requests"))

let scan_fixture_output =
  "ready\000symlink\000/masc-build/ready\000new\000absent\000\000"

let assert_build_input root kind expected =
  let matches = entries root "build-inputs" |> List.filter (fun item ->
    field "kind" item = `String kind) in
  match matches with
  | [item] ->
    check int (kind ^ " input byte count") (String.length expected)
      (match field "bytes" item with `Int bytes -> bytes | _ -> fail "bad input byte count");
    check string (kind ^ " input digest") Agent_core_sha256.(digest_string expected |> to_hex)
      (text (field "sha256" item))
  | _ -> fail (kind ^ " input was not received exactly once")

let build_scan_calls root =
  let config = Workspace.default_config root in
  let name = Turn.For_testing_microvm.microvm_container_name ~config ~keeper_name:keeper ~network_mode in
  let argv = Microvm.build_scan_argv_for backend ~container_name:name
      ~keeper_work_root:(Microvm.keeper_work_root ~keeper_name:keeper)
      ~uid:(Unix.getuid ()) ~gid:(Unix.getgid ()) in
  let expected = match argv with "container" :: args -> args | _ -> fail "expected container scan" in
  List.filter ((=) expected) (calls root)

let test_scan_failure_retries_on_the_next_turn_without_repeating_handoff () = with_fixture @@ fun root ->
  write (Filename.concat root "scan-fail-first") "";
  write (Filename.concat root "scan-output") scan_fixture_output;
  check bool "three turns remain usable" true (step root "scan-retry" = Unix.WEXITED 0);
  check int "failed scan and one successful retry" 2 (List.length (build_scan_calls root));
  check int "first-handoff cleanup was sent only once" 1 (List.length (entries root "requests"));
  let mkdirs = calls root |> List.filter (List.mem "masc-build-mkdir") in
  let links = calls root |> List.filter (List.mem "masc-build-link") in
  check int "the successful retry creates the target once" 1 (List.length mkdirs);
  check int "the successful retry sends the link action once" 1 (List.length links);
  assert_build_input root "mkdir" "/masc-build/ready\000/masc-build/new\000";
  assert_build_input root "link" "new\000/masc-build/new\000"

let test_uncertain_link_effect_is_not_replayed_in_the_same_process () = with_fixture @@ fun root ->
  write (Filename.concat root "scan-output") scan_fixture_output;
  write (Filename.concat root "build-mkdir-fails") "";
  check bool "three turns remain usable" true (step root "scan-retry" = Unix.WEXITED 0);
  check int "the uncertain effect does not cause another scan" 1 (List.length (build_scan_calls root));
  let mkdirs = calls root |> List.filter (List.mem "masc-build-mkdir") in
  check int "the possibly applied mkdir is not replayed" 1 (List.length mkdirs);
  check int "link application did not follow the failed mkdir" 0
    (List.length (calls root |> List.filter (List.mem "masc-build-link")));
  check int "first-handoff cleanup was not replayed" 1 (List.length (entries root "requests"));
  assert_build_input root "mkdir" "/masc-build/ready\000/masc-build/new\000"

let test_failed_replacement_keeps_uncertain_build_effect () =
  List.iter (fun (failed_kind, expected_links) -> with_fixture (fun root ->
    write (Filename.concat root "scan-output") scan_fixture_output;
    write (Filename.concat root ("build-effect-status-2-" ^ failed_kind)) "";
    let status, stderr = step_captured root "replace-failed-after-uncertain-build" in
    (match status with
     | Unix.WEXITED 0 -> ()
     | _ -> failf "%s: same-process replacement and re-adoption failed: %s" failed_kind stderr);
    check bool "the first effect outcome is reported unverified" true
      (Astring.String.is_infix ~affix:"microvm_build_link_effect_unverified" stderr);
    check int "the same guest is booted once" 1 (count "run" root);
    check int "replacement attempted to stop the guest" 1 (count "stop" root);
    check int "replacement attempted to delete the guest" 1 (count "delete" root);
    check int "first-handoff cleanup is not repeated" 1 (List.length (entries root "requests"));
    check int "the original scan is not repeated" 1 (List.length (build_scan_calls root));
    let mkdirs = calls root |> List.filter (List.mem "masc-build-mkdir") in
    let links = calls root |> List.filter (List.mem "masc-build-link") in
    check int "target preparation is sent once" 1 (List.length mkdirs);
    check int "link application is not replayed" expected_links (List.length links);
    assert_build_input root "mkdir" "/masc-build/ready\000/masc-build/new\000";
    if expected_links = 1 then assert_build_input root "link" "new\000/masc-build/new\000"))
    ["mkdir", 0; "link", 1]

(* The provider returns a failure after receiving its input. Neither status
   establishes which interpreter or module, if any, was unavailable. *)
let test_build_effect_failure_is_not_replayed_in_the_same_process () =
  List.iter (fun (failed_kind, failure_status, expected_links) -> with_fixture (fun root ->
    write (Filename.concat root "scan-output") scan_fixture_output;
    write (Filename.concat root (Printf.sprintf "build-effect-status-%d-%s" failure_status failed_kind)) "";
    let status, stderr = step_captured root "scan-retry" in
    check bool "three turns remain usable" true (status = Unix.WEXITED 0);
    let expected_warnings =
      [ (if failed_kind = "mkdir" then "microvm_build_link_mkdir_failed"
         else "microvm_build_link_apply_failed");
        Printf.sprintf "exit=%d" failure_status;
        "microvm_build_link_effect_unverified";
        "Keeper User Manual: Build preparation reports a failure" ]
      @ (if failure_status = 127 then
          [ "/usr/bin/python3"; "/usr/local/bin/python3";
            "exit 127 alone does not establish the cause or effect outcome" ]
         else []) in
    List.iter (fun expected ->
      check bool ("warning includes " ^ expected) true
        (Astring.String.is_infix ~affix:expected stderr)) expected_warnings;
    check bool "raw helper stderr is not included in the warning" false
      (Astring.String.is_infix ~affix:fixture_effect_stderr stderr);
    check int "the uncertain effect does not trigger another scan" 1
      (List.length (build_scan_calls root));
    check int "the target preparation is sent once" 1
      (List.length (calls root |> List.filter (List.mem "masc-build-mkdir")));
    check int "the link effect is never retried" expected_links
      (List.length (calls root |> List.filter (List.mem "masc-build-link")));
    check int "the first handoff is not replayed" 1 (List.length (entries root "requests"));
    check int "the guest is only started once" 1 (count "run" root);
    check int "the guest is not stopped" 0 (count "stop" root);
    check int "the guest is not deleted" 0 (count "delete" root);
    assert_build_input root "mkdir" "/masc-build/ready\000/masc-build/new\000";
    if expected_links = 1 then assert_build_input root "link" "new\000/masc-build/new\000"))
    [ "mkdir", 127, 0; "link", 127, 1; "mkdir", 2, 0; "link", 2, 1 ]

let test_differently_targeted_build_link_is_preserved_without_effects () = with_fixture @@ fun root ->
  let scan_output = "new\000symlink\000/masc-build/old\000" in
  let rows = match Microvm.build_scan_rows_of_output scan_output with
    | Ok rows -> Microvm.build_link_rows_of_scan rows
    | Error detail -> fail detail in
  (match rows with
   | [{ Microvm.checkout = "new";
        plan = Microvm.Link_preserve_symlink
          { existing = "/masc-build/old"; expected = "/masc-build/new" }; _ }] -> ()
   | _ -> fail "different build link target was not preserved");
  write (Filename.concat root "scan-output") scan_output;
  check bool "three turns remain usable" true (step root "scan-retry" = Unix.WEXITED 0);
  check int "the preserved link is scanned once" 1 (List.length (build_scan_calls root));
  check int "first handoff is sent once" 1 (List.length (entries root "requests"));
  let effects = calls root |> List.filter (fun args ->
    List.mem "masc-build-link" args || List.mem "masc-build-mkdir" args) in
  check int "no target directory or link operation is sent" 0 (List.length effects)

let test_real_build_warning_on_the_actual_scan_path () =
  let cases =
    [ "private-valid", "real", "", true
    ; "private:invalid-real", "real", "", true
    ; "private:invalid-absent", "absent", "", false
    ; "private:invalid-link", "symlink", "/private-target", false ] in
  List.iter (fun (checkout, kind, target, has_risk) -> with_fixture (fun root ->
    write (Filename.concat root "scan-output") (checkout ^ "\000" ^ kind ^ "\000" ^ target ^ "\000");
    let status, stderr = step_captured root "scan-retry" in
    check bool "the real scan path reports a usable turn" true (status = Unix.WEXITED 0);
    check bool "the warning is emitted" true
      (Astring.String.is_infix ~affix:"was not changed" stderr);
    List.iter (fun expected ->
      check bool ("warning includes " ^ expected) has_risk
        (Astring.String.is_infix ~affix:expected stderr))
      ["first owned handoff"; "can stage and delete it"; ".masc-keep-build";
       "Keeper User Manual: Inspecting _build entries"];
    check bool "guest checkout and target never enter the warning" false
      (Astring.String.is_infix ~affix:checkout stderr
       || Astring.String.is_infix ~affix:"/private-target" stderr);
    check int "the refusal is scanned once" 1 (List.length (build_scan_calls root));
    let effects = calls root |> List.filter (fun args ->
      List.mem "masc-build-link" args || List.mem "masc-build-mkdir" args) in
    check int "no target directory or link operation is sent" 0 (List.length effects))) cases

let test_invalid_or_oversized_scan_never_dispatches_link_effects () =
  List.iter (fun output -> with_fixture (fun root ->
    write (Filename.concat root "scan-output") output;
    check bool "three turns remain usable" true (step root "scan-retry" = Unix.WEXITED 0);
    check int "each new turn retries only the read" 3 (List.length (build_scan_calls root));
    check int "first handoff is still sent once" 1 (List.length (entries root "requests"));
    let effects = calls root |> List.filter (fun args ->
      List.mem "masc-build-link" args || List.mem "masc-build-mkdir" args) in
    check int "invalid or incomplete output dispatches no link effect" 0 (List.length effects)))
    [ "ready\000absent\000"; String.make (Common.max_process_capture_head_bytes + 1) 'x' ]

let test_forgotten_guest_rejects_old_scan_completion () = with_fixture @@ fun root ->
  let config = Workspace.default_config root in
  let meta = meta () in
  let name = Turn.For_testing_microvm.microvm_container_name ~config ~keeper_name:keeper ~network_mode in
  let mark () = Turn.For_testing_microvm.mark_microvm_guest_booted ~config ~meta () in
  let other_base = Filename.concat root "other-workspace" in
  let kata = Backend.Nerdctl_kata in
  let generation ~base_path ~backend =
    match Turn.For_testing_microvm.build_link_generation ~base_path ~backend ~container_name:name with
    | Some generation -> generation | None -> fail "missing root generation" in
  mark ();
  Turn.For_testing_microvm.mark_microvm_work_root_ready ~base_path:other_base ~backend ~container_name:name;
  Turn.For_testing_microvm.mark_microvm_work_root_ready ~base_path:root ~backend:kata ~container_name:name;
  let old = generation ~base_path:root ~backend in
  let other_old = generation ~base_path:other_base ~backend in
  let kata_generation = generation ~base_path:root ~backend:kata in
  Turn.forget_microvm_guest_booted ~config ~meta ();
  check bool "same-name Apple scope is forgotten" true
    (Option.is_none (Turn.For_testing_microvm.build_link_generation ~base_path:other_base ~backend ~container_name:name));
  check bool "same-name Kata generation survives" true
    (Option.is_some (Turn.For_testing_microvm.build_link_generation ~base_path:root ~backend:kata ~container_name:name));
  mark ();
  Turn.For_testing_microvm.mark_microvm_work_root_ready ~base_path:other_base ~backend ~container_name:name;
  let current = generation ~base_path:root ~backend in
  let other_current = generation ~base_path:other_base ~backend in
  check bool "old scan cannot mark the replacement ready" false
    (Turn.For_testing_microvm.complete_build_link_scan ~base_path:root ~backend ~container_name:name old);
  check bool "old colliding workspace scan cannot mark its replacement" false
    (Turn.For_testing_microvm.complete_build_link_scan ~base_path:other_base ~backend ~container_name:name other_old);
  check bool "one workspace scan cannot mark another workspace" false
    (Turn.For_testing_microvm.complete_build_link_scan ~base_path:other_base ~backend ~container_name:name current);
  check bool "another backend scan cannot mark this workspace" false
    (Turn.For_testing_microvm.complete_build_link_scan ~base_path:root ~backend ~container_name:name kata_generation);
  check bool "replacement remains unprepared" false
    (Turn.For_testing_microvm.build_link_scan_prepared ~base_path:root ~backend ~container_name:name);
  check bool "current scan can complete" true
    (Turn.For_testing_microvm.complete_build_link_scan ~base_path:root ~backend ~container_name:name current);
  check bool "current completion is retained" true
    (Turn.For_testing_microvm.build_link_scan_prepared ~base_path:root ~backend ~container_name:name);
  check bool "other workspace scan can complete independently" true
    (Turn.For_testing_microvm.complete_build_link_scan ~base_path:other_base ~backend ~container_name:name other_current);
  Turn.forget_microvm_guest_booted ~config ~meta ();
  Turn.forget_microvm_guest_booted ~config ~meta:{meta with microvm_backend=Some kata} ()

let wrapped_image root = save_json (Filename.concat root "image-entrypoint")
    (strings ["opam"; "exec"; "--"])

let test_wrapped_image_adopts_without_relabelling_or_boot_effects () = with_fixture @@ fun root ->
  wrapped_image root;
  boot root;
  let original = read (Filename.concat root "guest.json") in
  let config = field "configuration" (Yojson.Safe.from_string original) in
  check string "provider identifies the actual image argument" "fixture:image"
    (text (field "reference" (field "image" config)));
  let init = field "initProcess" config in
  check string "the requested entrypoint overrides the image" "tail" (text (field "executable" init));
  check (list string) "image Cmd is replaced by explicit Keeper argv"
    ["-f"; "/dev/null"]
    (match field "arguments" init with `List values -> List.map text values | _ -> fail "missing init argv");
  let inode = (Unix.lstat (snapshot_path root)).st_ino in
  let before = List.length (calls root) in
  check bool "independent process admits the wrapped command" true (step root "turn" = Unix.WEXITED 0);
  check string "image entrypoint comparison preserves the guest and its labelled plan"
    original (read (Filename.concat root "guest.json"));
  check int "same sealed credential snapshot" inode (Unix.lstat (snapshot_path root)).st_ino;
  let after = calls root |> List.drop before in
  check bool "wrapped adoption performs only guest/image observations and exec" true
    (List.for_all adoption_read after);
  check int "wrapped guest is never booted twice" 1 (count "run" root);
  check int "each process still performs its first handoff" 2 (List.length (entries root "requests"))

let test_helper_uncertainty_preserves_guest_on_adopt_and_replace () =
  List.iter (fun needs_replace ->
    List.iter (fun helper -> with_fixture (fun root ->
      boot root;
      let original = read (Filename.concat root "guest.json") in
      let row = Yojson.Safe.from_string original in
      let inode = (Unix.lstat (snapshot_path root)).st_ino in
      if needs_replace then (
        let config = field "configuration" row in
        let labels = field "labels" config |> replace Keeper_microvm_boot_plan.label_key (`String "different") in
        let changed = replace "configuration" (replace "labels" labels config) row in
        save_json (Filename.concat root "inspect-override") (`List [changed]));
      let expected_error = match helper with
       | Some name ->
         save_json (Filename.concat root "list-override")
           (`List [row; `Assoc ["id", `String name]]);
         "microvm_volume_helper_ownership_unverified"
       | None ->
         write (Filename.concat root "list-override") "[{}]";
         "microvm_volume_helper_inventory_unverified" in
      let before = List.length (calls root) in
      let status, stderr = step_captured root "turn" in
      check bool "helper presence or unknown inventory refuses the actual start" true
        (status = Unix.WEXITED 2);
      check bool "the helper gate supplied the refusal" true
        (Astring.String.is_infix ~affix:expected_error stderr);
      let after = calls root |> List.drop before in
      check bool "the real helper inventory was requested" true
        (List.mem ["list"; "--all"; "--format"; "json"] after);
      check bool "refusal only reads provider state" true
        (List.for_all (function ["list"; "--all"; "--format"; "json"] -> true
          | ["image"; "inspect"; "fixture:image"] -> true
          | "inspect" :: _ -> true | _ -> false) after);
      check string "existing guest remains unchanged" original (read (Filename.concat root "guest.json"));
      check int "existing credential snapshot remains" inode (Unix.lstat (snapshot_path root)).st_ino;
      check int "no replacement boot" 1 (count "run" root);
      check int "no guest stop" 0 (count "stop" root);
      check int "no guest or helper deletion" 0 (count "delete" root)))
      [ Some (Microvm.work_volume_trim_name ~keeper_name:keeper)
      ; Some (Microvm.volume_repair_name ~keeper_name:keeper)
      ; None ]) [ false; true ]

let assert_wrapped_refusals_preserve_guest root original inode before =
  List.iter (fun () -> check bool "wrapped refusal repeats without replay" true
    (step root "turn" = Unix.WEXITED 2)) [(); ()];
  let after = calls root |> List.drop before in
  let guest = text (field "id" (Yojson.Safe.from_string original)) in
  check bool "refused wrapped image uses only exact read-only observations" true
    (List.for_all (function ["inspect"; name] -> name = guest
      | ["image"; "inspect"; "fixture:image"] -> true | _ -> false) after);
  check int "each refusal directly re-observes the guest" 2
    (List.length (List.filter ((=) ["inspect"; guest]) after));
  check string "refusal preserves exact guest creation and plan bytes"
    original (read (Filename.concat root "guest.json"));
  check int "refusal preserves the host snapshot inode" inode (Unix.lstat (snapshot_path root)).st_ino;
  check int "no replacement run after either refusal" 1 (count "run" root)

let test_image_prefix_does_not_permit_command_tampering () =
  List.iter (fun changed_init -> with_fixture (fun root ->
    wrapped_image root;
    boot root;
    let path = Filename.concat root "guest.json" in
    let original = read path in
    let row = Yojson.Safe.from_string original in
    let config = field "configuration" row in
    let modified = replace "configuration"
        (replace "initProcess" (changed_init (field "initProcess" config)) config) row in
    save_json (Filename.concat root "inspect-override") (`List [modified]);
    let inode = (Unix.lstat (snapshot_path root)).st_ino in
    assert_wrapped_refusals_preserve_guest root original inode (List.length (calls root))))
    [(fun init -> replace "arguments" (strings ["-f"; "/foreign/file"]) init)
    ; (fun init -> replace "executable" (`String "opam")
        (replace "arguments" (strings ["exec"; "--"; "tail"; "-f"; "/dev/null"]) init))]

let test_unavailable_image_metadata_preserves_wrapped_guest () =
  List.iter (fun unavailable -> with_fixture (fun root ->
    wrapped_image root;
    boot root;
    let original = read (Filename.concat root "guest.json") in
    let inode = (Unix.lstat (snapshot_path root)).st_ino in
    unavailable root;
    assert_wrapped_refusals_preserve_guest root original inode (List.length (calls root))))
    [(fun root -> write (Filename.concat root "image-inspect-override") "not-json")
    ; (fun root -> save_json (Filename.concat root "image-inspect-override")
        (`List [`Assoc ["id", `String (String.make 64 'a');
          "configuration", `Assoc ["name", `String "fixture:image";
          "descriptor", `Assoc ["digest", `String image_digest]]; "variants", `List []]]))
    ; (fun root -> write (Filename.concat root "image-inspect-fails") "")]

let test_attached_endpoint_uses_host_snapshot_without_cleanup () = with_fixture @@ fun root ->
  boot root;
  let original = read (Filename.concat root "guest.json") in
  let before = calls root |> List.length in
  check bool "fresh attached process reaches shim" true (step root "attached" = Unix.WEXITED 0);
  let after = calls root |> List.drop before in
  check bool "attached reader only observes the guest and issues exec calls" true
    (List.for_all (function ("inspect" | "exec") :: _ -> true | _ -> false) after);
  check int "attached reader observes the guest once" 1
    (List.length (List.filter (function "inspect" :: _ -> true | _ -> false) after));
  let execs = List.filter (function "exec" :: _ -> true | _ -> false) after in
  let probes, payloads = List.partition (List.mem "--probe") execs in
  check int "one actual protocol negotiation" 1 (List.length probes);
  check int "one actual requested payload dispatch" 1 (List.length payloads);
  check string "attached reader preserves guest" original (read (Filename.concat root "guest.json"));
  let last = List.hd (List.rev (entries root "requests")) in
  check (list string) "reader did not run first-handoff cleanup" ["/bin/true"]
    (match field "argv" last with `List values -> List.map text values | _ -> fail "missing request argv")

let test_unknown_or_disagreeing_facts_never_churn () =
  List.iter (fun mutation -> with_fixture (fun root ->
    boot root;
    let original = json (Filename.concat root "guest.json") in
    let override = mutation original in
    save_json (Filename.concat root "inspect-override") override;
    let before = calls root |> List.length in
    List.iter (fun () -> check bool "refusal is repeatable" true (step root "turn" = Unix.WEXITED 2)) [(); ()];
    let after = calls root |> List.drop before in
    let expected = ["inspect"; text (field "id" original)] in
    let inspections = List.filter (function "inspect" :: _ -> true | _ -> false) after in
    check (list (list string)) "both refusals reached the exact guest inspect" [expected; expected] inspections;
    check bool "bad facts cause only reads" true
      (List.for_all (function ["image"; "inspect"; "fixture:image"] -> true
        | "inspect" :: _ -> true | _ -> false) after);
    check bool "original guest survives refusal" true (Sys.file_exists (Filename.concat root "guest.json"))))
    [ (fun row -> `List [match row with `Assoc fields -> `Assoc
        (List.map (fun (key,v) -> if key = "status" then key, `Assoc ["state", `String "unknown"] else key,v) fields)
        | _ -> row])
    ; (fun row -> `List [match row with `Assoc fields -> `Assoc (List.map (fun (key,v) ->
        if key = "configuration" then key, (match v with `Assoc config -> `Assoc (List.map (fun (key,v) ->
          if key = "resources" then key, `Assoc ["cpus", `Int 999; "memoryInBytes", `Int 2147483648] else key,v) config) | _ -> v)
        else key,v) fields) | _ -> row])
    ; (fun row -> `List [match row with `Assoc fields -> `Assoc (List.map (fun (key,v) ->
        if key = "id" then key, `String "foreign"
        else if key = "status" then key, `Assoc ["state", `String "stopped"]
        else if key = "configuration" then key, (match v with `Assoc config ->
          `Assoc (List.map (fun (key,v) -> if key = "id" then key, `String "foreign" else key,v) config)
          | _ -> v)
        else key,v) fields) | _ -> row]) ]

let configure_identity root token =
  let config = Workspace.default_config root in
  let keepers = Workspace.keepers_runtime_dir config in
  if not (Sys.file_exists keepers) then Unix.mkdir keepers 0o700;
  let directory = value (Keeper_github_identity.ensure_config_dir ~config ~keeper_name:keeper) in
  let hosts = "github.com:\n    user: fixture\n    oauth_token: " ^ token ^ "\n    git_protocol: https\n" in
  write (Filename.concat directory "hosts.yml") hosts;
  Unix.chmod (Filename.concat directory "hosts.yml") 0o600;
  directory, hosts

let assert_no_foreign_guest_effects operations =
  check bool "no guest or volume effect followed the foreign observation" true
    (List.for_all (function
      | ("stop" | "delete" | "run" | "exec") :: _ -> false
      | "volume" :: ("delete" | "create") :: _ -> false
      | [] | _ :: _ -> true) operations)

let test_foreign_apple_guest_is_preserved () =
  List.iter (fun (operation, state) -> with_fixture (fun root ->
    boot root;
    let guest_path = Filename.concat root "guest.json" in
    save_json guest_path (foreign_guest (json guest_path) ~state);
    let original = read guest_path in
    let snapshot_inode = (Unix.lstat (snapshot_path root)).Unix.st_ino in
    let work = value (Microvm.work_volume_name ~keeper_name:keeper) in
    let build = value (Microvm.build_volume_name ~keeper_name:keeper) in
    let images = List.map (fun name ->
      let path = Filename.concat root (name ^ ".img") in path, read path) [work; build] in
    let before = List.length (calls root) in
    let status, stderr = step_captured root operation in
    check bool (operation ^ " refuses foreign " ^ state) true (status = Unix.WEXITED 2);
    check bool "refusal identifies the guest ownership boundary" true
      (Astring.String.is_infix ~affix:"microvm_guest_ownership_unverified" stderr);
    assert_no_foreign_guest_effects (calls root |> List.drop before);
    check string "foreign guest bytes are preserved" original (read guest_path);
    check int "credential snapshot remains" snapshot_inode (Unix.lstat (snapshot_path root)).Unix.st_ino;
    List.iter (fun (path, bytes) -> check string "volume bytes are preserved" bytes (read path)) images))
    ["turn", "running"; "turn", "stopped"; "teardown", "running";
     "teardown", "stopped"; "attached", "running"; "attached", "stopped";
     "cleanup-attached", "running"; "override", "running"; "override", "stopped"]

let test_unverifiable_apple_guest_labels_are_preserved () =
  let open Keeper_sandbox_runtime_setup in
  let owner_keys =
    [sandbox_component_label_key; sandbox_base_path_hash_label_key;
     sandbox_keeper_label_key; sandbox_kind_label_key; sandbox_network_label_key;
     Microvm.microvm_backend_label_key] in
  let remove key = function
    | `Assoc fields -> `Assoc (List.remove_assoc key fields)
    | _ -> fail "fixture labels are not an object" in
  let duplicate key = function
    | `Assoc fields -> `Assoc ((key, `String "different") :: fields)
    | _ -> fail "fixture labels are not an object" in
  let cases =
    List.concat_map (fun key ->
      ["missing " ^ key, remove key, "microvm_guest_ownership_unverified";
       "different " ^ key, replace key (`String "different"), "microvm_guest_ownership_unverified"]) owner_keys
    @ ["duplicate owner key", duplicate sandbox_base_path_hash_label_key, "container inspect: invalid or missing labels";
       "non-string owner value", replace sandbox_base_path_hash_label_key (`Int 42), "container inspect: invalid or missing labels";
       "non-object labels", (fun _ -> `String "invalid"), "container inspect: invalid or missing labels"] in
  List.iter (fun operation -> with_fixture (fun root ->
    boot root;
    let guest_path = Filename.concat root "guest.json" in
    let pristine_guest = json guest_path in
    let guest = text (field "id" pristine_guest) in
    List.iter (fun (description, change, diagnostic) ->
      save_json guest_path (guest_with_labels pristine_guest change);
      let original = read guest_path in
      let snapshot_inode = (Unix.lstat (snapshot_path root)).Unix.st_ino in
      let before = List.length (calls root) in
      let status, stderr = step_captured root operation in
      check bool (operation ^ " refuses " ^ description) true (status = Unix.WEXITED 2);
      check bool (operation ^ " names the expected ownership boundary for " ^ description) true
        (Astring.String.is_infix ~affix:diagnostic stderr);
      let observed = calls root |> List.drop before in
      check bool (operation ^ " inspects the named guest for " ^ description) true
        (List.mem ["inspect"; guest] observed);
      assert_no_foreign_guest_effects observed;
      check string "guest with unverifiable labels is preserved" original (read guest_path);
      check int "credential snapshot remains" snapshot_inode (Unix.lstat (snapshot_path root)).Unix.st_ino) cases))
    ["turn"; "teardown"; "attached"]

let test_foreign_guest_during_identity_refresh_is_preserved () = with_fixture @@ fun root ->
  ignore (configure_identity root "first-fixture-token");
  boot root;
  let inode = (Unix.lstat (snapshot_path root)).Unix.st_ino in
  let status, stderr = step_captured root "identity-foreign" in
  check bool "identity refresh refuses foreign guest" true (status = Unix.WEXITED 2);
  check bool "identity refresh names the owner boundary" true
    (Astring.String.is_infix ~affix:"microvm_guest_ownership_unverified" stderr);
  let before = int_of_string (read (Filename.concat root "foreign-refresh-start-index")) in
  assert_no_foreign_guest_effects (calls root |> List.drop before);
  check string "foreign guest survives refresh" (read (Filename.concat root "foreign-expected"))
    (read (Filename.concat root "guest.json"));
  check int "original credential snapshot remains" inode (Unix.lstat (snapshot_path root)).Unix.st_ino

let test_running_endpoint_rechecks_foreign_guest () = with_fixture @@ fun root ->
  boot root;
  let inode = (Unix.lstat (snapshot_path root)).Unix.st_ino in
  let status, stderr = step_captured root "running-foreign" in
  check bool "cached runtime refuses foreign guest" true (status = Unix.WEXITED 2);
  check bool "refusal names the owner boundary" true
    (Astring.String.is_infix ~affix:"microvm_guest_ownership_unverified" stderr);
  let before = int_of_string (read (Filename.concat root "foreign-running-start-index")) in
  let after = calls root |> List.drop before in
  let guest = text (field "id" (json (Filename.concat root "guest.json"))) in
  check bool "the cached endpoint observes the current guest" true (List.mem ["inspect"; guest] after);
  assert_no_foreign_guest_effects after;
  check string "foreign guest remains unchanged" (read (Filename.concat root "foreign-expected"))
    (read (Filename.concat root "guest.json"));
  check int "credential snapshot remains" inode (Unix.lstat (snapshot_path root)).Unix.st_ino

let test_absent_teardown_reacquires_with_fresh_scoped_readiness () = with_fixture @@ fun root ->
  let status, stderr = step_captured root "absent-reacquire" in
  (match status with
   | Unix.WEXITED 0 -> ()
   | _ -> failf "same-process absent teardown and reacquisition failed: %s" stderr);
  check int "the provider booted only once" 1 (count "run" root);
  check int "confirmed absence caused no stop" 0 (count "stop" root);
  check int "confirmed absence caused no delete" 0 (count "delete" root);
  check int "same process performed first handoff again" 2 (List.length (entries root "requests"))

let test_checkout_observation_invalidates_before_reacquisition () =
  List.iter (fun operation -> with_fixture (fun root ->
    let status, stderr = step_captured root operation in
    (match status with Unix.WEXITED 0 -> () | _ -> failf "%s failed: %s" operation stderr);
    check int "one provider boot" 1 (count "run" root);
    check int "checkout never stops a guest" 0 (count "stop" root);
    check int "checkout never deletes a guest" 0 (count "delete" root);
    check int "only confirmed absence or stop requires a fresh first handoff"
      (if operation = "checkout-unknown" then 1 else 2)
      (List.length (entries root "requests"))))
    ["checkout-absent"; "checkout-stopped"; "checkout-unknown"; "read-stopped"]

let test_checkout_observation_cannot_late_forget_handoff () = with_fixture @@ fun root ->
  let status, stderr = step_captured root "checkout-race" in
  (match status with Unix.WEXITED 0 -> () | _ -> failf "checkout race failed: %s" stderr);
  check bool "the fake provider held an old inspect" true (Sys.file_exists (Filename.concat root "inspect-held"));
  check int "the replacement receives its own first handoff" 2 (List.length (entries root "requests"));
  check int "race does not stop a guest" 0 (count "stop" root);
  check int "race does not delete a guest" 0 (count "delete" root)

let test_captured_authority_rechecks_sequential_replacement () = with_fixture @@ fun root ->
  let status, stderr = step_captured root "authority-collision" in
  (match status with Unix.WEXITED 0 -> () | _ -> failf "captured authority fixture failed: %s" stderr);
  check int "both owners boot their own guest" 2 (count "run" root);
  check int "only A is stopped during its normal teardown" 1 (count "stop" root);
  check int "only A is deleted during its normal teardown" 1 (count "delete" root)

let test_legacy_review_binding_and_live_revision_guard () = with_fixture @@ fun root ->
  ignore (configure_identity root "first-fixture-token");
  let status, stderr = step_captured root "authority-revision" in
  (match status with Unix.WEXITED 0 -> () | _ -> failf "review identity fixture failed: %s" stderr);
  check int "identity refresh starts the replacement" 2 (count "run" root);
  check int "identity refresh stops the first guest" 1 (count "stop" root);
  check int "identity refresh deletes the first guest" 1 (count "delete" root)

let test_review_continues_when_guest_is_unavailable () =
  List.iter (fun operation -> with_fixture (fun root ->
    ignore (configure_identity root "first-fixture-token");
    let status, stderr = step_captured root operation in
    (match status with Unix.WEXITED 0 -> () | _ -> failf "%s failed: %s" operation stderr);
    check int "review fixture boots only its own guest" 1 (count "run" root);
    check int "review fixture never stops a guest" 0 (count "stop" root);
    check int "review fixture never deletes a guest" 0 (count "delete" root)))
    ["review-stopped"; "review-inspect-unavailable"]

let test_attached_reader_does_not_reread_central_identity () = with_fixture @@ fun root ->
  let central, hosts = configure_identity root "first-fixture-token" in
  boot root;
  write (Filename.concat central "hosts.yml") "malformed: [central identity is unavailable";
  check bool "attached reader admits validated host snapshot" true (step root "attached" = Unix.WEXITED 0);
  check string "exact host snapshot credential bytes survive central failure" hosts
    (read (Filename.concat (snapshot_path root) "hosts.yml"));
  check int "attached read cannot replace guest" 1 (count "run" root)

let test_identity_refresh_replaces_after_actual_absence () = with_fixture @@ fun root ->
  ignore (configure_identity root "first-fixture-token");
  boot root;
  let _, updated = configure_identity root "second-fixture-token" in
  check bool "authorized turn identity refresh completes" true (step root "prepare-identity" = Unix.WEXITED 0);
  check int "one replacement boot only" 2 (count "run" root);
  check int "one current guest stop" 1 (count "stop" root);
  check string "replacement mounts the refreshed immutable bytes" updated
    (read (Filename.concat (snapshot_path root) "hosts.yml"))

let test_identity_refresh_preserves_guest_if_helper_appears () = with_fixture @@ fun root ->
  ignore (configure_identity root "first-fixture-token");
  boot root;
  let original = read (Filename.concat root "guest.json") in
  let inode = (Unix.lstat (snapshot_path root)).st_ino in
  let status, stderr = step_captured root "identity-helper-race" in
  check bool "refresh refuses a helper appearing after adoption" true (status = Unix.WEXITED 2);
  check bool "the helper gate supplied the refresh refusal" true
    (Astring.String.is_infix ~affix:"microvm_volume_helper_ownership_unverified" stderr);
  check bool "the guest boundary reports it, not the identity" true
    (Astring.String.is_infix ~affix:"sandbox_unavailable: " stderr
     && not (Astring.String.is_infix ~affix:"identity_unavailable: " stderr));
  check bool "fixture reached the second identity revision" true
    (Sys.file_exists (Filename.concat root "list-override"));
  check string "the old guest stays running" original (read (Filename.concat root "guest.json"));
  check int "the old host credential snapshot is preserved" inode (Unix.lstat (snapshot_path root)).st_ino;
  check int "refresh did not stop the guest" 0 (count "stop" root);
  check int "refresh did not delete a guest or helper" 0 (count "delete" root);
  check int "refresh did not start a replacement" 1 (count "run" root)

let test_boot_refused_for_unusable_identity_reports_the_identity () = with_fixture @@ fun root ->
  let central, _ = configure_identity root "first-fixture-token" in
  write (Filename.concat central "hosts.yml") "malformed: [central identity is unavailable";
  let status, stderr = step_captured root "prepare-identity" in
  check bool "a boot with an unusable identity is refused" true (status = Unix.WEXITED 2);
  check bool "the identity reports it, not the guest boundary" true
    (Astring.String.is_infix ~affix:"identity_unavailable: " stderr
     && not (Astring.String.is_infix ~affix:"sandbox_unavailable: " stderr));
  check int "no guest was started for it" 0 (count "run" root)

let test_endpoint_uses_effective_network_override () = with_fixture @@ fun root ->
  check bool "runtime override reaches matching host snapshot" true (step root "override" = Unix.WEXITED 0);
  check bool "second process adopts override guest" true (step root "override" = Unix.WEXITED 0);
  check int "override does not cause repeated boots" 1 (count "run" root);
  let actual = Keeper_microvm_github_identity.host_path ~base_path:root ~keeper_name:keeper
      ~backend ~network_mode:Profile.Network_inherit in
  check bool "effective snapshot exists" true (Sys.file_exists actual);
  check bool "metadata default cannot select a different snapshot" false (Sys.file_exists (snapshot_path root))

let test_uncertain_postboot_retains_guest_and_recovers_without_replay () =
  List.iter (fun inventory_fails -> with_fixture (fun root ->
    write (Filename.concat root "inspect-fails-after-run") "";
    if inventory_fails then write (Filename.concat root "inventory-fails-after-run") "";
    check bool "uncertain boot is refused" true (step root "turn" = Unix.WEXITED 2);
    check bool "possibly mounted immutable snapshot survives" true (Sys.file_exists (snapshot_path root));
    check bool "possibly running guest survives" true (Sys.file_exists (Filename.concat root "guest.json"));
    check int "unknown result causes no stop" 0 (count "stop" root);
    check int "unknown result causes no delete" 0 (count "delete" root);
    Unix.unlink (Filename.concat root "inspect-fails-after-run");
    if inventory_fails then Unix.unlink (Filename.concat root "inventory-fails-after-run");
    check bool "later process adopts after actual facts recover" true (step root "turn" = Unix.WEXITED 0);
    check int "original run is never replayed" 1 (count "run" root))) [false; true]

let test_unreadable_inventory_never_authorizes_a_boot () = with_fixture @@ fun root ->
  write (Filename.concat root "list-override") "[{}]";
  check bool "unknown inventory refuses creation" true (step root "turn" = Unix.WEXITED 2);
  let config = Workspace.default_config root in
  let guest = Turn.For_testing_microvm.microvm_container_name ~config ~keeper_name:keeper ~network_mode in
  check (list (list string)) "failure reached actual complete inventory"
    [["inspect"; guest]; ["list"; "--all"; "--format"; "json"]] (calls root);
  check int "no run" 0 (count "run" root);
  check int "no stop" 0 (count "stop" root);
  check int "no delete" 0 (count "delete" root);
  check bool "no credential publication" false (Sys.file_exists (snapshot_path root))

let test_unverified_work_mount_blocks_handoff () =
  List.iter (fun (marker, error) -> List.iter (fun warm -> with_fixture (fun root ->
    let request_count () =
      if Sys.file_exists (Filename.concat root "requests")
      then List.length (entries root "requests") else 0 in
    let original_guest =
      if warm then (boot root; Some (read (Filename.concat root "guest.json"))) else None in
    let before_calls = List.length (calls root) in
    let before_requests = request_count () in
    write (Filename.concat root marker) "";
    check bool "unconfirmed work mount refuses adoption" true (step root "turn" = Unix.WEXITED 2);
    check bool "the refusal identifies the mount observation" true
      (String.starts_with ~prefix:("microvm_start_failed: " ^ error) (read (Filename.concat root "step-error")));
    let config = Workspace.default_config root in
    let guest = Turn.For_testing_microvm.microvm_container_name ~config ~keeper_name:keeper ~network_mode in
    let without_cli = function
      | "container" :: arguments -> arguments
      | [] | _ :: _ -> fail "expected Apple Container argv" in
    let probe = Microvm.work_volume_mounted_probe_argv_for backend ~container_name:guest |> without_cli in
    let mkdir = Microvm.keeper_work_root_mkdir_argv_for backend ~container_name:guest ~keeper_name:keeper |> without_cli in
    let operations = calls root |> List.drop before_calls in
    check bool "the exact work mount probe ran" true (List.mem probe operations);
    check bool "no keeper root is created after refusal" false (List.mem mkdir operations);
    check int "no new framed shim request is sent" before_requests (request_count ());
    check bool "the refused guest remains available" true (Sys.file_exists (Filename.concat root "guest.json"));
    Option.iter (fun original -> check string "the existing guest is preserved" original
      (read (Filename.concat root "guest.json"))) original_guest;
    check int "one boot total" 1 (count "run" root);
    check bool "no stop or delete after refusal" true
      (List.for_all (function ("stop" | "delete") :: _ -> false | [] | _ :: _ -> true) operations))) [false; true])
    ["work-mount-absent", "microvm_work_volume_not_mounted:"
    ; "work-mount-unverified", "microvm_work_volume_probe_unverified:"]

let () =
  match Array.to_list Sys.argv with
  | _ :: "--provider" :: root :: arguments -> provider root arguments
  | [_; "--step"; root; operation] -> process_step root operation
  | _ -> run "guest survival runtime against provider process fixture"
      ["process boundaries", [
        test_case "absent discard never runs legacy helper" `Quick test_absent_discard_never_runs_the_legacy_helper;
        test_case "postboot helper refusal preserves the new guest" `Quick test_postboot_helper_refusal_preserves_the_new_guest;
        test_case "uncertain postboot recovers without replay" `Quick test_uncertain_postboot_retains_guest_and_recovers_without_replay;
        test_case "unreadable inventory refuses boot" `Quick test_unreadable_inventory_never_authorizes_a_boot;
        test_case "unverified work mount blocks cold and warm handoff" `Quick test_unverified_work_mount_blocks_handoff;
        test_case "effective network override selects its host snapshot" `Quick test_endpoint_uses_effective_network_override;
        test_case "foreign Apple guests are preserved" `Quick test_foreign_apple_guest_is_preserved;
        test_case "unverifiable Apple guest labels are preserved" `Quick test_unverifiable_apple_guest_labels_are_preserved;
        test_case "foreign guest survives identity refresh" `Quick test_foreign_guest_during_identity_refresh_is_preserved;
        test_case "running endpoint rechecks foreign guest" `Quick test_running_endpoint_rechecks_foreign_guest;
        test_case "absent teardown invalidates scoped readiness" `Quick test_absent_teardown_reacquires_with_fresh_scoped_readiness;
        test_case "checkout observations preserve the handoff boundary" `Quick test_checkout_observation_invalidates_before_reacquisition;
        test_case "checkout observation cannot invalidate a newer handoff" `Quick test_checkout_observation_cannot_late_forget_handoff;
        test_case "captured authority rechecks a sequential replacement" `Quick test_captured_authority_rechecks_sequential_replacement;
        test_case "legacy review binding and live revision guard" `Quick test_legacy_review_binding_and_live_revision_guard;
        test_case "review continues when guest observation is unavailable" `Quick test_review_continues_when_guest_is_unavailable;
        test_case "attached reader never rereads central identity" `Quick test_attached_reader_does_not_reread_central_identity;
        test_case "identity refresh follows actual guest absence" `Quick test_identity_refresh_replaces_after_actual_absence;
        test_case "identity refresh preserves guest if helper appears" `Quick test_identity_refresh_preserves_guest_if_helper_appears;
        test_case "boot refused for an unusable identity names the identity" `Quick test_boot_refused_for_unusable_identity_reports_the_identity;
        test_case "fresh process adopts without boot effects" `Quick test_fresh_process_adopts_without_boot_effects;
        test_case "failed scan retries next turn without repeating handoff" `Quick test_scan_failure_retries_on_the_next_turn_without_repeating_handoff;
        test_case "uncertain link effect is not replayed" `Quick test_uncertain_link_effect_is_not_replayed_in_the_same_process;
        test_case "failed replacement keeps uncertain build effect" `Quick test_failed_replacement_keeps_uncertain_build_effect;
        test_case "build effect failure is not replayed" `Quick test_build_effect_failure_is_not_replayed_in_the_same_process;
        test_case "differently targeted build link is preserved without effects" `Quick test_differently_targeted_build_link_is_preserved_without_effects;
        test_case "real build warnings reach the actual scan path" `Quick test_real_build_warning_on_the_actual_scan_path;
        test_case "invalid or oversized scan dispatches no link effects" `Quick test_invalid_or_oversized_scan_never_dispatches_link_effects;
        test_case "forgotten guest rejects old scan completion" `Quick test_forgotten_guest_rejects_old_scan_completion;
        test_case "helper uncertainty preserves guest on adopt and replace" `Quick test_helper_uncertainty_preserves_guest_on_adopt_and_replace;
        test_case "wrapped image adopts without relabelling or boot effects" `Quick test_wrapped_image_adopts_without_relabelling_or_boot_effects;
        test_case "image prefix does not permit command tampering" `Quick test_image_prefix_does_not_permit_command_tampering;
        test_case "unavailable image metadata preserves wrapped guest" `Quick test_unavailable_image_metadata_preserves_wrapped_guest;
        test_case "attached reader never performs handoff cleanup" `Quick test_attached_endpoint_uses_host_snapshot_without_cleanup;
        test_case "uncertain or disagreeing facts preserve guest repeatedly" `Quick test_unknown_or_disagreeing_facts_never_churn]]
