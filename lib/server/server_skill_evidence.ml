type activation_evidence =
  { keeper_name : string
  ; activation : Keeper_skill_activation_ledger.activation
  }

let activation_reference
      (activation : Keeper_skill_activation_ledger.activation) =
  Skill_reference.make
    ~identity:activation.identity
    ~content_revision:activation.content_revision
;;

let newer_activation left right =
  if
    String.compare
      left.activation.Keeper_skill_activation_ledger.activated_at
      right.activation.Keeper_skill_activation_ledger.activated_at
    >= 0
  then left
  else right
;;

let latest_activation ~config reference =
  match Keeper_meta_store.keeper_names_result config with
  | Error _ -> None, 0, [ "keeper catalog: unavailable" ]
  | Ok keeper_names ->
    List.fold_left
      (fun (latest, loaded, unavailable) keeper_name ->
         match Keeper_meta_store.read_meta config keeper_name with
         | Error _ ->
           latest, loaded, (keeper_name ^ ": metadata unavailable") :: unavailable
         | Ok None -> latest, loaded, unavailable
         | Ok (Some meta) ->
           (match
              Keeper_skill_activation_ledger.load_existing
                ~config
                ~trace_id:meta.runtime.trace_id
            with
            | Error error ->
              ( latest
              , loaded
              , (keeper_name
                 ^ ": "
                 ^ Keeper_skill_activation_ledger.store_error_code error)
                :: unavailable )
            | Ok None -> latest, loaded, unavailable
            | Ok (Some ledger) ->
              let observed =
                Keeper_skill_activation_ledger.activations ledger
                |> List.filter (fun activation ->
                     Skill_reference.equal
                       reference
                       (activation_reference activation))
                |> List.map (fun activation -> { keeper_name; activation })
                |> List.fold_left
                     (fun latest candidate ->
                        Some
                          (match latest with
                           | None -> candidate
                           | Some current -> newer_activation current candidate))
                     latest
              in
              observed, loaded + 1, unavailable))
      (None, 0, [])
      keeper_names
    |> fun (latest, loaded, unavailable) ->
    latest, loaded, List.rev unavailable
;;

type composition_coverage =
  { scope : [ `Exact_reference_latest_completed | `Unavailable ]
  ; records_read : int
  }

let composition_scope_to_string = function
  | `Exact_reference_latest_completed -> "exact_reference_latest_completed"
  | `Unavailable -> "unavailable"
;;

let composition_evidence ~config reference =
  match Keeper_skill_composition_evidence.load_latest config reference with
  | Error error ->
    ( None
    , { scope = `Unavailable; records_read = 0 }
    , [ Keeper_skill_composition_evidence.error_to_string error ] )
  | Ok None ->
    None, { scope = `Exact_reference_latest_completed; records_read = 0 }, []
  | Ok (Some evidence) ->
    ( Some (Keeper_skill_composition_evidence.to_yojson evidence)
    , { scope = `Exact_reference_latest_completed; records_read = 1 }
    , [] )
;;

let to_yojson
      ~reference
      ~composition
      ~composition_coverage
      ~activation
      ~ledgers_loaded
      ~unavailable =
  let activation =
    Option.map
      (fun evidence ->
         `Assoc
           [ "keeper", `String evidence.keeper_name
           ; ( "activation"
             , Keeper_skill_activation_ledger.activation_to_yojson
                 evidence.activation )
           ])
      activation
  in
  let observed = Option.is_some activation || Option.is_some composition in
  `Assoc
    [ "schema", `String "masc.skill-evidence/v4"
    ; ( "status"
      , `String
          (if observed then "observed" else "not_observed_in_current_coverage") )
    ; "reference", Skill_reference.to_yojson reference
    ; "activation", Option.value ~default:`Null activation
    ; "composition", Option.value ~default:`Null composition
    ; ( "coverage"
      , `Assoc
          [ ( "composition_scope"
            , `String (composition_scope_to_string composition_coverage.scope) )
          ; "composition_records_read", `Int composition_coverage.records_read
          ; "coverage_complete", `Bool false
          ; "activation_scope", `String "current_keeper_sessions"
          ; "activation_ledgers_loaded", `Int ledgers_loaded
          ; "unavailable", `List (List.map (fun value -> `String value) unavailable)
          ] )
    ]
;;

let project ~config reference =
  let activation, ledgers_loaded, unavailable =
    latest_activation ~config reference
  in
  let composition, composition_coverage, composition_unavailable =
    composition_evidence ~config reference
  in
  to_yojson
    ~reference
    ~composition
    ~composition_coverage
    ~activation
    ~ledgers_loaded
    ~unavailable:(unavailable @ composition_unavailable)
;;

module For_testing = struct
  let to_yojson
        ~reference
        ~composition
        ~composition_records_read
        ~composition_scope
        ~activation
        ~ledgers_loaded
        ~unavailable =
    let activation =
      Option.map
        (fun (keeper_name, activation) -> { keeper_name; activation })
        activation
    in
    to_yojson
      ~reference
      ~composition
      ~composition_coverage:
        { scope = composition_scope; records_read = composition_records_read }
      ~activation
      ~ledgers_loaded
      ~unavailable
  ;;
end
