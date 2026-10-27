(* RFC play-link-for-the-shared-machine §2.7: the attached DOS machine's
   Skills reach an invited agent through the link. The installation is real
   Lane runtime state, declared or attached by hand; only its worker is a
   fixture that lists the DOS screen tool. Its Skills are published the way
   the server publishes them: reconciliation hands them to
   [Server_skill_snapshot_runtime.publish_lane_skills]. *)

open Alcotest
module Lane = Masc.Lane_addon_runtime
module Guide = Server_routes_http_routes_play_guide
module Service = Skill_catalog_snapshot_service

let public_base = "https://play.example"
let screen_tool = Machine_controller_contract.(dos_tool_name Dos_screen)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Unix.chmod path 0o755;
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | { Unix.st_kind = Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ } ->
    Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let read_file path = In_channel.with_open_bin path In_channel.input_all

let write_file path contents =
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel contents)

let contains ~sub s =
  let n = String.length sub and m = String.length s in
  let rec at i = i + n <= m && (String.sub s i n = sub || at (i + 1)) in
  at 0

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"

(* One GET through the real router the server mounts the guide on. *)
let dispatch_get ~state ~target ~token =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Guide.add_routes (Masc.Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 4096 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf "GET %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: http://127.0.0.1:8935\r\n%s\r\n"
        target
        (match token with
         | Some token -> Printf.sprintf "Authorization: Bearer %s\r\n" token
         | None -> "")
    in
    let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str in
    ignore (Httpun.Server_connection.read_eof conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
              Buffer.add_string response_buf (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
              total + iov.len)
            0 iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)

let split_response response =
  let separator = "\r\n\r\n" in
  let rec find i =
    if i + 4 > String.length response then failf "no body in %S" response
    else if String.sub response i 4 = separator then i
    else find (i + 1)
  in
  let at = find 0 in
  String.sub response 0 at, String.sub response (at + 4) (String.length response - at - 4)

let status_of response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | [] | [ _ ] -> failf "could not parse response status: %S" response

let header name head =
  let prefix = String.lowercase_ascii name ^ ":" in
  String.split_on_char '\n' head
  |> List.find_map (fun line ->
    let line = String.trim line in
    if String.length line > String.length prefix
       && String.lowercase_ascii (String.sub line 0 (String.length prefix)) = prefix
    then Some (String.trim (String.sub line (String.length prefix) (String.length line - String.length prefix)))
    else None)

let refusal_code response =
  match Yojson.Safe.from_string (snd (split_response response)) with
  | `Assoc fields -> List.assoc_opt "code" fields
  | _ -> None

let unwrap = function Ok value -> value | Error message -> fail message

(* A package of its own, so a large real guide cannot break the test. *)
let manifest =
  Printf.sprintf {|id = "dos-guides-fixture"
revision = "fixture-1"
title = "DOS guides fixture"
image = "fixture/dos-guides"
command = ["worker"]
contributions = ["observe"]
[world.skills]
directory = "skills"
[world.tools]
invocation = "host_context"
export = [%S]
[resources]
cpus = 1.0
memory_bytes = 536870912
pids = 32
max_reply_bytes = 4194304
|} screen_tool

let game = "fixture-game"
let machine = "fixture-machine"
let game_description = "Fixture game played in the invite link test."
let machine_description = "Fixture machine rules for the invite link test."
let reference_files = [ "keys.md"; "menu.md" ]

let skill_document name description body =
  Printf.sprintf "---\nname: %s\ndescription: %s\n---\n%s" name description body

let package_files =
  [ "lane.toml", manifest
  ; "skills/" ^ game ^ "/SKILL.md",
    skill_document game game_description "# Fixture game\n\nThe menu is in `references/menu.md`.\n"
  ; "skills/" ^ game ^ "/references/menu.md", "# Menu\n\nPress 1 to start.\n"
  ; "skills/" ^ game ^ "/references/keys.md", "# Keys\n\nEnter confirms.\n"
  ; "skills/" ^ game ^ "/references/notes.txt", "Not a guide file.\n"
  ; "skills/" ^ machine ^ "/SKILL.md",
    skill_document machine machine_description "Pass the controller when your turn ends.\n"
  ]

let runtime_toml = {|[[skills.sources]]
id = "workspace"
anchor = "base-path"
path = "skills"
access = "read-only"
|}

let screen_definition =
  match
    Mcp_protocol.Mcp_types.tool_of_yojson
      (`Assoc
        [ "name", `String screen_tool
        ; "description", `String "fixture screen"
        ; "inputSchema", `Assoc [ "type", `String "object" ] ])
  with
  | Ok tool -> tool
  | Error message -> fail message

