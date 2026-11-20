(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_provider_account_event
module Account_map = Map.Make (Provider_account_id)

type kind =
  | Login of { integration_id : Integration_id.t }
  | Key of
      { integration_id : Integration_id.t
      ; generation : Key_generation.t
      }

type account =
  { owner : User_id.t
  ; kind : kind
  }

type t = account Account_map.t

let empty = Account_map.empty
let find t provider_account_id = Account_map.find_opt provider_account_id t

let owner t provider_account_id =
  Option.map (fun { owner; kind = _ } -> owner) (find t provider_account_id)
;;

let owned_by t user_id =
  Account_map.fold
    (fun provider_account_id { owner; kind = _ } owned ->
      if User_id.equal owner user_id then provider_account_id :: owned else owned)
    t
    []
  |> List.rev
;;

let key_accounts t =
  Account_map.fold
    (fun provider_account_id { owner = _; kind } accounts ->
      match kind with
      | Key { integration_id = _; generation = _ } -> provider_account_id :: accounts
      | Login { integration_id = _ } -> accounts)
    t
    []
  |> List.rev
;;

type removal =
  | Not_begun
  | Begun
  | Stopped

type refusal =
  | Already_linked of Provider_account_id.t
  | Linked_for_another of
      { author : User_id.t
      ; user_id : User_id.t
      }
  | User_not_active of User_id.t
  | Not_a_human of Principal.t
  | Not_an_account_author of Author.t
  | Replaced_for_another of
      { author : User_id.t
      ; user_id : User_id.t
      }
  | Not_linked of Provider_account_id.t
  | Not_the_owner of Provider_account_id.t
  | Not_a_key_account of Provider_account_id.t
  | Account_removed of Provider_account_id.t
  | Removal_stopped of Provider_account_id.t
  | Generation_not_next of
      { held : Key_generation.t
      ; given : Key_generation.t
      }

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
      "the principal %s is not active and writes no provider account record"
      (User_id.to_string id)
  | Not_a_human principal ->
    Printf.sprintf
      "the principal %s is a service and writes no provider account record"
      (Principal.to_string principal)
  | Not_an_account_author author -> Author.label author ^ " writes no provider account record"
  | Replaced_for_another { author; user_id } ->
    Printf.sprintf
      "%s replaces the key of an account for %s, and a principal replaces a key only for \
       themselves"
      (User_id.to_string author)
      (User_id.to_string user_id)
  | Not_linked id ->
    Printf.sprintf "no record links the provider account %s" (Provider_account_id.to_string id)
  | Not_the_owner id ->
    Printf.sprintf
      "the provider account %s is another person's"
      (Provider_account_id.to_string id)
  | Not_a_key_account id ->
    Printf.sprintf
      "the provider account %s holds a login and no key"
      (Provider_account_id.to_string id)
  | Account_removed id ->
    Printf.sprintf
      "the removal of the provider account %s began"
      (Provider_account_id.to_string id)
  | Removal_stopped id ->
    Printf.sprintf
      "a removal of the provider account %s stopped, and the account is removed before its \
       key is replaced"
      (Provider_account_id.to_string id)
  | Generation_not_next { held; given } ->
    Printf.sprintf
      "the key is of generation %d, and the record names generation %d, which is not the \
       next"
      (Key_generation.to_int held)
      (Key_generation.to_int given)
;;

(* A login account and a key account are linked by the same person under the
   same conditions: for themselves, while active, an id once. *)
let link t ~author ~is_active ~provider_account_id ~user_id kind =
  if Account_map.mem provider_account_id t
  then Error (Already_linked provider_account_id)
  else if not (User_id.equal author user_id)
  then Error (Linked_for_another { author; user_id })
  else if not (is_active user_id)
  then Error (User_not_active user_id)
  else Ok (Account_map.add provider_account_id { owner = user_id; kind } t)
;;

(* The key account of [user_id] whose key they may replace: its integration
   and the generation it holds. The owner is compared before anything of the
   account is read, so what a person who names another's account is refused
   for does not change with that account. The kind comes before the removal,
   as a removal reads them. *)
let replaceable t ~is_active ~removal ~user_id provider_account_id =
  if not (is_active user_id)
  then Error (User_not_active user_id)
  else (
    match find t provider_account_id with
    | None -> Error (Not_linked provider_account_id)
    | Some { owner; kind = _ } when not (User_id.equal owner user_id) ->
      Error (Not_the_owner provider_account_id)
    | Some { owner = _; kind = Login { integration_id = _ } } ->
      Error (Not_a_key_account provider_account_id)
    | Some { owner; kind = Key { integration_id; generation } } ->
      (match removal ~owner provider_account_id with
       | Begun -> Error (Account_removed provider_account_id)
       | Stopped -> Error (Removal_stopped provider_account_id)
       | Not_begun -> Ok (integration_id, generation)))
;;

let key_to_replace t ~is_active ~removal ~user_id provider_account_id =
  Result.map
    (fun ((_ : Integration_id.t), generation) -> generation)
    (replaceable t ~is_active ~removal ~user_id provider_account_id)
;;

(* The generation comes last: a record read twice is refused here, and so is
   one written on a state that another replacement moved. *)
let replace t ~author ~is_active ~removal ~provider_account_id ~user_id given =
  if not (User_id.equal author user_id)
  then Error (Replaced_for_another { author; user_id })
  else (
    match replaceable t ~is_active ~removal ~user_id provider_account_id with
    | Error refusal -> Error refusal
    | Ok (integration_id, held) ->
      if Key_generation.equal given (Key_generation.next held)
      then
        Ok
          (Account_map.add
             provider_account_id
             { owner = user_id; kind = Key { integration_id; generation = given } }
             t)
      else Error (Generation_not_next { held; given }))
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_active ~removal (event : E.t) =
  match author, event with
  | ( Author.Authenticated (Principal.Human id)
    , E.Linked { provider_account_id; user_id; integration_id } ) ->
    link t ~author:id ~is_active ~provider_account_id ~user_id (Login { integration_id })
  | ( Author.Authenticated (Principal.Human id)
    , E.Key_linked { provider_account_id; user_id; integration_id } ) ->
    link
      t
      ~author:id
      ~is_active
      ~provider_account_id
      ~user_id
      (Key { integration_id; generation = Key_generation.first })
  | ( Author.Authenticated (Principal.Human id)
    , E.Key_replaced { provider_account_id; user_id; generation } ) ->
    replace t ~author:id ~is_active ~removal ~provider_account_id ~user_id generation
  | ( Author.Authenticated (Principal.Service _ as principal)
    , (E.Linked _ | E.Key_linked _ | E.Key_replaced _) ) -> Error (Not_a_human principal)
  | ( ( Author.Local_operator
      | Author.System_cron
      | Author.System_maintenance )
    , (E.Linked _ | E.Key_linked _ | E.Key_replaced _) ) -> Error (Not_an_account_author author)
;;
