(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Login = Server_setup_account_login
module Conversation = Server_keeper_conversation
module Turn = Server_preview_keeper_turn

let ( let* ) = Result.bind
let ms_per_second = 1000.
let error status text = R.json status [ "error", `String text ]
let start_shape = {|The body is {"keeper_id": "<name>"}.|}
let read_shape = "The query is keeper_id=<name>, and conversation_id=<id> to read an earlier one."
let unknown_conversation = "No conversation of this Keeper has this id."
let id_json id = `String (Conversation.Conversation_id.to_string id)

(* The body of a new conversation: exactly the one named field. *)
let start_request_of body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> Error (error R.Bad_request_400 start_shape)
  | `Assoc [ ("keeper_id", `String name) ] -> Ok name
  | _ -> Error (error R.Bad_request_400 start_shape)
;;

let start ~env ~(person : Login.person) ~base_path ~body =
  let answer =
    let* name = start_request_of body in
    let* keeper_id = Auth_preview_keeper.keeper_id_of name in
    let* (_ : Authz_types.Runtime_id.t), provider_account_id = Turn.assigned person keeper_id in
    let clock = Eio.Stdenv.clock env in
    let* conversation =
      Conversation.start
        (Conversation.root ~base_path ~namespace:person.namespace)
        keeper_id
        provider_account_id
        ~draw:Auth.generate_token
        ~now_ms:(fun () -> Int.of_float (Eio.Time.now clock *. ms_per_second))
      |> Result.map_error (Turn.record_answer ~keeper_id)
    in
    Ok
      (R.json
         R.Ok_200
         [ "keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)
         ; "conversation_id", id_json conversation.Conversation.conversation_id
         ])
  in
  Result.fold ~ok:Fun.id ~error:Fun.id answer
;;

(* The query of a read: the Keeper once, and a conversation at most once.
   Another name, or a name twice, is not read around. *)
let read_request_of query =
  let refused = Error (error R.Bad_request_400 read_shape) in
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
    let* keeper_id = Auth_preview_keeper.keeper_id_of name in
    let* (_ : Authz_types.Runtime_id.t option) = Turn.owned person keeper_id in
    let records = Conversation.root ~base_path ~namespace:person.namespace in
    let recorded result = Result.map_error (Turn.record_answer ~keeper_id) result in
    let* listed = Conversation.conversations records keeper_id |> recorded in
    let current =
      List.fold_left
        (fun (_ : Conversation.conversation option) (listed : Conversation.listed) ->
           Some listed.conversation)
        None
        listed
    in
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
         | Some { Conversation.conversation; started_at_ms = (_ : int) } -> Ok (Some conversation)
         | None -> Error (error R.Not_found_404 unknown_conversation))
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
               (List.map
                  (fun (listed : Conversation.listed) ->
                     `Assoc
                       [ "conversation_id", id_json listed.conversation.conversation_id
                       ; ( "provider_account_id"
                         , `String
                             (Authz_types.Provider_account_id.to_string
                                listed.conversation.provider_account_id) )
                       ; "started_at_ms", `Int listed.started_at_ms
                       ])
                  listed) )
         ; "conversation_id", id_or_null shown
         ; "turns", `List (List.map turn_json turns)
         ])
  in
  Result.fold ~ok:Fun.id ~error:Fun.id answer
;;
