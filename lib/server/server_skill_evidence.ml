type activation_evidence =
  { keeper_name : string
  ; activation : Keeper_skill_activation_ledger.activation
  }

let scan_limit = 5_000

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
              Keeper_skill_activation_ledger.load
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
            | Ok ledger ->
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

let composition_evidence ~reference rows =
  let exact_parent =
    rows
    |> List.rev
    |> List.find_opt (fun row ->
      match Json_util.assoc_member_opt "record_kind" row,
            Json_util.assoc_member_opt "skill_reference" row
      with
      | Some (`String "composition_run"), Some reference_json ->
        (match Skill_reference.of_yojson reference_json with
         | Ok observed -> Skill_reference.equal observed reference
         | Error _ -> false)
      | _ -> false)
  in
  Option.map
    (fun parent ->
       let run_id =
         match Json_util.assoc_member_opt "composition_run_id" parent with
         | Some (`String value) -> Some value
         | _ -> None
       in
       let nodes =
         match run_id with
         | None -> []
         | Some expected ->
           List.filter
             (fun row ->
                match Json_util.assoc_member_opt "composition_run_id" row,
                      Json_util.assoc_member_opt "record_kind" row
                with
                | Some (`String observed), Some (`String "tool_call") ->
                  String.equal expected observed
                | _ -> false)
             rows
       in
       `Assoc [ "run", parent; "nodes", `List nodes ])
    exact_parent
;;

let to_yojson
      ~reference
      ~rows
      ~activation
      ~ledgers_loaded
      ~unavailable =
  let composition = composition_evidence ~reference rows in
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
  `Assoc
    [ "schema", `String "masc.skill-evidence/v1"
    ; ( "status"
      , `String
          (if Option.is_some activation || Option.is_some composition
           then "observed"
           else "never_observed") )
    ; "reference", Skill_reference.to_yojson reference
    ; "activation", Option.value ~default:`Null activation
    ; "composition", Option.value ~default:`Null composition
    ; ( "coverage"
      , `Assoc
          [ "composition_scan_limit", `Int scan_limit
          ; "composition_rows_scanned", `Int (List.length rows)
          ; "instruction_ledgers_loaded", `Int ledgers_loaded
          ; "unavailable", `List (List.map (fun value -> `String value) unavailable)
          ] )
    ]
;;

let project ~config reference =
  let rows = Keeper_tool_call_log.read_recent_rows ~n:scan_limit () in
  let activation, ledgers_loaded, unavailable =
    latest_activation ~config reference
  in
  to_yojson
    ~reference
    ~rows
    ~activation
    ~ledgers_loaded
    ~unavailable
;;

module For_testing = struct
  let to_yojson
        ~reference
        ~rows
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
      ~rows
      ~activation
      ~ledgers_loaded
      ~unavailable
  ;;
end
