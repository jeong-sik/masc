(** AGENT_CORE boundary adapter for tool results, schemas, and tool definitions.

    MASC dispatch uses typed [Tool_result.result] internally.  This module is the
    boundary adapter that converts typed MASC results to/from
    [Agent_core.Types.tool_result = (tool_output, tool_error) Result.t].

    Central [Tool_dispatch.handler] implementations should return
    [Tool_result.result] directly rather than reintroducing tuple dispatch.

    @since 2.95.1 — result conversion
    @since 2.110.0 — schema conversion + AGENT_CORE Tool.t creation
    @since 2.??? — externalize large outputs via [Tool_blob_store] *)

(** {1 Tool Output Externalization}

    Tool outputs above [default_externalize_threshold_bytes] are stored
    in the content-addressed blob store ([Tool_blob_store]) and the
    AGENT_CORE [content] field carries a blob marker
    ([Tool_output.encode_for_agent_core (Stored {...})]). Smaller outputs flow
    through unchanged.

    Stored results remain content-addressed references at the durable and
    provider boundaries. Their exact bytes remain available from the artifact
    store and HTTP artifact route without expanding every later model request.

    Disabled unless the caller supplies [base_path]. This keeps output
    projection capability-aware: runtimes that do not also expose an artifact
    reader cannot accidentally replace exact output with an unreadable marker. *)

let default_externalize_threshold_bytes = Common.max_tool_result_wire_bytes

type projection_error_kind =
  | Artifact_storage_failure
  | Inline_budget_exceeded

type externalization_error =
  { kind : projection_error_kind
  ; message : string
  }

let artifact_manifest_metadata_key = "masc.artifact_manifest"

let metadata_with_artifact_manifest metadata reference =
  let manifest = Tool_output.normalized_artifact_ref_to_json reference in
  match metadata with
  | None -> `Assoc [ artifact_manifest_metadata_key, manifest ]
  | Some (`Assoc fields) ->
    `Assoc
      ((artifact_manifest_metadata_key, manifest)
       :: List.remove_assoc artifact_manifest_metadata_key fields)
  | Some payload ->
    `Assoc
      [ artifact_manifest_metadata_key, manifest
      ; "masc.payload", payload
      ]
;;

