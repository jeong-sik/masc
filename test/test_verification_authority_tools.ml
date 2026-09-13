(* Completion-authority descriptor, validation, dispatch, and containment
   contracts. *)

module Keeper_meta_store = Masc.Keeper_meta_store
module Descriptor = Masc.Keeper_tool_descriptor
module VAT = Masc.Verification_authority_tools
module AR = Masc.Task.Anti_rationalization

(* Existing text assertions inspect the typed disposition explicitly. *)
let dispatch_text surface ~name ~args =
  let result = VAT.dispatch surface ~name ~args in
  match result with
  | Tool_result.Completed _ -> Ok (Tool_result.message result)
  | Tool_result.Failed _ -> Error (Tool_result.message result)
  | Tool_result.Deferred _ -> Alcotest.fail "read-only lookup unexpectedly deferred"
;;

(* Prompts moved from code into config/prompts; load them so verification.lookup
   templates render instead of reporting missing. Matches the other
   prompt-rendering tests. *)
let () =
  let prompt_dir =
    Filename.concat
      (match Sys.getenv_opt "DUNE_SOURCEROOT" with
       | Some root -> root
       | None -> Sys.getcwd ())
      "config/prompts"
  in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir

let producer = "test-producer"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-vat-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()
;;

(* [agent_name] is deliberately omitted: [meta_of_json_fixture] fills in the
   canonical [Keeper_identity.keeper_agent_name], so this fixture cannot drift
   from the identity rule the meta parser enforces. *)
