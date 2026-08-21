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

type forest_tool =
  | Forest_read_file
  | Forest_search_files
  | Forest_web_fetch

type forest =
  { bindings : (string * t) list
  ; forest_tools : (forest_tool * Types_core.tool_schema) list
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
  let* producer_scope =
    match Keeper_meta_store.read_meta config producer with
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

(* Two levels, because a checkout root sits one level below the sandbox root
   ([repos/<name>/]) and that second level is the prefix an evaluator needs in
   order to open anything the submitter described relative to a checkout. The
   cap keeps a producer with many working trees from crowding the rest of the
   review prompt out of the context window. *)
let root_layout_depth_2_entry_cap = 64

let children path =
  match Fs_compat.read_dir path with
  | entries -> Some entries
  | exception _ -> None
;;

let root_layout t =
  match children t.ownership_root with
  | None -> []
  | Some top ->
    let rendered =
      List.concat_map
        (fun entry ->
           let entry_path = Filename.concat t.ownership_root entry in
           match children entry_path with
           | None -> [ entry ]
           | Some [] -> [ entry ^ "/  (empty)" ]
           | Some nested ->
             (entry ^ "/")
             :: List.map (fun nested_entry -> entry ^ "/" ^ nested_entry) nested)
        top
    in
    let shown = List.filteri (fun index _ -> index < root_layout_depth_2_entry_cap) rendered in
    let omitted = List.length rendered - List.length shown in
    if omitted <= 0
    then shown
    else shown @ [ Printf.sprintf "... and %d more not listed here" omitted ]
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
   construct and the judge has no turn of its own, so a producer on a Docker
   profile resolves no sandbox and the runtime returns its own error — the judge
   is told the tree is unreachable rather than silently inspecting the host. *)
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

(* ================================================================ *)
(* Multi-producer Goal proof surface                                *)
(* ================================================================ *)

let forest_tool_name = function
  | Forest_read_file -> "verification_read_file"
  | Forest_search_files -> "verification_search_files"
  | Forest_web_fetch -> tool_name Web_fetch
;;

let source_tool = function
  | Forest_read_file -> Read_file
  | Forest_search_files -> Search_files
  | Forest_web_fetch -> Web_fetch
;;

let surface_has_tool surface tool =
  List.exists (fun (candidate, _) -> candidate = tool) surface.tools
;;

let eligible_bindings bindings forest_tool =
  let tool = source_tool forest_tool in
  List.filter (fun (_, surface) -> surface_has_tool surface tool) bindings
;;

let replace_assoc key value fields =
  (key, value) :: List.filter (fun (candidate, _) -> not (String.equal key candidate)) fields
;;

