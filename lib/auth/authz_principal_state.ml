(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module User_map = Map.Make (User_id)
module Namespace_map = Map.Make (Account_home_namespace)
module Identity = Authz_external_identity

type status =
  | Active
  | Disabled

type principal =
  { identity : Identity.t
  ; status : status
  }

type membership =
  { workspace_id : Workspace_id.t
  ; account_home_namespace : Account_home_namespace.t
  }

(* [by_identity] and [by_namespace] name, for each bound identity and each
   namespace given, the principal it belongs to. The maps grow together in
   [admit]. A deletion takes the principal, its identity, its membership, and
   its assignment out, and puts its id in [deleted] and its identity in
   [deleted_identities]; its namespace stays given.
   [admins] holds the assignments in force; an Admin acts only while Active. *)
type t =
  { by_id : principal User_map.t
  ; by_identity : User_id.t Identity.Map.t
  ; memberships : membership User_map.t
  ; by_namespace : User_id.t Namespace_map.t
  ; admins : User_id.Set.t
  ; deleted : User_id.Set.t
  ; deleted_identities : unit Identity.Map.t
  }

let empty =
  { by_id = User_map.empty
  ; by_identity = Identity.Map.empty
  ; memberships = User_map.empty
  ; by_namespace = Namespace_map.empty
  ; admins = User_id.Set.empty
  ; deleted = User_id.Set.empty
  ; deleted_identities = Identity.Map.empty
  }
;;

let find t user_id = User_map.find_opt user_id t.by_id
let bindings t = User_map.bindings t.by_id
let find_identity t identity = Identity.Map.find_opt identity t.by_identity
let find_membership t user_id = User_map.find_opt user_id t.memberships
let find_namespace t namespace = Namespace_map.find_opt namespace t.by_namespace
let is_deleted t user_id = User_id.Set.mem user_id t.deleted
let was_deleted t identity = Identity.Map.mem identity t.deleted_identities

let is_active t user_id =
  match find t user_id with
  | Some { status = Active; identity = _ } -> true
  | Some { status = Disabled; identity = _ } | None -> false
;;

let has_admin_assignment t user_id = User_id.Set.mem user_id t.admins
let is_admin t user_id = has_admin_assignment t user_id && is_active t user_id

(* Design 5.1-5: an installation with Admins keeps one that acts. An Admin that
   is held writes nothing (design 8.3), so it does not act. *)
let an_admin_remains ~held t = User_id.Set.exists (fun id -> is_active t id && not (held id)) t.admins

type refusal =
  | Author_is_not_the_person of
      { author : Author.t
      ; user_id : User_id.t
      }
  | Invitation of Authz_invite_state.consume_refusal
  | Registration of Authz_registration_state.consume_refusal
  | User_id_taken of User_id.t
  | Identity_bound of
      { identity : Identity.t
      ; user_id : User_id.t
      }
  | Workspace_differs of
      { given : Workspace_id.t
      ; workspace_id : Workspace_id.t
      }
  | Namespace_taken of
      { namespace : Account_home_namespace.t
      ; user_id : User_id.t
      }

let refusal_to_string = function
  | Author_is_not_the_person { author; user_id } ->
    Printf.sprintf
      "%s wrote the admission of %s, which only that person writes"
      (Author.label author)
      (User_id.to_string user_id)
  | Invitation refusal -> Authz_invite_state.consume_refusal_to_string refusal
  | Registration refusal -> Authz_registration_state.consume_refusal_to_string refusal
  | User_id_taken user_id -> Printf.sprintf "the user id %s was given before" (User_id.to_string user_id)
  | Identity_bound { identity; user_id } ->
    Printf.sprintf
      "the identity %s is bound to %s"
      (Identity.to_string identity)
      (User_id.to_string user_id)
  | Workspace_differs { given; workspace_id } ->
    Printf.sprintf
      "the admission names the workspace %s, and the installation is %s"
      (Workspace_id.to_string given)
      (Workspace_id.to_string workspace_id)
  | Namespace_taken { namespace; user_id } ->
    Printf.sprintf
      "the account home namespace %s was given to %s"
      (Account_home_namespace.to_string namespace)
      (User_id.to_string user_id)
;;

type admitted =
  { principals : t
  ; invites : Authz_invite_state.t
  ; registrations : Authz_registration_state.t
  ; role : Authz_invite_event.role
  }

(* What the admission spends, and the role it gives. An invitation gives its
   role and also spends the open registration of the identity, so the identity
   has no entry left to come back through once the person is deleted. A
   registration gives a Member (plan C2d). *)
let spend ~invites ~registrations ~identity ~user_id ~at_ms (through : Authz_admission_event.through) =
  match through with
  | Authz_admission_event.Invite invite_id ->
    (match Authz_invite_state.consume invites invite_id ~user_id ~at_ms with
     | Error refusal -> Error (Invitation refusal)
     | Ok (invites, role) ->
       Ok (invites, Authz_registration_state.spend_open registrations identity ~user_id, role))
  | Authz_admission_event.Registration registration_id ->
    (match Authz_registration_state.consume registrations registration_id ~identity ~user_id with
     | Error refusal -> Error (Registration refusal)
     | Ok registrations -> Ok (invites, registrations, Authz_invite_event.Member))
;;

let author_is_the_person (author : Author.t) user_id =
  match author with
  | Author.Authenticated (Principal.Human id) -> User_id.equal id user_id
  | Author.Authenticated (Principal.Service _)
  | Author.Local_operator
  | Author.System_cron
  | Author.System_maintenance
  | Author.System_migration -> false
;;

let admit
  t
  ~invites
  ~registrations
  ~workspace_id
  ~author
  ~at_ms
  ({ Authz_admission_event.user_id; identity; through; membership } : Authz_admission_event.t)
  =
  if not (author_is_the_person author user_id)
  then Error (Author_is_not_the_person { author; user_id })
  else (
    match spend ~invites ~registrations ~identity ~user_id ~at_ms through with
    | Error refusal -> Error refusal
    | Ok (invites, registrations, role) ->
      let { Authz_admission_event.workspace_id = given; account_home_namespace = namespace } = membership in
      (match
         User_map.mem user_id t.by_id, find_identity t identity, find_namespace t namespace
       with
       | true, (None | Some _), (None | Some _) -> Error (User_id_taken user_id)
       | false, (None | Some _), (None | Some _) when is_deleted t user_id -> Error (User_id_taken user_id)
       | false, Some bound, (None | Some _) -> Error (Identity_bound { identity; user_id = bound })
       | false, None, (None | Some _) when not (Workspace_id.equal given workspace_id) ->
         Error (Workspace_differs { given; workspace_id })
       | false, None, Some holder -> Error (Namespace_taken { namespace; user_id = holder })
       | false, None, None ->
         let admins =
           match role with
           | Authz_invite_event.Admin -> User_id.Set.add user_id t.admins
           | Authz_invite_event.Member -> t.admins
         in
         let principals =
           { by_id = User_map.add user_id { identity; status = Active } t.by_id
           ; by_identity = Identity.Map.add identity user_id t.by_identity
           ; memberships =
               User_map.add
                 user_id
                 { workspace_id; account_home_namespace = namespace }
                 t.memberships
           ; by_namespace = Namespace_map.add namespace user_id t.by_namespace
           ; admins
           ; deleted = t.deleted
           ; deleted_identities = t.deleted_identities
           }
         in
         Ok { principals; invites; registrations; role }))
;;

type revocation_refusal =
  | Revoker_is_not_an_admin of Author.t
  | Not_an_admin of User_id.t
  | Last_admin of User_id.t

let revocation_refusal_to_string = function
  | Revoker_is_not_an_admin author ->
    Printf.sprintf "%s is not an Admin, and only an Admin revokes an Admin assignment" (Author.label author)
  | Not_an_admin user_id -> Printf.sprintf "%s has no Admin assignment" (User_id.to_string user_id)
  | Last_admin user_id ->
    Printf.sprintf "%s is the last Admin, so the assignment stays" (User_id.to_string user_id)
;;

(* An Admin that acts: active, and not held by a revocation the store gave up. *)
let author_is_an_admin ~held t (author : Author.t) =
  match author with
  | Author.Authenticated (Principal.Human id) -> is_admin t id && not (held id)
  | Author.Authenticated (Principal.Service _)
  | Author.Local_operator
  | Author.System_cron
  | Author.System_maintenance
  | Author.System_migration -> false
;;

let revoke_admin t ~author ~held (Authz_admin_event.Revoked { user_id; cause = _ }) =
  if not (author_is_an_admin ~held t author)
  then Error (Revoker_is_not_an_admin author)
  else if not (User_id.Set.mem user_id t.admins)
  then Error (Not_an_admin user_id)
  else (
    let after = { t with admins = User_id.Set.remove user_id t.admins } in
    if an_admin_remains ~held after then Ok after else Error (Last_admin user_id))
;;

type principal_refusal =
  | Writer_is_not_an_admin of Author.t
  | No_principal of User_id.t
  | Already_disabled of User_id.t
  | Not_disabled of User_id.t
  | Identity_differs of
      { user_id : User_id.t
      ; identity : Identity.t
      }
  | Would_leave_no_admin of User_id.t

let principal_refusal_to_string = function
  | Writer_is_not_an_admin author ->
    Printf.sprintf "%s is not an Admin, and only an Admin disables, enables, or deletes a principal" (Author.label author)
  | No_principal user_id -> Printf.sprintf "there is no principal %s" (User_id.to_string user_id)
  | Already_disabled user_id -> Printf.sprintf "%s is disabled already" (User_id.to_string user_id)
  | Not_disabled user_id -> Printf.sprintf "%s is not disabled" (User_id.to_string user_id)
  | Identity_differs { user_id; identity } ->
    Printf.sprintf
      "the deletion of %s names the identity %s, which is not the one it is bound to"
      (User_id.to_string user_id)
      (Identity.to_string identity)
  | Would_leave_no_admin user_id ->
    Printf.sprintf "%s is the last Admin that acts, so it stays" (User_id.to_string user_id)
;;

(* The author is an Admin that acts, so one acted before the event, and an
   event that leaves none is refused, as a revocation is. *)
let keep_an_admin ~held user_id after =
  if an_admin_remains ~held after then Ok after else Error (Would_leave_no_admin user_id)
;;

let set_status t user_id (principal : principal) status =
  { t with by_id = User_map.add user_id { principal with status } t.by_id }
;;

let apply_event t ~author ~held (event : Authz_principal_event.t) =
  if not (author_is_an_admin ~held t author)
  then Error (Writer_is_not_an_admin author)
  else (
    let user_id = Authz_principal_event.user_id event in
    match find t user_id, event with
    | ( None
      , ( Authz_principal_event.Disabled _
        | Authz_principal_event.Enabled _
        | Authz_principal_event.Deleted _ ) ) -> Error (No_principal user_id)
    | Some { status = Disabled; _ }, Authz_principal_event.Disabled _ -> Error (Already_disabled user_id)
    | Some ({ status = Active; _ } as principal), Authz_principal_event.Disabled _ ->
      keep_an_admin ~held user_id (set_status t user_id principal Disabled)
    | Some { status = Active; _ }, Authz_principal_event.Enabled _ -> Error (Not_disabled user_id)
    | Some ({ status = Disabled; _ } as principal), Authz_principal_event.Enabled _ ->
      Ok (set_status t user_id principal Active)
    | Some { identity = bound; _ }, Authz_principal_event.Deleted { identity; user_id = _ }
      when not (Identity.equal bound identity) -> Error (Identity_differs { user_id; identity })
    | Some { identity; _ }, Authz_principal_event.Deleted _ ->
      keep_an_admin
        ~held
        user_id
        { t with
          by_id = User_map.remove user_id t.by_id
        ; by_identity = Identity.Map.remove identity t.by_identity
        ; memberships = User_map.remove user_id t.memberships
        ; admins = User_id.Set.remove user_id t.admins
        ; deleted = User_id.Set.add user_id t.deleted
        ; deleted_identities = Identity.Map.add identity () t.deleted_identities
        })
;;

