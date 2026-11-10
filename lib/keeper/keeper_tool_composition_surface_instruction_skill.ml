module Catalog = Keeper_tool_composition_catalog
module Activation_ledger = Keeper_skill_activation_ledger
open Keeper_tool_composition_surface_schema

(* Progressive disclosure keeps names and descriptions in the tool
   description. The frozen body arrives only after an exact-reference call. *)
(* Declared in [config/tools/keeper_skill.toml] with every other tool rather
   than built here. Which skills are readable is workspace state and is
   appended below; the argument's shape and the sentence saying when to reach
   for the tool are not, and the model-prose ratchet is what says so. *)
let skill_reference_input_schema = skill_tool_schema.input_schema

let instruction_skill ?resource_location ~reference ~description ~body () =
  { reference; description; body; resource_location }
;;

let instruction_skills_of_catalog skill_catalog =
      Keeper_skill_catalog.skills skill_catalog
      |> List.filter_map (fun (skill : Keeper_skill_catalog.skill) ->
           match skill.reference, skill.surface with
           | Some reference, Keeper_skill_catalog.Instruction ->
             let resource_location =
               match skill.provenance with
               | Some
                   { source_root = Some source_root
                   ; resource_read_max_bytes = Some resource_read_max_bytes
                   ; directory
                   ; _
                   } ->
                 Some
                   { source_root; directory; resource_read_max_bytes }
               | Some { source_root = None; _ }
               | Some { resource_read_max_bytes = None; _ }
               | None ->
                 None
             in
             Some
               (instruction_skill
                  ?resource_location
                  ~reference
                  ~description:skill.description
                  ~body:skill.body
                  ())
           | None, _ | Some _, Keeper_skill_catalog.Composition _ ->
             None)
;;

let instruction_skill_schema_tool
      ~(instruction_skills : instruction_skill list)
  =
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~name:skill_tool_schema.name
    ~description:(instruction_skill_description instruction_skills)
    ~input_schema:skill_reference_input_schema
    (fun _ _ -> invalid_arg "schema-only instruction Skill tool cannot execute")
;;

let activation_failure ?reference ~tool_name ~start_time error =
  let reference_field =
    Option.to_list
      (Option.map
         (fun reference -> "reference", Skill_reference.to_yojson reference)
         reference)
  in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Runtime_failure
    ~start_time
    ~data:
      (`Assoc
         (( "skill_activation_error"
          , Keeper_skill_activation_recorder.error_to_yojson error )
          :: reference_field))
    (Keeper_skill_activation_recorder.error_to_string error)
;;

type skill_input_error =
  | Invalid_skill_reference
  | Duplicate_resource_path
  | Invalid_resource_path of Skill_resource_path.error

let skill_reference_and_resource_path input =
  match input with
  | `Assoc fields ->
    let reference_json =
      `Assoc (List.filter (fun (field, _) -> not (String.equal field "file")) fields)
    in
    let resource_fields =
      List.filter_map
        (fun (field, value) -> if String.equal field "file" then Some value else None)
        fields
    in
    (match Skill_reference.request_of_yojson reference_json with
     | Error _ -> Error Invalid_skill_reference
     | Ok reference ->
       (match resource_fields with
        | [] -> Ok (reference, None)
        | [ `String value ] ->
          Skill_resource_path.of_string value
          |> Result.map (fun resource_path -> reference, Some resource_path)
          |> Result.map_error (fun error -> Invalid_resource_path error)
        | [ _ ] -> Error (Invalid_resource_path Skill_resource_path.Empty)
        | _ :: _ :: _ -> Error Duplicate_resource_path))
  | _ ->
    Error Invalid_skill_reference
;;

type instruction_resource =
  | Resource_missing
  | Resource_too_large of
      { observed_bytes : int
      ; max_bytes : int
      }
  | Resource_loaded of string

let load_instruction_resource location relative_path =
  let skill_root = Filename.concat location.source_root location.directory in
  let path = Skill_resource_path.append_to ~root:skill_root relative_path in
  let max_bytes =
    Skill_source_config.resource_read_max_bytes_to_int
      location.resource_read_max_bytes
  in
  Fs_compat.load_owned_regular_file_prefix
    ~ownership_root:location.source_root
    ~max_bytes
    path
  |> Result.map (function
    | None -> Resource_missing
    | Some { Fs_compat.truncated = true; file_size; _ } ->
      Resource_too_large { observed_bytes = file_size; max_bytes }
    | Some { content; truncated = false; _ } -> Resource_loaded content)
;;

