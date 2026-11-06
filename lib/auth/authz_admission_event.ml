(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type membership =
  { workspace_id : Workspace_id.t
  ; account_home_namespace : Account_home_namespace.t
  }

type t =
  { user_id : User_id.t
  ; identity : Authz_external_identity.t
  ; invite_id : Invite_id.t
  ; membership : membership
  }

let equal a b =
  User_id.equal a.user_id b.user_id
  && Authz_external_identity.equal a.identity b.identity
  && Invite_id.equal a.invite_id b.invite_id
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

let to_body { user_id; identity; invite_id; membership } =
  let* user_id = Authz_body.string (User_id.to_string user_id) in
  let* identity = Authz_external_identity.to_body identity in
  let* invite_id = Authz_body.string (Invite_id.to_string invite_id) in
  let* membership = membership_body membership in
  Authz_body.object_
    [ "user_id", user_id; "identity", identity; "invite_id", invite_id; "membership", membership ]
;;

type error =
  | Not_an_object
  | Wrong_members
  | Invalid_user_id of Authz_id.error
  | Invalid_identity of Authz_external_identity.body_error
  | Invalid_invite_id of Authz_id.error
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
     invite_id, a string, and membership, an object of the strings workspace_id and \
     account_home_namespace, in this order"
  | Invalid_user_id error -> Printf.sprintf "the user id is not valid: %s" (id_error_to_string error)
  | Invalid_identity error ->
    "the identity is not valid: " ^ Authz_external_identity.body_error_to_string error
  | Invalid_invite_id error ->
    Printf.sprintf "the invite id is not valid: %s" (id_error_to_string error)
  | Invalid_workspace_id error ->
    Printf.sprintf "the workspace id is not valid: %s" (id_error_to_string error)
  | Invalid_account_home_namespace error ->
    Printf.sprintf "the account home namespace is not valid: %s" (id_error_to_string error)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object
      [ ("user_id", Authz_body.String user_id)
      ; ("identity", (Authz_body.Object _ as identity))
      ; ("invite_id", Authz_body.String invite_id)
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
    let* invite_id =
      Result.map_error (fun error -> Invalid_invite_id error) (Invite_id.of_string invite_id)
    in
    let* workspace_id =
      Result.map_error (fun error -> Invalid_workspace_id error) (Workspace_id.of_string workspace_id)
    in
    let* account_home_namespace =
      Result.map_error
        (fun error -> Invalid_account_home_namespace error)
        (Account_home_namespace.of_string namespace)
    in
    Ok { user_id; identity; invite_id; membership = { workspace_id; account_home_namespace } }
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
