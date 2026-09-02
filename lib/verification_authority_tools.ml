(** See [verification_authority_tools.mli]. *)

(* The tool names the evaluator may call. Parsed once at the dispatch boundary
   so the rest of this module matches on a constructor: a name that is not one
   of these cannot reach an implementation, and adding a tool without wiring it
   fails to compile. *)
type tool =
  | Read_file
  | Search_files
  | Web_fetch

let tool_name = function
  | Read_file -> "tool_read_file"
  | Search_files -> "tool_search_files"
  | Web_fetch -> "masc_web_fetch"
;;

let all_tools = [ Read_file; Search_files; Web_fetch ]

type t =
  { ownership_root : string
  ; config : Workspace.config
  ; producer_scope : producer_scope
  ; tools : (tool * Keeper_tool_descriptor.t) list
  }

and producer_scope =
  | Keeper_producer of Keeper_meta_contract.keeper_meta
  | Workspace_producer

let descriptor_of_tool tool =
  match Keeper_tool_descriptor.descriptors_for_internal (tool_name tool) with
  | [ descriptor ] -> Ok (tool, descriptor)
  | [] ->
    Error
      (Printf.sprintf
         "tool %s is missing from the keeper descriptor registry"
         (tool_name tool))
  | descriptors ->
    Error
      (Printf.sprintf
         "tool %s has %d keeper descriptors"
         (tool_name tool)
         (List.length descriptors))
;;

let rec resolve_tools = function
  | [] -> Ok []
  | tool :: rest ->
    let open Result.Syntax in
    let* descriptor = descriptor_of_tool tool in
    let* descriptors = resolve_tools rest in
    Ok (descriptor :: descriptors)
;;

let create ~config ~producer =
  let open Result.Syntax in
  let* producer_scope =
    match Keeper_meta_store.read_effective_meta config producer with
    | Error message ->
      Error (Printf.sprintf "producer %s meta unreadable: %s" producer message)
    | Ok None -> Ok Workspace_producer
    | Ok (Some producer_meta) -> Ok (Keeper_producer producer_meta)
  in
  let* tools =
    resolve_tools
      (match producer_scope with
       | Keeper_producer _ -> all_tools
       | Workspace_producer -> [ Read_file; Web_fetch ])
  in
  let* ownership_root =
    match producer_scope with
    | Keeper_producer producer_meta ->
      Ok (Keeper_sandbox.host_root_abs_of_meta ~config producer_meta)
    | Workspace_producer ->
      let project_root =
        Workspace_verification_store.project_root_of_base_path config.base_path
      in
      (try
         Ok
           (Keeper_sandbox_config.host_root_abs_of_agent
              ~base_path:project_root
              ~agent_name:producer)
       with
       | Keeper_sandbox_config.Invalid_keeper_sandbox_config detail ->
         Error
           (Printf.sprintf
              "producer %s sandbox configuration invalid: %s"
              producer
              detail))
  in
  let ownership_root =
    Env_config_core.strip_trailing_slashes ownership_root
  in
  Ok { ownership_root; config; producer_scope; tools }
;;

(* The Goal proof surface. A Goal names no producer: it is a shared intent
   that any Keeper may advance, so there is no owned tree to bind the tools
   to. The root is the shared playground prefix — one fixed workspace
   location, the same for every Goal, derived from nothing the Goal happens
   to be linked to. Every producer's tree sits under it, so a measurement
   written anywhere in the workspace is reachable.

   [tool_search_files] is absent. Its containment runs through a Keeper's
   sandbox meta and this surface has no Keeper identity; reimplementing that
   jail here would be a second containment boundary to keep correct. The
   judge navigates from [root_layout] instead, which names the producers and
   the checkouts under them. *)
let create_goal_proof ~(config : Workspace.config) =
  let open Result.Syntax in
  let* tools = resolve_tools [ Read_file; Web_fetch ] in
  let project_root =
    Workspace_verification_store.project_root_of_base_path config.base_path
  in
  let ownership_root =
    Env_config_core.strip_trailing_slashes
      (Filename.concat project_root Playground_paths.all_playgrounds_prefix)
  in
  Ok { ownership_root; config; producer_scope = Workspace_producer; tools }
;;

