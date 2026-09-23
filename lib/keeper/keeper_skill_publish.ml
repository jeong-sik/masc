module Publish = Workspace_skill_publish

let ( let* ) = Result.bind

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
  List.fold_right
    (fun item acc ->
       let* strings = acc in
       match item with
       | `String value -> Ok (value :: strings)
       | _ -> Error (Malformed "evidence entries must be strings"))
    items
    (Ok [])
;;

let request ~keeper_name = function
  | `Assoc fields
    when List.length fields = List.length field_names
         && List.for_all (fun (name, _) -> List.mem name field_names) fields ->
    (match
       ( List.assoc_opt "package_id" fields
       , List.assoc_opt "source_text" fields
       , List.assoc_opt "evidence" fields )
     with
     | Some (`String directory), Some (`String source_text), Some (`List items) ->
       let* package_id =
         Skill_reference.package_id_of_directory directory
         |> Result.map_error (fun error -> Invalid_package_id error)
       in
       let* strings = evidence_strings items in
       let* evidence =
         Publish.evidence_of_list strings
         |> Result.map_error (fun error -> Invalid_evidence error)
       in
       Ok { Publish.actor = keeper_name; package_id; source_text; evidence }
     | _ ->
       Error
         (Malformed "string package_id, string source_text and an evidence list are required"))
  | _ -> Error (Malformed "Expected exactly package_id, source_text and evidence")
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

let handle ~config ~keeper_name ~args =
  match request ~keeper_name args with
  | Error error ->
    failure
      ~class_:Tool_result.Policy_rejection
      ~effect_disposition:Tool_result.Proven_pre_effect
      ~code:(request_error_code error)
      ~message:(request_error_message error)
      []
  | Ok request ->
    let identity =
      [ "package_id", `String (Skill_reference.package_id_to_string request.package_id)
      ; ( "evidence"
        , `List
            (List.map (fun value -> `String value) (Publish.evidence_to_list request.evidence)) )
      ]
    in
    (match (Atomic.get Workspace_hooks.keeper_skill_publish_fn) config request with
     | Ok (Publish.Created_and_published { reference; snapshot_revision }) ->
       Keeper_tool_execution.success_data
         (`Assoc
            (identity
             @ [ "ok", `Bool true
               ; "status", `String "created_and_published"
               ; "reference", Skill_reference.to_yojson reference
               ; "snapshot_revision", `String snapshot_revision
               ]))
     | Ok (Created_but_shadowed { reference; snapshot_revision; winner }) ->
       (* The write and the republish both committed, but an earlier source
          declares the same name. Keeper turns list Skills by name and get
          [winner], so the Keeper learns its package is published yet unseen,
          and which package holds the name. *)
       failure
         ~class_:Tool_result.Workflow_rejection
         ~effect_disposition:Tool_result.Proven_post_effect
         ~code:"created_but_shadowed"
         ~message:
           (Printf.sprintf
              "SKILL.md was written and the catalog republished, but %s/%s \
               declares the name %s in an earlier Skill source and wins. \
               Keeper turns see that package under this name, not this one."
              (Skill_reference.identity_source_id_to_string winner)
              (Skill_reference.identity_package_id_to_string winner)
              winner.name)
         (identity
          @ [ "status", `String "created_but_shadowed"
            ; "reference", Skill_reference.to_yojson reference
            ; "snapshot_revision", `String snapshot_revision
            ; "winner", Skill_reference.identity_to_yojson winner
            ])
     | Ok (Created_but_unpublished { reference; reason }) ->
       (* SKILL.md is on disk, so a retry answers package_already_exists; the
          Keeper learns the write committed and why later turns cannot see it
          yet. *)
       failure
         ~class_:Tool_result.Runtime_failure
         ~effect_disposition:Tool_result.Proven_post_effect
         ~code:"created_but_unpublished"
         ~message:reason
         (identity
          @ [ "status", `String "created_but_unpublished"
            ; "reference", Skill_reference.to_yojson reference
            ; "reason", `String reason
            ])
     | Error Publish.Not_installed ->
       failure
         ~class_:Tool_result.Dependency_unavailable
         ~effect_disposition:Tool_result.Proven_pre_effect
         ~code:"skill_publish_not_installed"
         ~message:"Skill publication is not installed in this process"
         identity
     | Error (Refused { code; message; cause }) ->
       let class_, effect_disposition = refusal_class_and_effect cause in
       failure ~class_ ~effect_disposition ~code ~message identity)
;;
