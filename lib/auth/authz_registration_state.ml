(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_registration_event
module Identity_map = Authz_external_identity.Map
module Registration_map = Map.Make (Registration_id)

type status =
  | Open
  | Removed
  | Consumed of User_id.t

type registration =
  { identity : Authz_external_identity.t
  ; registrar : User_id.t
  ; status : status
  }

(* [open_by_identity] names, for each identity with an open registration, that
   registration. The two maps change together in [register], [remove], and
   [spend] and nowhere else. *)
type t =
  { by_id : registration Registration_map.t
  ; open_by_identity : Registration_id.t Identity_map.t
  }

let empty = { by_id = Registration_map.empty; open_by_identity = Identity_map.empty }
let find t registration_id = Registration_map.find_opt registration_id t.by_id
let bindings t = Registration_map.bindings t.by_id

let find_open t identity =
  match Identity_map.find_opt identity t.open_by_identity with
  | None -> None
  | Some registration_id ->
    (match find t registration_id with
     | Some registration -> Some (registration_id, registration)
     | None -> None)
;;

let find_consumed_by t user_id =
  Seq.find
    (fun ((_ : Registration_id.t), registration) ->
      match registration.status with
      | Consumed spender -> User_id.equal spender user_id
      | Open | Removed -> false)
    (Registration_map.to_seq t.by_id)
;;

type refusal =
  | Already_registered of Registration_id.t
  | Identity_registered of Registration_id.t
  | Identity_bound
  | Not_registered of Registration_id.t
  | Already_removed of Registration_id.t
  | Already_consumed of Registration_id.t
  | Author_is_not_an_admin of Principal.t
  | Not_a_registration_author of Author.t

let author_label : Author.t -> string = function
  | Author.Authenticated principal -> "the principal " ^ Principal.to_string principal
  | Author.Local_operator -> "the local operator"
  | Author.System_cron -> "the system cron"
  | Author.System_maintenance -> "the system maintenance"
  | Author.System_migration -> "the system migration"
;;

let refusal_to_string = function
  | Already_registered id ->
    Printf.sprintf "the registration %s was written before" (Registration_id.to_string id)
  | Identity_registered id ->
    Printf.sprintf "the identity already has the open registration %s" (Registration_id.to_string id)
  | Identity_bound -> "the identity is bound to a principal and signs in as it"
  | Not_registered id -> Printf.sprintf "no registration %s was written" (Registration_id.to_string id)
  | Already_removed id ->
    Printf.sprintf "the registration %s was removed before" (Registration_id.to_string id)
  | Already_consumed id ->
    Printf.sprintf "the registration %s was spent by an admission" (Registration_id.to_string id)
  | Author_is_not_an_admin principal ->
    Printf.sprintf
      "the principal %s is not an Admin, and only an Admin writes the allowlist"
      (Principal.to_string principal)
  | Not_a_registration_author author -> author_label author ^ " does not write the allowlist"
;;

let register t ~is_bound ~registrar ~registration_id ~identity =
  match
    Registration_map.mem registration_id t.by_id, Identity_map.find_opt identity t.open_by_identity
  with
  | true, (None | Some _) -> Error (Already_registered registration_id)
  | false, Some holder -> Error (Identity_registered holder)
  | false, None when is_bound identity -> Error Identity_bound
  | false, None ->
    Ok
      { by_id = Registration_map.add registration_id { identity; registrar; status = Open } t.by_id
      ; open_by_identity = Identity_map.add identity registration_id t.open_by_identity
      }
;;

(* Closes an open registration with [status]. *)
let close t registration_id (registration : registration) status =
  { by_id = Registration_map.add registration_id { registration with status } t.by_id
  ; open_by_identity = Identity_map.remove registration.identity t.open_by_identity
  }
;;

let remove t ~registration_id =
  match find t registration_id with
  | None -> Error (Not_registered registration_id)
  | Some { status = Removed; _ } -> Error (Already_removed registration_id)
  | Some { status = Consumed _; _ } -> Error (Already_consumed registration_id)
  | Some ({ status = Open; _ } as registration) -> Ok (close t registration_id registration Removed)
;;

type consume_refusal =
  | Registration_not_found of Registration_id.t
  | Registration_removed of Registration_id.t
  | Registration_consumed of Registration_id.t
  | Identity_differs of Registration_id.t

let consume_refusal_to_string = function
  | Registration_not_found id ->
    Printf.sprintf
      "the admission names the registration %s, which was never written"
      (Registration_id.to_string id)
  | Registration_removed id ->
    Printf.sprintf "the registration %s was removed" (Registration_id.to_string id)
  | Registration_consumed id ->
    Printf.sprintf "the registration %s was spent by an admission before" (Registration_id.to_string id)
  | Identity_differs id ->
    Printf.sprintf
      "the admission binds another identity than the registration %s"
      (Registration_id.to_string id)
;;

let consume t registration_id ~identity ~user_id =
  match find t registration_id with
  | None -> Error (Registration_not_found registration_id)
  | Some { status = Removed; _ } -> Error (Registration_removed registration_id)
  | Some { status = Consumed _; _ } -> Error (Registration_consumed registration_id)
  | Some ({ status = Open; _ } as registration)
    when not (Authz_external_identity.equal registration.identity identity) ->
    Error (Identity_differs registration_id)
  | Some ({ status = Open; _ } as registration) ->
    Ok (close t registration_id registration (Consumed user_id))
;;

let spend_open t identity ~user_id =
  match find_open t identity with
  | None -> t
  | Some (registration_id, registration) -> close t registration_id registration (Consumed user_id)
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~is_admin ~is_bound (event : E.t) =
  match author, event with
  | Author.Authenticated (Principal.Human id), E.Registered { registration_id; identity }
    when is_admin id -> register t ~is_bound ~registrar:id ~registration_id ~identity
  | Author.Authenticated (Principal.Human id), E.Removed { registration_id } when is_admin id ->
    remove t ~registration_id
  | ( Author.Authenticated ((Principal.Human _ | Principal.Service _) as principal)
    , (E.Registered _ | E.Removed _) ) -> Error (Author_is_not_an_admin principal)
  | ( (Author.Local_operator | Author.System_cron | Author.System_maintenance | Author.System_migration)
    , (E.Registered _ | E.Removed _) ) -> Error (Not_a_registration_author author)
;;