(* The listing answers one question for the evaluator: where do the paths the
   submitter wrote actually resolve. Two facts do that, and they are different
   facts.

   The immediate entries say what the root holds — [artifacts/] and the rest
   are read directly and need no prefix.

   The checkouts say where a repository-relative path has to be rooted, and
   they come from [Keeper_playground_checkouts], which finds a checkout by its
   [.git] entry wherever the keeper put it. This module must not scan for them
   itself: that module exists because three separate scans each hardcoded a
   [repos/] segment and each disagreed about what counted as a checkout
   (RFC-keeper-workspace-root-only §1.2). [repos/masc] is one keeper's own
   convention, written in its config, not a layout the system imposes — a
   keeper with a checkout at the top level or under another name is equally
   valid, and a fourth hardcoded scan here would miss it. *)
let root_entry_cap = 32

(* The Goal proof root lists producers rather than one producer's contents, so
   its cap is the number of producers a workspace is expected to carry, not the
   number of entries in one tree. A truncated producer list costs the judge a
   place it may not look; the live workspace carries 38. *)
let goal_root_entry_cap = 128

let children path =
  try Ok (Fs_compat.read_dir path) with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code, operation, _) ->
    Error (Printf.sprintf "%s: %s" operation (Unix.error_message code))
;;

let checkout_lines root =
  match Keeper_playground_checkouts.discover ~root with
  | Error error ->
    Error (Keeper_playground_checkouts.scan_error_to_string error)
  | Ok (Keeper_playground_checkouts.Partial { limit; _ }) ->
    Error
      (Printf.sprintf
         "checkout discovery is partial: %s"
         (Keeper_playground_checkouts.limit_to_string limit))
  | Ok (Keeper_playground_checkouts.Complete checkouts) ->
    let describe (checkout : Keeper_playground_checkouts.checkout) =
      Printf.sprintf
        "  %s/    (git checkout — a repository-relative path is rooted here)"
        checkout.relative_path
    in
    Ok (List.map describe checkouts)
;;

let entry_lines_of root ~cap =
  let open Result.Syntax in
  let* entries =
    children root
    |> Result.map_error (fun detail ->
      Printf.sprintf "verification root unreadable: %s" detail)
  in
  let entries = List.sort String.compare entries in
  let shown = List.filteri (fun index _ -> index < cap) entries in
  let omitted = List.length entries - List.length shown in
  let lines = List.map (fun entry -> "  " ^ entry) shown in
  Ok
    (if omitted <= 0
     then lines
     else lines @ [ Printf.sprintf "  ... and %d more" omitted ])
;;

let root_layout t =
  let open Result.Syntax in
  let* entry_lines = entry_lines_of t.ownership_root ~cap:root_entry_cap in
  let* checkout_lines = checkout_lines t.ownership_root in
  Ok (entry_lines @ checkout_lines)
;;

(* The Goal proof root holds every producer, so the checkout scan that maps one
   producer's tree does not apply: it walks all of them at once and stops on
   the reported-checkout budget long before it is done. That stop is an
   [Error], so running it here deferred every Goal review and the lane
   committed no verdict at all (observed live 2026-08-23 on a workspace with
   38 producers: "checkout budget exhausted (budget 32)", 0.85s, evaluator
   never reached).

   The scan is an [Error] once it finds more than [max_reported_checkouts]
   checkouts (32; the live workspace had 41), so it completes only on small
   workspaces. Leaving it out removes nothing the judge could use: the lookup
   surface is [Read_file] and [Web_fetch], neither lists a directory, and the
   path the judge opens comes from the Goal's metric, not from this listing.
   The listing tells the judge which producer directories exist under the
   root. The cap is per-producer-entry and states its own omissions. *)
let goal_proof_root_layout t = entry_lines_of t.ownership_root ~cap:goal_root_entry_cap
;;

(* ================================================================ *)
(* Schemas                                                          *)
(* ================================================================ *)

let schema_of_tool (tool, (descriptor : Keeper_tool_descriptor.t)) : Types_core.tool_schema =
  { Types_core.name = tool_name tool
  ; description = descriptor.description
  ; input_schema = descriptor.input_schema
  }
;;

let schemas t = List.map schema_of_tool t.tools

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

(* How one call ended. A closed sum rather than a string because the log level
   is derived from it: a rejected call reported at the same level as a resolved
   one is invisible in exactly the case an operator needs to see. *)
type lookup_outcome =
  | Resolved
  | Rejected
  | Unknown_tool
  | Invalid_input

let lookup_outcome_label = function
  | Resolved -> "resolved"
  | Rejected -> "rejected"
  | Unknown_tool -> "unknown_tool"
  | Invalid_input -> "invalid_input"
