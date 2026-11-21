module Publish = Workspace_skill_publish

open Result.Syntax

type request_error =
  | Malformed of string
  | Invalid_package_id of Skill_reference.package_id_error
  | Invalid_evidence of Publish.evidence_error

let request_error_code = function
  | Malformed _ -> "invalid_skill_publish_request"
  (* Same code the Skill editor answers for the same parse failure. *)
  | Invalid_package_id _ -> "invalid_package_id"
  | Invalid_evidence _ -> "invalid_evidence"
;;

let request_error_message = function
  | Malformed message -> message
  | Invalid_package_id error ->
    "package_id " ^ Skill_reference.package_id_error_to_string error
  | Invalid_evidence error -> Publish.evidence_error_to_string error
;;

let field_names = [ "package_id"; "source_text"; "evidence" ]

let evidence_strings items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | `String value :: rest -> loop (value :: acc) rest
    | _ :: _ -> Error (Malformed "evidence entries must be strings")
  in
  loop [] items
;;

let request ~config ~capability_surface ~keeper_name =
  ignore (config, capability_surface);
  function
  | `Assoc fields
    when List.length fields = 3
         && List.length (List.sort_uniq String.compare (List.map fst fields)) = 3
         && List.for_all (fun (name, _) -> List.mem name field_names) fields ->
    (match
       ( List.assoc_opt "package_id" fields
       , List.assoc_opt "evidence" fields )
     with
     | Some (`String directory), Some (`List items) ->
       let* package_id =
         Skill_reference.package_id_of_directory directory
         |> Result.map_error (fun error -> Invalid_package_id error)
       in
       let* strings = evidence_strings items in
       let* evidence =
         Publish.evidence_of_list strings
         |> Result.map_error (fun error -> Invalid_evidence error)
       in
       let* source_text =
         match List.assoc_opt "source_text" fields with
         | Some (`String text) -> Ok text
         | _ -> Error (Malformed "source_text is required")
       in
       Ok { Publish.actor = keeper_name; package_id; source_text; evidence }
     | _ ->
       Error
         (Malformed "string package_id, source_text, and an evidence list are required"))
  | _ -> Error (Malformed "Expected package_id, evidence and source_text")
;;

let failure ~class_ ~effect_disposition ~code ~message fields =
  Keeper_tool_execution.failure_data
    ~class_
    ~effect_disposition
    ~message
    (`Assoc
       ([ "ok", `Bool false; "error", `String code; "message", `String message ] @ fields))
;;

let refusal_class_and_effect = function
  | Publish.Request_refused -> Tool_result.Policy_rejection, Tool_result.Proven_pre_effect
  | Source_unavailable -> Tool_result.Dependency_unavailable, Tool_result.Proven_pre_effect
  | Write_outcome_unknown -> Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown
;;

let audit_fields = function
  | Publish.Audit_call_returned -> [ "audit_status", `String "audit_call_returned" ]
  | Publish.Audit_unconfirmed -> [ "audit_status", `String "unconfirmed" ]
;;

let handle ~descriptors ~capability_surface ~config ~keeper_name ~args =
  match request ~config ~capability_surface ~keeper_name args with
  | Error error ->
    failure
      ~class_:Tool_result.Policy_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect
      ~code:(request_error_code error)
      ~message:(request_error_message error)
      []
  | Ok request ->
    let identity =
      [ "source_sha256", `String Agent_core_sha256.(digest_string request.source_text |> to_hex)
      ; "package_id", `String (Skill_reference.package_id_to_string request.package_id)
      ; ( "evidence"
        , `List
            (List.map (fun value -> `String value) (Publish.evidence_to_list request.evidence)) )
      ]
    in
    let publication =
      match Keeper_skill_catalog.validate_authored_source ~descriptors
          ~directory:(Skill_reference.package_id_to_string request.package_id)
          request.source_text with
      | Ok _ -> (Atomic.get Workspace_hooks.keeper_skill_publish_fn) config request
      | Error error ->
          let code, message = match error with
            | Keeper_skill_catalog.Source_too_large { bytes; max_bytes } ->
                "source_too_large", Printf.sprintf "Skill source is %d bytes; maximum is %d bytes" bytes max_bytes
            | Invalid_document error ->
                Keeper_skill_catalog.error_code error, Keeper_skill_catalog.error_to_string error in
          Error (Publish.Refused { code; message; cause = Publish.Request_refused; audit = None })
    in
    (match publication with
     | Ok { Publish.creation = Publish.Created_and_published { reference; snapshot_revision; kind; diagnostics }; audit } ->
       Keeper_tool_execution.success_data
         (`Assoc
            (identity @ audit_fields audit
             @ [ "ok", `Bool true
               ; "status", `String "created_and_published"
               ; "reference", Skill_reference.to_yojson reference
               ; "snapshot_revision", `String snapshot_revision
               ; "kind", `String kind
               ; ( "diagnostics"
                 , `List (List.map (fun value -> `String value) diagnostics) )
               ]))
     | Ok { Publish.creation = Publish.Created_but_shadowed { reference; snapshot_revision; winner; kind; diagnostics }; audit } ->
       (* The write and the republish both committed; the catalog lists
          [winner] first under the same name, so turns that list Skills by
          name see it instead. The call did what it does, so it completes and
          the status says the rest. A failure class would be read back to the
          model with a fixed next move (config/prompts/tool_failure.md), and
          each of them is false here: nothing was refused, the runtime did
          not fail, and the same call now always answers
          package_already_exists. *)
       Keeper_tool_execution.success_data
         (`Assoc
            (identity @ audit_fields audit
             @ [ "ok", `Bool true
               ; "status", `String "created_but_shadowed"
               ; "reference", Skill_reference.to_yojson reference
               ; "snapshot_revision", `String snapshot_revision
               ; "kind", `String kind
               ; ( "diagnostics"
                 , `List (List.map (fun value -> `String value) diagnostics) )
               ; "winner", Skill_reference.identity_to_yojson winner
               ; ( "message"
                 , `String
                     (Printf.sprintf
                        "SKILL.md was written and the catalog republished, but \
                         %s/%s declares the name %s earlier in the catalog and \
                         wins. Turns that list Skills by name see that package, \
                         not this one; a Task that pins this exact reference \
                         still gets this one."
                        (Skill_reference.identity_source_id_to_string winner)
                        (Skill_reference.identity_package_id_to_string winner)
                        winner.name) )
               ]))
     | Ok { Publish.creation = Publish.Created_but_unpublished { reference; reason; kind; diagnostics }; audit } ->
       (* SKILL.md is on disk, so a retry answers package_already_exists; the
          Keeper learns the write committed and why later turns cannot see it
          yet. *)
       failure
         ~class_:Tool_result.Runtime_failure
         ~effect_disposition:Tool_result.Proven_post_effect
         ~code:"created_but_unpublished"
         ~message:reason
         (identity @ audit_fields audit
          @ [ "status", `String "created_but_unpublished"
            ; "reference", Skill_reference.to_yojson reference
            ; "reason", `String reason
            ; "kind", `String kind
            ; ( "diagnostics"
              , `List (List.map (fun value -> `String value) diagnostics) )
            ])
     | Error Publish.Not_installed ->
       failure
         ~class_:Tool_result.Dependency_unavailable
         ~effect_disposition:Tool_result.Proven_pre_effect
         ~code:"skill_publish_not_installed"
         ~message:"Skill publication is not installed in this process"
         identity
     | Error (Refused { code; message; cause; audit }) ->
       let class_, effect_disposition = refusal_class_and_effect cause in
       let audit_fields = match audit with None -> [] | Some value -> audit_fields value in
       failure ~class_ ~effect_disposition ~code ~message (identity @ audit_fields))
;;
