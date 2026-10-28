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
let keeper = "guest-survival-fixture"
let backend = Backend.Apple_container
let network_mode = Profile.Network_none

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
    | ("--name" | "--user" | "--memory" | "--cpus" | "--workdir" | "--network" | "--dns") as key :: v :: rest ->
      Hashtbl.replace one key v; flags rest
    | ("--label" | "--env" | "-e" | "-v" | "--volume" | "--tmpfs" | "--cap-drop" | "--cap-add") as key :: v :: rest ->
      add key v; flags rest
    | image :: command -> image, command
    | [] -> fail "provider did not receive an image"
  in
  let image, explicit_command = flags arguments in
  (* This is the provider's OCI execution behavior, independently observed
     from its own image config, rather than the product's expected command. *)
  let command = image_entrypoint root @ explicit_command in
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

let provider root args =
  let file name = Filename.concat root name in
  append (file "calls") (strings args);
  let answer value = print_string (Yojson.Safe.to_string value); flush stdout in
  let guest_rows () = if Sys.file_exists (file "guest.json") then [json (file "guest.json")] else [] in
  match args with
  | "inspect" :: name :: _ ->
    if Sys.file_exists (file "inspect-fails-after-run") && guest_rows () <> [] then exit 1;
    (match guest_rows () with
     | [row] when field "id" row = `String name ->
       if Sys.file_exists (file "inspect-override") then print_string (read (file "inspect-override"))
       else answer (`List [row])
     | [] | [_] -> exit 1 | _ -> fail "provider invalid rows")
  | ["list"; "--all"; "--format"; "json"] ->
    if Sys.file_exists (file "inventory-fails-after-run") && guest_rows () <> [] then exit 1;
    if Sys.file_exists (file "list-override") then print_string (read (file "list-override"))
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
    Bytes.set_int32_le bytes (1024 + 0x100) 0x0400l;
    write (file (name ^ ".img")) (Bytes.to_string bytes)
  | "run" :: rest ->
    if not (List.mem "-d" rest) then fail "discard-set volume must never start a helper";
    save_json (file "guest.json") (inspect_from_run root rest)
  | "stop" :: _ -> ()
  | "delete" :: rest ->
    (match guest_rows () with
     | [row] when List.mem (text (field "id" row)) rest -> Unix.unlink (file "guest.json")
     | [] | [_] -> () | _ -> fail "provider invalid rows")
  | "exec" :: rest ->
    if List.mem "--probe" rest then (
      print_string (Exec_ssh_protocol.render_probe {name="masc-exec-shim"; version="3.0.0"; capabilities=[]; release=None; boot_id=None});
      flush stdout)
    else if List.mem Microvm.shim_guest_path rest then (
      let header = read_exact Unix.stdin 8 in
      let length = Bytes.get_int64_be (Bytes.of_string header) 0 |> Int64.to_int in
      let request, _ = value (Exec_ssh_protocol.decode_request (header ^ read_exact Unix.stdin length)) in
      append (file "requests") (`Assoc ["argv", strings request.argv;
        "environment", `Assoc (List.map (fun (key,v) -> key, `String v) request.env)]);
      let execution_receipt : Exec_ssh_protocol.execution_receipt = {mode=request.mode; boundary=Sandbox_applied} in
      output_string stderr (Exec_ssh_protocol.render_trailer ~execution_receipt
        {v=request.v; exit=Some 0; signal=None; timed_out=false; shim_error=None; observed_syscalls=[]});
      flush stderr)
  | _ -> fail ("unsupported provider command " ^ String.concat " " args)

let meta () =
  let meta = value (Masc_test_deps.meta_of_json_fixture
      (`Assoc ["name", `String keeper; "trace_id", `String "survival-process-fixture"])) in
  {meta with sandbox_profile=Profile.Micro_vm; microvm_backend=Some backend; network_mode}

let process_step root operation =
  (* This provider fixture opens no network. Declare its resolver explicitly
     instead of inheriting a host-only systemd resolver in Linux CI. *)
  Unix.putenv "MASC_KEEPER_MICROVM_DNS" "192.0.2.53";
  Eio_main.run @@ fun env ->
  let fs = Eio.Stdenv.fs env in
  Fs_compat.set_fs fs;
  Process_eio.init ~cwd_default:Eio.Path.(fs / root)
    ~proc_mgr:(Eio.Stdenv.process_mgr env) ~clock:(Eio.Stdenv.clock env);
  let config = Workspace.default_config root in
  value (Keeper_microvm_shim_readiness.initialize ~base_path:root ~payload_path:"/usr/bin:/bin"
    |> Result.map_error Keeper_microvm_shim_readiness.error_message);
  let effective_network = if operation = "override" then Profile.Network_inherit else network_mode in
  let runtime = Turn.create ~config ~meta:(meta ()) ~image:(Ok "fixture:image") ~network_mode:effective_network () in
  let endpoint = match operation with
    | "attached" -> Turn.microvm_attached_endpoint ~config ~meta:(meta ()) ()
    | "prepare-identity" -> Result.bind (Turn.prepare_github_identity_secret_files ~timeout_sec:10. runtime)
        (fun _ -> Turn.microvm_remote_endpoint ~timeout_sec:10. runtime)
    | "turn" | "override" -> Turn.microvm_remote_endpoint ~timeout_sec:10. runtime
    | _ -> fail "unknown fixture step" in
  (match endpoint with
   | Error detail -> prerr_endline detail; exit 2
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
let entries root name = read (Filename.concat root name) |> String.split_on_char '\n'
  |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string
let calls root = entries root "calls" |> List.map (function
  | `List items -> List.map text items | _ -> fail "bad provider log")
let count operation root = calls root |> List.filter (function first :: _ -> first = operation | [] -> false) |> List.length
let boot root = check bool "cold process completed real boot path against provider fixture" true (step root "turn" = Unix.WEXITED 0)
let snapshot_path root = Keeper_microvm_github_identity.host_path ~base_path:root ~keeper_name:keeper ~backend ~network_mode
let adoption_read = function
  | ["image"; "inspect"; "fixture:image"] -> true
  | ("inspect" | "exec") :: _ -> true
  | _ -> false

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

let wrapped_image root = save_json (Filename.concat root "image-entrypoint")
    (strings ["opam"; "exec"; "--"])

let test_wrapped_image_adopts_without_relabelling_or_boot_effects () = with_fixture @@ fun root ->
  wrapped_image root;
  boot root;
  let original = read (Filename.concat root "guest.json") in
  let init = field "configuration" (Yojson.Safe.from_string original) |> field "initProcess" in
  check string "provider applies its actual image entrypoint" "opam" (text (field "executable" init));
  check (list string) "image Cmd is replaced by explicit Keeper argv"
    ["exec"; "--"; "tail"; "-f"; "/dev/null"]
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

let replace key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> fail "fixture replacement requires an object"

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
  check int "refusal preserves the mounted snapshot inode" inode (Unix.lstat (snapshot_path root)).st_ino;
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
    [(fun init -> replace "arguments" (strings ["exec"; "--"; "tail"; "-f"; "/foreign/file"]) init)
    ; (fun init -> replace "executable" (`String "tail")
        (replace "arguments" (strings ["-f"; "/dev/null"]) init))]

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

let test_attached_endpoint_uses_mounted_identity_without_cleanup () = with_fixture @@ fun root ->
  boot root;
  let original = read (Filename.concat root "guest.json") in
  let before = calls root |> List.length in
  check bool "fresh attached process reaches shim" true (step root "attached" = Unix.WEXITED 0);
  let after = calls root |> List.drop before in
  check bool "attached reader issues only exec calls" true
    (List.for_all (function "exec" :: _ -> true | _ -> false) after);
  let probes, payloads = List.partition (List.mem "--probe") after in
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

let test_attached_reader_does_not_reread_central_identity () = with_fixture @@ fun root ->
  let central, hosts = configure_identity root "first-fixture-token" in
  boot root;
  write (Filename.concat central "hosts.yml") "malformed: [central identity is unavailable";
  check bool "attached reader admits validated mounted identity" true (step root "attached" = Unix.WEXITED 0);
  check string "exact mounted credential bytes survive central failure" hosts
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

let test_endpoint_uses_effective_network_override () = with_fixture @@ fun root ->
  check bool "runtime override reaches matching mounted snapshot" true (step root "override" = Unix.WEXITED 0);
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

let () =
  match Array.to_list Sys.argv with
  | _ :: "--provider" :: root :: arguments -> provider root arguments
  | [_; "--step"; root; operation] -> process_step root operation
  | _ -> run "guest survival runtime against provider process fixture"
      ["process boundaries", [
        test_case "uncertain postboot recovers without replay" `Quick test_uncertain_postboot_retains_guest_and_recovers_without_replay;
        test_case "unreadable inventory refuses boot" `Quick test_unreadable_inventory_never_authorizes_a_boot;
        test_case "effective network override selects its mounted identity" `Quick test_endpoint_uses_effective_network_override;
        test_case "attached reader never rereads central identity" `Quick test_attached_reader_does_not_reread_central_identity;
        test_case "identity refresh follows actual guest absence" `Quick test_identity_refresh_replaces_after_actual_absence;
        test_case "fresh process adopts without boot effects" `Quick test_fresh_process_adopts_without_boot_effects;
        test_case "wrapped image adopts without relabelling or boot effects" `Quick test_wrapped_image_adopts_without_relabelling_or_boot_effects;
        test_case "image prefix does not permit command tampering" `Quick test_image_prefix_does_not_permit_command_tampering;
        test_case "unavailable image metadata preserves wrapped guest" `Quick test_unavailable_image_metadata_preserves_wrapped_guest;
        test_case "attached reader never performs handoff cleanup" `Quick test_attached_endpoint_uses_mounted_identity_without_cleanup;
        test_case "uncertain or disagreeing facts preserve guest repeatedly" `Quick test_unknown_or_disagreeing_facts_never_churn]]
