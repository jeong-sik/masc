(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type membership =
  { workspace_id : Workspace_id.t
  ; account_home_namespace : Account_home_namespace.t
  }

type through =
  | Invite of Invite_id.t
  | Registration of Registration_id.t

type t =
  { user_id : User_id.t
  ; identity : Authz_external_identity.t
  ; through : through
  ; membership : membership
  }

let through_equal a b =
  match a, b with
  | Invite a, Invite b -> Invite_id.equal a b
  | Registration a, Registration b -> Registration_id.equal a b
  | Invite _, Registration _ | Registration _, Invite _ -> false
;;

let equal a b =
  User_id.equal a.user_id b.user_id
  && Authz_external_identity.equal a.identity b.identity
  && through_equal a.through b.through
  && Workspace_id.equal a.membership.workspace_id b.membership.workspace_id
  && Account_home_namespace.equal
       a.membership.account_home_namespace
       b.membership.account_home_namespace
;;

let membership_body { workspace_id; account_home_namespace } =
  let* workspace_id = Authz_body.string (Workspace_id.to_string workspace_id) in
  let* namespace = Authz_body.string (Account_home_namespace.to_string account_home_namespace) in
  Authz_body.object_ [ "workspace_id", workspace_id; "account_home_namespace", namespace ]
;;

let invite_label = "invite"
let registration_label = "registration"

let through_body through =
  let label, id =
    match through with
    | Invite id -> invite_label, Invite_id.to_string id
    | Registration id -> registration_label, Registration_id.to_string id
  in
  let* label = Authz_body.string label in
  let* id = Authz_body.string id in
  Authz_body.object_ [ "type", label; "id", id ]
;;

let to_body { user_id; identity; through; membership } =
  let* user_id = Authz_body.string (User_id.to_string user_id) in
  let* identity = Authz_external_identity.to_body identity in
  let* through = through_body through in
  let* membership = membership_body membership in
  Authz_body.object_
    [ "user_id", user_id; "identity", identity; "through", through; "membership", membership ]
;;

type error =
  | Not_an_object
  | Wrong_members
  | Invalid_user_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error
  | Unknown_through of string
  | Invalid_invite_id of Authz_id.error
  | Invalid_registration_id of Authz_id.error
  | Invalid_workspace_id of Authz_id.error
  | Invalid_account_home_namespace of Authz_id.error

let id_error_to_string : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte at %d" index
  | Authz_id.Path_segment -> "a path segment"
;;

let error_to_string = function
  | Not_an_object -> "the body of an admission is an object"
  | Wrong_members ->
    "the body of an admission has the members user_id, a string, identity, an object, \
     through, an object of the strings type and id, and membership, an object of the \
     strings workspace_id and account_home_namespace, in this order"
  | Invalid_user_id error -> Printf.sprintf "the user id is not valid: %s" (id_error_to_string error)
  | Invalid_identity error ->
    "the identity is not valid: " ^ Authz_external_identity.body_error_to_string error
  | Unknown_through label ->
    Printf.sprintf
      "%S is not a way into the installation, which is an invite or a registration"
      label
  | Invalid_invite_id error ->
    Printf.sprintf "the invite id is not valid: %s" (id_error_to_string error)
  | Invalid_registration_id error ->
    Printf.sprintf "the registration id is not valid: %s" (id_error_to_string error)
  | Invalid_workspace_id error ->
    Printf.sprintf "the workspace id is not valid: %s" (id_error_to_string error)
  | Invalid_account_home_namespace error ->
    Printf.sprintf "the account home namespace is not valid: %s" (id_error_to_string error)
;;

let through_of ~label ~id =
  if String.equal label invite_label
  then
    Result.map
      (fun id -> Invite id)
      (Result.map_error (fun error -> Invalid_invite_id error) (Invite_id.of_string id))
  else if String.equal label registration_label
  then
    Result.map
      (fun id -> Registration id)
      (Result.map_error (fun error -> Invalid_registration_id error) (Registration_id.of_string id))
  else Error (Unknown_through label)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object
      [ ("user_id", Authz_body.String user_id)
      ; ("identity", (Authz_body.Object _ as identity))
      ; ("through", Authz_body.Object [ ("type", Authz_body.String label); ("id", Authz_body.String id) ])
      ; ( "membership"
        , Authz_body.Object
            [ ("workspace_id", Authz_body.String workspace_id)
            ; ("account_home_namespace", Authz_body.String namespace)
            ] )
      ] ->
    let* user_id =
      Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string user_id)
    in
    let* identity =
      Result.map_error (fun error -> Invalid_identity error) (Authz_external_identity.of_body identity)
    in
    let* through = through_of ~label ~id in
    let* workspace_id =
      Result.map_error (fun error -> Invalid_workspace_id error) (Workspace_id.of_string workspace_id)
    in
    let* account_home_namespace =
      Result.map_error
        (fun error -> Invalid_account_home_namespace error)
        (Account_home_namespace.of_string namespace)
    in
    Ok { user_id; identity; through; membership = { workspace_id; account_home_namespace } }
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
