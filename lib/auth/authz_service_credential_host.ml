(* HIGH-RISK-UNREVIEWED: see the interface. *)

let ( let* ) = Result.bind

(* 128 random bits in hex. An id is never used again (design 4.1):
   [Authz_service_credential.issue] draws again, or refuses an id that the
   log holds. *)
let id_bytes = 16

type error =
  | Not_active of Authz_activation.invite_error
  | Zone_not_opened of Authz_zone.open_error
  | Service_id_invalid of Authz_id.error
  | Credential_id_invalid of Authz_id.error
  | Not_issued of Authz_service_credential.error
  | Not_revoked of Authz_service_credential.error

let error_to_string = function
  | Not_active error -> Authz_activation.invite_error_to_string error
  | Zone_not_opened error ->
    "the authorization log was not opened: " ^ Authz_zone.open_error_to_string error
  | Service_id_invalid error -> "the service name is not a service id: " ^ Authz_id.error_to_string error
  | Credential_id_invalid error ->
    "the credential id is not a credential id: " ^ Authz_id.error_to_string error
  | Not_issued error ->
    "the credential was not issued: " ^ Authz_service_credential.error_to_string error
  | Not_revoked error ->
    "the credential was not revoked: " ^ Authz_service_credential.error_to_string error
;;

let open_zone ~base_path ~config_dir ~anonymous_mutations ~now_ms =
  let* store_path =
    Result.map_error
      (fun error -> Not_active error)
      (Authz_activation.active_store ~base_path ~config_dir ~anonymous_mutations)
  in
  Result.map_error
    (fun error -> Zone_not_opened error)
    (Authz_zone.open_at_start
       ~now_ms
       ~log_path:(Authz_log.path_of_base_path ~base_path)
       ~store_path)
;;

let issue ~base_path ~config_dir ~anonymous_mutations ~now_ms ~service =
  let* service_id =
    Result.map_error
      (fun error -> Service_id_invalid error)
      (Authz_types.Service_id.of_string service)
  in
  let* zone = open_zone ~base_path ~config_dir ~anonymous_mutations ~now_ms in
  Result.map_error
    (fun error -> Not_issued error)
    (Authz_service_credential.issue zone ~service_id ~draw:(fun () ->
       Random_id.hex ~bytes:id_bytes))
;;

let revoke ~base_path ~config_dir ~anonymous_mutations ~now_ms ~credential =
  let* credential_id =
    Result.map_error
      (fun error -> Credential_id_invalid error)
      (Authz_types.Service_credential_id.of_string credential)
  in
  let* zone = open_zone ~base_path ~config_dir ~anonymous_mutations ~now_ms in
  Result.map_error
    (fun error -> Not_revoked error)
    (Authz_service_credential.revoke zone credential_id)
;;

type listed =
  { credential_id : Authz_types.Service_credential_id.t
  ; service_id : Authz_types.Service_id.t
  ; issued_at_ms : int
  ; status : Authz_service_credential_state.status
  }

let list ~base_path ~config_dir ~anonymous_mutations ~now_ms =
  let* zone = open_zone ~base_path ~config_dir ~anonymous_mutations ~now_ms in
  Ok
    (List.map
       (fun ( credential_id
            , { Authz_service_credential_state.service_id
              ; secret_digest = _
              ; issued_at_ms
              ; status
              } ) -> { credential_id; service_id; issued_at_ms; status })
       (Authz_service_credential_state.bindings
          (Authz_zone.snapshot zone).state.service_credentials))
;;