;;

let lookup_outcome_level = function
  | Resolved -> Log.Info
  | Rejected | Unknown_tool | Invalid_input -> Log.Warn
;;

(* What the judge ran, and whether it got an answer. An operator reading the
   logs otherwise cannot tell a review that inspected the tree from one that
   only read the submitted snapshot, and that difference is the whole point of
   this surface. Output is never logged — only the tool name and the model's own
   arguments, which the run registry records anyway. *)
let log_call t ~name ~argument ~outcome =
  Log.Task.emit
    (lookup_outcome_level outcome)
    (Printf.sprintf
       "[verification-lookup] tool=%s root=%s argument=%s outcome=%s"
       name
       t.ownership_root
       argument
       (lookup_outcome_label outcome))
;;

(* [Keeper_tool_execution.t] carries the runtime's own disposition. A failed
   call has to reach the model as [Error]: handing back [raw_output] on both
   paths would let a build that never ran read like one that produced no
   findings. *)
let result_of_execution (execution : Keeper_tool_execution.t) =
  match execution.disposition with
  | Tool_result.Completed () -> Ok execution.raw_output
  | Tool_result.Failed _ | Tool_result.Deferred () -> Error execution.raw_output
;;

(* The producer's meta binds the jail. [turn_sandbox_factory] is a keeper-turn
   construct and the judge has no turn of its own, so it passes [None] — the
   one caller outside a turn. That names what the judge lacks, not what it may
   read: a Docker producer's tree is a shared mount the read backend reaches
   through its own container, and a microvm producer's guest is named by the
   keeper and the base path, so the backend attaches to a running one. Neither
   route lets the judge start anything or touch the host outside the
   playground, which is the property [None] is protecting. *)
let run t tool ~args =
  match t.producer_scope, tool with
  | Keeper_producer producer_meta, Read_file ->
    Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
      ~turn_sandbox_factory:None
      ~config:t.config
      ~meta:producer_meta
      ~args
    |> result_of_execution
  | Keeper_producer producer_meta, Search_files ->
    Keeper_workspace_ops.handle_tool_search_files_with_outcome
      ~turn_sandbox_factory:None
      ~config:t.config
      ~meta:producer_meta
      ~args
    |> result_of_execution
  | Workspace_producer, Read_file ->
    Keeper_tool_filesystem_runtime.handle_owned_read_file_with_outcome
      ~ownership_root:t.ownership_root
      ~args
    |> result_of_execution
  | Workspace_producer, Search_files ->
    Error "workspace producers do not expose tool_search_files"
  (* Evidence notes carry URLs (a PR, a CI run) the judge must be able to
     dereference itself — a producer's claim about a URL is not inspection
     (masc#28989: three genuinely-completed submissions rejected because the
     PR URL arrived as "a note, not proof"). The shared web-fetch tool owns
     the boundary guards: http/https only, private-network and localhost
     targets refused, validated redirects, bounded extraction. It reads the
     public internet, not the producer tree, so it is producer-scope
     independent; it dispatches directly because the judge has no turn
     continuation for a Gate to resume. *)
  | (Keeper_producer _ | Workspace_producer), Web_fetch ->
    Tool_misc_web_fetch.handle
      ~tool_name:(tool_name Web_fetch)
      ~start_time:(Time_compat.now ())
      args
    |> Keeper_tool_execution.of_tool_result
    |> result_of_execution
;;

let dispatch t ~name ~args =
  match List.find_opt (fun (tool, _) -> String.equal (tool_name tool) name) t.tools with
  | None ->
    let detail =
      Printf.sprintf
        "unknown tool %s; this review offers %s"
        name
        (String.concat ", " (List.map (fun (tool, _) -> tool_name tool) t.tools))
    in
    log_call t ~name ~argument:"" ~outcome:Unknown_tool;
    Error detail
  | Some (tool, descriptor) ->
    let argument = Yojson.Safe.to_string args in
    (match
       Keeper_tool_descriptor_resolution.prepare_model_input_for_descriptor
         ~tool_name:name
         descriptor
         ~input:args
     with
     | Error rejection ->
       let detail = Tool_result.message rejection in
       log_call t ~name ~argument ~outcome:Invalid_input;
       Error detail
     | Ok prepared_args ->
       let result = run t tool ~args:prepared_args in
       log_call
         t
         ~name
         ~argument
         ~outcome:(match result with Ok _ -> Resolved | Error _ -> Rejected);
       result)
;;
