(* HIGH-RISK-UNREVIEWED: auth-boundary canary for official-client hosts
   (#39314). It needs human review before any line here is read as a
   guarantee.

   A Keeper's raw bearer sits at [Auth.raw_token_file], which is
   <base_path>/.masc/auth/<agent>.token, mode 0600. Official clients run as
   host processes under the server's own uid, so the file mode does not keep
   them out. What keeps a host out is what MASC hands it: the cwd it starts
   in, the built-in tools it may use, the permission profile or rules it runs
   under, and MASC's own answer when the host asks for permission.

   Every test builds a throwaway base path, writes a random marker to
   <base>/.masc/auth/canary.token, and checks what MASC hands one client in
   that client's default posture. No real credential, account home or vendor
   CLI is touched. A run against a real vendor would look for the marker in
   tool results and traces; the stand-ins here never read it.

   A stand-in that replays canned protocol frames cannot show what a real
   vendor reads. The Antigravity read hook is MASC's own executable, so it is
   the one guard this file runs against the canary file itself.

   Where the path is open today, the test asserts today's input and carries a
   HIGH-RISK-UNREVIEWED line naming the gap. Closing a gap changes the test on
   purpose. *)
open Alcotest
open Masc

let keeper_name = "auth-canary"

let write_file ~mode path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents);
  Unix.chmod path mode
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let path_parts path = String.split_on_char '/' path |> List.filter (fun part -> part <> "")

(* Whole-component containment of canonical paths: /a/b holds /a/b/c, not /a/bc. *)
let within ~root path =
  let rec below = function
    | [], _ -> true
    | parent :: parents, child :: children -> String.equal parent child && below (parents, children)
    | _ :: _, [] -> false
  in
  below (path_parts root, path_parts path)
;;

(* The relative spelling of [<runtime_root>/auth/canary.token] from [dir], a
   folder below the runtime root. *)
let escape_to_canary ~runtime_root dir =
  let depth = List.length (path_parts dir) - List.length (path_parts runtime_root) in
  String.concat "/" (List.init depth (fun _ -> "..") @ [ "auth"; "canary.token" ])
;;

type canary =
  { base : string
  ; runtime_root : string
  ; auth_dir : string
  ; token : string
  }

let with_canary f =
  Random.self_init ();
  let base = Filename.temp_dir "masc-auth-canary-" "" |> Unix.realpath in
  Unix.chmod base 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base)
    (fun () ->
       let runtime_root = Common.masc_dir_from_base_path ~base_path:base in
       Unix.mkdir runtime_root 0o700;
       let token = Auth.raw_token_file base "canary" in
       let auth_dir = Filename.dirname token in
       Unix.mkdir auth_dir 0o700;
       write_file ~mode:0o600 token
         (Printf.sprintf "masc-auth-canary-%08x%08x" (Random.bits ()) (Random.bits ()));
       f { base; runtime_root; auth_dir; token })
;;

let flag_value argv flag =
  let rec walk = function
    | name :: value :: _ when String.equal name flag -> Some value
    | _ :: rest -> walk rest
    | [] -> None
  in
  walk argv
;;

(* ---------- Codex app-server ---------- *)

(* What the client waits for, in the order it asks: initialize, account/read,
   thread/start, turn/start, then the turn's own end. *)
let codex_initialized =
  {|{"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
;;

let codex_account =
  {|{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
;;

let codex_thread = {|{"id":3,"result":{"thread":{"id":"thread-1"},"model":"gpt-fixture"}}|}
let codex_turn = {|{"id":4,"result":{"turn":{"id":"turn-1"}}}|}

let codex_item_completed =
  {|{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"type":"agentMessage","id":"message-1","text":"done","phase":"final_answer"}}}|}
;;

let codex_turn_completed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[{"type":"agentMessage","id":"message-1","text":"done","phase":"final_answer"}],"status":"completed"}}}|}
;;

(* A stand-in app-server: it records its argv, its cwd and every frame it is
   sent, and answers one turn. It reads no file and models no sandbox. *)