let artifact_manifest_from_metadata metadata =
  let rec decode = function
    | `Assoc fields ->
      (match List.assoc_opt artifact_manifest_metadata_key fields with
     | Some json ->
       (match Tool_output.normalized_artifact_ref_of_json json with
        | Tool_output.Decoded_normalized_artifact_ref reference
          when String.equal reference.mime Tool_output.artifact_manifest_mime ->
          Ok reference
        | Tool_output.Decoded_normalized_artifact_ref _ ->
          Error "artifact manifest metadata has the wrong media type"
        | Tool_output.Not_normalized_artifact_ref ->
          Error "artifact manifest metadata is not a normalized reference"
        | Tool_output.Invalid_normalized_artifact_ref { detail } -> Error detail)
     | None ->
       (match List.assoc_opt "producer" fields with
        | Some producer -> decode producer
        | None ->
          (match List.assoc_opt "masc.payload" fields with
           | Some payload -> decode payload
           | None -> Error "typed artifact result is missing its durable manifest")))
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "typed artifact result is missing its durable manifest"
  in
  match metadata with
  | Some metadata -> decode metadata
  | None -> Error "typed artifact result is missing its durable manifest"
;;

let attach_artifact_manifest ~base_path (result : Tool_result.result) =
  match
    Tool_output.normalized_artifact_refs_in_json_strict
      (Tool_result.data result)
  with
  | Error message -> Error { kind = Artifact_storage_failure; message }
  | Ok [] -> Ok result
  | Ok (_ :: _) ->
    (try
       let manifest =
         Tool_output.artifact_manifest_to_json
           ~content:(Tool_result.message result)
           ~structured_content:(Tool_result.data result)
         |> Yojson.Safe.to_string
       in
       let reference =
         Tool_blob_store.put_durable
           (Tool_blob_store.create ~base_path)
           ~bytes:manifest
           ~mime:Tool_output.artifact_manifest_mime
         |> fun reference -> Tool_output.with_preview reference ""
       in
       Ok
         (Tool_result.with_metadata
            (metadata_with_artifact_manifest (Tool_result.metadata result) reference)
            result)
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       let message = Printexc.to_string exn in
       Log.Misc.error
         "tool_bridge: result manifest persistence failed: %s"
         message;
       Error { kind = Artifact_storage_failure; message })
;;

let resolve_blob_store ?base_path () =
  match base_path with
  | None -> None
  | Some base_path -> Some (Tool_blob_store.create ~base_path)

(** Externalize [msg] when it exceeds the threshold and a blob store is
    available; otherwise pass through unchanged. A configured store that
    cannot persist the bytes returns a typed error: putting the oversized
    payload back on the provider wire would defeat this boundary. *)
let maybe_externalize ?base_path ?(mime = "text/plain")
      ?(threshold_bytes = default_externalize_threshold_bytes) (msg : string)
  : (string, externalization_error) result
  =
  if String.length msg <= threshold_bytes then Ok msg
  else
    match resolve_blob_store ?base_path () with
    | None -> Ok msg
    | Some store ->
        (try
           let reference =
             Tool_blob_store.put_durable store ~bytes:msg ~mime
           in
           Ok
             (Tool_output.encode_for_agent_core
                (Tool_output.Stored reference))
         with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          let message = Printexc.to_string exn in
          Log.Misc.error "tool_bridge: blob externalization failed: %s" message;
          Error { kind = Artifact_storage_failure; message })

(** {1 Result Conversion} *)

let make_tool_error ?(recoverable = false) ?error_class message
  : Agent_core.Types.tool_result =
  Error { Agent_core.Types.message; recoverable; error_class }

let project_content ?base_path ~model_projection message =
  match model_projection with
  | Tool_output.Store_above { threshold_bytes } ->
    maybe_externalize ?base_path ~threshold_bytes message
  | Tool_output.Inline_up_to { maximum_bytes } ->
    if String.length message <= maximum_bytes
    then Ok message
    else
      Error
        { kind = Inline_budget_exceeded
        ; message =
            Printf.sprintf
              "inline tool output exceeds descriptor budget (%d > %d bytes)"
              (String.length message)
              maximum_bytes
        }
;;

let externalization_tool_error ~recoverable error =
  match error.kind with
  | Artifact_storage_failure ->
    make_tool_error
      ~recoverable
      ~error_class:
        (if recoverable
         then Agent_core.Types.Transient
         else Agent_core.Types.Unknown)
      "tool output artifact storage failed"
  | Inline_budget_exceeded ->
    make_tool_error
      ~recoverable:false
      ~error_class:Agent_core.Types.Deterministic
      "tool output exceeds descriptor budget"
;;

(* The class is typed at the producer and AGENT_CORE folds it into
   [error_class], which no provider wire serializer emits. So the only way the
   class reaches the model is as text on the failure content, and the only
   text the model needs is what to do next. The sentences are prompt assets
   ([config/prompts/tool_failure.<class>.md]), not OCaml literals; the match
   is exhaustive so a new class cannot ship without its sentence key. A key
   with no file and no override is reported and the line carries the class
   alone -- the model still learns the class, and the operator learns the
   deploy is missing a prompt asset. *)
let failure_next_move (class_ : Tool_result.tool_failure_class) : string option =
  let key =
    match class_ with
    | Tool_result.Dependency_unavailable -> Prompt_names.tool_failure_dependency_unavailable
    | Tool_result.Policy_rejection -> Prompt_names.tool_failure_policy_rejection
    | Tool_result.Runtime_failure -> Prompt_names.tool_failure_runtime_failure
    | Tool_result.Workflow_rejection -> Prompt_names.tool_failure_workflow_rejection
    | Tool_result.Operator_cancelled -> Prompt_names.tool_failure_operator_cancelled
  in
  match Prompt_registry.resolve_prompt key with
  | { Prompt_registry.file_exists = false; has_override = false; _ } ->
    Log.Misc.error
      "tool_bridge: prompt %s has no file and no override; the model sees only failure_class=%s"
      key
      (Tool_result.tool_failure_class_to_string class_);
    None
  | resolution -> Some (String.trim resolution.effective)
;;

let agent_core_error_class_of_tool_failure_class = function
  | Tool_result.Policy_rejection
  | Tool_result.Workflow_rejection
  (* Operator interrupt: final for the model — it must not re-attempt what
     an operator explicitly stopped (#28810). *)
  | Tool_result.Operator_cancelled ->
    Agent_core.Types.Deterministic
  | Tool_result.Dependency_unavailable -> Agent_core.Types.Transient
  | Tool_result.Runtime_failure -> Agent_core.Types.Unknown
;;

(** {1 Schema Conversion}

    AGENT_CORE owns the JSON Schema to [tool_param] contract. Invalid, missing, or
    ambiguous property types fail at this boundary instead of being guessed
    as strings or reduced to the first union member. *)

let params_of_json_schema schema =
  let params =
    match Agent_core.Mcp.json_schema_to_params_result schema with
    | Ok params -> params
    | Error detail -> invalid_arg detail
  in
  let unprojected_property =
    match schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc properties) ->
         List.find_opt
           (fun (name, _) ->
              not
                (List.exists
                   (fun (param : Agent_core.Types.tool_param) ->
                      String.equal param.name name)
                   params))
           properties
       | None | Some `Null | Some _ -> None)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      None
  in
  match unprojected_property with
  | None -> params
  | Some (name, _) ->
    invalid_arg
      (Printf.sprintf
         "property %S cannot be represented by the typed tool parameter surface"
         name)
