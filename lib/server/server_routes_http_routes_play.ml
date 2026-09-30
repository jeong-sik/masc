(** HTTP routes for invites to the shared machine (RFC
    play-link-for-the-shared-machine §2.4).

    - [POST /api/v1/play/invites] [{name, hours}] issues a [Player]
      credential and answers [{name, expires_at, link}]. The link carries the
      raw token after [#]; this answer is its only copy.
    - [GET /api/v1/play/invites] lists them, with who holds the DOS controller.
    - [DELETE /api/v1/play/invites/<name>] deletes the credential and frees the
      controller the name still holds. Asked again for a name with no
      credential and no keeper, it frees a controller the name took back.

    All three need [CanAdmin] from a bearer, and name the operator who acted.
    A field of the wrong type is a 400 naming the field, never a default. *)

open Server_auth
module Http = Http_server_eio

let invites_path = "/api/v1/play/invites"
let invite_prefix = invites_path ^ "/"

let decode_issue body =
  let ( let* ) = Result.bind in
  let* json =
    try Ok (Yojson.Safe.from_string body) with
    | Yojson.Json_error message -> Error ("body is not JSON: " ^ message)
  in
  let field name =
    match json with
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  let* name =
    match field "name" with
    | Some (`String raw) -> Play_invite.Name.of_string raw
    | None -> Error "name is required"
    | Some (`Int _ | `Intlit _ | `Float _ | `Bool _ | `Null | `List _ | `Assoc _) ->
      Error "name must be a string"
  in
  let* hours =
    match field "hours" with
    | Some (`Int hours) -> Ok hours
    | None -> Error "hours is required: an invite always expires"
    | Some (`Intlit _ | `Float _ | `String _ | `Bool _ | `Null | `List _ | `Assoc _) ->
      Error "hours must be an integer"
  in
  Ok (name, hours)

let issue_response ~config ~body =
  match decode_issue body with
  | Error message -> `Bad_request, Server_refusal.json ~code:"invalid_request" message
  | Ok (name, hours) ->
    (match
       Play_invite.issue ~base_path:config.Workspace.base_path
         ~public_base_url:(Env_config_core.masc_http_base_url_opt ())
         ~keeper_names:(Play_seat.keeper_names config) ~name ~hours
     with
     | Ok { Play_invite.name; expires_at; link } ->
       ( `Created
       , `Assoc
           [ ("name", `String (Play_invite.Name.to_string name))
           ; ("expires_at", `String expires_at)
           ; ("link", `String link)
           ] )
     | Error (Play_invite.Not_ready gaps) ->
       ( `Conflict
       , Server_refusal.json ~code:"not_ready"
           ~fields:
             [ ( "missing"
               , `List (List.map (fun gap -> `String (Play_invite.readiness_gap_to_string gap)) gaps) )
             ]
           "an invite needs auth enabled with require_token, and MASC_HTTP_BASE_URL set" )
     | Error (Play_invite.Name_taken by) ->
       ( `Conflict
       , Server_refusal.json ~code:"name_taken"
           ~fields:[ ("taken_by", `String (Play_invite.taken_by_to_string by)) ]
           "another participant already has this name" )
     | Error (Play_invite.Keeper_names_unreadable detail) ->
       `Service_unavailable, Server_refusal.json ~code:"keepers_unreadable" detail
     | Error (Play_invite.Hours_out_of_range hours) ->
       ( `Bad_request
       , Server_refusal.json ~code:"invalid_request"
           (Printf.sprintf "hours must be between %d and %d, got %d"
              Masc_domain.min_token_expiry_hours Masc_domain.max_token_expiry_hours hours) )
     | Error (Play_invite.Credential_not_saved err) ->
       `Internal_server_error, Server_refusal.json ~code:"not_saved" (Masc_domain.masc_error_to_string err))

let current_controller () =
  match Tool_misc_dos_lane.off_domain Dos_lane.screen with
  | Ok { Dos_lane.controller; _ } -> controller
  | Error _ -> None

let list_json ~config =
  let controller = current_controller () in
  `Assoc
    [ ( "invites"
      , `List
          (List.map
             (fun { Play_invite.invite_name; expires_at; expired } ->
               `Assoc
                 [ ("name", `String invite_name)
                 ; ("expires_at", Json_util.string_opt_to_json expires_at)
                 ; ("expired", `Bool expired)
                 ; ("holds_controller", `Bool (controller = Some invite_name))
                 ])
             (Play_invite.list ~base_path:config.Workspace.base_path ~now:(Time_compat.now ()))) )
    ]

type release =
  | Released
  | Not_held
  | Release_failed of string

let release_controller ~holder ~by =
  match Tool_misc_dos_lane.release_revoked_invite ~holder ~by with
  | Ok true -> Released
  | Ok false | Error Dos_lane.No_machine -> Not_held
  | Error
      (( Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
       | Dos_lane.Guest_fault _ | Dos_lane.Unsaveable _ | Dos_lane.Checkpoint_refused _
       | Dos_lane.Other_program _ ) as err) ->
    Release_failed (Dos_lane.error_to_string err)

let release_fields = function
  | Released -> [ ("released_controller", `Bool true) ]
  | Not_held -> [ ("released_controller", `Bool false) ]
  | Release_failed message ->
    [ ("released_controller", `Bool false); ("release_error", `String message) ]

let revoke_response ~config ~by ~raw_name =
  match Play_invite.Name.of_string raw_name with
  | Error message -> `Bad_request, Server_refusal.json ~code:"invalid_request" message
  | Ok name ->
    let holder = Play_invite.Name.to_string name in
    let no_such_invite () = `Not_found, Server_refusal.json ~code:"no_such_invite" ("no invite is named " ^ raw_name) in
    let after_revoke = function
     | Play_invite.Deleted ->
       ( `OK
       , `Assoc
           (("name", `String holder) :: ("revoked", `Bool true)
            :: release_fields (release_controller ~holder ~by)) )
     (* Revoked before, or never issued. A request the invitee sent before
        the delete can take the freed controller after it, and a release can
        fail; revoking again frees it then. A keeper's name is left alone:
        its controller is the keeper's, and [Keeper_dos_controller] decides
        when that one is let go. *)
     | Play_invite.Already_gone ->
       (match Play_seat.keeper_names config with
        | Error detail -> `Service_unavailable, Server_refusal.json ~code:"keepers_unreadable" detail
        | Ok keepers when Play_invite.is_keeper_name ~keepers name -> no_such_invite ()
        | Ok _ ->
          (match release_controller ~holder ~by with
           | Released ->
             ( `OK
             , `Assoc
                 (("name", `String holder) :: ("revoked", `Bool false) :: release_fields Released) )
           | Not_held -> no_such_invite ()
           | Release_failed message as failed ->
             ( `Internal_server_error
             , Server_refusal.json ~code:"release_failed"
                 ~fields:(("name", `String holder) :: release_fields failed)
                 (Printf.sprintf "%s holds the DOS controller and it could not be released: %s"
                    holder message) )))
    in
    let revoked =
      Play_invite.revoke ~base_path:config.Workspace.base_path ~name ~after_revoke
      |> Tool_misc_dos_lane.after_announcing
    in
    (match revoked with
     | Ok response -> response
     | Error (Play_invite.Not_an_invite role) ->
       ( `Conflict
       , Server_refusal.json ~code:"not_an_invite"
           (Printf.sprintf "%s is a %s credential, not an invite" raw_name
              (Masc_domain.agent_role_to_string role)) )
     | Error (Play_invite.Credential_not_deleted error) ->
       `Service_unavailable,
       Server_refusal.json ~code:"not_deleted" (Masc_domain.masc_error_to_string error)
     | Error Play_invite.Credential_unreadable ->
       `Service_unavailable, Server_refusal.json ~code:"credential_unreadable"
         ("the credential for " ^ raw_name ^ " could not be read")
     | Error (Play_invite.Credential_identity_mismatch owner) ->
       `Service_unavailable, Server_refusal.json ~code:"credential_identity_mismatch"
         (Printf.sprintf "the credential for %s resolves to %s" raw_name owner))

module For_testing = struct
  let revoke_response = revoke_response
end

(* Serialize invite routes. Auth's credential transaction owns the name-file
   check and publication, also excluding credential writers outside these routes. *)
let invites_lock = Eio.Mutex.create ()
let one_at_a_time f = Eio.Mutex.use_rw ~protect:true invites_lock f

let add_routes router =
  router
  |> Http.Router.post invites_path (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _by request reqd ->
           let config = Mcp_server.workspace_config state in
           Http.Request.read_body_async reqd (fun body ->
             let status, json = one_at_a_time (fun () -> issue_response ~config ~body) in
             respond_json_value_with_cors ~status request reqd json))
         request reqd)
  |> Http.Router.get invites_path (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _by request reqd ->
           respond_json_value_with_cors request reqd
             (list_json ~config:(Mcp_server.workspace_config state)))
         request reqd)
  |> Http.Router.prefix_delete invite_prefix (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state by request reqd ->
           let status, json =
             match Server_utils.extract_path_param ~prefix:invite_prefix (Http.Request.path request) with
             | None -> `Bad_request, Server_refusal.json ~code:"invalid_request" "an invite name is required"
             | Some raw_name ->
               one_at_a_time (fun () ->
                 revoke_response ~config:(Mcp_server.workspace_config state) ~by ~raw_name)
           in
           respond_json_value_with_cors ~status request reqd json)
         request reqd)
