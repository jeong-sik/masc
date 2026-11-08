(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_provider_account_event
module Account_map = Map.Make (Provider_account_id)

type t = User_id.t Account_map.t

let empty = Account_map.empty
let owner t provider_account_id = Account_map.find_opt provider_account_id t

type refusal =
  | Already_linked of Provider_account_id.t
  | Linked_for_another of
      { author : User_id.t
      ; user_id : User_id.t
      }
  | User_not_active of User_id.t
  | Not_a_human of Principal.t
  | Not_a_link_author of Author.t

let refusal_to_string = function
  | Already_linked id ->
    Printf.sprintf "the provider account %s was linked before" (Provider_account_id.to_string id)
  | Linked_for_another { author; user_id } ->
    Printf.sprintf
      "%s links a provider account for %s, and a principal links an account only for \
       themselves"
      (User_id.to_string author)
      (User_id.to_string user_id)
  | User_not_active id ->
    Printf.sprintf
      "the principal %s is not active and links no provider account"
      (User_id.to_string id)
  | Not_a_human principal ->
    Printf.sprintf
      "the principal %s is a service and links no provider account"
      (Principal.to_string principal)
  | Not_a_link_author author -> Author.label author ^ " links no provider account"
;;

let link t ~author ~is_active ~provider_account_id ~user_id =
  if Account_map.mem provider_account_id t
  then Error (Already_linked provider_account_id)
  else if not (User_id.equal author user_id)
  then Error (Linked_for_another { author; user_id })
  else if not (is_active user_id)
  then Error (User_not_active user_id)
  else Ok (Account_map.add provider_account_id user_id t)
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_active (event : E.t) =
  match author, event with
  | Author.Authenticated (Principal.Human id), E.Linked { provider_account_id; user_id } ->
    link t ~author:id ~is_active ~provider_account_id ~user_id
  | Author.Authenticated (Principal.Service _ as principal), E.Linked _ ->
    Error (Not_a_human principal)
  | ( ( Author.Local_operator
      | Author.System_cron
      | Author.System_maintenance
      | Author.System_migration )
    , E.Linked _ ) -> Error (Not_a_link_author author)
;;