;;

(** {1 AGENT_CORE Tool.t Creation}

    Create AGENT_CORE [Tool.t] from MASC schema definition + dispatch handler.
    This allows incremental migration: each tool can be converted independently. *)

let project_result
      ?base_path
      ?on_externalization_error
      ~model_projection
      ~structured_content
      ~metadata
      message
      on_content
  : Agent_core.Types.tool_result
  =
  let project () = project_content ?base_path ~model_projection message in
  let projected =
    match Tool_output.normalized_artifact_refs_in_json structured_content with
    | [] -> project ()
    | _ :: _ when Option.is_none base_path -> project ()
    | _ :: _ ->
      (match Tool_output.normalized_artifact_refs_in_json_strict structured_content with
       | Error message -> Error { kind = Artifact_storage_failure; message }
       | Ok [] -> Error { kind = Artifact_storage_failure; message = "typed artifact result lost its normalized references" }
       | Ok (_ :: _) ->
         (match artifact_manifest_from_metadata metadata with
          | Ok reference ->
            Ok (Tool_output.encode_for_agent_core (Tool_output.Stored reference))
          | Error message -> Error { kind = Artifact_storage_failure; message }))
  in
  match projected with
  | Ok content -> on_content content
  | Error error ->
    Option.iter (fun observe -> observe error) on_externalization_error;
    externalization_tool_error ~recoverable:false error
;;