let ensure_producer config name =
  match
    Result.bind
      (Masc_test_deps.meta_of_json_fixture
         (`Assoc [ "name", `String name; "always_allow", `Bool true ]))
      (Keeper_meta_store.replace_snapshot config)
  with
  | Ok _ -> ()
  | Error err -> Alcotest.failf "write keeper meta failed: %s" err
;;

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f
;;

(* The endpoint name the remote_ssh fixture registers and the producer's TOML
   points at. One literal, two writers. *)
let ssh_fixture_endpoint = "fixture"

(* The shim answers a framed request on stdin with the body on stdout and a
   result trailer on stderr. The trailer is rendered by the function the real
   shim renders it with, so a wire change updates this fixture or fails to
   compile -- the same contract test_keeper_sandbox_read_backend keeps. *)
let ssh_fixture_body = "remote-file-content"

let fake_ssh_script =
  Printf.sprintf
    {|#!/bin/sh
cat >/dev/null 2>/dev/null &
printf '%%s' '%s'
printf '%%s' '%s' >&2
exit 0
|}
    ssh_fixture_body
    (Exec_ssh_protocol.render_trailer
       { v = Exec_ssh_protocol.newest
       ; exit = Some 0
       ; signal = None
       ; timed_out = false
       ; shim_error = None
       })
;;

let write_runtime_toml ~base_path =
  let path = Filename.concat base_path ".masc/config/runtime.toml" in
  Fs_compat.mkdir_p (Filename.dirname path);
  Out_channel.with_open_text path (fun channel ->
    output_string
      channel
      (Exec_ssh_endpoint.to_toml
         Exec_ssh_endpoint.
           { name = ssh_fixture_endpoint
           ; host = "fixture.invalid"
           ; user = "masc"
           ; port = default_port
           ; identity_file = default_identity_file ~name:ssh_fixture_endpoint
           ; known_hosts_file = default_known_hosts_file ~name:ssh_fixture_endpoint
           ; remote_root = "/srv/masc/playground"
           ; connect_timeout_sec = 1
           ; max_concurrent_sessions = 2
           ; env_allowlist = []
           ; capabilities = []
           ; private_home = false
           }))
;;

let with_fake_ssh ?(script = fake_ssh_script) f =
  let dir = temp_dir () in
  let ssh_path = Filename.concat dir "ssh" in
  Out_channel.with_open_text ssh_path (fun channel ->
    output_string channel script);
  Unix.chmod ssh_path 0o755;
  Masc.Keeper_sandbox_ssh.For_testing.set_ssh_bin_override (Some ssh_path);
  Fun.protect
    ~finally:(fun () ->
      Masc.Keeper_sandbox_ssh.For_testing.set_ssh_bin_override None;
      rm_rf dir)
    f
;;

(* A workspace holding one producer keeper, and the surface bound to it.

   [remote_ssh] is the default because it is the one hardened profile a test
   can stand up on any host: the endpoint is a runtime.toml row and the
   transport is a shim this file installs. Docker needs a daemon and the
   masc-keeper-sandbox image, which the release evidence job does not build,
   so a read routed through it fails there for a reason that is not about the
   verifier. Micro_vm needs Apple's container CLI, so it cannot run on Linux
   at all. Tests that are about the Docker route ask for it by name. *)
let with_surface ?(sandbox_profile = "remote_ssh") ?ssh_script f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  let remote = String.equal sandbox_profile "remote_ssh" in
  let profile_path =
    Keeper_sandbox_config.keeper_toml_path
      ~base_path:config.base_path
      ~agent_name:producer
  in
  Fs_compat.mkdir_p (Filename.dirname profile_path);
  Out_channel.with_open_text profile_path (fun channel ->
    Printf.fprintf
      channel
      "[keeper]\ninstructions = \"verification test producer\"\nsandbox_profile = %S\n"
      sandbox_profile;
    if remote
    then Printf.fprintf channel "remote_endpoint = %S\n" ssh_fixture_endpoint);
  if remote then write_runtime_toml ~base_path:config.base_path;
  ensure_producer config producer;
  let run () =
    match VAT.create ~config ~producer with
    | Error reason -> Alcotest.failf "surface creation failed: %s" reason
    | Ok surface -> f config surface
  in
  if remote
  then (
    (* The SSH runner spawns through [Process_eio], which answers "initialized
       Eio runtime required" until it holds this run's process manager. The
       Docker route reaches its backend without it, which is why only this
       branch pays for it. *)
    let clock = Eio.Stdenv.clock env in
    Eio_context.set_clock clock;
    Eio_context.set_switch sw;
    Process_eio.init
      ~cwd_default:Eio.Path.(Eio.Stdenv.fs env / Sys.getcwd ())
      ~proc_mgr:(Eio.Stdenv.process_mgr env)
      ~clock;
    (* The bootstrap preflight ends in [gh auth status], which a fixture
       endpoint cannot answer; the read path under test never needed it. *)
    with_env "MASC_KEEPER_SANDBOX_PREFLIGHT_ENABLED" "false" (fun () ->
      with_fake_ssh ?script:ssh_script run))
  else run ()
;;

let require_layout = function
  | Ok layout -> layout
  | Error detail -> Alcotest.failf "root layout unavailable: %s" detail
;;

(* Create the producer playground used to resolve relative tool paths. *)
let producer_playground (config : Workspace_core.config) producer_name =
  let path =
    Keeper_sandbox_config.host_root_abs_of_agent
      ~base_path:
        (Workspace_verification_store.project_root_of_base_path config.base_path)
      ~agent_name:producer_name
  in
  let rec mkdir_p dir =
    if not (Sys.file_exists dir)
    then (
      mkdir_p (Filename.dirname dir);
      try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p path;
  path
;;

(* A workspace agent declares no sandbox profile, so its root is the
   playground itself -- the same arm [VAT.create] takes for a producer with no
   keeper meta. Writing here and then reading through the surface is what
   proves the two agree on the root; a path this file invented on its own
   would pass while the product looked somewhere else. *)
let workspace_producer_playground (config : Workspace_core.config) producer_name =
  let path =
    Filename.concat
      (Workspace_verification_store.project_root_of_base_path config.base_path)
      (Playground_paths.bundle_root producer_name)
  in
  Fs_compat.mkdir_p path;
  path
;;

(* The judge and producer share the descriptor-owned model surface. *)
let test_schemas_are_the_descriptor_schemas () =
  with_surface (fun _config surface ->
    let offered = VAT.schemas surface in
    let names =
      List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) offered
    in
    Alcotest.(check (list string))
      "the surface is read-only"
      [ "tool_read_file"; "tool_search_files"; "masc_web_fetch" ]
      names;
    List.iter
      (fun (schema : Masc_domain.tool_schema) ->
         match Descriptor.descriptors_for_internal schema.name with
         | [ descriptor ] ->
           (* The lookup surface alone reads images as visual input, so its
              read_file description carries the descriptor's text plus that
              one sanctioned sentence. *)
           let expected =
             match schema.name with
             | "tool_read_file" ->
                 descriptor.Descriptor.description
                 ^ " " ^ VAT.image_delivery_note
             | _ -> descriptor.Descriptor.description
           in
           Alcotest.(check string)
             (schema.name ^ " description is the descriptor's")
             expected
             schema.description;
           Alcotest.(check bool)
             (schema.name ^ " input schema is the descriptor's")
             true
             (Yojson.Safe.equal descriptor.Descriptor.input_schema schema.input_schema)
         | found ->
           Alcotest.failf
             "%s resolves to %d descriptors; the surface needs exactly one"
             schema.name
             (List.length found))
      offered)
;;

(* A successful read proves descriptor translation reaches the runtime handler;
   a missing required argument must be rejected at the same boundary. *)
let test_read_translates_the_advertised_argument_and_refuses_a_malformed_one () =
  with_surface (fun config surface ->
    let playground = producer_playground config producer in
    let name = "advertised-argument-probe.txt" in
    let contents = "written by the probe" in
    (try
       Out_channel.with_open_text (Filename.concat playground name) (fun oc ->
         output_string oc contents)
     with
     | Sys_error err -> Alcotest.failf "probe file could not be written: %s" err);
    let read key =
      dispatch_text surface ~name:"tool_read_file" ~args:(`Assoc [ key, `String name ])
    in
    let required =
      match
        List.find_opt
          (fun (schema : Masc_domain.tool_schema) ->
             String.equal schema.name "tool_read_file")
          (VAT.schemas surface)
      with
      | Some { input_schema = `Assoc fields; _ } ->
        (match List.assoc_opt "required" fields with
         | Some (`List (`String field :: _)) -> field
         | _ -> Alcotest.fail "tool_read_file advertises no required argument")
      | _ -> Alcotest.fail "tool_read_file is not offered"
    in
    (match read required with
     | Error detail ->
       Alcotest.failf
         "the advertised required argument %S did not reach the handler: %s"
         required
         detail
     | Ok output ->
       (* The producer's tree is on the endpoint, so the bytes come back from
          the shim, not from the host copy written above. This asserts the
          argument reached the backend and a read resolved; that the host path
          is translated to the endpoint's is pinned separately, by
          test_keeper_sandbox_read_backend. *)
       Alcotest.(check bool)
         (Printf.sprintf "%S returns what the endpoint served" required)
         true
         (Astring.String.is_infix ~affix:ssh_fixture_body output));
    match dispatch_text surface ~name:"tool_read_file" ~args:(`Assoc []) with
    | Ok output ->
      Alcotest.failf
        "a read with no %S resolved instead of being refused, so an unopened \
         file reads as an answer: %s"
        required
        output
    | Error detail ->
      Alcotest.(check bool)
        "the refusal names the missing argument"
        true
        (Astring.String.is_infix ~affix:required detail))
;;

(* The persisted runtime snapshot deliberately omits TOML-owned policy fields.
   The verifier must reapply the current profile before choosing the producer
   root, or a Docker keeper's evidence is looked up in the local playground. *)
let test_keeper_surface_uses_the_effective_sandbox_root () =
  with_surface ~sandbox_profile:"docker" (fun config surface ->
    let playground = producer_playground config producer in
    let name = "docker-evidence.json" in
    Out_channel.with_open_text (Filename.concat playground name) (fun channel ->
      output_string channel "{\"lane\":\"docker\"}\n");
    match VAT.root_layout surface with
    | Error detail ->
      Alcotest.failf "Docker producer root was not inspected: %s" detail
    | Ok layout ->
      Alcotest.(check bool)
        "inspects the Docker-scoped producer root"
        true
        (List.exists
           (Astring.String.is_infix ~affix:name)
           layout))
;;

(* A search requires an explicit non-empty pattern. *)
let test_search_refuses_a_call_without_its_required_pattern () =
  with_surface (fun config surface ->
    ignore (producer_playground config producer);
    (match
       dispatch_text surface ~name:"tool_search_files" ~args:(`Assoc [])
     with
     | Ok output ->
       Alcotest.failf
         "a search with no pattern resolved instead of being refused: %s"
         output
     | Error detail ->
       Alcotest.(check bool)
         "the refusal names the missing argument"
         true
         (Astring.String.is_infix ~affix:"pattern" detail));
    match
      dispatch_text
        surface
        ~name:"tool_search_files"
        ~args:(`Assoc [ "pattern", `String "advertised" ])
    with
    | Ok _ -> ()
    | Error detail ->
      Alcotest.failf "a search carrying its pattern was refused: %s" detail)
