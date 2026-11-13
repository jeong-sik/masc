(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Ks = Authz_keeper_state

let keepers_path = "/api/v1/auth/keepers"
let assign_path = keepers_path ^ "/assign"
let turn_path = keepers_path ^ "/turn"
let conversation_path = keepers_path ^ "/conversation"
let error status text = R.json status [ "error", `String text ]
let make_shape = {|The body is {"keeper_id": "<name>"}.|}
let assign_shape = {|The body is {"keeper_id": "<name>", "runtime_id": "<id>"}.|}
let unknown_keeper = "No Keeper of yours has this name."
let unknown_runtime = "No Runtime of yours has this id."
let not_recorded = "The Keeper could not be recorded."
let ( let* ) = Result.bind

let json_of body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error (_ : string) -> None
  | json -> Some json
;;

(* A Keeper name of the Keeper grammar, which is also the name of its TOML,
   and then an id of the log. *)
let keeper_id_of name =
  match Keeper_id.Keeper_name.of_string name with
  | Error detail -> Error detail
  | Ok name ->
    Authz_types.Keeper_id.of_string (Keeper_id.Keeper_name.to_string name)
    |> Result.map_error (fun id_error ->
      "The Keeper name is not an id: " ^ Authz_id.error_to_string id_error)
;;

let keeper_id_answer name = keeper_id_of name |> Result.map_error (error R.Bad_request_400)

let runtime_id_of id =
  Authz_types.Runtime_id.of_string id
  |> Result.map_error (fun (_ : Authz_id.error) -> error R.Bad_request_400 unknown_runtime)
;;

(* The policy the turns of a Keeper made here run under: the owner runs it,
   alone or on their own request, on any Runtime of theirs it is given, with
   what that Runtime's Self grant allows (user decision 2026-11-09). The
   Runtime and the effects are limited by the assignment and the Self grant,
   so this policy limits only the channels. *)
let own_keeper_turn_scope =
  { Authz_types.Authorization_scope.runtimes = Authz_types.Runtime_scope.all
  ; channels =
      Authz_types.Channel_scope.only
        (Authz_types.Channel.Set.of_list Authz_types.Channel.[ Autonomous; Direct ])
  ; allowed_effects = Authz_types.Effect_scope.all
  }
;;

let refusal_answer (refusal : Ks.refusal) =
  match refusal with
  | Ks.Not_made (_ : Authz_types.Keeper_id.t) -> error R.Not_found_404 unknown_keeper
  | Ks.Runtime_not_made (_ : Authz_types.Runtime_id.t) | Ks.Not_the_owners_runtime _ ->
    error R.Not_found_404 unknown_runtime
  | Ks.User_not_active (_ : Authz_types.User_id.t) ->
    (* An Admin disabled the person after the gate read the log. *)
    error R.Forbidden_403 "The principal is not active."
  | Ks.Already_made (_ : Authz_types.Keeper_id.t)
  | Ks.Made_for_another _
  | Ks.Not_a_human _
  | Ks.Not_a_keeper_author _
  | Ks.Policy_named_before (_ : Authz_types.Policy_id.t) ->
    (* The gate let a human through, who writes in their own name, the
       policy id is drawn fresh, and [make] answers a Keeper the person made
       before from the log without writing. *)
    Log.Server.warn "A Keeper record was refused: %s" (Ks.refusal_to_string refusal);
    error R.Internal_error_500 not_recorded
;;

let failed (error_ : Authz_keeper.error) =
  match error_ with
  | Authz_keeper.Refused refusal -> refusal_answer refusal
  | Authz_keeper.Id_not_drawn _ | Authz_keeper.Body_not_built _ | Authz_keeper.Commit_failed _ ->
    Log.Server.warn "A Keeper record was not written: %s" (Authz_keeper.error_detail error_);
    error R.Service_unavailable_503 not_recorded
;;

let keeper_json keeper_id members =
  R.json R.Ok_200 (("keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)) :: members)
;;

(* The Keepers of the state the zone can be trusted for. An answer that says
   a Keeper is there is read from it, and a zone that cannot be trusted
   answers no such thing. *)
let keepers_of zone =
  Result.map
    (fun (trusted : Authz_zone.trusted) ->
      (trusted :> Authz_zone.snapshot).Authz_zone.state.Authz_state.keepers)
    (Authz_zone.read zone)
;;

let list state user_id =
  R.json
    R.Ok_200
    [ ( "keepers"
      , `List
          (List.map
             (fun (keeper_id, (keeper : Ks.keeper)) ->
               `Assoc
                 [ "keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)
                 ; ( "runtime_id"
                   , match keeper.Ks.runtime with
                     | None -> `Null
                     | Some runtime_id -> `String (Authz_types.Runtime_id.to_string runtime_id) )
                 ])
             (Authz_keeper.owned state user_id)) )
    ]
;;

let make zone user_id ~body =
  let answer =
    let* name =
      match json_of body with
      | Some (`Assoc [ ("keeper_id", `String name) ]) -> Ok name
      | Some _ | None -> Error (error R.Bad_request_400 make_shape)
    in
    let* keeper_id = keeper_id_answer name in
    let made record = keeper_json keeper_id [ "record", `String record ] in
    let made_before () =
      match keepers_of zone with
      | Error uncertain -> Some (Error (R.zone_uncertain uncertain))
      | Ok keepers ->
        (* A Keeper of this name that another person made is another
           Keeper: it is not read here, and it does not take the name. *)
        (match Ks.find keepers ~owner:user_id keeper_id with
         | Some (_ : Ks.keeper) -> Some (Ok (made "existing"))
         | None -> None)
    in
    match made_before () with
    | Some answer -> answer
    | None ->
      (match
         Authz_keeper.make
           zone
           ~user_id
           ~keeper_id
           ~turn_scope:own_keeper_turn_scope
           ~draw:Auth.generate_token
       with
       | Ok () -> Ok (made "made")
       | Error error_ ->
         (* Another request of the person can make the Keeper between the
            read above and this write. The log then has it. *)
         (match made_before () with
          | Some answer -> answer
          | None -> Error (failed error_)))
  in
  Result.fold ~ok:Fun.id ~error:Fun.id answer
;;

let assign zone user_id ~body =
  let answer =
    let* name, runtime =
      match json_of body with
      | Some (`Assoc [ ("keeper_id", `String name); ("runtime_id", `String runtime) ]) ->
        Ok (name, runtime)
      | Some _ | None -> Error (error R.Bad_request_400 assign_shape)
    in
    let* keeper_id = keeper_id_answer name in
    let* runtime_id = runtime_id_of runtime in
    let assigned record =
      keeper_json
        keeper_id
        [ "runtime_id", `String (Authz_types.Runtime_id.to_string runtime_id)
        ; "record", `String record
        ]
    in
    match keepers_of zone with
    | Error uncertain -> Error (R.zone_uncertain uncertain)
    | Ok keepers ->
      (match Ks.find keepers ~owner:user_id keeper_id with
       | Some { Ks.runtime = Some current; owner = _; policy_id = _; turn_scope = _ }
         when Authz_types.Runtime_id.equal current runtime_id -> Ok (assigned "existing")
       | Some (_ : Ks.keeper) | None ->
         (match Authz_keeper.assign zone ~user_id ~keeper_id ~runtime_id with
          | Ok () -> Ok (assigned "assigned")
          | Error error_ -> Error (failed error_)))
  in
  Result.fold ~ok:Fun.id ~error:Fun.id answer
;;
