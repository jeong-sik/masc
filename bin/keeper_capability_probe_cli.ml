(* Operator entry point for the RFC-0374 probe lane.

   [Keeper_capability_probe] exists so that asking "can runtime R reach tool T"
   stops costing a durable keeper turn: on 2026-08-12 the probe traffic itself
   entered the keeper's memory as a fact prescribing non-response, after which
   a zero answer no longer distinguished "unreachable" from "declined"
   (masc#28414). The lane writes nothing. It was, however, reachable only from
   OCaml, so the measurement it was built for still could not be run. This is
   that runner.

   Output is JSON Lines on stdout, one object per probe, so a sweep can be
   replayed and diffed. Human-readable progress goes to stderr. *)

module Probe = Masc.Keeper_capability_probe

let usage =
  {|Usage: masc-keeper-capability-probe [OPTIONS]

Options:
  --runtime ID       Runtime to probe (repeatable; default: all Agent Core runtimes)
  --tool NAME        Tool to probe (repeatable; required unless --list-*)
  --repeat N         Probe turns per (runtime, tool) pair (default 1)
  --prompt TEXT      Prompt template; {tool} is replaced by the model-facing name
  --base-path PATH   Runtime workspace root (default: MASC_BASE_PATH)
  --surface-only     Resolve the tool surface offline; send no provider request
  --list-runtimes    Print every runtime id and its lane, then exit
  --list-tools       Print every model-facing tool name, then exit
  --doctor           Sweep every keeper tool: surface verdict + defer state,
                     flag names advertised to keepers that no descriptor
                     projects (invisible to agent-core keepers), then exit
  -h, --help         Print this help

The surface pass runs first for every tool and is free. A tool that is not
projected is reported and never dispatched: spending a turn on it would
measure the projection policy, not the runtime.
|}

type config =
  { runtimes : string list
  ; tools : string list
  ; repeat : int
  ; prompt : string
  ; base_path : string option
  ; surface_only : bool
  ; list_runtimes : bool
  ; list_tools : bool
  ; doctor : bool
  }

let initial_config =
  { runtimes = []
  ; tools = []
  ; repeat = 1
  ; prompt = ""
  ; base_path = Sys.getenv_opt "MASC_BASE_PATH"
  ; surface_only = false
  ; list_runtimes = false
  ; list_tools = false
  ; doctor = false
  }
;;

let error msg =
  prerr_endline msg;
  prerr_endline usage;
  exit 1
;;

let rec parse_args argv index cfg =
  if index >= Array.length argv
  then cfg
  else (
    let need name =
      if index + 1 >= Array.length argv then error (Printf.sprintf "%s needs a value" name);
      argv.(index + 1)
    in
    match argv.(index) with
    | "-h" | "--help" ->
      print_endline usage;
      exit 0
    | "--surface-only" -> parse_args argv (index + 1) { cfg with surface_only = true }
    | "--list-runtimes" -> parse_args argv (index + 1) { cfg with list_runtimes = true }
    | "--list-tools" -> parse_args argv (index + 1) { cfg with list_tools = true }
    | "--doctor" -> parse_args argv (index + 1) { cfg with doctor = true }
    | "--runtime" ->
      parse_args argv (index + 2) { cfg with runtimes = cfg.runtimes @ [ need "--runtime" ] }
    | "--tool" -> parse_args argv (index + 2) { cfg with tools = cfg.tools @ [ need "--tool" ] }
    | "--prompt" -> parse_args argv (index + 2) { cfg with prompt = need "--prompt" }
    | "--base-path" ->
      parse_args argv (index + 2) { cfg with base_path = Some (need "--base-path") }
    | "--repeat" ->
      let raw = need "--repeat" in
      (match int_of_string_opt raw with
       | Some n when n > 0 -> parse_args argv (index + 2) { cfg with repeat = n }
       | _ -> error (Printf.sprintf "invalid --repeat: %S" raw))
    | other -> error (Printf.sprintf "unknown argument: %S" other))
;;

(* [{tool}] rather than [%s]: the template is operator-supplied, and a stray
   percent in a hand-written prompt would otherwise raise at format time. *)
let render_prompt template ~tool =
  let placeholder = "{tool}" in
  let plen = String.length placeholder in
  let buf = Buffer.create (String.length template + String.length tool) in
  let rec go i =
    if i >= String.length template
    then ()
    else if i + plen <= String.length template && String.sub template i plen = placeholder
    then (
      Buffer.add_string buf tool;
      go (i + plen))
    else (
      Buffer.add_char buf template.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents buf
;;

let lane_label runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> "unresolvable"
  | Some rt -> Runtime_execution.label rt.Runtime.execution
;;

let is_agent_core runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | None -> false
  | Some rt ->
    (match rt.Runtime.execution with
     | Runtime_execution.Agent_core _ -> true
     | Runtime_execution.Codex_app_server _
     | Runtime_execution.Antigravity_cli _
     | Runtime_execution.Claude_code _ -> false)
;;

let verdict_json (verdict : Probe.verdict) =
  match verdict with
  | Probe.Projected { model_facing_name } ->
    `Assoc [ "kind", `String "projected"; "model_facing_name", `String model_facing_name ]
  | Probe.Not_a_descriptor -> `Assoc [ "kind", `String "not_a_descriptor" ]
  | Probe.Operator_only -> `Assoc [ "kind", `String "operator_only" ]
  | Probe.Aliased { projected_by } ->
    `Assoc [ "kind", `String "aliased"; "projected_by", `String projected_by ]
  | Probe.Withheld_by_schema_error { errors } ->
    `Assoc
      [ "kind", `String "withheld_by_schema_error"
      ; "errors", `List (List.map (fun e -> `String e) errors)
      ]
;;

let invocation_json (invocation : Probe.invocation) =
  match invocation with
  | Probe.Tool_invoked { tool; elapsed_s } ->
    `Assoc
      [ "kind", `String "tool_invoked"
      ; "tool", `String tool
      ; "elapsed_s", `Float elapsed_s
      ]
  | Probe.Other_tool_invoked { requested; invoked; elapsed_s } ->
    `Assoc
      [ "kind", `String "other_tool_invoked"
      ; "requested", `String requested
      ; "invoked", `List (List.map (fun t -> `String t) invoked)
      ; "elapsed_s", `Float elapsed_s
      ]
  | Probe.Replied_no_tool { reply_bytes; elapsed_s } ->
    `Assoc
      [ "kind", `String "replied_no_tool"
      ; "reply_bytes", `Int reply_bytes
      ; "elapsed_s", `Float elapsed_s
      ]
  | Probe.Provider_rejected { detail } ->
    `Assoc [ "kind", `String "provider_rejected"; "detail", `String detail ]
;;

let invocation_error_json (err : Probe.invocation_error) =
  match err with
  | Probe.Not_on_surface verdict ->
    `Assoc [ "kind", `String "not_on_surface"; "verdict", verdict_json verdict ]
  | Probe.Unresolvable_runtime detail ->
    `Assoc [ "kind", `String "unresolvable_runtime"; "detail", `String detail ]
  | Probe.Not_agent_core_lane lane ->
    `Assoc [ "kind", `String "not_agent_core_lane"; "lane", `String lane ]
  | Probe.Not_official_client_lane lane ->
    `Assoc [ "kind", `String "not_official_client_lane"; "lane", `String lane ]
  | Probe.Tools_only_via_mcp_bridge lane ->
    `Assoc [ "kind", `String "tools_only_via_mcp_bridge"; "lane", `String lane ]
  | Probe.Not_antigravity_lane lane ->
    `Assoc [ "kind", `String "not_antigravity_lane"; "lane", `String lane ]
  | Probe.Antigravity_home_unavailable detail ->
    `Assoc [ "kind", `String "antigravity_home_unavailable"; "detail", `String detail ]
  | Probe.Tool_schema_rejected detail ->
    `Assoc [ "kind", `String "tool_schema_rejected"; "detail", `String detail ]
;;

let emit json =
  print_endline (Yojson.Safe.to_string json);
  flush stdout
;;

let run_surface_pass ~tools =
  List.map
    (fun tool ->
      let verdict = Probe.probe_surface ~tool in
      emit
        (`Assoc
          [ "phase", `String "surface"
          ; "tool", `String tool
          ; "verdict", verdict_json verdict
          ]);
      tool, verdict)
    tools
;;

(* Route by lane rather than making the operator pick an entry point: the two
   probes answer the same question and only differ in how the turn is carried.
   A wrong choice would come back as a lane-guard error, which is a worse
   answer than the one the runtime can actually give. *)
let is_antigravity runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some { execution = Runtime_execution.Antigravity_cli _; _ } -> true
  | Some _ | None -> false
;;

let probe_for_lane ~sw ~net ~secure_random ~clock ~mgr ~fs ~base_path ~runtime_id ~tool
    ~prompt =
  if is_agent_core runtime_id
  then
    Probe.probe_invocation ~sw ~net ~clock ~now:Unix.gettimeofday ~runtime_id ~tool
      ~prompt ()
  else if is_antigravity runtime_id
  then
    Probe.probe_antigravity_invocation ~sw ~net ~secure_random ~mgr ~clock ~fs
      ~base_path ~now:Unix.gettimeofday ~runtime_id ~tool ~prompt ()
  else
    Probe.probe_official_client_invocation ~mgr ~clock ~fs ~base_path
      ~now:Unix.gettimeofday ~runtime_id ~tool ~prompt ()
;;

let run_invocation_pass ~sw ~net ~secure_random ~clock ~mgr ~fs ~base_path ~cfg
    ~surface =
  List.iter
    (fun runtime_id ->
      List.iter
        (fun (tool, verdict) ->
          match verdict with
          | Probe.Projected { model_facing_name } ->
            for attempt = 1 to cfg.repeat do
              let prompt = render_prompt cfg.prompt ~tool:model_facing_name in
              let started = Unix.gettimeofday () in
              let outcome =
                probe_for_lane ~sw ~net ~secure_random ~clock ~mgr ~fs ~base_path
                  ~runtime_id ~tool ~prompt
              in
              let wall_s = Unix.gettimeofday () -. started in
              let body =
                match outcome with
                | Ok invocation -> `Assoc [ "ok", invocation_json invocation ]
                | Error err -> `Assoc [ "error", invocation_error_json err ]
              in
              emit
                (`Assoc
                  [ "phase", `String "invocation"
                  ; "runtime", `String runtime_id
                  ; "lane", `String (lane_label runtime_id)
                  ; "tool", `String tool
                  ; "model_facing_name", `String model_facing_name
                  ; "attempt", `Int attempt
                  ; "wall_s", `Float wall_s
                  ; "outcome", body
                  ]);
              Printf.eprintf
                "  %-46s %-22s #%d  %s\n%!"
                runtime_id
                tool
                attempt
                (match outcome with
                 | Ok invocation -> Probe.invocation_to_string invocation
                 | Error err -> Probe.invocation_error_to_string err)
            done
          | Probe.Not_a_descriptor
          | Probe.Operator_only
          | Probe.Aliased _
          | Probe.Withheld_by_schema_error _ ->
            (* Reported by the surface pass already. Dispatching anyway would
               measure the projection policy rather than the runtime. *)
            ())
        surface)
    cfg.runtimes
;;

let loading_label name =
  match Tool_loading_declarations.loading_of_tool name with
  | Tool_definition_toml.Deferrable -> "deferred"
  | Tool_definition_toml.Always_loaded -> "always"
;;

let verdict_short (verdict : Probe.verdict) =
  match verdict with
  | Probe.Projected _ -> "projected"
  | Probe.Not_a_descriptor -> "no-descriptor"
  | Probe.Operator_only -> "operator-only"
  | Probe.Aliased { projected_by } -> "aliased->" ^ projected_by
  | Probe.Withheld_by_schema_error _ -> "schema-error"
;;

(* One offline sweep of every keeper tool. Per tool: the surface verdict (is it
   projected to the keeper model, operator-only, an alias, or backed by no
   descriptor) and whether it is deferred or rides every turn. It names two
   classes the manual eye keeps missing:

   - advertised to keepers on the spawned-agent MCP surface but backed by no
     descriptor, so agent-core keepers -- most of the fleet -- never see it.
     This is the #32699 class. (masc_messages is a known member that is
     delivered as turn context instead, so this reports rather than fails.)
   - projected AND always-loaded: the schema rides every keeper turn. Deferring
     a rarely-used one is what [config/tools/<name>.toml] defer_loading is for.

   No provider request -- the surface pass is free. *)
let run_doctor () =
  let spawned = Tool_catalog_surfaces.spawned_agent_surface_tools in
  let names = List.sort_uniq String.compare (spawned @ Probe.model_facing_names ()) in
  let verdict_of = List.map (fun name -> name, Probe.probe_surface ~tool:name) names in
  let no_descriptor_on_surface =
    List.filter
      (fun (name, verdict) ->
        List.mem name spawned
        && (match verdict with Probe.Not_a_descriptor -> true | _ -> false))
      verdict_of
  in
  let rides_every_turn =
    List.filter
      (fun (name, verdict) ->
        (match verdict with Probe.Projected _ -> true | _ -> false)
        && (match Tool_loading_declarations.loading_of_tool name with
            | Tool_definition_toml.Always_loaded -> true
            | Tool_definition_toml.Deferrable -> false))
      verdict_of
  in
  Printf.printf "== masc tool doctor -- %d tool names ==\n\n" (List.length names);
  List.iter
    (fun (name, verdict) ->
      Printf.printf "  %-38s %-20s %-9s%s\n" name (verdict_short verdict)
        (loading_label name)
        (if List.mem_assoc name no_descriptor_on_surface then "  <- no agent-core descriptor"
         else ""))
    verdict_of;
  Printf.printf "\nprojected AND always-loaded (rides every keeper turn): %d\n"
    (List.length rides_every_turn);
  List.iter
    (fun (name, _) -> Printf.printf "  always  %s\n" name)
    rides_every_turn;
  Printf.printf
    "\nadvertised on the spawned MCP surface but no descriptor projects it: %d\n"
    (List.length no_descriptor_on_surface);
  List.iter
    (fun (name, _) -> Printf.printf "  check   %s\n" name)
    no_descriptor_on_surface
;;

let () =
  let cfg = parse_args Sys.argv 1 initial_config in
  let base_path =
    match cfg.base_path with
    | Some path when String.trim path <> "" -> String.trim path
    | _ -> error "--base-path or MASC_BASE_PATH is required"
  in
  Server_runtime_bootstrap.bootstrap_base_path_config_root ~base_path;
  Server_runtime_bootstrap.bootstrap_prompt_assets ();
  let config_path = Masc.Fusion_config_loader.runtime_toml_path ~base_path in
  ignore
    (Masc.Prompt_defaults.bootstrap_runtime ~workspace_path:base_path ~base_path : string);
  let cfg =
    if String.trim cfg.prompt <> "" then cfg
    else
        (match
           Prompt_registry.render_prompt_template Prompt_names.keeper_capability_probe
             [ "tool", "{tool}" ]
         with
         | Ok prompt -> { cfg with prompt }
         | Error detail -> error ("default capability probe prompt: " ^ detail))
  in
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio_context.set_env env;
  Eio_context.set_clock clock;
  (* The server installs the deployment capability overlay at boot and a CLI
     does not, so without this an Agent Core runtime that exists in
     runtime.toml still resolves as "absent from the AGENT_CORE capability
     catalog". fusion_run.ml carries the same call for the same reason. *)
  ignore
    (Server_runtime_bootstrap.configure_agent_core_model_catalog_overlay
       ~config_root:(Filename.dirname config_path)
       ()
     : string option);
  (match Runtime.init_default ~config_path with
   | Error msg ->
     Printf.eprintf "runtime init failed (%s): %s\n" config_path msg;
     exit 1
   | Ok () -> ());
  if cfg.list_runtimes
  then (
    List.iter
      (fun id -> Printf.printf "%s\t%s\n" id (lane_label id))
      (Runtime.get_runtime_ids ());
    exit 0);
  if cfg.list_tools
  then (
    List.iter print_endline (Probe.model_facing_names ());
    exit 0);
  if cfg.doctor
  then (
    run_doctor ();
    exit 0);
  if cfg.tools = [] then error "at least one --tool is required";
  let cfg =
    if cfg.runtimes <> []
    then cfg
    else { cfg with runtimes = List.filter is_agent_core (Runtime.get_runtime_ids ()) }
  in
  let surface = run_surface_pass ~tools:cfg.tools in
  if not cfg.surface_only
  then (
    let projected =
      List.length
        (List.filter
           (fun (_, v) ->
             match v with
             | Probe.Projected _ -> true
             | _ -> false)
           surface)
    in
    Printf.eprintf
      "probing %d runtime(s) x %d projected tool(s) x %d attempt(s)\n%!"
      (List.length cfg.runtimes)
      projected
      cfg.repeat;
    run_invocation_pass ~sw ~net ~secure_random:(Eio.Stdenv.secure_random env)
      ~clock ~mgr:(Eio.Stdenv.process_mgr env) ~fs:(Eio.Stdenv.fs env) ~base_path
      ~cfg ~surface)
;;
