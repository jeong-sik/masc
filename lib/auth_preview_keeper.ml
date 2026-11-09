(* HIGH-RISK-UNREVIEWED: see the interface. *)

module R = Login_routes
module Ks = Authz_keeper_state

let keepers_path = "/api/v1/auth/keepers"
let assign_path = keepers_path ^ "/assign"
let turn_path = keepers_path ^ "/turn"
let error status text = R.json status [ "error", `String text ]
let make_shape = {|The body is {"keeper_id": "<name>"}.|}
let assign_shape = {|The body is {"keeper_id": "<name>", "runtime_id": "<id>"}.|}
let unknown_keeper = "No Keeper of yours has this name."
let unknown_runtime = "No Runtime of yours has this id."
let taken = "Another person has a Keeper of this name."
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
  | Error detail -> Error (error R.Bad_request_400 detail)
  | Ok name ->
    Authz_types.Keeper_id.of_string (Keeper_id.Keeper_name.to_string name)
    |> Result.map_error (fun id_error ->
      error R.Bad_request_400 ("The Keeper name is not an id: " ^ Authz_id.error_to_string id_error))
;;

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
  | Ks.Already_made (_ : Authz_types.Keeper_id.t) -> error R.Conflict_409 taken
  | Ks.Not_made (_ : Authz_types.Keeper_id.t) | Ks.Assigned_by_another _ ->
    error R.Not_found_404 unknown_keeper
  | Ks.Runtime_not_made (_ : Authz_types.Runtime_id.t) | Ks.Not_the_owners_runtime _ ->
    error R.Not_found_404 unknown_runtime
  | Ks.User_not_active (_ : Authz_types.User_id.t) ->
    (* An Admin disabled the person after the gate read the log. *)
    error R.Forbidden_403 "The principal is not active."
  | Ks.Made_for_another _
  | Ks.Not_a_human _
  | Ks.Not_a_keeper_author _
  | Ks.Policy_named_before (_ : Authz_types.Policy_id.t) ->
    (* The gate let a human through, who writes in their own name, and the
       policy id is drawn fresh. *)
    Log.Server.warn "A Keeper record was refused: %s" (Ks.refusal_to_string refusal);
    error R.Internal_error_500 not_recorded
;;

let failed (error_ : Authz_keeper.error) =
  match error_ with
  | Authz_keeper.Refused refusal -> refusal_answer refusal
  | Authz_keeper.Id_not_drawn _ | Authz_keeper.Body_not_built _ | Authz_keeper.Commit_failed _ ->
    Log.Server.warn "A Keeper record was not written: %s" (Authz_keeper.error_to_string error_);
    error R.Service_unavailable_503 not_recorded
;;

let keeper_json keeper_id members =
  R.json R.Ok_200 (("keeper_id", `String (Authz_types.Keeper_id.to_string keeper_id)) :: members)
;;

let state_of zone = (Authz_zone.snapshot zone).Authz_zone.state

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
    let* keeper_id = keeper_id_of name in
    let made record = keeper_json keeper_id [ "record", `String record ] in
    let made_before () =
      match Ks.find (state_of zone).Authz_state.keepers keeper_id with
      | Some keeper when Authz_types.User_id.equal keeper.Ks.owner user_id ->
        Some (Ok (made "existing"))
      | Some (_ : Ks.keeper) -> Some (Error (error R.Conflict_409 taken))
      | None -> None
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
         (* Another request can make the Keeper between the read above and
            this write. The log then has it, and says whose it is. *)
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
    let* keeper_id = keeper_id_of name in
    let* runtime_id = runtime_id_of runtime in
    let assigned record =
      keeper_json
        keeper_id
        [ "runtime_id", `String (Authz_types.Runtime_id.to_string runtime_id)
        ; "record", `String record
        ]
    in
    match Ks.find (state_of zone).Authz_state.keepers keeper_id with
    | Some { Ks.owner; runtime = Some current }
      when Authz_types.User_id.equal owner user_id && Authz_types.Runtime_id.equal current runtime_id
      -> Ok (assigned "existing")
    | Some (_ : Ks.keeper) | None ->
      (match Authz_keeper.assign zone ~user_id ~keeper_id ~runtime_id with
       | Ok () -> Ok (assigned "assigned")
       | Error error_ -> Error (failed error_))
  in
  Result.fold ~ok:Fun.id ~error:Fun.id answer
;;
