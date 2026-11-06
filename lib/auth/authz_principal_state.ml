(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module User_map = Map.Make (User_id)
module Identity = Authz_external_identity

type status = Active

type principal =
  { identity : Identity.t
  ; status : status
  }

(* [by_identity] names, for each bound identity, the principal it is bound to.
   The maps and the set change together in [admit] and nowhere else. *)
type t =
  { by_id : principal User_map.t
  ; by_identity : User_id.t Identity.Map.t
  ; admins : User_id.Set.t
  }

let empty = { by_id = User_map.empty; by_identity = Identity.Map.empty; admins = User_id.Set.empty }
let find t user_id = User_map.find_opt user_id t.by_id
let find_identity t identity = Identity.Map.find_opt identity t.by_identity
let is_admin t user_id = User_id.Set.mem user_id t.admins

type refusal =
  | Author_is_not_the_person of
      { author : Author.t
      ; user_id : User_id.t
      }
  | Invitation of Authz_invite_state.consume_refusal
  | User_id_taken of User_id.t
  | Identity_bound of
      { identity : Identity.t
      ; user_id : User_id.t
      }

let author_label : Author.t -> string = function
  | Author.Authenticated principal -> "the principal " ^ Principal.to_string principal
  | Author.Local_operator -> "the local operator"
  | Author.System_cron -> "the system cron"
  | Author.System_maintenance -> "the system maintenance"
  | Author.System_migration -> "the system migration"
;;

let refusal_to_string = function
  | Author_is_not_the_person { author; user_id } ->
    Printf.sprintf
      "%s wrote the admission of %s, which only that person writes"
      (author_label author)
      (User_id.to_string user_id)
  | Invitation refusal -> Authz_invite_state.consume_refusal_to_string refusal
  | User_id_taken user_id -> Printf.sprintf "the user id %s was given before" (User_id.to_string user_id)
  | Identity_bound { identity; user_id } ->
    Printf.sprintf
      "the identity %s is bound to %s"
      (Identity.to_string identity)
      (User_id.to_string user_id)
;;

type admitted =
  { principals : t
  ; invites : Authz_invite_state.t
  ; role : Authz_invite_event.role
  }

let author_is_the_person (author : Author.t) user_id =
  match author with
  | Author.Authenticated (Principal.Human id) -> User_id.equal id user_id
  | Author.Authenticated (Principal.Service _)
  | Author.Local_operator
  | Author.System_cron
  | Author.System_maintenance
  | Author.System_migration -> false
;;

let admit t ~invites ~author ~at_ms ({ Authz_admission_event.user_id; identity; invite_id } : Authz_admission_event.t) =
  if not (author_is_the_person author user_id)
  then Error (Author_is_not_the_person { author; user_id })
  else (
    match Authz_invite_state.consume invites invite_id ~user_id ~at_ms with
    | Error refusal -> Error (Invitation refusal)
    | Ok (invites, role) ->
      (match User_map.mem user_id t.by_id, find_identity t identity with
       | true, (None | Some _) -> Error (User_id_taken user_id)
       | false, Some bound -> Error (Identity_bound { identity; user_id = bound })
       | false, None ->
         let admins =
           match role with
           | Authz_invite_event.Admin -> User_id.Set.add user_id t.admins
           | Authz_invite_event.Member -> t.admins
         in
         let principals =
           { by_id = User_map.add user_id { identity; status = Active } t.by_id
           ; by_identity = Identity.Map.add identity user_id t.by_identity
           ; admins
           }
         in
         Ok { principals; invites; role }))
;;

type revocation_refusal =
  | Revoker_is_not_an_admin of Author.t
  | Not_an_admin of User_id.t
  | Last_admin of User_id.t

let revocation_refusal_to_string = function
  | Revoker_is_not_an_admin author ->
    Printf.sprintf "%s is not an Admin, and only an Admin revokes an Admin assignment" (author_label author)
  | Not_an_admin user_id -> Printf.sprintf "%s has no Admin assignment" (User_id.to_string user_id)
  | Last_admin user_id ->
    Printf.sprintf "%s is the last Admin, so the assignment stays" (User_id.to_string user_id)
;;

let author_is_an_admin t (author : Author.t) =
  match author with
  | Author.Authenticated (Principal.Human id) -> is_admin t id
  | Author.Authenticated (Principal.Service _)
  | Author.Local_operator
  | Author.System_cron
  | Author.System_maintenance
  | Author.System_migration -> false
;;

let revoke_admin t ~author ~held (Authz_admin_event.Revoked { user_id; cause = _ }) =
  if not (author_is_an_admin t author)
  then Error (Revoker_is_not_an_admin author)
  else if not (is_admin t user_id)
  then Error (Not_an_admin user_id)
  else (
    let admins = User_id.Set.remove user_id t.admins in
    if User_id.Set.exists (fun id -> not (held id)) admins
    then Ok { t with admins }
    else Error (Last_admin user_id))
;;