let codex_stand_in ~scratch =
  let script = Filename.concat scratch "codex-stand-in.sh" in
  let argv = Filename.concat scratch "argv.txt" in
  let cwd = Filename.concat scratch "cwd.txt" in
  let frames = Filename.concat scratch "frames.jsonl" in
  let reply line = "printf '%s\\n' " ^ Filename.quote line in
  let take = "IFS= read -r request || exit 98\nprintf '%s\\n' \"$request\" >> " ^ Filename.quote frames in
  write_file ~mode:0o700 script
    (String.concat "\n"
       [ "#!/bin/sh"
       ; "printf '%s\\n' \"$@\" > " ^ Filename.quote argv
       ; "pwd > " ^ Filename.quote cwd
       ; take
       ; reply codex_initialized
       ; take (* the initialized notification *)
       ; take
       ; reply codex_account
       ; take
       ; reply codex_thread
       ; take
       ; reply codex_turn
       ; reply codex_item_completed
       ; reply codex_turn_completed
       ; "while IFS= read -r ignored; do :; done"
       ; ""
       ]);
  script, argv, cwd, frames
;;

let test_codex_default_posture () =
  with_canary
  @@ fun canary ->
  let scratch = Filename.concat canary.base "scratch" in
  Unix.mkdir scratch 0o700;
  (* The Keeper layer's cwd for a Codex Keeper with no sandbox profile
     (keeper_codex_runtime.ml, Keeper_native_cwd.resolve). *)
  let keeper_cwd =
    match
      Keeper_native_cwd.resolve ~base_path:canary.base ~keeper_name ~sandbox_profile:None
        Keeper_native_cwd.Codex_app_server
    with
    | Ok dir -> dir
    | Error detail -> fail detail
  in
  check bool "the Codex cwd lies under the runtime root" true
    (within ~root:canary.runtime_root keeper_cwd);
  check bool "the auth folder is not inside the Codex cwd" false
    (within ~root:keeper_cwd canary.auth_dir);
  check string "a relative path from the Codex cwd reaches the canary" canary.token
    (Unix.realpath
       (Filename.concat keeper_cwd (escape_to_canary ~runtime_root:canary.runtime_root keeper_cwd)));
  let codex_home = Filename.concat scratch "codex-home" in
  Unix.mkdir codex_home 0o700;
  let account =
    match
      Runtime_official_account.capture ~client:Runtime_official_account.Codex
        ~declaration:(Some codex_home)
    with
    | Ok captured -> Masc_test_deps.authorized_account (Runtime_account_access.seal captured)
    | Error detail -> fail detail
  in
  let cli, argv_path, cwd_path, frames_path = codex_stand_in ~scratch in
  let config =
    { (Runtime_codex_app_server.default_config ()) with
      cli_path = cli
    ; admission_timeout_s = 30.0
    ; timeout_s = Some 30.0
    }
  in
  check bool "the default config runs the Codex default posture" true
    (config.native = Runtime_native_tools.codex_default);
  check bool "the Codex default posture is read" true
    (Runtime_native_tools.codex_default = Runtime_native_tools.Native_read);
  (match
     Eio_main.run (fun env ->
       Runtime_codex_app_server.run_turn
         ~thread:(Runtime_codex_app_server.Persistent Runtime_codex_app_server.Start)
         ~mgr:(Eio.Stdenv.process_mgr env)
         ~clock:(Eio.Stdenv.clock env)
         ~cwd:Eio.Path.(Eio.Stdenv.fs env / keeper_cwd)
         ~account
         config
         ~prompt:"Report the fixture marker"
         ~images:[])
   with
   | Ok _ -> ()
   | Error error -> fail (Runtime_codex_app_server.error_to_string error));
  check string "the spawned app-server starts in the Codex cwd" (Unix.realpath keeper_cwd)
    (Unix.realpath (String.trim (read_file cwd_path)));
  let thread_start =
    In_channel.with_open_bin frames_path In_channel.input_lines
    |> List.map Yojson.Safe.from_string
    |> List.find (fun frame ->
      Yojson.Safe.Util.member "method" frame = `String "thread/start")
  in
  let params = Yojson.Safe.Util.member "params" thread_start in
  check string "thread/start names the Codex cwd" (Unix.realpath keeper_cwd)
    (Unix.realpath (Yojson.Safe.Util.(params |> member "cwd" |> to_string)));
  (* HIGH-RISK-UNREVIEWED: Codex does not deny .masc/auth. The one filesystem
     input MASC sends is the built-in profile id ":read-only"
     (runtime_codex_app_server.ml permissions_profile_of_posture); no deny
     rule names the auth folder or the runtime root above it. How far
     ":read-only" lets the app-server's own tools read is the vendor's
     behaviour, and nothing in this file establishes it. *)
  check string "default posture names the built-in :read-only profile" ":read-only"
    (Yojson.Safe.Util.(params |> member "permissions" |> to_string));
  check bool "thread/start carries no sandbox field" true
    (Yojson.Safe.Util.member "sandbox" params = `Null);
  (* The whole config override set the app-server starts with. Shell and
     unified exec are off under read; nothing here is a filesystem rule. *)
  let argv = In_channel.with_open_bin argv_path In_channel.input_lines in
  check (list string) "argv: app-server with posture and sub-agent overrides only"
    [ "app-server"; "--stdio"
    ; "-c"; "features.shell_tool=false"; "-c"; "features.unified_exec=false"
    ; "-c"; "project_root_markers=[]"
    ; "-c"; "agents.enabled=false"; "-c"; "features.multi_agent_v2=false"
    ]
    argv
