(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records
module E = Authz_session_event
module Session_map = Map.Make (Session_id)

(* A week bounds how long a stolen cookie works, and a person who uses the
   Dashboard every day signs in once a week. *)
let lifetime_ms = 7 * 24 * 60 * 60 * 1000

type status =
  | Open
  | Revoked
  | Replaced of Session_id.t

type session =
  { user_id : User_id.t
  ; secret_digest : E.Secret_digest.t
  ; issued_at_ms : int
  ; status : status
  }

type t = session Session_map.t

let empty = Session_map.empty
let find t session_id = Session_map.find_opt session_id t

type inactive =
  | Unknown
  | Ended
  | Expired

let find_active t session_id ~now_ms =
  match find t session_id with
  | None -> Error Unknown
  | Some { status = Revoked | Replaced _; _ } -> Error Ended
  | Some ({ status = Open; issued_at_ms; _ } as session) ->
    if now_ms - issued_at_ms >= lifetime_ms then Error Expired else Ok session
;;

type refusal =
  | Already_issued of Session_id.t
  | Issued_for_another of
      { author : User_id.t
      ; user_id : User_id.t
      }
  | User_not_active of User_id.t
  | Not_issued of Session_id.t
  | Already_ended of Session_id.t
  | Not_the_owner of
      { session_id : Session_id.t
      ; author : User_id.t
      }
  | Not_a_human of Principal.t
  | Not_a_session_author of Author.t

let author_label : Author.t -> string = function
  | Author.Authenticated principal -> "the principal " ^ Principal.to_string principal
  | Author.Local_operator -> "the local operator"
  | Author.System_cron -> "the system cron"
  | Author.System_maintenance -> "the system maintenance"
  | Author.System_migration -> "the system migration"
;;

let refusal_to_string = function
  | Already_issued id -> Printf.sprintf "the session %s was issued before" (Session_id.to_string id)
  | Issued_for_another { author; user_id } ->
    Printf.sprintf
      "%s issues a session for %s, and a principal issues a session only for themselves"
      (User_id.to_string author)
      (User_id.to_string user_id)
  | User_not_active id ->
    Printf.sprintf "the principal %s is not active and signs in to no session" (User_id.to_string id)
  | Not_issued id -> Printf.sprintf "no session %s was issued" (Session_id.to_string id)
  | Already_ended id ->
    Printf.sprintf "the session %s was revoked or replaced before" (Session_id.to_string id)
  | Not_the_owner { session_id; author } ->
    Printf.sprintf
      "%s revokes the session %s of another principal"
      (User_id.to_string author)
      (Session_id.to_string session_id)
  | Not_a_human principal ->
    Printf.sprintf "the principal %s is a service and has no browser session" (Principal.to_string principal)
  | Not_a_session_author author -> author_label author ^ " writes no browser session"
;;

(* Ends an open session with [status]. *)
let close t session_id (session : session) status =
  Session_map.add session_id { session with status } t
;;

(* The session that an issue ends, if it names one. *)
let ended_by_issue t ~session_id = function
  | None -> Ok t
  | Some replaced ->
    (match find t replaced with
     | None -> Error (Not_issued replaced)
     | Some { status = Revoked | Replaced _; _ } -> Error (Already_ended replaced)
     | Some ({ status = Open; _ } as session) -> Ok (close t replaced session (Replaced session_id)))
;;

let issue t ~author ~at_ms ~is_active ~session_id ~user_id ~secret_digest ~replaces =
  if Session_map.mem session_id t
  then Error (Already_issued session_id)
  else if not (User_id.equal author user_id)
  then Error (Issued_for_another { author; user_id })
  else if not (is_active user_id)
  then Error (User_not_active user_id)
  else
    Result.map
      (fun t ->
        Session_map.add session_id { user_id; secret_digest; issued_at_ms = at_ms; status = Open } t)
      (ended_by_issue t ~session_id replaces)
;;

let revoke t ~author ~session_id =
  match find t session_id with
  | None -> Error (Not_issued session_id)
  | Some { status = Revoked | Replaced _; _ } -> Error (Already_ended session_id)
  | Some ({ status = Open; user_id; _ } as session) ->
    if User_id.equal user_id author
    then Ok (close t session_id session Revoked)
    else Error (Not_the_owner { session_id; author })
;;

(* The author is matched before the event, so a branch says what each author
   may write. *)
let apply t ~(author : Author.t) ~at_ms ~is_active (event : E.t) =
  match author, event with
  | ( Author.Authenticated (Principal.Human id)
    , E.Issued { session_id; user_id; secret_digest; replaces } ) ->
    issue t ~author:id ~at_ms ~is_active ~session_id ~user_id ~secret_digest ~replaces
  | Author.Authenticated (Principal.Human id), E.Revoked { session_id } ->
    revoke t ~author:id ~session_id
  | Author.Authenticated (Principal.Service _ as principal), (E.Issued _ | E.Revoked _) ->
    Error (Not_a_human principal)
  | ( (Author.Local_operator | Author.System_cron | Author.System_maintenance | Author.System_migration)
    , (E.Issued _ | E.Revoked _) ) -> Error (Not_a_session_author author)
;;
