(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
open Authz_records

let ( let* ) = Result.bind

type t =
  { aborted : Authz_record.Hash.t
  ; subject : Subject.t
  }

let equal a b = Authz_record.Hash.equal a.aborted b.aborted && Subject.equal a.subject b.subject

(* The labels are those of [Authz_external_store.subject_text] and
   [Authz_record.principal_text]; [test_authz_cancel_event] checks that the two
   write the same bytes for every subject. *)
let id_object label id =
  let* label = Authz_body.string label in
  let* id = Authz_body.string id in
  Authz_body.object_ [ "type", label; "id", id ]
;;

let principal_body = function
  | Principal.Human id -> id_object "human" (User_id.to_string id)
  | Principal.Service id -> id_object "service" (Service_id.to_string id)
;;

let subject_body = function
  | Subject.Grant id -> id_object "grant" (Grant_id.to_string id)
  | Subject.Credential id -> id_object "credential" (Provider_account_id.to_string id)
  | Subject.Principal principal ->
    let* label = Authz_body.string "principal" in
    let* principal = principal_body principal in
    Authz_body.object_ [ "type", label; "principal", principal ]
  | Subject.Runtime id -> id_object "runtime" (Runtime_id.to_string id)
  | Subject.Session id -> id_object "session" (Session_id.to_string id)
  | Subject.Pat id -> id_object "pat" (Pat_id.to_string id)
  | Subject.Service_credential id ->
    id_object "service_credential" (Service_credential_id.to_string id)
  | Subject.Invite id -> id_object "invite" (Invite_id.to_string id)
  | Subject.Registration id -> id_object "registration" (Registration_id.to_string id)
  | Subject.Keeper_conversation { owner; conversation_id } ->
    let* label = Authz_body.string "keeper_conversation" in
    let* owner = Authz_body.string (User_id.to_string owner) in
    let* conversation_id = Authz_body.string (Conversation_id.to_string conversation_id) in
    Authz_body.object_ [ "type", label; "owner", owner; "conversation_id", conversation_id ]
;;

let to_body { aborted; subject } =
  let* aborted = Authz_body.string (Authz_record.Hash.to_hex aborted) in
  let* subject = subject_body subject in
  Authz_body.object_ [ "aborted", aborted; "subject", subject ]
;;

type error =
  | Not_an_object
  | Wrong_members
  | Invalid_aborted
  | Invalid_subject

let error_to_string = function
  | Not_an_object -> "the body of a revocation cancel is an object"
  | Wrong_members ->
    "a revocation cancel has the members aborted, a string, and subject, an object, in this order"
  | Invalid_aborted -> "the aborted digest is not 64 lowercase hex characters"
  | Invalid_subject -> "the subject is not one of the shapes of a subject"
;;

(* The label of [type] and the members after it. A wildcard below covers the
   members or the labels, never a constructor of a body, so a constructor
   added to [Authz_body.t] stops the compiler here. *)
let typed (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("type", label) :: members) ->
    Option.map (fun label -> label, members) (Authz_body.string_value label)
  | Authz_body.Object _
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> None
;;

let id_of of_string make = function
  | [ ("id", id) ] ->
    Option.bind (Authz_body.string_value id) (fun id -> Option.map make (Result.to_option (of_string id)))
  | _ -> None
;;

let principal_of_body body =
  match typed body with
  | Some ("human", members) -> id_of User_id.of_string (fun id -> Principal.Human id) members
  | Some ("service", members) -> id_of Service_id.of_string (fun id -> Principal.Service id) members
  | Some _ | None -> None
;;

let keeper_conversation_of = function
  | [ ("owner", owner); ("conversation_id", conversation_id) ] ->
    (match Authz_body.string_value owner, Authz_body.string_value conversation_id with
     | Some owner, Some conversation_id ->
       (match User_id.of_string owner, Conversation_id.of_string conversation_id with
        | Ok owner, Ok conversation_id -> Some (Subject.Keeper_conversation { owner; conversation_id })
        | Error (_ : Authz_id.error), (Ok (_ : Conversation_id.t) | Error (_ : Authz_id.error))
        | Ok (_ : User_id.t), Error (_ : Authz_id.error) -> None)
     | None, (None | Some _) | Some _, None -> None)
  | _ -> None
;;

let subject_of_body body =
  match typed body with
  | Some ("grant", members) -> id_of Grant_id.of_string (fun id -> Subject.Grant id) members
  | Some ("credential", members) ->
    id_of Provider_account_id.of_string (fun id -> Subject.Credential id) members
  | Some ("principal", [ ("principal", principal) ]) ->
    Option.map (fun principal -> Subject.Principal principal) (principal_of_body principal)
  | Some ("runtime", members) -> id_of Runtime_id.of_string (fun id -> Subject.Runtime id) members
  | Some ("session", members) -> id_of Session_id.of_string (fun id -> Subject.Session id) members
  | Some ("pat", members) -> id_of Pat_id.of_string (fun id -> Subject.Pat id) members
  | Some ("service_credential", members) ->
    id_of Service_credential_id.of_string (fun id -> Subject.Service_credential id) members
  | Some ("invite", members) -> id_of Invite_id.of_string (fun id -> Subject.Invite id) members
  | Some ("registration", members) ->
    id_of Registration_id.of_string (fun id -> Subject.Registration id) members
  | Some ("keeper_conversation", members) -> keeper_conversation_of members
  | Some _ | None -> None
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object [ ("aborted", aborted); ("subject", subject) ] ->
    (match Authz_body.string_value aborted, subject with
     | Some hex, Authz_body.Object _ ->
       (match Authz_record.Hash.of_hex hex, subject_of_body subject with
        | None, (None | Some _) -> Error Invalid_aborted
        | Some _, None -> Error Invalid_subject
        | Some aborted, Some subject -> Ok { aborted; subject })
     | ( None
       , ( Authz_body.Null
         | Authz_body.Bool _
         | Authz_body.Int _
         | Authz_body.String _
         | Authz_body.List _
         | Authz_body.Object _ ) )
     | ( Some _
       , (Authz_body.Null | Authz_body.Bool _ | Authz_body.Int _ | Authz_body.String _ | Authz_body.List _) ) ->
       Error Wrong_members)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
