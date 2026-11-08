(** Server_routes_http_routes_skills — HTTP routes for the Skill editor dashboard surface. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val skill_delete_audit_of_outcome :
    Server_skill_editor.delete_outcome -> Audit_log.outcome * Yojson.Safe.t
  (** The [skill_delete] audit row the delete route writes for any delete that
      went through ([Deleted_and_published] or [Deleted_but_unpublished]),
      built from the outcome alone. *)
end