let to_agent_core_typed_result
      ?base_path
      ?(model_projection = Tool_output.default_model_projection)
      ?on_externalization_error
      (tr : Tool_result.result)
  : Agent_core.Types.tool_result
  =
  match tr with
  | Tool_result.Completed output ->
    project_result
      ?base_path
      ?on_externalization_error
      ~model_projection
      ~structured_content:(Tool_result.data tr)
      ~metadata:(Tool_result.metadata tr)
      (Tool_result.message tr)
      (fun content ->
         Ok { Agent_core.Types.content; _meta = output.metadata })
  | Tool_result.Deferred output ->
    let disposition_field =
      "masc.tool_disposition", `String (Tool_result.string_of_disposition tr)
    in
    let metadata =
      match output.metadata with
      | None -> `Assoc [ disposition_field ]
      | Some metadata ->
        `Assoc [ disposition_field; "masc.payload", metadata ]
    in
    project_result
      ?base_path
      ?on_externalization_error
      ~model_projection
      ~structured_content:(Tool_result.data tr)
      ~metadata:(Tool_result.metadata tr)
      (Tool_result.message tr)
      (fun content ->
         Ok { Agent_core.Types.content; _meta = Some metadata })
  | Tool_result.Failed { class_; message; metadata; _ } ->
    let failure_class = Tool_result.tool_failure_class_to_string class_ in
    let next_move = failure_next_move class_ in
    let message =
      match metadata with
      | None ->
        (match next_move with
         | Some next_move ->
           Printf.sprintf "%s\nfailure_class=%s — %s" message failure_class next_move
         | None -> Printf.sprintf "%s\nfailure_class=%s" message failure_class)
      | Some metadata ->
        Yojson.Safe.to_string
          (`Assoc
              ([ "message", `String message
               ; "masc.tool_disposition", `String "failed"
               ; "failure_class", `String failure_class
               ]
               @ (match next_move with
                  | Some next_move -> [ "next_move", `String next_move ]
                  | None -> [])
               @ [ "masc.payload", metadata ]))
    in
    project_result
      ?base_path
      ?on_externalization_error
      ~model_projection
      ~structured_content:(Tool_result.data tr)
      ~metadata:(Tool_result.metadata tr)
      message
      (fun message ->
       make_tool_error
         ~recoverable:false
         ~error_class:(agent_core_error_class_of_tool_failure_class class_)
         message)

(** Create an AGENT_CORE [Tool.t] from a MASC tool schema and a typed handler.

    [handler] receives raw JSON args and returns a {!Tool_result.result}.
    The bridge converts the result to AGENT_CORE [tool_result] automatically.

    {[
      let agent_core_tool = agent_core_tool_of_masc
        ~name:"masc_board_post"
        ~description:"Post to the board..."
        ~input_schema:schema_json
        (fun args -> handle_board_post ctx args)
    ]} *)
let agent_core_tool_of_masc
    ?descriptor
    ?base_path
    ?model_projection
    ?on_externalization_error
    ~name
    ~description
    ~input_schema
    handler : Agent_core.Tool.t =
  let parameters = params_of_json_schema input_schema in
  let agent_core_handler json_args =
    to_agent_core_typed_result
      ?base_path
      ?model_projection
      ?on_externalization_error
      (handler json_args)
  in
  Agent_core.Tool.create ?descriptor ~name ~description ~parameters agent_core_handler

let agent_core_tool_of_masc_with_execution_env
    ?descriptor
    ?base_path
    ?model_projection
    ?on_externalization_error
    ~name
    ~description
    ~input_schema
  handler
  : Agent_core.Tool.t
  =
  (* Resolved per call, not per tool. One bundle is built before the turn
     picks a runtime, and a heterogeneous lane fallback can change the answer
     between attempts, so a value captured here would describe the wrong lane. *)
  let agent_core_handler execution_env json_args =
    to_agent_core_typed_result
      ?base_path
      ?model_projection:(Option.map (fun decide -> decide ()) model_projection)
      ?on_externalization_error
      (handler execution_env json_args)
  in
  match Agent_core.Types.tool_schema_of_input_schema ~name ~description ~input_schema () with
  | Ok schema -> Agent_core.Base.Tool.of_schema ?descriptor schema agent_core_handler
  | Error detail ->
    invalid_arg (Printf.sprintf "tool %S schema invalid: %s" name detail)
