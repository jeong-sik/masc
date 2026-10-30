(** Server_dashboard_http_delete_actions — POST handlers for
    dashboard delete/sweep endpoints.

    Extracted from {!Server_routes_http_routes_dashboard}. Registers
    admin-only routes:
    - [/api/v1/dashboard/board/delete] — delete one board post
    - [/api/v1/dashboard/tasks/delete] — delete one task
    - [/api/v1/dashboard/goals/delete] — delete one goal
    - [/api/v1/dashboard/agents/purge] — delete an exact agent or accept a
      durable Keeper purge operation. Its optional [expected_workspace] body
      field contains the canonical [base_path] and [masc_root]: a mismatch
      returns 409 before looking up or starting a purge, and malformed values
      return 400. Omitting the field preserves existing client behavior. *)

(** [add_delete_action_routes router] returns [router] with the delete
    endpoints appended.
    Each route requires {!Masc_domain.CanAdmin} via
    [Server_auth.with_token_permission_auth]. *)
val add_delete_action_routes :
  Http_server_eio.Router.t -> Http_server_eio.Router.t

(** Process-boundary completion handler for durable Keeper lifecycle
    operations. Dashboard purge artifacts are removed strictly and
    repeat-safely; non-dashboard actions delegate to the supervisor cleanup
    handler. *)
val handle_keeper_lifecycle_completion :
  Workspace.config ->
  Keeper_shutdown_types.t ->
  Keeper_shutdown_types.completion_action ->
  (unit, string) result

module For_testing : sig
  type official_client_purge_warning =
    | Runtime_toml_unreadable of
        { path : string
        ; detail : string
        }
    | Keeper_not_assigned
    | Empty_lane_candidates of { lane_id : string }
    | Candidate_binding_missing of { runtime_id : string }
    | Candidate_provider_missing of
        { runtime_id : string
        ; provider_id : string
        }
    | Antigravity_credentials_not_file of
        { runtime_id : string
        ; provider_id : string
        }
    | Muse_account_home_missing of
        { runtime_id : string
        ; provider_id : string
        }

  val official_client_purge_warning_to_string :
    official_client_purge_warning -> string

  val resolve_official_client_purge_artifacts :
    Workspace.config ->
    keeper_name:string ->
    Keeper_shutdown_types.dashboard_purge_artifact list
    * official_client_purge_warning list

  val purge_agent_artifacts :
    Workspace.config -> string list -> (unit, string) result

  val handle_board_close_post :
    agent_name:string -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

  val purge_keeper_artifacts :
    Workspace.config ->
    keeper_name:string ->
    remove_configuration:bool ->
    Keeper_shutdown_types.dashboard_purge_context ->
    (unit, string) result
end
