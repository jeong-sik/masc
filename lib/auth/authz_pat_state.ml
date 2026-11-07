(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_pat_event
module Pat_map = Map.Make (Pat_id)

type status =
  | Open
  | Revoked

type pat =
  { user_id : User_id.t
  ; secret_digest : Authz_credential_token.Pat.Digest.t
  ; scope : Authorization_scope.t
  ; expires_at_ms : int option
  ; issued_at_ms : int
  ; status : status
  }

type t = pat Pat_map.t

let empty = Pat_map.empty
let find t pat_id = Pat_map.find_opt pat_id t

type inactive =
  | Unknown
  | Ended
  | Expired

let find_active t pat_id ~now_ms =
  match find t pat_id with
  | None -> Error Unknown
  | Some { status = Revoked; _ } -> Error Ended
  | Some ({ status = Open; expires_at_ms = Some expires_at_ms; _ } as pat) ->
    if now_ms >= expires_at_ms then Error Expired else Ok pat
  | Some ({ status = Open; expires_at_ms = None; _ } as pat) -> Ok pat
;;

type refusal =
  | Already_issued of Pat_id.t
  | Issued_for_another of
      { author : User_id.t
      ; user_id : User_id.t
      }
  | User_not_active of User_id.t
  | Not_issued of Pat_id.t
  | Already_revoked of Pat_id.t
  | Not_the_owner of
      { pat_id : Pat_id.t
      ; author : User_id.t
      }
  | Not_a_human of Principal.t
  | Not_a_pat_author of Author.t

let author_label : Author.t -> string = function
  | Author.Authenticated principal -> "the principal " ^ Principal.to_string principal
  | Author.Local_operator -> "the local operator"
  | Author.System_cron -> "the system cron"
  | Author.System_maintenance -> "the system maintenance"
  | Author.System_migration -> "the system migration"
;;

let refusal_to_string = function
  | Already_issued id -> Printf.sprintf "the PAT %s was issued before" (Pat_id.to_string id)
  | Issued_for_another { author; user_id } ->
    Printf.sprintf
      "%s issues a PAT for %s, and a principal issues a PAT only for themselves"
      (User_id.to_string author)
      (User_id.to_string user_id)
  | User_not_active id ->
    Printf.sprintf "the principal %s is not active and issues no PAT" (User_id.to_string id)
  | Not_issued id -> Printf.sprintf "no PAT %s was issued" (Pat_id.to_string id)
  | Already_revoked id -> Printf.sprintf "the PAT %s was revoked before" (Pat_id.to_string id)
  | Not_the_owner { pat_id; author } ->
    Printf.sprintf
      "%s revokes the PAT %s of another principal"
      (User_id.to_string author)
      (Pat_id.to_string pat_id)
  | Not_a_human principal ->
    Printf.sprintf "the principal %s is a service and has no PAT" (Principal.to_string principal)
  | Not_a_pat_author author -> author_label author ^ " writes no PAT"
;;

let issue t ~author ~at_ms ~is_active ~pat_id ~user_id ~secret_digest ~scope ~expires_at_ms =
  if Pat_map.mem pat_id t
  then Error (Already_issued pat_id)
  else if not (User_id.equal author user_id)
  then Error (Issued_for_another { author; user_id })
  else if not (is_active user_id)
  then Error (User_not_active user_id)
  else
    Ok
      (Pat_map.add
         pat_id
         { user_id; secret_digest; scope; expires_at_ms; issued_at_ms = at_ms; status = Open }
         t)
;;

let revoke t ~author ~pat_id =
  match find t pat_id with
  | None -> Error (Not_issued pat_id)
  | Some { status = Revoked; _ } -> Error (Already_revoked pat_id)
  | Some ({ status = Open; user_id; _ } as pat) ->
    if User_id.equal user_id author
    then Ok (Pat_map.add pat_id { pat with status = Revoked } t)
    else Error (Not_the_owner { pat_id; author })
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~at_ms ~is_active (event : E.t) =
  match author, event with
  | ( Author.Authenticated (Principal.Human id)
    , E.Issued { pat_id; user_id; secret_digest; scope; expires_at_ms } ) ->
    issue t ~author:id ~at_ms ~is_active ~pat_id ~user_id ~secret_digest ~scope ~expires_at_ms
  | Author.Authenticated (Principal.Human id), E.Revoked { pat_id } -> revoke t ~author:id ~pat_id
  | Author.Authenticated (Principal.Service _ as principal), (E.Issued _ | E.Revoked _) ->
    Error (Not_a_human principal)
  | ( (Author.Local_operator | Author.System_cron | Author.System_maintenance | Author.System_migration)
    , (E.Issued _ | E.Revoked _) ) -> Error (Not_a_pat_author author)
;;
