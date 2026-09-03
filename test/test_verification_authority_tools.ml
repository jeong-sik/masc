(* Completion-authority descriptor, validation, dispatch, and containment
   contracts. *)

module Keeper_meta_store = Masc.Keeper_meta_store
module Descriptor = Masc.Keeper_tool_descriptor
module VAT = Masc.Verification_authority_tools
module AR = Masc.Task.Anti_rationalization

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
       { v = Exec_ssh_protocol.protocol_version
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
           }))
;;

let with_fake_ssh f =
  let dir = temp_dir () in
  let ssh_path = Filename.concat dir "ssh" in
  Out_channel.with_open_text ssh_path (fun channel ->
    output_string channel fake_ssh_script);
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
let with_surface ?(sandbox_profile = "remote_ssh") f =
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
      with_fake_ssh run))
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
           Alcotest.(check string)
             (schema.name ^ " description is the descriptor's")
             descriptor.Descriptor.description
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
      VAT.dispatch surface ~name:"tool_read_file" ~args:(`Assoc [ key, `String name ])
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
    match VAT.dispatch surface ~name:"tool_read_file" ~args:(`Assoc []) with
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
       VAT.dispatch surface ~name:"tool_search_files" ~args:(`Assoc [])
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
      VAT.dispatch
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
    match VAT.dispatch surface ~name:"tool_write_file" ~args:(`Assoc []) with
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
       VAT.dispatch
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
    (match VAT.dispatch surface ~name:"tool_search_files" ~args:(`Assoc []) with
     | Ok output -> Alcotest.failf "workspace search unexpectedly ran: %s" output
     | Error detail ->
       Alcotest.(check bool)
         "error lists only the exact offered surface"
         false
         (Astring.String.is_infix ~affix:"this review offers tool_search_files" detail))
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
      }
    in
    let text =
      match
        AR.build_prompt
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
       config/prompts/verification.lookup.producer_tree.md. *)
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
      }
    in
    let render lookup =
      match AR.build_prompt ~lookup request with
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
       (config/prompts/verification.lookup.producer_tree.md); the prompt is
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
          VAT.dispatch
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
      VAT.dispatch
        surface
        ~name:"masc_web_fetch"
        ~args:(`Assoc [ "url", `String "http://127.0.0.1:8935/health" ])
    with
    | Ok output ->
      Alcotest.failf "private-network fetch must be refused, got: %s" output
    | Error _ -> ())
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
        ; Alcotest.test_case "keeper surface uses effective sandbox root" `Quick
            test_keeper_surface_uses_the_effective_sandbox_root
        ] )
    ; ( "dispatch"
      , [ Alcotest.test_case "unknown tool name is an error" `Quick
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
            "prompt states the root instead of implying a repository"
            `Quick
            test_prompt_states_the_root_and_not_a_repository
        ] )
    ]
;;