;;

(* A judge that calls a name this surface does not offer must be told so. A
   dropped call would read to the model as a tool that returned nothing. *)
let test_unknown_tool_name_is_an_error () =
  with_surface (fun _config surface ->
    match dispatch_text surface ~name:"tool_write_file" ~args:(`Assoc []) with
    | Ok output -> Alcotest.failf "unknown tool should not succeed; got %s" output
    | Error detail ->
      Alcotest.(check bool)
        "names the offered tools"
        true
        (Astring.String.is_infix ~affix:"tool_search_files" detail))
;;

(* Workspace agents are valid verification producers even though they have no
   Keeper runtime metadata. Their surface is rooted directly at the producer
   playground and exposes only the owned regular-file reader. *)
let test_workspace_producer_gets_owned_read_surface () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  let producer_name = "workspace-producer" in
  let playground = workspace_producer_playground config producer_name in
  let path = Filename.concat playground "evidence.txt" in
  Out_channel.with_open_text path (fun channel ->
    output_string channel "first line\nsecond line\n");
  match VAT.create ~config ~producer:producer_name with
  | Error reason -> Alcotest.failf "workspace surface creation failed: %s" reason
  | Ok surface ->
    Alcotest.(check (list string))
      "workspace producer surface"
      [ "tool_read_file"; "masc_web_fetch" ]
      (VAT.schemas surface
       |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name));
    (match
       dispatch_text
         surface
         ~name:"tool_read_file"
         ~args:
           (`Assoc
               [ "file_path", `String "evidence.txt"
               ; "offset", `Int 2
               ; "limit", `Int 1
               ])
     with
     | Error detail -> Alcotest.failf "owned read failed: %s" detail
     | Ok payload ->
       let json = Yojson.Safe.from_string payload in
       Alcotest.(check string)
         "reads the requested line"
         "second line\n"
         Yojson.Safe.Util.(json |> member "content" |> to_string));
    (match dispatch_text surface ~name:"tool_search_files" ~args:(`Assoc []) with
     | Ok output -> Alcotest.failf "workspace search unexpectedly ran: %s" output
     | Error detail ->
       Alcotest.(check bool)
         "error lists only the exact offered surface"
         false
         (Astring.String.is_infix ~affix:"this review offers tool_search_files" detail))
;;

(* Nothing creates a workspace producer's playground: no boot, no sandbox.
   Its absence is a fact about the producer, not an unavailable surface, and
   deferring on it left every Task submitted over MCP awaiting a verdict that
   never came (nine Tasks, 131 sweep lines on 2026-09-11). The judge gets the
   fact as its layout and rules on the evidence that is there. *)
let test_workspace_producer_without_a_playground_gets_a_stated_absence () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  let producer_name = "mcp-client" in
  let bundle =
    Filename.concat Playground_paths.all_playgrounds_prefix producer_name
  in
  match VAT.create ~config ~producer:producer_name with
  | Error reason -> Alcotest.failf "workspace surface creation failed: %s" reason
  | Ok surface ->
    let layout = VAT.root_layout surface |> require_layout in
    Alcotest.(check int) "one line states the absence" 1 (List.length layout);
    Alcotest.(check bool)
      "the line names the absent root"
      true
      (List.exists (fun entry -> Astring.String.is_infix ~affix:bundle entry) layout);
    Alcotest.(check bool)
      "the playground is not created as a side effect of the review"
      false
      (Sys.file_exists
         (Filename.concat
            (Workspace_verification_store.project_root_of_base_path config.base_path)
            bundle))
;;

(* Unsupported binary lookups must retain their encoding failure through the
   descriptor/owned-file path, observation persistence and API projection used
   by the completion reviewer. No model verdict is simulated. *)
let test_binary_lookup_failures_survive_observation_replay () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  let producer_name = "binary-evidence-producer" in
  let playground = workspace_producer_playground config producer_name in
  let surface =
    match VAT.create ~config ~producer:producer_name with
    | Ok surface -> surface
    | Error detail -> Alcotest.fail detail
  in
  let module Registry = Masc.Verification_run_registry in
  let journal = Filename.concat dir "binary-review.jsonl" in
  let registry = Registry.create ~path:journal () in
  let verification_id = "vrf-binary-lookups" in
  Registry.register_running registry ~verification_id ~task_id:"task-binary"
    ~producer:producer_name ~authority_kind:"system_llm_agent"
    ~authority_actor:"verifier_exact" ~started_at:1.0;
  let fixtures =
    [ "unsupported.bin", "\000\255\147\140" ]
  in
  let tools = List.map (fun (name, bytes) ->
    Out_channel.with_open_bin (Filename.concat playground name)
      (fun channel -> output_string channel bytes);
    let input = `Assoc [ "file_path", `String name; "limit", `Int 5 ] in
    let detail = match dispatch_text surface ~name:"tool_read_file" ~args:input with
      | Ok _ -> Alcotest.fail "binary text lookup must not succeed"
      | Error detail -> detail
    in
    Alcotest.(check bool) "error is UTF-8" true (String_util.is_valid_utf8 detail);
    let json = Yojson.Safe.from_string detail in
    Alcotest.(check string) "explicit encoding failure"
      "lookup_output_invalid_utf8"
      Yojson.Safe.Util.(json |> member "code" |> to_string);
    Alcotest.(check bool) "failure retains output size" true
      (Yojson.Safe.Util.(json |> member "output_bytes" |> to_int) > 0);
    Alcotest.(check int) "failure retains output digest" 64
      (String.length Yojson.Safe.Util.(json |> member "output_sha256" |> to_string));
    Registry.observe_tool_result ~input ~finished_at:2.0
      (Tool_result.error ~failure_class:Tool_result.Runtime_failure
         ~tool_name:"tool_read_file" ~start_time:(Time_compat.now ()) detail)
  ) fixtures in
  Registry.mark_completed registry ~verification_id
    ~outcome:(Registry.Rejected { reason = "lookup text unavailable" })
    ~tools ~elapsed_s:1.0 ();
  let persisted = In_channel.with_open_bin journal In_channel.input_all in
  Alcotest.(check bool) "journal is UTF-8" true (String_util.is_valid_utf8 persisted);
  let replayed = Registry.replay journal in
  let run = match Registry.get replayed ~verification_id with
    | Some run -> run
    | None -> Alcotest.fail "review must survive replay"
  in
  let api_json = Registry.run_to_yojson run in
  Alcotest.(check bool) "API projection is UTF-8" true
    (String_util.is_valid_utf8 (Yojson.Safe.to_string api_json));
  match run.status with
  | Registry.Completed { tools; _ } ->
    Alcotest.(check int) "binary failure retained" 1 (List.length tools);
    List.iter (fun (tool : Registry.tool_observation) ->
      match tool.disposition with
      | Tool_result.Failed () -> ()
      | _ -> Alcotest.fail "binary lookup was falsely recorded as successful") tools
  | Registry.Running -> Alcotest.fail "completion lost on replay"
;;

let make_checkout root relative =
  let mkdir path = try Unix.mkdir path 0o755 with Unix.Unix_error _ -> () in
  let rec mkdir_p path =
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then mkdir_p parent;
    mkdir path
  in
  let checkout = Filename.concat root relative in
  mkdir_p checkout;
  mkdir (Filename.concat checkout ".git")
;;

let test_root_layout_fails_closed_when_discovery_is_unavailable () =
  with_surface (fun _config surface ->
    match VAT.root_layout surface with
    | Ok layout ->
      Alcotest.failf
        "missing producer root was presented as a usable layout: %s"
        (String.concat ", " layout)
    | Error detail ->
      Alcotest.(check bool)
        "unavailable discovery remains an error"
        true
        (Astring.String.is_infix ~affix:"workspace root" detail
         || Astring.String.is_infix ~affix:"verification root" detail))
;;

let test_root_layout_fails_closed_when_checkout_discovery_is_partial () =
  with_surface (fun config surface ->
    let root = producer_playground config producer in
    for index = 0 to Masc.Keeper_playground_checkouts.max_reported_checkouts do
      make_checkout root (Printf.sprintf "checkout-%02d" index)
    done;
    match VAT.root_layout surface with
    | Ok layout ->
      Alcotest.failf
        "partial checkout discovery was presented as complete: %s"
        (String.concat ", " layout)
    | Error detail ->
      Alcotest.(check bool)
        "partial discovery names its limit"
        true
        (Astring.String.is_infix ~affix:"checkout discovery is partial" detail))
;;

let test_root_layout_reports_entries_and_discovered_checkouts () =
  with_surface (fun config surface ->
    let root = producer_playground config producer in
    let mkdir path = try Unix.mkdir path 0o755 with Unix.Unix_error _ -> () in
    make_checkout root "repos/masc";
    (* A checkout the conventional prefix would miss entirely. *)
    make_checkout root "scratch-tree";
    mkdir (Filename.concat root "artifacts");
    let layout = VAT.root_layout surface |> require_layout in
    let holds affix =
      List.exists (fun entry -> Astring.String.is_infix ~affix entry) layout
    in
    Alcotest.(check bool)
      "reports a checkout under the keeper's own repos/ convention"
      true
      (holds "repos/masc");
    Alcotest.(check bool)
      "reports a checkout that convention would have missed"
      true
      (holds "scratch-tree");
    Alcotest.(check bool)
      "a checkout is marked as one, so a path prefix is identifiable"
      true
      (holds "git checkout");
    Alcotest.(check bool)
      "still names the root's own entries, which need no prefix"
      true
      (holds "artifacts"))
;;

let test_prompt_states_the_root_and_not_a_repository () =
  with_surface (fun config surface ->
    let root = producer_playground config producer in
    make_checkout root "repos/masc";
    let request : AR.review_request =
      { agent_name = producer
      ; task_title = "t"
      ; task_description = "d"
      ; completion_notes = "n"
      ; task_id = "task-403"
      ; evidence_refs = []
      ; evidence_images = []
      }
    in
    let text =
      match
        AR.build_prompt
          ~question:
            { AR.completion_contract = None
            ; required_evidence = []
            ; evidence_posture = AR.Note_only
            ; few_shot_block = ""
            }
          ~lookup:
            (AR.Lookup_tools
               { schemas = VAT.schemas surface
               ; dispatch = VAT.dispatch surface
               ; root_layout = VAT.root_layout surface |> require_layout
               })
          request
      with
      | Ok text -> text
      | Error detail -> Alcotest.failf "prompt render failed: %s" detail
    in
    Alcotest.(check bool)
      "the prompt shows the checkout prefix the evaluator would otherwise guess"
      true
      (Astring.String.is_infix ~affix:"repos/masc" text);
    (* Anchored on the fragment's tag, not on a sentence inside it (#32663):
       the English sentences this once pinned stopped existing when the
       prompts were translated (#32133), and the check had been asserting
       prose no template could produce. What the section says -- a missing
       path answers about the path, not about the work -- is reviewed in
       config/prompts/verification.md, slot lookup.producer_tree. *)
    Alcotest.(check bool)
      "the live lookup section reaches the prompt"
      true
      (Astring.String.is_infix ~affix:"<live_lookup>" text))
;;

let test_prompt_states_the_available_surface () =
  with_surface (fun config surface ->
    ignore (producer_playground config producer);
    let request : AR.review_request =
      { agent_name = producer
      ; task_title = "t"
      ; task_description = "d"
      ; completion_notes = "n"
      ; task_id = "task-001"
      ; evidence_refs = []
      ; evidence_images = []
      }
    in
    let render lookup =
      let question =
        { AR.completion_contract = None
        ; required_evidence = []
        ; evidence_posture = AR.Note_only
        ; few_shot_block = ""
        }
      in
      match AR.build_prompt ~question ~lookup request with
      | Ok text -> text
      | Error detail -> Alcotest.failf "prompt render failed: %s" detail
    in
    let without = render AR.No_lookup_surface in
    let with_tools =
      render
        (AR.Lookup_tools
           { schemas = VAT.schemas surface
           ; dispatch = VAT.dispatch surface
           ; root_layout = VAT.root_layout surface |> require_layout
           })
    in
    Alcotest.(check bool)
      "toolless prompt carries the no-lookup section"
      true
      (Astring.String.is_infix ~affix:"<no_lookup_surface>" without);
    Alcotest.(check bool)
      "toolless prompt carries no live lookup section"
      false
      (Astring.String.is_infix ~affix:"<live_lookup>" without);
    Alcotest.(check bool)
      "toolless prompt does not advertise a tool"
      false
      (Astring.String.is_infix ~affix:"tool_search_files" without);
    Alcotest.(check bool)
      "tool prompt names the tools"
      true
      (Astring.String.is_infix ~affix:"tool_search_files" with_tools);
    Alcotest.(check bool)
      "tool prompt carries no no-lookup section"
      false
      (Astring.String.is_infix ~affix:"<no_lookup_surface>" with_tools);
    (* The read-only boundary is a sentence inside the live-lookup fragment
       (config/prompts/verification.md, slot lookup.producer_tree); the prompt is
       checked for carrying that fragment, and the sentence is reviewed there. *)
    Alcotest.(check bool)
      "tool prompt carries the live lookup section"
      true
      (Astring.String.is_infix ~affix:"<live_lookup>" with_tools))
;;


(* masc#28989: a URL left in note evidence must be inspectable by the judge
   itself. The fetch boundary is stubbed; what is pinned here is the surface —
   the tool is offered on both producer scopes, a valid call dispatches through
   the shared guards, and the typed envelope reaches the judge. *)
let test_web_fetch_is_offered_and_dispatches () =
  with_surface (fun _config surface ->
    Alcotest.(check bool)
      "keeper producer offers tool_web_fetch"
      true
      (List.exists
         (fun (schema : Masc_domain.tool_schema) ->
           String.equal schema.name "masc_web_fetch")
         (VAT.schemas surface));
    Masc.Tool_misc_web_fetch.with_http_fetch_for_test
      (fun ~timeout_sec:_ ~headers:_ ~max_response_bytes:_ url ->
        Ok
          { Masc.Tool_misc_web_fetch.http_status = Some 200
          ; final_url = url
          ; redirect_count = 0
          ; content_type = Some "text/plain"
          ; downloaded_bytes = Some 20
          ; body = "diff --git a/x b/x\n"
          })
      (fun () ->
        match
          dispatch_text
            surface
            ~name:"masc_web_fetch"
            ~args:
              (`Assoc
                [ "url", `String "https://github.com/jeong-sik/masc/pull/28988"
                ])
        with
        | Error reason -> Alcotest.failf "web fetch dispatch failed: %s" reason
        | Ok output ->
          Alcotest.(check bool)
            "envelope carries the fetched text"
            true
            (Astring.String.is_infix ~affix:"diff --git" output)))
;;

let test_web_fetch_refuses_a_private_target () =
  with_surface (fun _config surface ->
    match
      dispatch_text
        surface
        ~name:"masc_web_fetch"
        ~args:(`Assoc [ "url", `String "http://127.0.0.1:8935/health" ])
    with
    | Ok output ->
      Alcotest.failf "private-network fetch must be refused, got: %s" output
    | Error _ -> ())
;;

let test_keeper_endpoint_read_preserves_png_bytes () =
  let fixture = Filename.concat
      (match Sys.getenv_opt "DUNE_SOURCEROOT" with Some root -> root | None -> Sys.getcwd ())
      "test/fixtures/verifier-image-lookup.png" in
  let bytes = In_channel.with_open_bin fixture In_channel.input_all in
  let trailer = Exec_ssh_protocol.render_trailer
      { v=Exec_ssh_protocol.newest; exit=Some 0; signal=None; timed_out=false; shim_error=None } in
  let ssh_script = Printf.sprintf
      "#!/bin/sh\ncat >/dev/null 2>/dev/null &\ncat %s\nprintf '%%s' %s >&2\nexit 0\n"
      (Filename.quote fixture) (Filename.quote trailer) in
  with_surface ~ssh_script (fun config surface ->
    ignore (producer_playground config producer);
    let result = VAT.dispatch surface ~name:"tool_read_file"
        ~args:(`Assoc [ "file_path", `String "endpoint-only.png" ]) in
    match result with
    | Tool_result.Completed { content_blocks=Some blocks; data; _ } ->
      Alcotest.(check bool) "remote complete byte count" true
        (Yojson.Safe.Util.member "bytes" data = `Int (String.length bytes));
      Alcotest.(check bool) "remote raw PNG reaches model unchanged" true
        (List.exists (function
          | Llm_provider.Types.Image { data; _ } -> Base64.decode_exn data = bytes
          | _ -> false) blocks)
    | _ -> Alcotest.fail (Tool_result.message result))
;;

let test_goal_and_task_read_deliver_full_png () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  let producer_name = "visual-producer" in
  let root = workspace_producer_playground config producer_name in
  let fixture = Filename.concat
      (match Sys.getenv_opt "DUNE_SOURCEROOT" with Some root -> root | None -> Sys.getcwd ())
      "test/fixtures/verifier-image-lookup.png" in
  let bytes = In_channel.with_open_bin fixture In_channel.input_all in
  Alcotest.(check bool) "fixture exceeds text Read default" true (String.length bytes > 200000);
  let image_path = Filename.concat root "proof.png" in
  Out_channel.with_open_bin image_path (fun out -> output_string out bytes);
  let sha = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let encoded = Base64.encode_exn bytes in
  let task_surface = VAT.create ~config ~producer:producer_name |> Result.get_ok in
  let goal_surface = VAT.create_goal_proof ~config |> Result.get_ok in
  List.iter (fun (surface, path) ->
    let args = `Assoc [ "file_path", `String path ] in
    let result = VAT.dispatch surface ~name:"tool_read_file" ~args in
    (match result with
     | Tool_result.Completed output ->
       Alcotest.(check bool) "SHA receipt" true
         (Yojson.Safe.Util.member "sha256" output.data = `String sha);
       Alcotest.(check bool) "full byte receipt" true
         (Yojson.Safe.Util.member "bytes" output.data = `Int (String.length bytes))
     | Tool_result.Failed _ | Tool_result.Deferred _ -> Alcotest.fail (Tool_result.message result));
    let observation = Tool_result.to_json result |> Yojson.Safe.to_string in
    Alcotest.(check bool) "observation valid UTF-8" true (String_util.is_valid_utf8 observation);
    Alcotest.(check bool) "observation excludes image body" false
      (Astring.String.is_infix ~affix:encoded observation);
    let output = Masc.Tool_bridge.to_agent_core_typed_result result |> Result.get_ok in
    let actual_blocks = match output.content_blocks with
      | Some blocks -> blocks | None -> Alcotest.fail "bridge erased image blocks" in
    Alcotest.(check bool) "bridge preserves complete PNG" true
      (List.exists (function
         | Agent_core.Types.Image { media_type="image/png"; data; source_type=Base64 } -> data = encoded
         | _ -> false) actual_blocks);
    let message role content : Agent_core.Types.message =
      { role; content; name=None; tool_call_id=None; metadata=[] } in
    let messages =
      [ message User [ Text "Inspect the artifact visually" ]
      ; message Assistant [ ToolUse { id="read-visual"; name="Read"; input=args } ]
      ; message Tool [ ToolResult { tool_use_id="read-visual"; content=output.content
                                 ; content_blocks=output.content_blocks; json=None; outcome=Tool_succeeded } ] ] in
    let provider = Llm_provider.Provider_config.make ~kind:Anthropic
      ~model_id:"visual-fixture" ~base_url:"https://api.anthropic.com" ~max_tokens:1024 () in
    let request = Llm_provider.Backend_anthropic.build_request ~config:provider ~messages ()
      |> Yojson.Safe.from_string in
    let rec has_image = function
      | `Assoc fields ->
        (match List.assoc_opt "type" fields, List.assoc_opt "source" fields with
         | Some (`String "image"), Some (`Assoc source) -> List.assoc_opt "data" source = Some (`String encoded)
         | _ -> List.exists (fun (_, value) -> has_image value) fields)
      | `List items -> List.exists has_image items
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> false in
    Alcotest.(check bool) "next request receives image bytes" true (has_image request))
    [ task_surface, "proof.png"; goal_surface, producer_name ^ "/proof.png" ];
  let outside = Filename.concat dir "outside.png" in
  Out_channel.with_open_bin outside (fun out -> output_string out bytes);
  Unix.symlink outside (Filename.concat root "escape.png");
  let rejected path =
    let result = VAT.dispatch goal_surface ~name:"tool_read_file"
      ~args:(`Assoc [ "file_path", `String path ]) in
    Alcotest.(check bool) "out-of-root read rejected" true (Tool_result.is_failed result)
  in
  rejected outside;
  rejected (producer_name ^ "/escape.png");
  with_env "MASC_KEEPER_VISION_MAX_IMAGE_BYTES" "1024" (fun () ->
    let result = VAT.dispatch goal_surface ~name:"tool_read_file"
      ~args:(`Assoc [ "file_path", `String (producer_name ^ "/proof.png") ]) in
    Alcotest.(check bool) "existing image cap enforced" true
      (Tool_result.failure_class result = Some Tool_result.Policy_rejection));
  Alcotest.(check string) "read left exact file unchanged" bytes
    (In_channel.with_open_bin image_path In_channel.input_all)
;;

let test_goal_and_task_inspect_real_pdf () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Masc_test_deps.init_eio_clock ~sw env;
  let dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  Process_eio.init ~cwd_default:Eio.Path.(env#fs / dir)
    ~proc_mgr:env#process_mgr ~clock:env#clock;
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "pdf-test"));
  let producer_name = "pdf-producer" in
  let root = workspace_producer_playground config producer_name in
  let fixture = Filename.concat (Masc_test_deps.find_project_root ())
    "docs/evidence/2026-09-10-collaboration-baseline/goal-publication/booklet.pdf" in
  let bytes = In_channel.with_open_bin fixture In_channel.input_all in
  let sha = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let source = Filename.concat root "booklet.pdf" in
  Out_channel.with_open_bin source (fun out -> output_string out bytes);
  Out_channel.with_open_bin (Filename.concat root "broken.pdf")
    (fun out -> output_string out "%PDF-1.7\nnot a PDF document\n");
  let task = VAT.create ~config ~producer:producer_name |> Result.get_ok in
  let goal = VAT.create_goal_proof ~config |> Result.get_ok in
  let read surface path = VAT.dispatch surface ~name:"tool_read_file"
    ~args:(`Assoc ["file_path",`String path]) in
  List.iter (fun (surface,prefix) ->
    let result = read surface (prefix ^ "booklet.pdf") in
    (match result with
     | Tool_result.Completed {data;content_blocks=Some blocks;_} ->
       let open Yojson.Safe.Util in
       Alcotest.(check int) "exact original PDF byte count" (String.length bytes)
         (member "bytes" data |> to_int);
       Alcotest.(check string) "exact original PDF SHA-256" sha
         (member "sha256" data |> to_string);
       Alcotest.(check int) "Poppler parsed three pages" 3 (member "page_count" data |> to_int);
       let pages = member "pages" data |> to_list in
       Alcotest.(check int) "all page metadata delivered" 3 (List.length pages);
       let images = List.filter_map (function
         | Llm_provider.Types.Image {media_type="image/png";data;source_type=Base64} ->
           Some (Base64.decode_exn data)
         | _ -> None) blocks in
       Alcotest.(check int) "all three parsed pages actually rendered" 3 (List.length images);
       List.iteri (fun i (page,png) ->
         Alcotest.(check int) "page identity" (i+1) (member "page" page |> to_int);
         Alcotest.(check string) "rendered bytes tied to metadata"
           Digestif.SHA256.(digest_string png |> to_hex)
           (member "rendered_sha256" page |> to_string);
         Alcotest.(check bool) "A4 width from parsed PDF geometry" true
           (abs_float ((member "width_points" page |> to_float) -. 595.2756) < 0.001);
         Alcotest.(check bool) "A4 height from parsed PDF geometry" true
           (abs_float ((member "height_points" page |> to_float) -. 841.8898) < 0.001))
         (List.combine pages images);
       Alcotest.(check bool) "Korean text was extracted from original PDF" true
         (List.exists (fun page -> String_util.contains_substring
           (member "text" page |> to_string) "기억의 정원") pages)
     | _ -> Alcotest.fail (Tool_result.message result));
    Alcotest.(check bool) "malformed PDF never becomes successful metadata" true
      (Tool_result.is_failed (read surface (prefix ^ "broken.pdf")));
    let partial = VAT.dispatch surface ~name:"tool_read_file"
      ~args:(`Assoc ["file_path",`String (prefix ^ "booklet.pdf");"limit",`Int 1]) in
    Alcotest.(check bool) "line windows do not masquerade as complete PDF" true
      (Tool_result.failure_class partial = Some Tool_result.Workflow_rejection))
    [task,"";goal,producer_name ^ "/"];
  let outside = Filename.concat dir "outside.pdf" in
  Out_channel.with_open_bin outside (fun out -> output_string out bytes);
  Unix.symlink outside (Filename.concat root "escape.pdf");
  List.iter (fun (surface,path) ->
    Alcotest.(check bool) "PDF access keeps the same owned root" true
      (Tool_result.is_failed (read surface path)))
    [task,outside;goal,outside;task,"escape.pdf";goal,producer_name ^ "/escape.pdf"];
  with_env "PATH" (Filename.concat dir "no-poppler") (fun () ->
    let result = read task "booklet.pdf" in
    Alcotest.(check bool) "missing parser is an explicit infrastructure failure" true
      (Tool_result.is_failed result && String_util.contains_substring
        (Tool_result.message result) "pdf_dependency_unavailable"));
  Alcotest.(check string) "read-only inspection preserves original PDF" bytes
    (In_channel.with_open_bin source In_channel.input_all)
;;

let test_goal_and_task_inspect_real_mp4 () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Masc_test_deps.init_eio_clock ~sw env;
  let dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  Process_eio.init ~cwd_default:Eio.Path.(env#fs / dir)
    ~proc_mgr:env#process_mgr ~clock:env#clock;
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "video-test"));
  let producer_name = "video-producer" in
  let root = workspace_producer_playground config producer_name in
  let fixture = Filename.concat (Masc_test_deps.find_project_root ())
    "test/fixtures/verifier-video.mp4" in
  let bytes = In_channel.with_open_bin fixture In_channel.input_all in
  let sha = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let source = Filename.concat root "clip.mp4" in
  Out_channel.with_open_bin source (fun out -> output_string out bytes);
  Out_channel.with_open_bin (Filename.concat root "broken.mp4")
    (fun out -> output_string out (String.sub bytes 0 (String.length bytes / 2)));
  let task = VAT.create ~config ~producer:producer_name |> Result.get_ok in
  let goal = VAT.create_goal_proof ~config |> Result.get_ok in
  let read surface path = VAT.dispatch surface ~name:"tool_read_file"
    ~args:(`Assoc ["file_path",`String path]) in
  List.iter (fun (surface,prefix) ->
    let result = read surface (prefix ^ "clip.mp4") in
    (match result with
     | Tool_result.Completed {data;_} ->
       let open Yojson.Safe.Util in
       let data = member "inspection" data in
       Alcotest.(check int) "exact video bytes" (String.length bytes) (member "bytes" data |> to_int);
       Alcotest.(check string) "exact video SHA" sha (member "sha256" data |> to_string);
       Alcotest.(check bool) "video and audio independently observed" true
         (member "video_present" data = `Bool true && member "audio_present" data = `Bool true);
       Alcotest.(check bool) "all audio/video streams decoded" true
         (member "decoded_stream_indices" data = `List [`Int 0;`Int 1]);
       Alcotest.(check bool) "no visual inspection invented" true
         (member "visual_input" data = `Bool false);
       Alcotest.(check int) "direct decoder exit" 0
         (member "full_decode" data |> member "exit_code" |> to_int);
       Alcotest.(check (float 0.001)) "observed duration" 1.
         (member "duration_seconds" data |> to_float);
       let video = member "streams" data |> to_list |> List.hd in
       Alcotest.(check int) "decoded video width" 64 (member "width" video |> to_int);
       Alcotest.(check int) "decoded video height" 48 (member "height" video |> to_int)
     | _ -> Alcotest.fail (Tool_result.message result));
    Alcotest.(check bool) "truncated video is not a complete successful decode" true
      (Tool_result.is_failed (read surface (prefix ^ "broken.mp4")));
    let partial = VAT.dispatch surface ~name:"tool_read_file"
      ~args:(`Assoc ["file_path",`String (prefix ^ "clip.mp4");"limit",`Int 1]) in
    Alcotest.(check bool) "line window refused" true
      (Tool_result.failure_class partial = Some Tool_result.Workflow_rejection))
    [task,"";goal,producer_name ^ "/"];
  let outside = Filename.concat dir "outside.mp4" in
  Out_channel.with_open_bin outside (fun out -> output_string out bytes);
  Unix.symlink outside (Filename.concat root "escape.mp4");
  List.iter (fun (surface,path) ->
    Alcotest.(check bool) "video keeps producer containment" true
      (Tool_result.is_failed (read surface path)))
    [task,outside;goal,outside;task,"escape.mp4";goal,producer_name ^ "/escape.mp4"];
  with_env "PATH" (Filename.concat dir "no-ffmpeg") (fun () ->
    List.iter (fun (surface,path) ->
      let result = read surface path in
      Alcotest.(check bool) "missing decoder keeps dependency classification" true
        (Tool_result.failure_class result = Some Tool_result.Dependency_unavailable);
      Alcotest.(check bool) "missing decoder is stated" true
        (String_util.contains_substring (Tool_result.message result) "video_dependency_unavailable"))
      [task,"clip.mp4";goal,producer_name ^ "/clip.mp4"]);
  (* The process runner's deadline result must not reject the producer's
     evidence as a policy violation. Exercise the public dispatch projection. *)
  let fake_bin = Filename.concat dir "timeout-bin" in
  Unix.mkdir fake_bin 0o700;
  List.iter (fun program ->
    let executable = Filename.concat fake_bin program in
    Out_channel.with_open_bin executable (fun out -> output_string out "#!/bin/sh\nexit 124\n");
    Unix.chmod executable 0o700) ["ffmpeg"; "ffprobe"];
  with_env "PATH" fake_bin (fun () ->
    List.iter (fun (surface,path) ->
      let result = read surface path in
      Alcotest.(check bool) "command deadline is a runtime failure" true
        (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
      Alcotest.(check bool) "timeout diagnostic explicit" true
        (String_util.contains_substring (Tool_result.message result) "video_inspection_timeout"))
      [task,"clip.mp4";goal,producer_name ^ "/clip.mp4"]);
  let oversized = Filename.concat root "oversized.mp4" in
  Out_channel.with_open_bin oversized (fun out ->
    seek_out out (64 * 1024 * 1024);
    output_char out '\000');
  with_env "PATH" (Filename.concat dir "no-ffmpeg") (fun () ->
    List.iter (fun (surface,path) ->
      let result = read surface path in
      Alcotest.(check bool) "oversized source rejected before decoder lookup" true
        (Tool_result.failure_class result = Some Tool_result.Policy_rejection
         && String_util.contains_substring (Tool_result.message result) "media_source_too_large"))
      [task,"oversized.mp4";goal,producer_name ^ "/oversized.mp4"]);
  Alcotest.(check string) "inspection preserves source" bytes
    (In_channel.with_open_bin source In_channel.input_all)
;;

(* A capture saved without its extension used to fall through to the ordinary
   text Read, which projects container bytes as characters. The ISO file type
   box is what names the format, so the same file must reach the same
   inspection under either name. *)
let test_a_capture_without_the_mp4_extension_is_still_inspected () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs env#fs;
  Masc_test_deps.init_eio_clock ~sw env;
  let dir = temp_dir () in
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  Process_eio.init ~cwd_default:Eio.Path.(env#fs / dir)
    ~proc_mgr:env#process_mgr ~clock:env#clock;
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "video-signature-test"));
  let producer_name = "video-signature-producer" in
  let root = workspace_producer_playground config producer_name in
  let fixture = Filename.concat (Masc_test_deps.find_project_root ())
    "test/fixtures/verifier-video.mp4" in
  let bytes = In_channel.with_open_bin fixture In_channel.input_all in
  let sha = Digestif.SHA256.(digest_string bytes |> to_hex) in
  List.iter (fun filename ->
  Out_channel.with_open_bin (Filename.concat root filename)
    (fun out -> output_string out bytes);
  let task = VAT.create ~config ~producer:producer_name |> Result.get_ok in
  let result = VAT.dispatch task ~name:"tool_read_file"
    ~args:(`Assoc ["file_path",`String filename]) in
  (match result with
   | Tool_result.Completed {data;_} ->
     let open Yojson.Safe.Util in
     let data = member "inspection" data in
     Alcotest.(check int) "exact video bytes" (String.length bytes)
       (member "bytes" data |> to_int);
     Alcotest.(check string) "exact video SHA" sha (member "sha256" data |> to_string);
     Alcotest.(check bool) "no visual inspection invented" true
       (member "visual_input" data = `Bool false)
   | _ -> Alcotest.fail (Tool_result.message result))) ["capture"; "capture.m4v"]
