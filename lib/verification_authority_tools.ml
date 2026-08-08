(** See [verification_authority_tools.mli]. *)

(* The tool names the evaluator may call. Parsed once at the dispatch boundary
   so the rest of this module matches on a constructor: a name that is not one
   of these cannot reach an implementation, and adding a tool without wiring it
   fails to compile. *)
type tool =
  | Read_file
  | Search_files
  | Execute

let tool_name = function
  | Read_file -> "tool_read_file"
  | Search_files -> "tool_search_files"
  | Execute -> "tool_execute"
;;

let all_tools = [ Read_file; Search_files; Execute ]

type t =
  { ownership_root : string
  ; config : Workspace.config
  ; producer_meta : Keeper_meta_contract.keeper_meta
  ; tools : (tool * Keeper_tool_descriptor.t) list
  }

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
  let* tools = resolve_tools all_tools in
  let* producer_meta =
    match Keeper_meta_store.read_meta config producer with
    | Error message ->
      Error (Printf.sprintf "producer %s meta unreadable: %s" producer message)
    | Ok None -> Error (Printf.sprintf "producer %s has no keeper meta" producer)
    | Ok (Some producer_meta) -> Ok producer_meta
  in
  let project_root =
    Workspace_verification_store.project_root_of_base_path config.base_path
  in
  let ownership_root =
    Keeper_sandbox_config.host_root_abs_of_agent
      ~base_path:project_root
      ~agent_name:producer
    |> Env_config_core.strip_trailing_slashes
  in
  Ok { ownership_root; config; producer_meta; tools }
;;

let ownership_root t = t.ownership_root

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
   construct and the judge has no turn of its own, so a producer on a Docker
   profile resolves no sandbox and the runtime returns its own error — the judge
   is told the tree is unreachable rather than silently inspecting the host. *)
let run t tool ~args =
  match tool with
  | Read_file ->
    Keeper_tool_filesystem_runtime.handle_read_file_with_outcome
      ~turn_sandbox_factory:None
      ~config:t.config
      ~meta:t.producer_meta
      ~args
    |> result_of_execution
  | Search_files ->
    Keeper_workspace_ops.handle_tool_search_files_with_outcome
      ~turn_sandbox_factory:None
      ~config:t.config
      ~meta:t.producer_meta
      ~args
    |> result_of_execution
  | Execute ->
    Keeper_tool_execute_runtime.handle_tool_execute_with_outcome
      ~turn_sandbox_factory:None
      ~config:t.config
      ~meta:t.producer_meta
      ~args
      ()
    |> result_of_execution
;;

let dispatch t ~name ~args =
  match List.find_opt (fun (tool, _) -> String.equal (tool_name tool) name) t.tools with
  | None ->
    let detail =
      Printf.sprintf
        "unknown tool %s; this review offers %s"
        name
        (String.concat ", " (List.map tool_name all_tools))
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
