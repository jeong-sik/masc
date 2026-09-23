module Publish = Workspace_skill_publish

(* Declared in config/runtime.toml as [[skills.sources]] id = "project-agents"
   (<base-path>/.agents/skills, read-write). *)
let project_agents_source_id = "project-agents"

let cause_of_editor_error : Server_skill_editor.error -> Publish.refusal_cause = function
  | Server_skill_editor.Invalid_workspace
  | Snapshot_not_registered
  | Snapshot_uninitialized
  | Source_not_ready
  | Source_file_missing
  | Source_read_failed
  | Source_path_rejected _
  | Source_read_only ->
    Publish.Source_unavailable
  | Package_already_exists
  | Invalid_package_id _
  | Source_too_large _
  | Validation_failed _
  (* The next four are edit/delete refusals that create does not return
     today; each still refuses the request before anything is written. *)
  | Reference_not_current
  | Confirmation_required
  | Revision_conflict _
  | Delete_revision_conflict _ ->
    Publish.Request_refused
  | Write_failed _
  | Quarantine_failed _
  | Recovery_required _ ->
    Publish.Write_outcome_unknown
;;

let refusal_of_editor_error error =
  Publish.Refused
    { code = Server_skill_editor.error_code error
    ; message = Server_skill_editor.error_to_string error
    ; cause = cause_of_editor_error error
    }
;;

let source_id () =
  Skill_source_config.source_id_of_string project_agents_source_id
;;

let publish ~refresh (config : Workspace.config) (request : Publish.request) =
  match source_id () with
  | Error detail ->
    Error
      (Publish.Refused
         { code = "invalid_source_id"
         ; message = "project-agents source id is invalid: " ^ detail
         ; cause = Publish.Source_unavailable
         })
  | Ok source_id ->
    (match
       Server_skill_editor.create
         ~base_path:config.base_path
         ~source_id
         ~package_id:(Skill_reference.package_id_to_string request.package_id)
         ~source_text:request.source_text
         ~refresh
     with
     | Error error ->
       let refusal = refusal_of_editor_error error in
       (match cause_of_editor_error error with
        | Publish.Write_outcome_unknown ->
          (* The write began and may have committed: a SKILL.md left on disk
             reaches the catalog at the next refresh. Record who tried and
             with what evidence, so such a Skill never appears unattributed. *)
          Server_skill_write_audit.record
            config
            ~agent_id:request.actor
            ~subject:
              (Server_skill_write_audit.Attempted
                 { source_id = project_agents_source_id
                 ; package_id = Skill_reference.package_id_to_string request.package_id
                 })
            ~source_text:request.source_text
            ~status:"write_outcome_unknown"
            ~evidence:(Publish.evidence_to_list request.evidence)
            ~outcome:(Audit_log.Failure (Server_skill_editor.error_to_string error))
            ()
        | Publish.Request_refused | Publish.Source_unavailable -> ());
       Error refusal
     | Ok outcome ->
       let preview, status, audit_outcome, result =
         match outcome with
         | Server_skill_editor.Created_and_published { preview; snapshot_revision } ->
           ( preview
           , "created_and_published"
           , Audit_log.Success
           , Publish.Created_and_published
               { reference = preview.profile.reference
               ; snapshot_revision =
                   Skill_catalog_snapshot.snapshot_revision_to_string snapshot_revision
               } )
         | Created_but_shadowed { preview; snapshot_revision; winner } ->
           ( preview
           , "created_but_shadowed"
           , Audit_log.Failure (Server_skill_editor.shadowed_reason winner)
           , Publish.Created_but_shadowed
               { reference = preview.profile.reference
               ; snapshot_revision =
                   Skill_catalog_snapshot.snapshot_revision_to_string snapshot_revision
               ; winner
               } )
         | Created_but_unpublished { preview; reason } ->
           ( preview
           , "created_but_unpublished"
           , Audit_log.Failure reason
           , Publish.Created_but_unpublished
               { reference = preview.profile.reference; reason } )
       in
       Server_skill_write_audit.record
         config
         ~agent_id:request.actor
         ~subject:(Server_skill_write_audit.Published preview.profile.reference)
         ~source_text:request.source_text
         ~status
         ~evidence:(Publish.evidence_to_list request.evidence)
         ~outcome:audit_outcome
         ();
       Ok result)
;;

let install () =
  Atomic.set Workspace_hooks.keeper_skill_publish_fn (fun config request ->
    let refresh () =
      match Runtime.load_config_observation () with
      | Error message -> Error message
      | Ok observation ->
        Server_skill_snapshot_runtime.refresh_from_observation
          ~base_path:config.Workspace.base_path
          observation
        |> Result.map_error Server_skill_snapshot_runtime.error_to_string
    in
    publish ~refresh config request)
;;