;;

let () =
  Random.self_init ();
  Alcotest.run
    "verification authority tools"
    [ ( "surface"
      , [ Alcotest.test_case "schemas are the descriptor schemas" `Quick
            test_schemas_are_the_descriptor_schemas
        ; Alcotest.test_case
            "read translates the advertised argument and refuses a malformed one"
            `Quick
            test_read_translates_the_advertised_argument_and_refuses_a_malformed_one
        ; Alcotest.test_case "search refuses a call without its required pattern"
            `Quick test_search_refuses_a_call_without_its_required_pattern
        ; Alcotest.test_case "workspace producer gets owned read surface" `Quick
            test_workspace_producer_gets_owned_read_surface
        ; Alcotest.test_case "binary lookup failure persists as valid UTF-8" `Quick
            test_binary_lookup_failures_survive_observation_replay
        ; Alcotest.test_case "keeper surface uses effective sandbox root" `Quick
            test_keeper_surface_uses_the_effective_sandbox_root
        ] )
    ; ( "dispatch"
      , [ Alcotest.test_case "Goal and Task inspect original MP4 metadata and all audio/video streams" `Quick
            test_goal_and_task_inspect_real_mp4
        ; Alcotest.test_case
            "a capture without the .mp4 extension is still inspected as video" `Quick
            test_a_capture_without_the_mp4_extension_is_still_inspected
        ; Alcotest.test_case "Goal and Task inspect actual PDF pages, bytes and text" `Quick
            test_goal_and_task_inspect_real_pdf
        ; Alcotest.test_case "Goal and Task receive complete visual PNG" `Quick
            test_goal_and_task_read_deliver_full_png
        ; Alcotest.test_case "Keeper endpoint read keeps exact PNG bytes" `Quick
            test_keeper_endpoint_read_preserves_png_bytes
        ; Alcotest.test_case "unknown tool name is an error" `Quick
            test_unknown_tool_name_is_an_error
        ; Alcotest.test_case "web fetch is offered and dispatches" `Quick
            test_web_fetch_is_offered_and_dispatches
        ; Alcotest.test_case "web fetch refuses a private target" `Quick
            test_web_fetch_refuses_a_private_target
        ] )
    ; ( "prompt"
      , [ Alcotest.test_case "prompt states the available surface" `Quick
            test_prompt_states_the_available_surface
        ; Alcotest.test_case
            "root_layout reports entries and discovered checkouts"
            `Quick
            test_root_layout_reports_entries_and_discovered_checkouts
        ; Alcotest.test_case
            "root_layout fails closed when discovery is unavailable"
            `Quick
            test_root_layout_fails_closed_when_discovery_is_unavailable
        ; Alcotest.test_case
            "root_layout fails closed when checkout discovery is partial"
            `Quick
            test_root_layout_fails_closed_when_checkout_discovery_is_partial
        ; Alcotest.test_case
            "a workspace producer without a playground gets a stated absence"
            `Quick
            test_workspace_producer_without_a_playground_gets_a_stated_absence
        ; Alcotest.test_case
            "prompt states the root instead of implying a repository"
            `Quick
            test_prompt_states_the_root_and_not_a_repository
        ] )
    ]
;;