let backend ~stops : Lane.For_testing.backend = {
  start = (fun ~sw:_ ~state_owner:_ ~instance_id ~installation_id:_ ~(package : Masc.Lane_addon_types.package) ~binding:_ ~on_authority ~is_live_instance:_ ~on_created ->
    let exported = List.filter (fun (tool : Mcp_protocol.Mcp_types.tool) ->
      List.mem tool.name package.exported_tools) [ screen_definition ] in
    let connection : Lane.For_testing.connection = {browser=None;
        await_exit = (fun () -> Eio.Fiber.await_cancel ());
        resolved_image = (match Masc.Lane_addon_engine.image_of_inspect Masc.Lane_addon_types.Docker ("sha256:" ^ String.make 64 'a') with
          | Ok image -> Some image | Error detail -> fail detail);
        host = None; resource = Masc.Lane_addon_lifecycle.Container_resource instance_id;
        exported_tools = (fun () -> exported);
        call_exported_tool = (fun ~companion:_ ~on_result:_ ~on_dispatch:_ ~authorize:_ ~principal:_ ~name:_ ~arguments:_ ->
          Error (Lane_addon_call_context.Transport_error "fixture worker runs no tool"));
        operator_schema=(fun () -> None);
        companion_tools=(fun () -> []);
        observation_effect=(fun _ -> Lane_addon_call_context.May_change);
        call_operator=(fun ~admit:_ ~arguments:_ -> Error Masc.Lane_addon_worker_protocol.Operator_unavailable);
        action_schema = (fun () -> None);
        act = (fun ~arguments:_ -> Error "read-only fixture");
        observe = (fun ~binding:_ ~sources:_ -> Ok { Masc.Lane_addon_types.rows = []; coverage = [] });
        stop = (fun () ->
          incr stops;
          Ok (Masc.Lane_addon_lifecycle.Released {engine=Masc.Lane_addon_lifecycle.Docker_engine "fixture-engine";container_id=Some instance_id}));
    } in
    ignore (on_authority (Masc.Lane_addon_lifecycle.Container_authority {runtime=Masc.Lane_addon_types.Docker;engine=Masc.Lane_addon_lifecycle.Docker_engine "fixture-engine"}));
    on_created connection;
    Ok connection);
  package_ready = (fun ~package:_ -> Ok ());
  acquire = (fun ~access:_ ~store:_ ~package:_ ~resolve_machine_output:_ ~resolve_lane_output:_ ~read_browser_document:_ ~binding:_ -> Ok (`List []));
  recover_stop = (fun ~state_owner:_ ~instance_id:_ ~authority ~resource ->
      match authority,resource with
      | Masc.Lane_addon_lifecycle.Container_authority {engine;_},None ->
          Ok (Masc.Lane_addon_lifecycle.Released {engine;container_id=None})
      | Masc.Lane_addon_lifecycle.Container_authority {engine;_},Some (Masc.Lane_addon_lifecycle.Container_resource id) ->
          Ok (Masc.Lane_addon_lifecycle.Released {engine;container_id=Some id})
      | Masc.Lane_addon_lifecycle.Container_authority _,Some (Masc.Lane_addon_lifecycle.Native_resource _)
      | Masc.Lane_addon_lifecycle.Native_admission _,(None | Some _) ->
          Error (Masc.Lane_addon_lifecycle.Cleanup_unconfirmed "container fixture cannot release native resources"));
  condition_met = (fun ~runtime:_ _ -> true);
  sweep = (fun ~runtime:_ ~is_live_instance:_ -> Ok []);
}

type fixture = {
  root : string;
  state : Masc.Mcp_server.server_state;
  config : Masc.Workspace.config;
  workspace : Service.workspace;
  declarations : string;
  package : string;
  player : string;
  stops : int ref;
  sleep : float -> unit;
}

let get ?token fx target = dispatch_get ~state:fx.state ~target ~token
let skill_path name = "/play/skills/" ^ name ^ "/SKILL.md"
let reference_path name file = "/play/skills/" ^ name ^ "/references/" ^ file

let await fx predicate =
  let rec loop () = if predicate () then () else (fx.sleep 0.001; loop ()) in
  loop ()

let refresh fx source_text =
  match
    Service.refresh ~workspace:fx.workspace ~user_home:None
      ~read_config:(fun () ->
        { Service.path = Filename.concat fx.root ".masc/config/runtime.toml"; source_text })
  with
  | Service.Published _ | Unchanged _ -> ()
  | Workspace_retired -> fail "the fixture workspace retired"

let reconcile fx = ignore (unwrap (Lane.reconcile_configuration ~config:fx.config ~directory:fx.declarations))

let lane_dispatch fx operation fields =
  Lane.dispatch ~access:Masc.Lane_addon_sources.Operator_configuration ~config:fx.config ~operation
    (`Assoc fields)
  |> Result.map_error Lane.error_to_string |> unwrap

(* The installation serving the DOS screen, read the way the host reads it. *)
let serving fx =
  (Lane.tool_execution_snapshot ~config:fx.config ~access:Masc.Lane_addon_sources.Unauthenticated
     ~reserved:[]).serving
  |> List.find_opt (fun (serving : Lane.tool_execution) ->
    String.equal serving.export.tool.name screen_tool)

let serving_instance fx =
  match serving fx with
  | Some serving -> serving.export.instance_id
  | None -> fail "no installation serves the DOS screen"

let phase fx id =
  lane_dispatch fx Lane.Inspect []
  |> Yojson.Safe.Util.member "instances" |> Yojson.Safe.Util.to_list
  |> List.find_opt (fun row -> Yojson.Safe.Util.(row |> member "instance_id" |> to_string) = id)
  |> Option.map (fun row -> Yojson.Safe.Util.(row |> member "phase" |> member "kind" |> to_string))

let detach fx =
  let id = serving_instance fx in
  let stopped = !(fx.stops) in
  ignore (lane_dispatch fx Lane.Detach [ "instance_id", `String id ]);
  await fx (fun () -> !(fx.stops) > stopped);
  await fx (fun () -> phase fx id = Some "detached");
  reconcile fx

let with_fixture f =
  let root = Unix.realpath (Filename.temp_dir "play-skills-" "") in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let config_root = Filename.concat root ".masc/config" in
    let declarations = Filename.concat config_root "lane-addons" in
    Fs_compat.mkdir_p declarations;
    let package = Filename.concat root "packages/dos-guides" in
    List.iter (fun (relative, contents) -> write_file (Filename.concat package relative) contents) package_files;
    Auth.save_auth_config root
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let player =
      match Auth.create_token root ~agent_name:"minsu" ~role:Masc_domain.Player with
      | Ok (token, _) -> token
      | Error error -> fail (Masc_domain.masc_error_to_string error)
    in
    let state = Masc.Mcp_server.For_testing.create_state ~base_path:root in
    let config = Masc.Mcp_server.workspace_config state in
    Masc_test_deps.with_process_env "MASC_CONFIG_DIR" (Some config_root) (fun () ->
    Masc_test_deps.with_process_env "MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE" (Some "true") (fun () ->
    Masc_test_deps.with_process_env "MASC_HTTP_BASE_URL" (Some public_base) (fun () ->
      Eio_main.run (fun env ->
        Masc_test_deps.init_eio_clock env;
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        let clock = Eio.Stdenv.clock env in
        Eio.Time.with_timeout_exn clock 30. (fun () ->
        Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env) ~clock
          ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
          Lane.For_testing.reset ();
          let workspace =
            match Service.workspace_of_base_path ~base_path:root with
            | Ok workspace -> workspace
            | Error _ -> fail "the fixture workspace path is not canonical"
          in
          Fun.protect ~finally:(fun () -> Service.retire ~workspace) (fun () ->
            Lane.register_skill_export_handler Server_skill_snapshot_runtime.publish_lane_skills;
            let stops = ref 0 in
            Lane.For_testing.with_backend (backend ~stops) (fun () ->
              f { root; state; config; workspace; declarations; package; player; stops;
                  sleep = Eio.Time.sleep clock }))))))))))

let guide fx =
  let response = get fx Masc.Play_invite.agent_guide_path in
  check int "the guide stays public" 200 (status_of response);
  snd (split_response response)

let check_unavailable fx label code =
  let response = get ~token:fx.player fx (skill_path game) in
  check int (label ^ ": a guide is unavailable") 503 (status_of response);
  check bool (label ^ ": named " ^ code) true (refusal_code response = Some (`String code));
  check bool (label ^ ": no host path") false (contains ~sub:fx.root response)

let check_listed fx =
  let body = guide fx in
  List.iter
    (fun (name, description) ->
      check bool (name ^ ": listed with its URL") true
        (contains ~sub:(public_base ^ skill_path name) body);
      check bool (name ^ ": listed with its description") true (contains ~sub:description body))
    [ game, game_description; machine, machine_description ];
  check bool "the guide lists no reference file" false
    (contains ~sub:(public_base ^ "/play/skills/" ^ game ^ "/references/") body)

let snapshot_body fx name =
  match Service.current ~workspace:fx.workspace with
  | None -> fail "nothing published"
  | Some snapshot ->
    (match Skill_catalog_snapshot.find_effective_by_name snapshot name with
     | Some entry -> entry.document.body
     | None -> failf "%s is not in the published snapshot" name)

let declaration fx id =
  write_file (Filename.concat fx.declarations (id ^ ".toml"))
    (Printf.sprintf "id = %S\nrun_id = \"shared-dos\"\nmanifest_path = %S\n[binding]\nsources = []\n" id
       (Filename.concat fx.package "lane.toml"))

let references_dir fx = Filename.concat fx.package ("skills/" ^ game ^ "/references")

let test_declared_under_another_id () =
  with_fixture (fun fx ->
    let secret = "SECRET-OUTSIDE-EVERY-SKILL" in
    let outside = Filename.concat fx.root "outside.md" in
    write_file outside secret;
    Unix.symlink outside (Filename.concat (references_dir fx) "escape.md");
    check bool "nothing published yet, and the guide says so" true
      (contains ~sub:"this server has not published its Skill catalog" (guide fx));
    check_unavailable fx "unpublished" "skills_unpublished";
    refresh fx runtime_toml;
    check bool "no machine, and the guide says so" true
      (contains ~sub:"no DOS machine add-on is attached" (guide fx));
    check_unavailable fx "no machine" "machine_unavailable";
    (* Declared under an id that is not the package's. *)
    declaration fx "shared-machine";
    reconcile fx;
    await fx (fun () -> Option.is_some (serving fx));
    reconcile fx;
    check_listed fx;
    check int "a guide needs a bearer" 401 (status_of (get fx (skill_path game)));
    check int "an unknown bearer is refused" 401
      (status_of (get ~token:"not-an-invitation" fx (skill_path game)));
    let response = get ~token:fx.player fx (skill_path game) in
    check int "a guide is served to the invite" 200 (status_of response);
    let head, served = split_response response in
    List.iter
      (fun (name, value) -> check (option string) name (Some value) (header name head))
      [ "content-type", "text/markdown; charset=utf-8"
      ; "cache-control", "no-store"
      ; "x-content-type-options", "nosniff" ];
    check bool "the guide is the text a Keeper's keeper_skill reads" true
      (String.starts_with ~prefix:(snapshot_body fx game) served);
    List.iter
      (fun file ->
        check bool (file ^ ": its URL follows the guide") true
          (contains ~sub:(public_base ^ reference_path game file) served))
      reference_files;
    check bool "a link out of the Skill is not offered" false (contains ~sub:"escape.md" served);
    check bool "a non-markdown file is not offered" false (contains ~sub:"notes.txt" served);
    check string "a guide without reference files is its text alone" (snapshot_body fx machine)
      (snd (split_response (get ~token:fx.player fx (skill_path machine))));
    List.iter
      (fun file ->
        let path = reference_path game file in
        check int (file ^ ": needs a bearer") 401 (status_of (get fx path));
        let response = get ~token:fx.player fx path in
        check int (file ^ ": served") 200 (status_of response);
        check string (file ^ ": its bytes")
          (read_file (Filename.concat (references_dir fx) file))
          (snd (split_response response)))
      reference_files;
    List.iter
      (fun path ->
        let response = get ~token:fx.player fx path in
        check int (path ^ ": nothing published") 404 (status_of response);
        check bool (path ^ ": named skill_not_found") true
          (refusal_code response = Some (`String "skill_not_found"));
        check bool (path ^ ": reads nothing outside") false (contains ~sub:secret response))
      [ skill_path "no-such-game"
      ; reference_path game "no-such-file.md"
      ; reference_path machine "menu.md"
      ; reference_path game "notes.txt"
      ; "/play/skills/" ^ game ^ ".md"
      ; skill_path game ^ "/x"
      ; "/play/skills/../agent.md"
      ; reference_path game "../SKILL.md"
      ; reference_path game "..%2F..%2F..%2F..%2Foutside.md"
      ; reference_path "%2e%2e" "outside.md"
      ; reference_path game "escape.md"
      ; reference_path game outside
      ; reference_path game (String.concat "%2F" (String.split_on_char '/' outside))
      ];
    (* A references directory the server cannot read: CI runs as the
       unprivileged runner user, for whom mode 000 refuses the listing. *)
    if Unix.geteuid () <> 0 then begin
      Unix.chmod (references_dir fx) 0o000;
      Fun.protect ~finally:(fun () -> Unix.chmod (references_dir fx) 0o755) (fun () ->
        let response = get ~token:fx.player fx (reference_path game "menu.md") in
        check int "unlistable references are unavailable" 503 (status_of response);
        check bool "named references_unreadable" true
          (refusal_code response = Some (`String "references_unreadable"));
        check bool "the refusal names no host path" false (contains ~sub:fx.root response);
        let response = get ~token:fx.player fx (skill_path game) in
        check int "the guide itself is still served" 200 (status_of response);
        check string "without reference URLs or a host path" (snapshot_body fx game)
          (snd (split_response response));
        check_listed fx)
    end;
    (* A workspace Skill of the same name wins, as it does for a Keeper. *)
    let shadow = Filename.concat fx.root ("skills/" ^ game ^ "/SKILL.md") in
    write_file shadow (skill_document game "The workspace's own guide." "Workspace text.\n");
    refresh fx runtime_toml;
    check bool "a shadowed guide is not listed" false
      (contains ~sub:(public_base ^ skill_path game) (guide fx));
    let response = get ~token:fx.player fx (skill_path game) in
    check int "a shadowed guide is not served" 404 (status_of response);
    check bool "nor the workspace's" false (contains ~sub:"Workspace text." response);
    remove_tree (Filename.dirname shadow);
    refresh fx runtime_toml;
    check_listed fx;
    (* Configurations under which the snapshot holds no add-on Skills. *)
    List.iter
      (fun (label, source_text) ->
        refresh fx source_text;
        check bool (label ^ ": the guide says so") true
          (contains ~sub:"Skill configuration is not in effect" (guide fx));
        check_unavailable fx label "skills_not_configured")
      [ "no [skills] table", ""; "a refused configuration", "[skills]\nunknown-key = 1\n" ];
    refresh fx runtime_toml;
    check_listed fx;
    (* The machine's Skill source is gone from disk. *)
    let skills = Filename.concat fx.package "skills" in
    Unix.rename skills (skills ^ ".away");
    refresh fx runtime_toml;
    check bool "an unreadable source, and the guide says so" true
      (contains ~sub:"the DOS machine add-on's Skills cannot be read" (guide fx));
    check_unavailable fx "source missing" "skills_source_unavailable";
    Unix.rename (skills ^ ".away") skills;
    refresh fx runtime_toml;
    check_listed fx;
    detach fx;
    check bool "detached, and the guide says so" true
      (contains ~sub:"no DOS machine add-on is attached" (guide fx));
    check_unavailable fx "detached" "machine_unavailable")

let test_attached_by_hand () =
  with_fixture (fun fx ->
    refresh fx runtime_toml;
    ignore
      (lane_dispatch fx Lane.Attach
         [ "manifest_path", `String (Filename.concat fx.package "lane.toml")
         ; "run_id", `String "manual-dos"
         ; "binding", `Assoc [ "sources", `List [] ] ]);
    await fx (fun () -> Option.is_some (serving fx));
    (* An empty declaration directory: reconciliation still publishes the
       Skills of a manual installation. *)
    reconcile fx;
    check_listed fx;
    let response = get ~token:fx.player fx (skill_path machine) in
    check int "a manual installation's guide is served" 200 (status_of response);
    check string "its text" (snapshot_body fx machine) (snd (split_response response));
    detach fx)

let () =
  run "play-skills"
    [ ( "skills"
      , [ test_case "declared under another id" `Quick test_declared_under_another_id
        ; test_case "attached by hand" `Quick test_attached_by_hand
        ] )
    ]
