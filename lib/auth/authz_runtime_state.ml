(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_runtime_event
module Runtime_map = Map.Make (Runtime_id)

type runtime =
  { owner : User_id.t
  ; provider_account_id : Provider_account_id.t
  ; self_grant : Grant_id.t
  ; self_effects : Effect.Set.t
  }

type t =
  { runtimes : runtime Runtime_map.t
  ; grants : Grant_id.Set.t
  }

let empty = { runtimes = Runtime_map.empty; grants = Grant_id.Set.empty }
let find t runtime_id = Runtime_map.find_opt runtime_id t.runtimes
let owner t runtime_id = Option.map (fun runtime -> runtime.owner) (find t runtime_id)

let owned_by t user_id =
  Runtime_map.bindings t.runtimes
  |> List.filter (fun (_, runtime) -> User_id.equal runtime.owner user_id)
;;

type refusal =
  | Already_made of Runtime_id.t
  | Grant_named_before of Grant_id.t
  | Made_for_another of
      { author : User_id.t
      ; user_id : User_id.t
      }
  | Account_not_theirs of
      { provider_account_id : Provider_account_id.t
      ; user_id : User_id.t
      }
  | User_not_active of User_id.t
  | Not_a_human of Principal.t
  | Not_a_runtime_author of Author.t

let refusal_to_string = function
  | Already_made id -> Printf.sprintf "the Runtime %s was made before" (Runtime_id.to_string id)
  | Grant_named_before id ->
    Printf.sprintf "the grant %s was named before" (Grant_id.to_string id)
  | Made_for_another { author; user_id } ->
    Printf.sprintf
      "%s makes a Runtime for %s, and a principal makes a Runtime only for themselves"
      (User_id.to_string author)
      (User_id.to_string user_id)
  | Account_not_theirs { provider_account_id; user_id } ->
    Printf.sprintf
      "the provider account %s is not one of %s, and a Runtime spends only an account of \
       its owner"
      (Provider_account_id.to_string provider_account_id)
      (User_id.to_string user_id)
  | User_not_active id ->
    Printf.sprintf "the principal %s is not active and makes no Runtime" (User_id.to_string id)
  | Not_a_human principal ->
    Printf.sprintf
      "the principal %s is a service and makes no Runtime"
      (Principal.to_string principal)
  | Not_a_runtime_author author -> Author.label author ^ " makes no Runtime"
;;

let owns ~account_owner ~provider_account_id user_id =
  match account_owner provider_account_id with
  | Some owner -> User_id.equal owner user_id
  | None -> false
;;

let make
      t
      ~author
      ~is_active
      ~account_owner
      ~runtime_id
      ~provider_account_id
      ~user_id
      ~grant_id
      ~self_effects
  =
  if Runtime_map.mem runtime_id t.runtimes
  then Error (Already_made runtime_id)
  else if Grant_id.Set.mem grant_id t.grants
  then Error (Grant_named_before grant_id)
  else if not (User_id.equal author user_id)
  then Error (Made_for_another { author; user_id })
  else if not (is_active user_id)
  then Error (User_not_active user_id)
  else if not (owns ~account_owner ~provider_account_id user_id)
  then Error (Account_not_theirs { provider_account_id; user_id })
  else
    Ok
      { runtimes =
          Runtime_map.add
            runtime_id
            { owner = user_id; provider_account_id; self_grant = grant_id; self_effects }
            t.runtimes
      ; grants = Grant_id.Set.add grant_id t.grants
      }
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_active ~account_owner (event : E.t) =
  match author, event with
  | ( Author.Authenticated (Principal.Human id)
    , E.Made { runtime_id; provider_account_id; user_id; grant_id; self_effects } ) ->
    make
      t
      ~author:id
      ~is_active
      ~account_owner
      ~runtime_id
      ~provider_account_id
      ~user_id
      ~grant_id
      ~self_effects
  | Author.Authenticated (Principal.Service _ as principal), E.Made _ ->
    Error (Not_a_human principal)
  | ( ( Author.Local_operator
      | Author.System_cron
      | Author.System_maintenance
      | Author.System_migration )
    , E.Made _ ) -> Error (Not_a_runtime_author author)
;;