let producer_scoped_input_schema ~producers = function
  | `Assoc fields ->
    let open Result.Syntax in
    let* properties =
      match List.assoc_opt "properties" fields with
      | Some (`Assoc properties) -> Ok properties
      | Some other ->
        Error
          (Printf.sprintf
             "verification tool descriptor properties must be an object, got %s"
             (Json_util.excerpt other))
      | None -> Error "verification tool descriptor has no properties"
    in
    let* required =
      match List.assoc_opt "required" fields with
      | Some (`List required) -> Ok required
      | Some other ->
        Error
          (Printf.sprintf
             "verification tool descriptor required must be an array, got %s"
             (Json_util.excerpt other))
      | None -> Ok []
    in
    let producer_schema =
      `Assoc
        [ "type", `String "string"
        ; "enum", `List (List.map (fun producer -> `String producer) producers)
        ; ( "description"
          , `String
              "Exact linked-Task producer whose owned tree this read targets" )
        ]
    in
    let properties = replace_assoc "producer" producer_schema properties in
    let required =
      `String "producer"
      :: List.filter
           (function
             | `String name -> not (String.equal name "producer")
             | _ -> true)
           required
    in
    Ok
      (`Assoc
         (fields
          |> replace_assoc "properties" (`Assoc properties)
          |> replace_assoc "required" (`List required)))
  | other ->
    Error
      (Printf.sprintf
         "verification tool descriptor input schema must be an object, got %s"
         (Json_util.excerpt other))
;;

let forest_schema bindings forest_tool =
  let open Result.Syntax in
  let tool = source_tool forest_tool in
  let* _, descriptor = descriptor_of_tool tool in
  let eligible = eligible_bindings bindings forest_tool in
  let producers = List.map fst eligible in
  let* input_schema =
    match forest_tool with
    | Forest_web_fetch -> Ok descriptor.input_schema
    | Forest_read_file | Forest_search_files ->
      producer_scoped_input_schema ~producers descriptor.input_schema
  in
  Ok
    { Types_core.name = forest_tool_name forest_tool
    ; description =
        (match forest_tool with
         | Forest_read_file ->
           "Read a file from one exact linked-Task producer tree. "
           ^ descriptor.description
         | Forest_search_files ->
           "Search files in one exact linked-Task producer tree. "
           ^ descriptor.description
         | Forest_web_fetch -> descriptor.description)
    ; input_schema
    }
;;

let rec create_bindings ~config = function
  | [] -> Ok []
  | producer :: rest ->
    let open Result.Syntax in
    let* surface = create ~config ~producer in
    let* bindings = create_bindings ~config rest in
    Ok ((producer, surface) :: bindings)
;;

let create_forest ~config ~producers =
  let open Result.Syntax in
  let producers = List.sort_uniq String.compare producers in
  let* () =
    match List.find_opt (fun producer -> String.equal (String.trim producer) "") producers with
    | Some _ -> Error "verification producer identity must not be blank"
    | None -> Ok ()
  in
  let* bindings =
    match producers with
    | [] -> Error "verification producer forest must not be empty"
    | _ -> create_bindings ~config producers
  in
  let forest_tool_kinds =
    [ Forest_read_file ]
    @ (match eligible_bindings bindings Forest_search_files with
       | [] -> []
       | _ -> [ Forest_search_files ])
    @ [ Forest_web_fetch ]
  in
  let rec build = function
    | [] -> Ok []
    | forest_tool :: rest ->
      let* schema = forest_schema bindings forest_tool in
      let* schemas = build rest in
      Ok ((forest_tool, schema) :: schemas)
  in
  let* forest_tools = build forest_tool_kinds in
  Ok { bindings; forest_tools }
;;

(* A forest has one root per producer, so the listing has to say which
   producer each path belongs to: the forest dispatcher requires an exact
   producer argument, and a bare path would not tell the evaluator which one
   to pass. The same cap applies to the joined listing. *)
let forest_root_layout forest =
  let rendered =
    List.concat_map
      (fun (producer, tools) ->
         match root_layout tools with
         | [] -> [ producer ^ ": root could not be listed" ]
         | entries -> List.map (fun entry -> producer ^ ": " ^ entry) entries)
      forest.bindings
  in
  let shown =
    List.filteri (fun index _ -> index < root_layout_depth_2_entry_cap) rendered
  in
  let omitted = List.length rendered - List.length shown in
  if omitted <= 0
  then shown
  else shown @ [ Printf.sprintf "... and %d more not listed here" omitted ]
;;

let forest_schemas forest = List.map snd forest.forest_tools

let forest_tool_of_name forest name =
  forest.forest_tools
  |> List.find_opt (fun (tool, _) -> String.equal (forest_tool_name tool) name)
  |> Option.map fst
;;

let select_producer forest forest_tool args =
  match args with
  | `Assoc fields ->
    (match List.assoc_opt "producer" fields with
     | Some (`String producer) ->
       let eligible = eligible_bindings forest.bindings forest_tool in
       (match List.assoc_opt producer eligible with
        | Some surface ->
          Ok
            ( surface
            , `Assoc
                (List.filter
                   (fun (name, _) -> not (String.equal name "producer"))
                   fields) )
        | None ->
          Error
            (Printf.sprintf
               "producer %s is not admitted for %s; admitted producers: %s"
               producer
               (forest_tool_name forest_tool)
               (String.concat ", " (List.map fst eligible))))
     | Some other ->
       Error
         (Printf.sprintf
            "producer must be a string, got %s"
            (Json_util.excerpt other))
     | None -> Error "producer is required")
  | other ->
    Error
      (Printf.sprintf
         "%s input must be an object, got %s"
         (forest_tool_name forest_tool)
         (Json_util.excerpt other))
;;

let dispatch_forest forest ~name ~args =
  match forest_tool_of_name forest name with
  | None ->
    Error
      (Printf.sprintf
         "unknown tool %s; this Goal review offers %s"
         name
         (forest.forest_tools
          |> List.map (fun (tool, _) -> forest_tool_name tool)
          |> String.concat ", "))
  | Some Forest_web_fetch ->
    (match forest.bindings with
     | (_, surface) :: _ -> dispatch surface ~name:(tool_name Web_fetch) ~args
     | [] -> Error "verification producer forest is empty")
  | Some (Forest_read_file as forest_tool)
  | Some (Forest_search_files as forest_tool) ->
    (match select_producer forest forest_tool args with
     | Error _ as error -> error
     | Ok (surface, forwarded_args) ->
       dispatch
         surface
         ~name:(tool_name (source_tool forest_tool))
         ~args:forwarded_args)
;;