let make_instruction_skill_tool
      ~(config : Workspace.config)
      ?record_activation
      ?assess_applicability
      ?on_result
      ~instruction_skills
      ()
  =
  let name = Catalog.skill_tool_name in
  let description = instruction_skill_description instruction_skills in
  let observe handler execution_env input =
    let result = handler execution_env input in
    (* task-3268: the Skill reader bypasses the exec handler, so its honest
       typed result never reached the shared dispatch observers and
       tool_metric_events held zero keeper_skill rows (#38824). Emit here,
       where the result still carries its Completed/Failed disposition. *)
    Tool_dispatch.run_dispatch_observers Dispatch_outcome.Handled (Some result);
    Option.iter (fun callback -> callback ~input result) on_result;
    result
  in
  Tool_bridge.agent_core_tool_of_masc_with_execution_env
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~base_path:config.base_path
    ~model_projection:(fun () -> Tool_output.bounded_inline_model_projection)
    ~name
    ~description
    ~input_schema:skill_reference_input_schema
    (observe (fun execution_env input ->
      let start_time = Tool_timing.start () in
      match
        Tool_input_validation.validate_args ~schema:skill_reference_input_schema ~name
          ~args:input ()
      with
      | Error rejection -> rejection
      | Ok _ ->
        (match Agent_core.Tool.Execution_env.invocation execution_env with
         | None ->
           Tool_result.runtime_err
             ~tool_name:name
             ~start_time
             "keeper_skill execution requires Agent-Core invocation identity"
         | Some invocation ->
        (match skill_reference_and_resource_path input with
         | Error Invalid_skill_reference ->
           Tool_result.make_err
             ~tool_name:name
             ~class_:Tool_result.Workflow_rejection
             ~start_time
             (Printf.sprintf
                "keeper_skill requires one canonical exact Skill reference; \
                 this keeper carries: %s"
                (carried_references_text instruction_skills))
         | Error Duplicate_resource_path ->
           Tool_result.make_err
             ~tool_name:name
             ~class_:Tool_result.Workflow_rejection
             ~start_time
             "keeper_skill accepts at most one resource file"
         | Error (Invalid_resource_path error) ->
           Tool_result.make_err
             ~tool_name:name
             ~class_:Tool_result.Workflow_rejection
             ~start_time
             (Skill_resource_path.error_to_string error)
         | Ok (asked, resource_path) ->
           (* A pinned request is matched whole, as before: a revision the
              caller spelled out is honoured or refused, never replaced. A
              request that named the Skill and left the revision open is
              resolved against this turn's frozen list — the same list the
              pinned match searches, so nothing new is reachable by dropping
              the revision.

              Two carried Skills sharing an identity cannot be told apart by
              name, so that ask is refused rather than answered with a guess;
              the refusal carries the exact references, which is the one
              contract that can still separate them. RFC-0411 §4.2, §4.3. *)
           (match
              match asked with
              | Skill_reference.Pinned reference ->
                List.filter
                  (fun (skill : instruction_skill) ->
                     Skill_reference.equal skill.reference reference)
                  instruction_skills
              | Skill_reference.By_identity identity ->
                List.filter
                  (fun (skill : instruction_skill) ->
                     Skill_reference.equal_identity
                       skill.reference.identity
                       identity)
                  instruction_skills
            with
            | _ :: _ :: _ ->
              Tool_result.make_err
                ~tool_name:name
                ~class_:Tool_result.Workflow_rejection
                ~start_time
                (Printf.sprintf
                   "this keeper carries more than one Skill under that name, so \
                    the name alone cannot say which; call again with \
                    content_revision. Carried: %s"
                   (carried_references_text instruction_skills))
            | [ skill ] ->
              let reference = skill.reference in
              let skill_tool_use_id =
                Agent_core.Tool_contract.Invocation.tool_use_id invocation
              in
              let success ~wire_content metadata =
                Tool_result.make_ok
                  ~tool_name:name
                  ~start_time
                  ~data:(`String wire_content)
                  ~metadata:
                    (`Assoc
                       (("reference", Skill_reference.to_yojson reference)
                        :: ("skill_tool_use_id", `String skill_tool_use_id)
                        :: metadata))
                  ()
              in
              let record_and_return ~content ~wire_content metadata =
                let wire_bytes = String.length wire_content in
                if wire_bytes > Common.max_tool_result_wire_bytes
                then
                  Tool_result.make_err
                    ~tool_name:name
                    ~class_:Tool_result.Workflow_rejection
                    ~start_time
                    ~data:
                      (`Assoc
                         [ ( "skill_content_error"
                           , `Assoc
                               [ "kind", `String "provider_inline_too_large"
                               ; "observed_bytes", `Int wire_bytes
                               ; "max_bytes", `Int Common.max_tool_result_wire_bytes
                               ] )
                         ])
                    (Printf.sprintf
                       "Skill content does not fit the provider inline tool-result boundary: observed_bytes=%d max_bytes=%d"
                       wire_bytes
                       Common.max_tool_result_wire_bytes)
                else
                  let wire_content, metadata =
                    match content, assess_applicability with
                    | Keeper_skill_activation_recorder.Body body, Some assess ->
                      let assessment = assess ~reference ~body in
                      let advice =
                        let open Result.Syntax in
                        let* advice = Typesafeai_skill_applicability.model_advice assessment in
                        match advice with
                        | None -> Ok None
                        | Some advice ->
                          Prompt_registry.render_prompt_template
                            Prompt_names.skill_applicability_projection
                            ["advice", advice]
                          |> Result.map (fun heading -> Some (String.trim heading ^ "\n" ^ wire_content))
                      in
                      let projected = match advice with
                        | Ok (Some text) -> text
                        | Ok None | Error _ -> wire_content in
                      let fits = String.length projected <= Common.max_tool_result_wire_bytes in
                      let has_advice = match advice with Ok (Some _) -> true | Ok None | Error _ -> false in
                      let metadata = match advice with
                        | Error reason -> ("applicability_projection_error", `String reason) :: metadata
                        | Ok _ -> metadata in
                      let metadata =
                        ("skill_applicability", Typesafeai_skill_applicability.to_yojson assessment)
                        :: ("applicability_advice_in_model_content", `Bool (fits && has_advice))
                        :: ("applicability_projection", `String
                              (match advice with
                               | Error _ -> "unavailable"
                               | Ok None -> "not_requested"
                               | Ok (Some _) -> if fits then "inline" else "omitted_inline_limit"))
                        :: metadata in
                      (if fits then projected else wire_content), metadata
                    | Keeper_skill_activation_recorder.Resource _, _
                    | Keeper_skill_activation_recorder.Body _, None -> wire_content, metadata
                  in
                  match record_activation with
                  | Some record ->
                    (match record ~invocation ~content reference with
                     | Error error ->
                       let failure = activation_failure ~reference ~tool_name:name ~start_time error in
                       (match List.assoc_opt "skill_applicability" metadata with
                        | None -> failure
                        | Some assessment ->
                          Tool_result.with_metadata
                            (`Assoc
                               [ "reference", Skill_reference.to_yojson reference
                               ; "skill_tool_use_id", `String skill_tool_use_id
                               ; "skill_applicability", assessment
                               ; "applicability_advice_in_model_content", `Bool false
                               ; "applicability_projection", `String "withheld_activation_failure"
                               ])
                            failure)
                     | Ok
                         ( Activation_ledger.Recorded _
                         | Activation_ledger.Already_recorded _ ) ->
                       success ~wire_content metadata)
                  | None -> success ~wire_content metadata
              in
              (match resource_path with
               | None ->
                 record_and_return
                   ~content:(Keeper_skill_activation_recorder.Body skill.body)
                   ~wire_content:skill.body
                   [ "kind", `String "skill_body"
                   ; "bytes", `Int (String.length skill.body)
                   ; ( "sha256"
                     , `String
                         Agent_core_sha256.(digest_string skill.body |> to_hex) )
                   ]
               | Some relative_path ->
                 (match skill.resource_location with
                  | None ->
                    Tool_result.runtime_err
                      ~tool_name:name
                      ~start_time
                      "the frozen Skill snapshot has no resolved resource root"
                  | Some location ->
                    (match load_instruction_resource location relative_path with
                     | Error error ->
                       Tool_result.runtime_err
                         ~tool_name:name
                         ~start_time
                         (Fs_compat.owned_regular_file_read_error_to_string error)
                     | Ok Resource_missing ->
                       Tool_result.make_err
                         ~tool_name:name
                         ~class_:Tool_result.Workflow_rejection
                         ~start_time
                         (Printf.sprintf
                            "the Skill carries no resource %S"
                            (Skill_resource_path.to_string relative_path))
                     | Ok (Resource_too_large { observed_bytes; max_bytes }) ->
                       Tool_result.make_err
                         ~tool_name:name
                         ~class_:Tool_result.Workflow_rejection
                         ~start_time
                         ~data:
                           (`Assoc
                              [ ( "skill_resource_error"
                                , `Assoc
                                    [ "kind", `String "too_large"
                                    ; ( "file"
                                      , `String
                                          (Skill_resource_path.to_string
                                             relative_path) )
                                    ; "observed_bytes", `Int observed_bytes
                                    ; "max_bytes", `Int max_bytes
                                    ] )
                              ])
                         (Printf.sprintf
                            "Skill resource too_large: observed_bytes=%d max_bytes=%d"
                            observed_bytes
                            max_bytes)
                     | Ok (Resource_loaded contents) ->
                       let relative_path_text =
                         Skill_resource_path.to_string relative_path
                       in
                       let sha256 =
                         Agent_core_sha256.(digest_string contents |> to_hex)
                       in
                       record_and_return
                         ~content:
                           (Keeper_skill_activation_recorder.Resource
                              { relative_path; contents })
                         ~wire_content:contents
                         [ "file", `String relative_path_text
                         ; "kind", `String "skill_resource"
                         ; "bytes", `Int (String.length contents)
                         ; "sha256", `String sha256
                         ])))
            | (* A reference the frozen catalog does not carry is the caller's
                 error and says so with the exact references it does carry,
                 rather than an empty
                 body the model would read as "this skill says nothing". *)
              [] ->
              Tool_result.make_err ~tool_name:name
                ~class_:Tool_result.Workflow_rejection ~start_time
                (Printf.sprintf
                   "no instruction Skill matches %s; this keeper carries: %s"
                   (match asked with
                    | Skill_reference.Pinned reference ->
                      Printf.sprintf
                        "exact reference %s"
                        (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
                    | Skill_reference.By_identity identity ->
                      Printf.sprintf
                        "identity %s"
                        (Skill_reference.identity_to_yojson identity
                         |> Yojson.Safe.to_string))
                   (carried_references_text instruction_skills)))))))
;;