;;

(* ---------- Antigravity CLI ---------- *)

let permission_strings settings section =
  Yojson.Safe.Util.(
    settings |> member "permissions" |> member section |> to_list |> List.map to_string)
;;

(* [read_file(<root>)] gives [<root>]; any other entry gives nothing. *)
let read_root entry =
  let prefix = "read_file(" in
  if String.starts_with ~prefix entry && String.ends_with ~suffix:")" entry
  then
    Some
      (String.sub entry (String.length prefix)
         (String.length entry - String.length prefix - 1))
  else None
;;

let test_antigravity_read_hook_denies_the_canary () =
  with_canary
  @@ fun canary ->
  let oauth_source = Filename.concat canary.base "synthetic-oauth" in
  write_file ~mode:0o600 oauth_source (Masc_test_deps.antigravity_oauth_fixture "synthetic");
  let posture = Runtime_native_tools.antigravity_default in
  check bool "the Antigravity default posture is read" true
    (posture = Runtime_native_tools.Native_read);
  (* The Keeper layer prepares the HOME under the runtime root and runs an
     Endpoint_owned or unprofiled Keeper in its private workspace
     (keeper_antigravity_runtime.ml native_workspace). *)
  let home, cwd =
    match
      Runtime_antigravity_home.prepare_native
        ~host:(Masc_test_deps.host_account Runtime_account_access.Antigravity)
        ~runtime_root:canary.runtime_root
        ~owner_leaf:(Runtime_antigravity_home.keeper_owner_leaf ~keeper_name ~oauth_source)
        ~oauth_source ~posture ~workspace:Runtime_antigravity_home.Private_workspace
        ~additional_workspaces:[]
    with
    | Ok prepared -> prepared
    | Error error -> fail (Runtime_antigravity_home.error_to_string error)
  in
  (match Runtime_antigravity_home.prepare_read_hook home ~posture ~cwd ~additional_workspaces:[] with
   | Ok () -> ()
   | Error error -> fail (Runtime_antigravity_home.error_to_string error));
  check bool "the private workspace lies under the runtime root" true
    (within ~root:canary.runtime_root cwd);
  check bool "the auth folder is not inside the private workspace" false
    (within ~root:cwd canary.auth_dir);
  (* settings.json: no read grant reaches the auth folder. It carries no
     all-files read deny either, so the read hook below is the guard MASC owns
     for a read outside the granted roots. *)
  let paths = Runtime_antigravity_home.For_testing.paths home in
  let settings = Yojson.Safe.from_file paths.settings_path in
  let granted = List.filter_map read_root (permission_strings settings "allow") in
  check bool "the private workspace is a granted read root" true (List.mem cwd granted);
  check (list string) "no granted read root holds the auth folder" []
    (List.filter (fun root -> within ~root canary.auth_dir) granted);
  check bool "settings.json carries no all-files read deny under read" false
    (List.mem "read_file(*)" (permission_strings settings "deny"));
  (* An extra root that would hold the auth folder is refused before any
     rule is written: the base path holds the runtime root, and the auth
     folder lies inside it. *)
  List.iter
    (fun (label, extra) ->
       check bool label true
         (Result.is_error
            (Runtime_antigravity_home.prepare_native_tools home ~posture
               ~workspace:Runtime_antigravity_home.Private_workspace
               ~additional_workspaces:[ extra ])))
    [ "the base path is refused as an extra root", canary.base
    ; "the auth folder is refused as an extra root", canary.auth_dir
    ];
  (* The canary run: the hook command agy is told to run before read_file,
     fed read requests for the synthetic token as agy would send them. *)
  let hooks_path = Filename.concat (Filename.dirname paths.mcp_config_path) "hooks.json" in
  let command =
    Yojson.Safe.Util.(
      Yojson.Safe.from_file hooks_path
      |> member "masc-native-read" |> member "PreToolUse" |> to_list |> List.hd
      |> member "hooks" |> to_list |> List.hd |> member "command" |> to_string)
  in
  let input = Filename.concat canary.base "hook-input.json" in
  let output = Filename.concat canary.base "hook-output.json" in
  let decide path =
    write_file ~mode:0o600 input
      (Yojson.Safe.to_string
         (`Assoc
             [ "toolCall", `Assoc [ "name", `String "read_file"; "args", `Assoc [ "Path", `String path ] ]
             ; "conversationId", `String "canary"
             ]));
    check int "the hook exits with a decision" 0
      (Sys.command (command ^ " < " ^ Filename.quote input ^ " > " ^ Filename.quote output));
    Yojson.Safe.Util.(Yojson.Safe.from_file output |> member "decision" |> to_string)
  in
  let inside = Filename.concat cwd "inside.txt" in
  write_file ~mode:0o600 inside "inside";
  let alias = Filename.concat cwd "alias.token" in
  Unix.symlink canary.token alias;
  let escape = escape_to_canary ~runtime_root:canary.runtime_root cwd in
  check string "the relative escape names the canary" canary.token
    (Unix.realpath (Filename.concat cwd escape));
  check string "control: a file in the workspace is passed on" "allow" (decide inside);
  check string "the canary by absolute path is denied" "deny" (decide canary.token);
  check string "the canary by relative escape is denied" "deny" (decide escape);
  check string "the canary through a workspace symlink is denied" "deny" (decide alias)
;;

(* ---------- Claude Code ---------- *)

let claude_argv ~cwd native =
  match
    Runtime_claude_code.command ~system_prompt_file:None
      { (Runtime_claude_code.default_config ~cwd) with native }
      ~dynamic_tools:[] ~reasoning_effort:None ~session_mode:Runtime_claude_code.Start
      ~session_id:"11111111-1111-4111-8111-111111111111"
  with
  | Ok argv -> argv
  | Error error -> fail (Runtime_claude_code.error_to_string error)
;;

(* The Keeper starts Claude Code with base_path as both its config cwd and
   its process cwd (keeper_claude_code_runtime.ml, [cwd = base_path] and
   [process_cwd]), so .masc/auth lies inside the cwd. The default posture
   closes the path by granting no built-in that reads; it names no deny. *)
let test_claude_code_default_grants_no_read_tool () =
  with_canary
  @@ fun canary ->
  let default_native = (Runtime_claude_code.default_config ~cwd:canary.base).native in
  check bool "the default config runs none" true
    (default_native = Runtime_native_tools.Native_none);
  let argv = claude_argv ~cwd:canary.base default_native in
  check (option string) "--tools lists only the schema lookup" (Some "ToolSearch")
    (flag_value argv "--tools");
  check (option string) "no built-in is pre-approved" None (flag_value argv "--allowedTools");
  check bool "no settings layer can add a grant" true (List.mem "--setting-sources=" argv);
  check bool "no --disallowedTools rule is sent" false (List.mem "--disallowedTools" argv)
;;

let test_claude_code_declared_read_leaves_the_auth_folder_open () =
  with_canary
  @@ fun canary ->
  let argv = claude_argv ~cwd:canary.base Runtime_native_tools.Native_read in
  (* HIGH-RISK-UNREVIEWED: Claude Code does not deny .masc/auth. A Keeper that
     declares native = "read" gets Read, Glob and Grep pre-approved in a cwd
     (base_path) that holds the auth folder, and no deny rule. *)
  check (option string) "--tools adds the read built-ins" (Some "Read,Glob,Grep,ToolSearch")
    (flag_value argv "--tools");
  check (option string) "the read built-ins are pre-approved" (Some "Read,Glob,Grep")
    (flag_value argv "--allowedTools");
  check bool "no --disallowedTools rule is sent" false (List.mem "--disallowedTools" argv);
  check bool "the auth folder lies inside the base path the Keeper runs in" true
    (within ~root:canary.base canary.auth_dir)
;;

(* ---------- ACP hosts ---------- *)

let acp_argv ?(skip_permissions = false) driver posture =
  Runtime_acp_client.For_testing.build_argv ~native_posture:posture
    { (Runtime_acp_client.default_config ~driver ~cwd:"/acp-cwd-unused") with
      dangerously_skip_permissions = skip_permissions
    }
    ~temp_gemini_dir:None
;;

let acp_env driver posture =
  Runtime_acp_client.For_testing.host_environment ~base_env:[| "PATH=/usr/bin" |] ~driver
    ~extra_strip_env:[] ~git_author_environment:[] (Some posture)
  |> Array.to_list
;;

let test_acp_cwd_by_posture () =
  with_canary
  @@ fun canary ->
  let cwd posture =
    match
      Keeper_acp_runtime.For_testing.native_cwd_of_posture ~base_path:canary.base ~keeper_name
        ~required_native_posture:(Some posture) posture
    with
    | Ok cwd -> cwd
    | Error error -> fail (Agent_core.Error.to_string error)
  in
  (match cwd Runtime_native_tools.Native_none with
   | Keeper_acp_runtime.For_testing.Isolated_per_spawn -> ()
   | Keeper_acp_runtime.For_testing.Keeper_folder dir ->
     fail ("none ran in a Keeper folder: " ^ dir));
  (match
     Eio_main.run (fun _ ->
       Eio.Switch.run (fun sw ->
         Runtime_acp_client.create_isolated_workspace ~sw ~prefix:("keeper-" ^ keeper_name) ()
         |> Result.map (fun dir ->
           ( within ~root:canary.base dir
           , within ~root:dir canary.auth_dir ))))
   with
   | Ok (under_base, holds_auth) ->
     check bool "the none folder lies outside the base path" false under_base;
     check bool "the none folder does not hold the auth folder" false holds_auth
   | Error error -> fail (Runtime_acp_client.error_to_string error));
  match cwd Runtime_native_tools.Native_read with
  | Keeper_acp_runtime.For_testing.Isolated_per_spawn -> fail "read ran in a new empty folder"
  | Keeper_acp_runtime.For_testing.Keeper_folder dir ->
    check bool "the read folder lies under the runtime root" true
      (within ~root:canary.runtime_root dir);
    check bool "the read folder does not hold the auth folder" false
      (within ~root:dir canary.auth_dir);
    check string "a relative path from the read folder reaches the canary" canary.token
      (Unix.realpath (Filename.concat dir (escape_to_canary ~runtime_root:canary.runtime_root dir)))
;;

(* What each host is told about its native tools under the ACP default,
   none (keeper_acp_runtime.ml resolve_native_posture ~default:Native_none). *)
let test_acp_none_hands_no_native_read () =
  let none = Runtime_native_tools.Native_none in
  check bool "Muse: run.toolset lists no native tool" true
    (List.mem "run.toolset=[]" (acp_argv Runtime_acp_client.Muse_code none));
  check bool "Vibe: the tool allowlist holds only the session plan" true
    (List.mem {|VIBE_ENABLED_TOOLS=["todo"]|} (acp_env Runtime_acp_client.Mistral_vibe none));
  check bool "Antigravity: an operator skip-permissions flag is dropped" false
    (List.mem "--dangerously-skip-permissions"
       (acp_argv ~skip_permissions:true Runtime_acp_client.Antigravity none));
  (* HIGH-RISK-UNREVIEWED: Kimi Code receives no posture in argv or env. Under
     none it runs in session mode "default" in a new empty folder; whether its
     read tool asks MASC before reading an absolute path outside that folder
     is not established here. *)
  let kimi = Runtime_acp_client.Kimi_code in
  check (list string) "Kimi: argv is the same under none and full"
    (acp_argv kimi Runtime_native_tools.Native_full) (acp_argv kimi none);
  check (list string) "Kimi: env is the same under none and full"
    (acp_env kimi Runtime_native_tools.Native_full) (acp_env kimi none);
  check string "Kimi: session mode under none" "default"
    (Runtime_acp_client.mode_of_posture kimi none)
;;

let test_acp_declared_read_hands_a_native_read () =
  let read = Runtime_native_tools.Native_read in
  (* HIGH-RISK-UNREVIEWED: under a declared read posture Muse and Vibe get
     read_file and no path rule; runtime_acp_client.ml records a live Muse
     read_file reading /etc/hosts, outside its workspace. *)
  check bool "Muse: run.toolset adds read_file and search" true
    (List.mem {|run.toolset=["read_file","search"]|} (acp_argv Runtime_acp_client.Muse_code read));
  check bool "Vibe: the tool allowlist adds read_file" true
    (List.mem {|VIBE_ENABLED_TOOLS=["todo","read_file"]|}
       (acp_env Runtime_acp_client.Mistral_vibe read));
  check bool "Antigravity: skip-permissions is still dropped" false
    (List.mem "--dangerously-skip-permissions"
       (acp_argv ~skip_permissions:true Runtime_acp_client.Antigravity read))
;;

(* MASC's answer when a host asks to run a native read of the canary. The
   frame carries the path in [locations] and [rawInput]; the answer does not
   look at it. *)
let test_acp_permission_answer_for_a_canary_read () =
  with_canary
  @@ fun canary ->
  let frame =
    `Assoc
      [ "toolCallId", `String "canary-read"
      ; "title", `String "read_file"
      ; "name", `String "read_file"
      ; "kind", `String "read"
      ; "status", `String "pending"
      ; "locations", `List [ `Assoc [ "path", `String canary.token ] ]
      ; "rawInput", `Assoc [ "path", `String canary.token ]
      ]
  in
  List.iter
    (fun driver ->
       let label = Runtime_acp_client.driver_to_string driver in
       let mcp_server_name = Runtime_acp_client.bridge_server_name driver ~owner:keeper_name in
       let identity =
         Runtime_acp_client.For_testing.classify_tool_call_json ~driver ~mcp_server_name frame
       in
       let answer posture =
         Runtime_acp_client.should_allow_tool_call
           ~policy:
             (Runtime_acp_client.permission_policy_of_posture ~mcp_server_name
                ~allowed_tool_names:[] posture)
           identity
       in
       check bool (label ^ ": none refuses the canary read") false
         (answer Runtime_native_tools.Native_none);
       (* HIGH-RISK-UNREVIEWED: under read MASC allows any native read the
          host asks about, whatever its path, the canary included. *)
       check bool (label ^ ": read allows the canary read") true
         (answer Runtime_native_tools.Native_read))
    Runtime_acp_client.all_drivers
;;

let () =
  run "official_client_auth_boundary"
    [ ( "codex"
      , [ test_case "default read posture sends no rule for the auth folder" `Quick
            test_codex_default_posture
        ] )
    ; ( "antigravity"
      , [ test_case "the read hook denies the canary and no root holds it" `Quick
            test_antigravity_read_hook_denies_the_canary
        ] )
    ; ( "claude code"
      , [ test_case "default none grants no read built-in" `Quick
            test_claude_code_default_grants_no_read_tool
        ; test_case "declared read leaves the auth folder open" `Quick
            test_claude_code_declared_read_leaves_the_auth_folder_open
        ] )
    ; ( "acp"
      , [ test_case "cwd by posture" `Quick test_acp_cwd_by_posture
        ; test_case "none hands no native read" `Quick test_acp_none_hands_no_native_read
        ; test_case "declared read hands a native read" `Quick
            test_acp_declared_read_hands_a_native_read
        ; test_case "permission answer for a canary read" `Quick
            test_acp_permission_answer_for_a_canary_read
        ] )
    ]
;;
