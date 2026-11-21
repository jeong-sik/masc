(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types

let ( let* ) = Result.bind

type t =
  | Inventory_frozen of
      { bootstrap_invite_id : Invite_id.t
      ; cutover_at_ms : int
      ; legacy_keepers : Engine_name.t list
      ; legacy_task_ids : string list
      ; legacy_manifest_sha256 : Authz_record.Hash.t
      }
  | Candidate_bound of
      { user_id : User_id.t
      ; invite_id : Invite_id.t
      }
  | Keeper_claimed of
      { engine_name : Engine_name.t
      ; claimant : User_id.t
      ; keeper_id : Keeper_id.t
      ; runtime_id : Runtime_id.t
      ; policy_id : Policy_id.t
      ; turn_scope : Authorization_scope.t
      }
  | Keeper_retired of
      { engine_name : Engine_name.t
      ; actor : User_id.t
      }

let inventory_label = "inventory_frozen"
let candidate_label = "candidate_bound"
let claimed_label = "keeper_claimed"
let retired_label = "keeper_retired"

let label = function
  | Inventory_frozen _ -> inventory_label
  | Candidate_bound _ -> candidate_label
  | Keeper_claimed _ -> claimed_label
  | Keeper_retired _ -> retired_label
;;

(* One inventory has one body: the lists are written in the order of their
   bytes and without a repeat, whatever order the walk that found them gave. *)
let canonical labels = List.sort_uniq String.compare labels

let ascending labels =
  let rec go = function
    | first :: (second :: _ as rest) -> String.compare first second < 0 && go rest
    | [] | [ _ ] -> true
  in
  go labels
;;

let rec all_ok f = function
  | [] -> Ok []
  | value :: rest ->
    let* value = f value in
    let* rest = all_ok f rest in
    Ok (value :: rest)
;;

let string_list labels =
  let rec go acc = function
    | [] -> Ok (Authz_body.list (List.rev acc))
    | label :: rest ->
      let* value = Authz_body.string label in
      go (value :: acc) rest
  in
  go [] labels
;;

(* The labels of a list member, or [Error ()] when it is not a list of strings.
   The caller answers [Wrong_members] for that: a list of another type is the
   same refusal as a member of another name or order. *)
let labels_of_body = function
  | Authz_body.List values ->
    let rec go acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        (match Authz_body.string_value value with
         | Some label -> go (label :: acc) rest
         | None -> Error ())
    in
    go [] values
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.Object _ -> Error ()
;;

type error =
  | Not_an_object
  | Unknown_event of string
  | Wrong_members
  | Not_ascending of string
  | Invalid_invite_id of Authz_id.error
  | Invalid_user_id of Authz_id.error
  | Invalid_engine_name of Authz_id.error
  | Invalid_keeper_id of Authz_id.error
  | Invalid_runtime_id of Authz_id.error
  | Invalid_policy_id of Authz_id.error
  | Invalid_manifest_hash
  | Invalid_scope of Authz_scope_body.error

let error_to_string = function
  | Not_an_object -> "the body of a legacy attribution record is an object"
  | Unknown_event label ->
    Printf.sprintf "%S is not an event of a legacy attribution" label
  | Wrong_members ->
    "the body of a legacy attribution record has the members of its event, in the \
     order of the interface, the ids and the labels strings and the cutover a number"
  | Not_ascending member ->
    Printf.sprintf "the list %S is not in strictly ascending byte order" member
  | Invalid_invite_id error ->
    Printf.sprintf "the invite id is not valid: %s" (Authz_id.error_to_string error)
  | Invalid_user_id error ->
    Printf.sprintf "the user id is not valid: %s" (Authz_id.error_to_string error)
  | Invalid_engine_name error ->
    Printf.sprintf "the engine name is not valid: %s" (Authz_id.error_to_string error)
  | Invalid_keeper_id error ->
    Printf.sprintf "the keeper id is not valid: %s" (Authz_id.error_to_string error)
  | Invalid_runtime_id error ->
    Printf.sprintf "the runtime id is not valid: %s" (Authz_id.error_to_string error)
  | Invalid_policy_id error ->
    Printf.sprintf "the policy id is not valid: %s" (Authz_id.error_to_string error)
  | Invalid_manifest_hash -> "the manifest hash is not 64 lowercase hex characters"
  | Invalid_scope error ->
    Printf.sprintf "the turn scope is not valid: %s" (Authz_scope_body.error_to_string error)
;;

let invite_id_of text = Result.map_error (fun error -> Invalid_invite_id error) (Invite_id.of_string text)
let user_id_of text = Result.map_error (fun error -> Invalid_user_id error) (User_id.of_string text)
let engine_name_of text = Result.map_error (fun error -> Invalid_engine_name error) (Engine_name.of_string text)
let keeper_id_of text = Result.map_error (fun error -> Invalid_keeper_id error) (Keeper_id.of_string text)
let runtime_id_of text = Result.map_error (fun error -> Invalid_runtime_id error) (Runtime_id.of_string text)
let policy_id_of text = Result.map_error (fun error -> Invalid_policy_id error) (Policy_id.of_string text)

let to_body = function
  | Inventory_frozen
      { bootstrap_invite_id
      ; cutover_at_ms
      ; legacy_keepers
      ; legacy_task_ids
      ; legacy_manifest_sha256
      } ->
    let* event = Authz_body.string inventory_label in
    let* bootstrap_invite_id = Authz_body.string (Invite_id.to_string bootstrap_invite_id) in
    let* cutover_at_ms = Authz_body.int cutover_at_ms in
    let* legacy_keepers = string_list (canonical (List.map Engine_name.to_string legacy_keepers)) in
    let* legacy_task_ids = string_list (canonical legacy_task_ids) in
    let* legacy_manifest_sha256 =
      Authz_body.string (Authz_record.Hash.to_hex legacy_manifest_sha256)
    in
    Authz_body.object_
      [ "event", event
      ; "bootstrap_invite_id", bootstrap_invite_id
      ; "cutover_at_ms", cutover_at_ms
      ; "legacy_keepers", legacy_keepers
      ; "legacy_task_ids", legacy_task_ids
      ; "legacy_manifest_sha256", legacy_manifest_sha256
      ]
  | Candidate_bound { user_id; invite_id } ->
    let* event = Authz_body.string candidate_label in
    let* user_id = Authz_body.string (User_id.to_string user_id) in
    let* invite_id = Authz_body.string (Invite_id.to_string invite_id) in
    Authz_body.object_ [ "event", event; "user_id", user_id; "invite_id", invite_id ]
  | Keeper_claimed
      { engine_name; claimant; keeper_id; runtime_id; policy_id; turn_scope } ->
    let* event = Authz_body.string claimed_label in
    let* engine_name = Authz_body.string (Engine_name.to_string engine_name) in
    let* claimant = Authz_body.string (User_id.to_string claimant) in
    let* keeper_id = Authz_body.string (Keeper_id.to_string keeper_id) in
    let* runtime_id = Authz_body.string (Runtime_id.to_string runtime_id) in
    let* policy_id = Authz_body.string (Policy_id.to_string policy_id) in
    let* turn_scope = Authz_scope_body.to_body turn_scope in
    Authz_body.object_
      [ "event", event
      ; "engine_name", engine_name
      ; "claimant", claimant
      ; "keeper_id", keeper_id
      ; "runtime_id", runtime_id
      ; "policy_id", policy_id
      ; "turn_scope", turn_scope
      ]
  | Keeper_retired { engine_name; actor } ->
    let* event = Authz_body.string retired_label in
    let* engine_name = Authz_body.string (Engine_name.to_string engine_name) in
    let* actor = Authz_body.string (User_id.to_string actor) in
    Authz_body.object_ [ "event", event; "engine_name", engine_name; "actor", actor ]
;;

(* Structural, so a value equals itself even when its bytes cannot be written
   (an unvalidated task id, a cutover outside the wire range). Comparing bodies
   instead made [equal v v] false for those values. *)
let equal left right =
  match left, right with
  | Inventory_frozen left, Inventory_frozen right ->
    Invite_id.equal left.bootstrap_invite_id right.bootstrap_invite_id
    && Int.equal left.cutover_at_ms right.cutover_at_ms
    && List.equal Engine_name.equal left.legacy_keepers right.legacy_keepers
    && List.equal String.equal left.legacy_task_ids right.legacy_task_ids
    && Authz_record.Hash.equal left.legacy_manifest_sha256 right.legacy_manifest_sha256
  | Candidate_bound left, Candidate_bound right ->
    User_id.equal left.user_id right.user_id && Invite_id.equal left.invite_id right.invite_id
  | Keeper_claimed left, Keeper_claimed right ->
    Engine_name.equal left.engine_name right.engine_name
    && User_id.equal left.claimant right.claimant
    && Keeper_id.equal left.keeper_id right.keeper_id
    && Runtime_id.equal left.runtime_id right.runtime_id
    && Policy_id.equal left.policy_id right.policy_id
    && Authorization_scope.equal left.turn_scope right.turn_scope
  | Keeper_retired left, Keeper_retired right ->
    Engine_name.equal left.engine_name right.engine_name && User_id.equal left.actor right.actor
  | Inventory_frozen _, _
  | Candidate_bound _, _
  | Keeper_claimed _, _
  | Keeper_retired _, _ -> false
;;

let lists = function
  | Ok keeper_names, Ok task_ids ->
    (match ascending keeper_names, ascending task_ids with
     | true, true -> Ok (keeper_names, task_ids)
     | false, _ -> Error (Not_ascending "legacy_keepers")
     | _, false -> Error (Not_ascending "legacy_task_ids"))
  | Error (), _ | _, Error () -> Error Wrong_members
;;

let inventory_of = function
  | [ ( "bootstrap_invite_id", bootstrap_invite_id )
    ; ( "cutover_at_ms", cutover_at_ms )
    ; ( "legacy_keepers", legacy_keepers )
    ; ( "legacy_task_ids", legacy_task_ids )
    ; ( "legacy_manifest_sha256", legacy_manifest_sha256 )
    ] ->
    (match
       ( Authz_body.string_value bootstrap_invite_id
       , Authz_body.int_value cutover_at_ms
       , Authz_body.string_value legacy_manifest_sha256 )
     with
     | Some bootstrap_invite_id, Some cutover_at_ms, Some legacy_manifest_sha256 ->
       (match lists (labels_of_body legacy_keepers, labels_of_body legacy_task_ids) with
        | Error error -> Error error
        | Ok (keeper_names, legacy_task_ids) ->
          let* bootstrap_invite_id = invite_id_of bootstrap_invite_id in
          let* legacy_keepers = all_ok engine_name_of keeper_names in
          (match Authz_record.Hash.of_hex legacy_manifest_sha256 with
           | Some legacy_manifest_sha256 ->
             Ok
               (Inventory_frozen
                  { bootstrap_invite_id
                  ; cutover_at_ms
                  ; legacy_keepers
                  ; legacy_task_ids
                  ; legacy_manifest_sha256
                  })
           | None -> Error Invalid_manifest_hash))
     | (None | Some _), (None | Some _), (None | Some _) -> Error Wrong_members)
  | _ -> Error Wrong_members
;;

let candidate_of = function
  | [ ("user_id", user_id); ("invite_id", invite_id) ] ->
    (match Authz_body.string_value user_id, Authz_body.string_value invite_id with
     | Some user_id, Some invite_id ->
       let* user_id = user_id_of user_id in
       let* invite_id = invite_id_of invite_id in
       Ok (Candidate_bound { user_id; invite_id })
     | (None | Some _), (None | Some _) -> Error Wrong_members)
  | _ -> Error Wrong_members
;;

let claimed_of = function
  | [ ("engine_name", engine_name)
    ; ("claimant", claimant)
    ; ("keeper_id", keeper_id)
    ; ("runtime_id", runtime_id)
    ; ("policy_id", policy_id)
    ; ("turn_scope", turn_scope)
    ] ->
    (match
       ( Authz_body.string_value engine_name
       , Authz_body.string_value claimant
       , Authz_body.string_value keeper_id
       , Authz_body.string_value runtime_id
       , Authz_body.string_value policy_id )
     with
     | ( Some engine_name
       , Some claimant
       , Some keeper_id
       , Some runtime_id
       , Some policy_id ) ->
       let* engine_name = engine_name_of engine_name in
       let* claimant = user_id_of claimant in
       let* keeper_id = keeper_id_of keeper_id in
       let* runtime_id = runtime_id_of runtime_id in
       let* policy_id = policy_id_of policy_id in
       let* turn_scope =
         match Authz_scope_body.of_body turn_scope with
         | Ok turn_scope -> Ok turn_scope
         | Error error -> Error (Invalid_scope error)
       in
       Ok
         (Keeper_claimed
            { engine_name; claimant; keeper_id; runtime_id; policy_id; turn_scope })
     | (None | Some _), (None | Some _), (None | Some _), (None | Some _), (None | Some _) ->
       Error Wrong_members)
  | _ -> Error Wrong_members
;;

let retired_of = function
  | [ ("engine_name", engine_name); ("actor", actor) ] ->
    (match Authz_body.string_value engine_name, Authz_body.string_value actor with
     | Some engine_name, Some actor ->
       let* engine_name = engine_name_of engine_name in
       let* actor = user_id_of actor in
       Ok (Keeper_retired { engine_name; actor })
     | (None | Some _), (None | Some _) -> Error Wrong_members)
  | _ -> Error Wrong_members
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object (("event", Authz_body.String event) :: members) ->
    if String.equal event inventory_label
    then inventory_of members
    else if String.equal event candidate_label
    then candidate_of members
    else if String.equal event claimed_label
    then claimed_of members
    else if String.equal event retired_label
    then retired_of members
    else Error (Unknown_event event)
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
