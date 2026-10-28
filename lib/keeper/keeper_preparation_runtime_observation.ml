type boundary = Returned | Raised | Cancelled
type report =
  { report_id : string
  ; boundary : boundary
  ; turn_ref : Ids.Turn_ref.t option
  ; execution_scope : Keeper_execution_scope_id.t option
  ; timeline : Keeper_turn_preview.preparation_timeline
  }

let boundary_name = function
  | Returned -> "returned" | Raised -> "raised" | Cancelled -> "cancelled"
;;

let report_to_json report =
  `Assoc
    [ "schema_version", `Int 1
    ; "report_id", `String report.report_id
    ; "boundary", `String (boundary_name report.boundary)
    ; "turn_ref", Option.fold ~none:`Null ~some:Ids.Turn_ref.to_yojson report.turn_ref
    ; "execution_scope", Option.fold ~none:`Null ~some:Keeper_execution_scope_id.to_json report.execution_scope
    ; "scopes", Keeper_turn_preview.preparation_timeline_to_json report.timeline
    ]
;;

let report_of_json json =
  let open Result.Syntax in
  match json with
  | `Assoc fields when List.sort String.compare (List.map fst fields) =
      ["boundary"; "execution_scope"; "report_id"; "schema_version"; "scopes"; "turn_ref"] ->
    let* () = match List.assoc "schema_version" fields with
      | `Int 1 -> Ok () | _ -> Error "unsupported preparation report schema" in
    let* report_id = match List.assoc "report_id" fields with
      | `String value when Option.is_some (Uuidm.of_string value) -> Ok value
      | _ -> Error "preparation report ID must be a UUID" in
    let* boundary = match List.assoc "boundary" fields with
      | `String "returned" -> Ok Returned | `String "raised" -> Ok Raised
      | `String "cancelled" -> Ok Cancelled | _ -> Error "unknown preparation report boundary" in
    let* turn_ref = match List.assoc "turn_ref" fields with
      | `Null -> Ok None | value -> Result.map Option.some (Ids.Turn_ref.of_yojson value) in
    let* execution_scope = match List.assoc "execution_scope" fields with
      | `Null -> Ok None | value -> Result.map Option.some (Keeper_execution_scope_id.of_json value) in
    let* timeline = Keeper_turn_preview.preparation_timeline_of_json (List.assoc "scopes" fields) in
    Ok {report_id; boundary; turn_ref; execution_scope; timeline}
  | _ -> Error "preparation report requires exactly its version, identity, boundary and scopes"
;;

let with_report ~preview ~on_report operation =
  let emit boundary =
    try
      let snapshot = Keeper_turn_preview.snapshot preview in
      on_report
        { report_id = Random_id.uuid_v7 (); boundary
        ; turn_ref = Keeper_turn_preview.original_turn_ref preview
        ; execution_scope = snapshot.execution_scope
        ; timeline = snapshot.preparation_timeline }
    with
    | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as error -> raise error
    | error ->
      (try Log.Keeper.warn "Preparation report sink failed: %s" (Printexc.to_string error) with
       | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow | Sys.Break) as error -> raise error
       | _ -> ())
  in
  match operation () with
  | result -> emit Returned; result
  | exception error ->
    let backtrace = Printexc.get_raw_backtrace () in
    let emit () = emit (match error with Eio.Cancel.Cancelled _ -> Cancelled | _ -> Raised) in
    (match Fs_compat.execution_context () with
     | Fs_compat.Eio_fiber -> Eio.Cancel.protect emit
     | Non_eio -> emit ());
    Printexc.raise_with_backtrace error backtrace
;;

let with_turn ~config ~keeper_name ~preview operation =
  with_report ~preview operation ~on_report:(fun report ->
    match report.turn_ref with
    | None ->
      Log.Keeper.warn ~keeper_name "Preparation report has no original turn reference"
    | Some turn_ref ->
      if not (Keeper_turn_preview.preparation_timeline_is_empty report.timeline) then (
        let context : Keeper_runtime_manifest.turn_context =
          { manifest_keeper_name = keeper_name
          ; manifest_trace_id = Ids.Turn_ref.trace_id turn_ref
          ; manifest_keeper_turn_id = Some (Ids.Turn_ref.absolute_turn turn_ref) } in
        let clock_refs = `Assoc
            [ "edge_id", `String report.report_id
            ; "lane", `String "keeper"; "source_clock", `String "logical" ] in
        Keeper_runtime_manifest.make_for_context context
          ~event:Keeper_runtime_manifest.Preparation_observed
          ~status:(boundary_name report.boundary)
          ~decision:(Keeper_runtime_manifest.with_payload_role
              ~payload_role:Keeper_runtime_manifest.Operator_evidence
              (Keeper_runtime_manifest.with_clock_refs ~clock_refs
                 (`Assoc ["preparation_report", report_to_json report]))) ()
        |> Keeper_runtime_manifest.append_best_effort ~site:"preparation_observed" config))
;;
