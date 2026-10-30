(** Which authentication the HTTP/2 gateway runs for a request.

    The gateway asks the HTTP/1 router for the kind of the request
    ({!Route_access.t}) and runs the gate that goes with it, so the kind is written
    in one place: the HTTP/1 registration. This module is the decision and nothing
    else. The gateway runs the gate. *)

type gate =
  | Open  (** Nothing to run: the route is public, or its handler authenticates. *)
  | Public_read
  | Read_auth
  | Token_permission of Masc_domain.permission

type refusal =
  | No_route  (** The HTTP/1 router has no route for the path. *)
  | Wrong_method  (** It has a route for the path, but not for the method. *)
  | Kind_not_served of Route_access.t
      (** HTTP/2 has no gate for the kind, or the route table does not hold the
          kind of the sub-routes under it. *)
  | Actor_not_provided of Route_access.t
      (** The arm needs the authenticated actor and the kind does not
          authenticate one. *)

(** The kind the HTTP/1 router records for the request it resolved. *)
val access_of_resolution
  :  Http_server_eio.Router.resolution
  -> (Route_access.t, refusal) result

(** The gate for a kind. A kind that HTTP/2 does not serve is a refusal, never an
    open route. *)
val plan : Route_access.t -> (gate, refusal) result

(** The permission to check for an arm that takes the authenticated actor. Only a
    kind bound to a token provides one. *)
val plan_actor : Route_access.t -> (Masc_domain.permission, refusal) result

(** One line for the log. *)
val refusal_to_string : refusal -> string
