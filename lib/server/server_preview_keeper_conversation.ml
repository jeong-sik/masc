(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Login = Server_setup_account_login
module Conversation = Server_keeper_conversation
module Turn = Server_preview_keeper_turn
module E = Server_preview_keeper_error
module Purge = Server_keeper_conversation_purge

let ( let* ) = Result.bind
let ms_per_second = 1000.
let start_shape = {|The body is {"keeper_id": "<name>"}.|}
let read_shape = "The query is keeper_id=<name>, and conversation_id=<id> to read an earlier one."
let delete_shape = "The path ends in the id of the conversation."
let id_json id = `String (Conversation.Conversation_id.to_string id)

(* The body of a new conversation: exactly the one named field. *)
let start_request_of body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error (E.Invalid_request start_shape)
  | `Assoc [ ("keeper_id", `String name) ] -> Ok name
  | _ -> Error (E.Invalid_request start_shape)
;;

let start ~env ~(person : Login.person) ~base_path ~body =
  let answer =
    let* name = start_request_of body in
    let* keeper_id = Turn.keeper_id_of name in
    let* (_ : Authz_types.Runtime_id.t), provider_account_id = Turn.assigned person keeper_id in
    let clock = Eio.Stdenv.clock env in
    let* conversation =
      Conversation.start
        (Conversation.root ~base_path ~namespace:person.namespace)
        keeper_id
        provider_account_id
        ~deleted:(Purge.deletion_began person)
        ~draw:Auth.generate_token
        ~now_ms:(fun () -> Int.of_float (Eio.Time.now clock *. ms_per_second))
        ~one_call_of:Login.one_call_of
      |> Result.map_error (function
        | Conversation.Account_busy -> E.Account_call_running E.Conversation_account
        | Conversation.Record_failed failure -> Turn.record_error ~keeper_id failure)
    in
    Ok
      (R.json
         R.Ok_200
         [ "keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)
         ; "conversation_id", id_json conversation.Conversation.conversation_id
         ])
  in
  Result.fold ~ok:Fun.id ~error:E.answer answer
;;

(* The query of a read: the Keeper once, and a conversation at most once.
   Another name, or a name twice, is not read around. *)
let read_request_of query =
  let refused = Error (E.Invalid_request read_shape) in
  match List.sort (fun (left, (_ : string)) (right, (_ : string)) -> String.compare left right) query with
  | [ ("keeper_id", name) ] -> Ok (name, None)
  | [ ("conversation_id", id); ("keeper_id", name) ] ->
    (match Conversation.Conversation_id.of_string id with
     | Ok id -> Ok (name, Some id)
     | Error (_ : Authz_id.error) -> refused)
  | _ -> refused
;;

let turn_json (turn : Conversation.recorded) =
  `Assoc
    ([ "message", `String turn.message; "asked_at_ms", `Int turn.asked_at_ms ]
     @
     match turn.outcome with
     | Conversation.Answered { text; model; at_ms; session_id = (_ : string) } ->
       (* The session is an id of the vendor that the record keeps to resume
          it. The person has no use for it. *)
       [ "outcome", `String "answered"
       ; "text", `String text
       ; "model", `String model
       ; "answered_at_ms", `Int at_ms
       ]
     | Conversation.Failed { failure; at_ms } ->
       [ "outcome", `String "failed"
       ; "failure", `String (Conversation.failure_to_string failure)
       ; "failed_at_ms", `Int at_ms
       ; "model_may_have_read", `Bool (Conversation.reached_client failure)
       ]
     | Conversation.Unrecorded ->
       (* The [asked] row is written before the client starts, and nothing
          says how far the turn went. *)
       [ "outcome", `String "unrecorded"; "model_may_have_read", `Bool true ])
;;

let read ~(person : Login.person) ~base_path ~query =
  let answer =
    let* name, asked_for = read_request_of query in
    let* keeper_id = Turn.keeper_id_of name in
    let* (_ : Authz_types.Runtime_id.t option) = Turn.owned person keeper_id in
    let records = Conversation.root ~base_path ~namespace:person.namespace in
    let recorded result = Result.map_error (Turn.record_error ~keeper_id) result in
    let* listed = Conversation.conversations records keeper_id |> recorded in
    (* The judgment of the deletions and the read of the turns come between
       two removals of a directory, so a read does not bring back one a
       deletion removed. *)
    Conversation.reading @@ fun () ->
    let standing (listed : Conversation.listed) =
      Purge.standing person listed.conversation.conversation_id
    in
    (* The current conversation is judged on all the conversations, so a
       deleted last one leaves none current and no earlier one comes back. *)
    let current = Conversation.current ~deleted:(Purge.deletion_began person) listed in
    let* shown =
      match asked_for with
      | None -> Ok current
      | Some id ->
        (match
           List.find_opt
             (fun (listed : Conversation.listed) ->
                Conversation.Conversation_id.equal listed.conversation.conversation_id id)
             listed
         with
         | Some ({ Conversation.conversation; started_at_ms = (_ : int) } as found) ->
           (match standing found with
            | Purge.Kept -> Ok (Some conversation)
            | Purge.Deletion_failed | Purge.Deleted -> Error (E.Unknown_conversation E.Of_keeper))
         | None -> Error (E.Unknown_conversation E.Of_keeper))
    in
    let* turns =
      match shown with
      | None -> Ok []
      | Some conversation -> Conversation.turns records conversation |> recorded
    in
    let id_or_null = function
      | Some (conversation : Conversation.conversation) -> id_json conversation.conversation_id
      | None -> `Null
    in
    Ok
      (R.json
         R.Ok_200
         [ "keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)
         ; "current_conversation_id", id_or_null current
         ; ( "conversations"
           , `List
               (List.filter_map
                  (fun (listed : Conversation.listed) ->
                     let fields =
                       [ "conversation_id", id_json listed.conversation.conversation_id
                       ; ( "provider_account_id"
                         , `String
                             (Authz_types.Provider_account_id.to_string
                                listed.conversation.provider_account_id) )
                       ; "started_at_ms", `Int listed.started_at_ms
                       ]
                     in
                     match standing listed with
                     | Purge.Kept -> Some (`Assoc fields)
                     | Purge.Deletion_failed -> Some (`Assoc (fields @ [ "deletion", `String "failed" ]))
                     | Purge.Deleted -> None)
                  listed) )
         ; "conversation_id", id_or_null shown
         ; "turns", `List (List.map turn_json turns)
         ])
  in
  Result.fold ~ok:Fun.id ~error:E.answer answer
;;

(* The details of each failure are in the log ({!Purge.delete}). *)
let deletion_error : Purge.error -> E.t = function
  | Purge.Not_found -> E.Unknown_conversation E.Of_person
  | Purge.Account_busy -> E.Account_call_running E.Deleted_conversation_account
  | Purge.Record_unavailable error -> E.of_record_error error
  | Purge.Not_started (Authz_purge.Refused (Authz_purge_state.User_not_active _)) -> E.Deletion_refused
  | Purge.Not_started (Authz_purge.Commit_failed (_ : Authz_zone.error)) ->
    E.Server_unavailable "The deletion could not be recorded, and nothing was deleted."
  | Purge.Not_started
      ( Authz_purge.Body_not_built (_ : Authz_body.error)
      | Authz_purge.Refused
          ( Authz_purge_state.Not_the_owner _
          | Authz_purge_state.Already_pending _
          | Authz_purge_state.Already_purged _
          | Authz_purge_state.Not_started _
          | Authz_purge_state.Not_a_human _
          | Authz_purge_state.Ended_by_a_principal _
          | Authz_purge_state.Started_by_the_maintenance _
          | Authz_purge_state.Not_a_purge_author _ ) ) ->
    (* The person starts the deletion of a conversation of their own, as a
       person, after the status of the conversation was read inside the call
       of its account, which keeps a second deletion of it out. The body is
       two ids. *)
    E.Internal "The deletion was refused for a reason this preview does not expect."
  | Purge.Not_ended (_ : Authz_purge.error) ->
    E.Server_unavailable "The end of the deletion could not be recorded. Ask again to finish it."
  | Purge.Directory_not_removed (_ : Authz_purge_event.vendor_copy) -> E.Conversation_not_deleted
;;

let delete ~env ~(person : Login.person) ~base_path ~conversation_id =
  let answer =
    let* id =
      Conversation.Conversation_id.of_string conversation_id
      |> Result.map_error (fun (_ : Authz_id.error) -> E.Invalid_request delete_shape)
    in
    Purge.delete ~env ~person ~base_path id
    |> Result.map (fun vendor_copy ->
      R.json
        R.Ok_200
        [ "conversation_id", id_json id
        ; "vendor_copy", `String (Authz_purge_event.vendor_copy_label vendor_copy)
        ])
    |> Result.map_error deletion_error
  in
  Result.fold ~ok:Fun.id ~error:E.answer answer
;;
