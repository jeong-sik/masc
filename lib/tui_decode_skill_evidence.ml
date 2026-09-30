(** Strict skill-evidence wire model and decoder for the Tools surface. *)
open Tui_decode_fields

let ( let* ) = Result.bind

type skill_evidence_status =
  | Skill_evidence_observed
  | Skill_evidence_not_observed_in_retained_coverage

type skill_evidence_composition_scope =
  | Skill_evidence_exact_reference_latest_completed
  | Skill_evidence_composition_unavailable

type skill_evidence_coverage =
  { sec_composition_scope : skill_evidence_composition_scope
  ; sec_composition_records_read : int
  ; sec_composition_unavailable : string list
  ; sec_activation_scope : string
  ; sec_activation_sessions_inspected : int
  ; sec_activation_ledgers_loaded : int
  ; sec_activation_gap_count : int
  ; sec_activation_owner_gap_count : int
  }

type skill_evidence_owner_claim =
  { seo_keeper : string
  ; seo_source : string
  }

type skill_evidence_activation_item =
  { sea_trace_id : string
  ; sea_owner_status : string
  ; sea_owner_claims : skill_evidence_owner_claim list
  ; sea_owner_gap_count : int
  ; sea_activation : Yojson.Safe.t
  }

type skill_evidence_activation =
  | Skill_evidence_most_recent_observed of skill_evidence_activation_item
  | Skill_evidence_most_recent_observed_timestamp_tie of
      skill_evidence_activation_item list

type skill_evidence =
  { se_status : skill_evidence_status
  ; se_activation : skill_evidence_activation option
  ; se_composition : Yojson.Safe.t option
  ; se_coverage : skill_evidence_coverage
  }

let decode_skill_evidence_optional_object field json =
  match json with
  | `Assoc fields when not (List.mem_assoc field fields) ->
    Error ("Skill evidence " ^ field ^ " is required")
  | `Assoc _ ->
    (match member field json with
     | `Null -> Ok None
     | `Assoc _ as value -> Ok (Some value)
     | _ -> Error ("Skill evidence " ^ field ^ " must be an object or null"))
  | _ -> Error "Skill evidence must be an object"
;;

let decode_skill_evidence_nonnegative_int field json =
  match member field json with
  | `Int value when value >= 0 -> Ok value
  | _ -> Error ("Skill evidence coverage " ^ field ^ " must be nonnegative")
;;

let decode_skill_evidence_string_list field json =
  match member field json with
  | `List values ->
    List.fold_left
      (fun result value ->
         let* reversed = result in
         match value with
         | `String value -> Ok (value :: reversed)
         | _ -> Error ("Skill evidence " ^ field ^ " rows must be strings"))
      (Ok [])
      values
    |> Result.map List.rev
  | _ -> Error ("Skill evidence " ^ field ^ " must be a list")
;;

let skill_evidence_exact_fields expected fields =
  let actual = List.map fst fields in
  List.length actual = List.length expected
  && List.sort_uniq String.compare actual = List.sort String.compare expected
;;

let skill_evidence_string_field field json =
  match member field json with `String _ -> true | _ -> false
;;

let skill_evidence_positive_int_field field json =
  match member field json with `Int value -> value > 0 | _ -> false
;;

let skill_evidence_manifest_cause = function
  | `Assoc fields as cause ->
    (match member "code" cause with
     | `String "manifest_read_failed" ->
       skill_evidence_exact_fields [ "code"; "detail" ] fields
       && skill_evidence_string_field "detail" cause
     | `String "manifest_empty" ->
       skill_evidence_exact_fields [ "code" ] fields
     | `String ("manifest_invalid_json" | "manifest_invalid_row") ->
       skill_evidence_exact_fields [ "code"; "line_number"; "detail" ] fields
       && skill_evidence_positive_int_field "line_number" cause
       && skill_evidence_string_field "detail" cause
     | `String "manifest_identity_mismatch" ->
       skill_evidence_exact_fields
         [ "code"; "line_number"; "observed_keeper"; "observed_trace" ]
         fields
       && skill_evidence_positive_int_field "line_number" cause
       && skill_evidence_string_field "observed_keeper" cause
       && skill_evidence_string_field "observed_trace" cause
     | _ -> false)
  | _ -> false
;;

let skill_evidence_owner_gap = function
  | `Assoc fields as gap ->
    (match member "code" gap with
     | `String "keeper_catalog_unavailable" ->
       skill_evidence_exact_fields [ "code"; "detail" ] fields
       && skill_evidence_string_field "detail" gap
     | `String "keeper_catalog_changed_during_resolution" ->
       skill_evidence_exact_fields [ "code" ] fields
     | `String "invalid_persisted_keeper_name" ->
       skill_evidence_exact_fields [ "code"; "keeper" ] fields
       && skill_evidence_string_field "keeper" gap
     | `String "keeper_meta_name_mismatch" ->
       skill_evidence_exact_fields [ "code"; "keeper"; "metadata_name" ] fields
       && skill_evidence_string_field "keeper" gap
       && skill_evidence_string_field "metadata_name" gap
     | `String "keeper_meta_unavailable" ->
       skill_evidence_exact_fields [ "code"; "keeper"; "detail" ] fields
       && skill_evidence_string_field "keeper" gap
       && skill_evidence_string_field "detail" gap
     | `String "runtime_manifest_unreadable" ->
       skill_evidence_exact_fields [ "code"; "keeper"; "cause" ] fields
       && skill_evidence_string_field "keeper" gap
       && skill_evidence_manifest_cause (member "cause" gap)
     | _ -> false)
  | _ -> false
;;

let skill_evidence_filesystem_gap expected_code = function
  | `Assoc fields as gap ->
    skill_evidence_exact_fields [ "code"; "operation"; "path"; "detail" ] fields
    && member "code" gap = `String expected_code
    && (match member "operation" gap with
        | `String ("open_directory" | "read_directory" | "close_directory" | "stat_entry") -> true
        | _ -> false)
    && skill_evidence_string_field "path" gap
    && skill_evidence_string_field "detail" gap
  | _ -> false
;;

let skill_evidence_file_kind = function
  | `String
      ( "regular"
      | "directory"
      | "character_device"
      | "block_device"
      | "symbolic_link"
      | "fifo"
      | "socket" ) -> true
  | _ -> false
;;

let skill_evidence_activation_gap = function
  | `Assoc fields as gap ->
    (match member "code" gap with
     | `String ("trace_root_unavailable" as code)
     | `String ("trace_entry_unreadable" as code) ->
       skill_evidence_filesystem_gap code gap
     | `String "trace_root_not_directory" ->
       skill_evidence_exact_fields [ "code"; "kind" ] fields
       && skill_evidence_file_kind (member "kind" gap)
     | `String ("invalid_trace_directory" | "symlink_trace_entry") ->
       skill_evidence_exact_fields [ "code"; "entry" ] fields
       && skill_evidence_string_field "entry" gap
     | `String "trace_entry_not_directory" ->
       skill_evidence_exact_fields [ "code"; "trace_id"; "kind" ] fields
       && skill_evidence_string_field "trace_id" gap
       && skill_evidence_file_kind (member "kind" gap)
     | `String
         ( "trace_inventory_changed_during_discovery"
         | "trace_root_changed_during_discovery" ) ->
       skill_evidence_exact_fields [ "code" ] fields
     | `String "ledger_changed_during_discovery" ->
       skill_evidence_exact_fields [ "code"; "trace_id" ] fields
       && skill_evidence_string_field "trace_id" gap
     | `String "ledger_unreadable" ->
       skill_evidence_exact_fields
         [ "code"; "trace_id"; "cause_code"; "detail" ]
         fields
       && skill_evidence_string_field "trace_id" gap
       && skill_evidence_string_field "cause_code" gap
       && skill_evidence_string_field "detail" gap
     | _ -> false)
  | _ -> false
;;

let decode_skill_evidence_activation_item reference = function
  | `Assoc _ as evidence ->
    let* trace_id, sea_trace_id =
      match member "trace_id" evidence with
      | `String value ->
        Keeper_id.Trace_id.of_string value
        |> Result.map (fun trace_id -> trace_id, value)
        |> Result.map_error (fun _ -> "Skill activation trace_id is invalid")
      | _ -> Error "Skill activation trace_id is invalid"
    in
    let* sea_owner_status, sea_owner_claims, sea_owner_gap_count =
      match member "owner" evidence with
      | `Assoc _ as owner ->
        let* status =
          match member "status" owner with
          | `String
              ( "known"
              | "not_claimed_in_retained_catalog"
              | "conflicting"
              | "incomplete"
              | "catalog_unavailable" as value ) ->
            Ok value
          | _ -> Error "Skill activation owner status is invalid"
        in
        let* claims =
          match member "claims" owner with
          | `List claims ->
            List.fold_left
              (fun result claim ->
                 let* reversed = result in
                 match claim with
                 | `Assoc _ as claim ->
                   (match member "keeper" claim, member "source" claim with
                    | ( `String keeper
                      , `String ("current_meta" | "runtime_manifest" as source) )
                      when String.trim keeper <> "" ->
                      Ok ({ seo_keeper = keeper; seo_source = source } :: reversed)
                    | _ -> Error "Skill activation owner claim is invalid")
                 | _ -> Error "Skill activation owner claim must be an object")
              (Ok [])
              claims
            |> Result.map List.rev
          | _ -> Error "Skill activation owner claims must be a list"
        in
        let* gaps =
          match member "gaps" owner with
          | `List gaps when List.for_all skill_evidence_owner_gap gaps ->
            Ok gaps
          | _ -> Error "Skill activation owner gaps must be objects"
        in
        let owner_agrees =
          match status with
          | "known" -> List.length claims = 1 && gaps = []
          | "not_claimed_in_retained_catalog" -> claims = [] && gaps = []
          | "conflicting" -> List.length claims >= 2 && gaps = []
          | "incomplete" -> gaps <> []
          | "catalog_unavailable" -> claims = [] && gaps <> []
          | _ -> false
        in
        if owner_agrees
        then Ok (status, claims, List.length gaps)
        else Error "Skill activation owner status disagrees with claims or gaps"
      | _ -> Error "Skill activation owner must be an object"
    in
    let* sea_activation =
      match member "activation" evidence with
      | `Assoc _ as activation ->
        (match
           Keeper_skill_activation_ledger.activation_of_yojson
             ~expected_trace_id:trace_id
             activation
         with
         | Ok observed ->
           let observed_reference =
             Skill_reference.make
               ~identity:observed.identity
               ~content_revision:observed.content_revision
           in
           if Skill_reference.equal reference observed_reference
           then Ok activation
           else Error "Skill activation reference disagrees with envelope"
         | Error _ -> Error "Skill activation payload is invalid")
      | _ -> Error "Skill activation payload must be an object"
    in
    Ok
      { sea_trace_id
      ; sea_owner_status
      ; sea_owner_claims
      ; sea_owner_gap_count
      ; sea_activation
      }
  | _ -> Error "Skill activation evidence must be an object"
;;

let decode_skill_evidence_activation reference json =
  match json with
  | `Assoc fields when not (List.mem_assoc "activation" fields) ->
    Error "Skill evidence activation is required"
  | _ ->
  match member "activation" json with
  | `Null -> Ok None
  | `Assoc _ as activation ->
    (match member "selection" activation, member "evidence" activation with
     | `String "most_recent_observed", evidence ->
       decode_skill_evidence_activation_item reference evidence
       |> Result.map (fun evidence ->
            Some (Skill_evidence_most_recent_observed evidence))
     | `String "most_recent_observed_timestamp_tie", `List evidence ->
       let* evidence =
         List.fold_left
           (fun result value ->
              let* reversed = result in
              let* evidence =
                decode_skill_evidence_activation_item reference value
              in
              Ok (evidence :: reversed))
           (Ok [])
           evidence
         |> Result.map List.rev
       in
       let parsed_timestamps =
         evidence
         |> List.filter_map (fun item ->
              match member "activated_at" item.sea_activation with
              | `String value -> Time_codec.parse_rfc3339_opt value
              | _ -> None)
         |> List.sort_uniq Float.compare
       in
       let distinct_traces =
         evidence
         |> List.map (fun item -> item.sea_trace_id)
         |> List.sort_uniq String.compare
       in
       if
         List.length evidence >= 2
         && List.length parsed_timestamps = 1
         && List.length distinct_traces = List.length evidence
       then
         Ok
           (Some
              (Skill_evidence_most_recent_observed_timestamp_tie evidence))
       else Error "Skill activation timestamp tie is inconsistent"
     | _ -> Error "Skill activation selection is invalid")
  | _ -> Error "Skill evidence activation must be an object or null"
;;

let decode_skill_evidence json =
  if member "schema" json <> `String "masc.skill-evidence/v5"
  then Error "Skill evidence schema is unsupported"
  else
    let* reference =
      match Skill_reference.of_yojson (member "reference" json) with
      | Ok reference -> Ok reference
      | Error _ -> Error "Skill evidence reference is invalid"
    in
    let* se_activation = decode_skill_evidence_activation reference json in
    let* se_composition = decode_skill_evidence_optional_object "composition" json in
    let* () =
      match se_composition with
      | None -> Ok ()
      | Some composition ->
        (match Keeper_skill_composition_evidence.of_yojson composition with
         | Ok evidence
           when Skill_reference.equal
                  reference
                  (Keeper_skill_composition_evidence.reference evidence) ->
           Ok ()
         | Ok _ -> Error "Skill composition evidence reference disagrees with envelope"
         | Error _ -> Error "Skill composition evidence record is invalid")
    in
    let observed = Option.is_some se_activation || Option.is_some se_composition in
    let* se_status =
      match member "status" json, observed with
      | `String "observed", true -> Ok Skill_evidence_observed
      | `String "not_observed_in_retained_coverage", false ->
        Ok Skill_evidence_not_observed_in_retained_coverage
      | `String ("observed" | "not_observed_in_retained_coverage"), _ ->
        Error "Skill evidence status disagrees with its observations"
      | _ -> Error "Skill evidence status is unsupported"
    in
    match member "coverage" json with
    | `Assoc _ as coverage ->
      let* () =
        match member "coverage_complete" coverage with
        | `Bool false -> Ok ()
        | _ -> Error "Skill evidence coverage must remain incomplete"
      in
      let* sec_activation_scope =
        match member "activation_scope" coverage with
        | `String
            ( "complete_retained_trace_snapshot"
            | "incomplete_retained_trace_snapshot"
            | "trace_store_unavailable" as value ) ->
          Ok value
        | _ -> Error "Skill evidence activation scope is unsupported"
      in
      let* sec_composition_scope =
        match member "composition_scope" coverage with
        | `String "exact_reference_latest_completed" ->
          Ok Skill_evidence_exact_reference_latest_completed
        | `String "unavailable" -> Ok Skill_evidence_composition_unavailable
        | _ -> Error "Skill evidence composition scope is unsupported"
      in
      let* sec_composition_records_read =
        decode_skill_evidence_nonnegative_int
          "composition_records_read"
          coverage
      in
      let* sec_composition_unavailable =
        decode_skill_evidence_string_list "composition_unavailable" coverage
      in
      let* sec_activation_sessions_inspected =
        decode_skill_evidence_nonnegative_int
          "activation_sessions_inspected"
          coverage
      in
      let* sec_activation_ledgers_loaded =
        decode_skill_evidence_nonnegative_int
          "activation_ledgers_loaded"
          coverage
      in
      let* activation_gaps =
        match member "activation_gaps" coverage with
        | `List gaps when List.for_all skill_evidence_activation_gap gaps ->
          Ok gaps
        | _ -> Error "Skill evidence activation gaps must be objects"
      in
      let sec_activation_gap_count = List.length activation_gaps in
      let* sec_activation_owner_gap_count =
        decode_skill_evidence_nonnegative_int
          "activation_owner_gap_count"
          coverage
      in
      let* () =
        match sec_composition_scope, se_composition, sec_composition_records_read with
        | Skill_evidence_exact_reference_latest_completed, Some _, 1
          when sec_composition_unavailable = [] ->
          Ok ()
        | Skill_evidence_exact_reference_latest_completed, None, 0
          when sec_composition_unavailable = [] ->
          Ok ()
        | Skill_evidence_composition_unavailable, None, 0
          when sec_composition_unavailable <> [] ->
          Ok ()
        | _ -> Error "Skill evidence composition coverage disagrees with its record"
      in
      let owner_gap_count =
        match se_activation with
        | None -> 0
        | Some (Skill_evidence_most_recent_observed evidence) ->
          evidence.sea_owner_gap_count
        | Some (Skill_evidence_most_recent_observed_timestamp_tie evidence) ->
          List.fold_left (fun total row -> total + row.sea_owner_gap_count) 0 evidence
      in
      let activation_count =
        match se_activation with
        | None -> 0
        | Some (Skill_evidence_most_recent_observed _) -> 1
        | Some (Skill_evidence_most_recent_observed_timestamp_tie evidence) ->
          List.length evidence
      in
      let* () =
        if
          sec_activation_ledgers_loaded <= sec_activation_sessions_inspected
          && activation_count <= sec_activation_ledgers_loaded
          && owner_gap_count = sec_activation_owner_gap_count
          &&
          (match sec_activation_scope with
           | "complete_retained_trace_snapshot" -> sec_activation_gap_count = 0
           | "incomplete_retained_trace_snapshot" ->
             sec_activation_gap_count > 0
           | "trace_store_unavailable" ->
             (match activation_gaps with
              | [ gap ] ->
                member "code" gap = `String "trace_root_unavailable"
                || member "code" gap = `String "trace_root_not_directory"
              | _ -> false)
             && Option.is_none se_activation
             && sec_activation_sessions_inspected = 0
             && sec_activation_ledgers_loaded = 0
             && sec_activation_owner_gap_count = 0
           | _ -> false)
        then Ok ()
        else Error "Skill evidence activation coverage disagrees with snapshot"
      in
      Ok
        { se_status
        ; se_activation
        ; se_composition
        ; se_coverage =
            { sec_composition_scope
            ; sec_composition_records_read
            ; sec_composition_unavailable
            ; sec_activation_scope
            ; sec_activation_sessions_inspected
            ; sec_activation_ledgers_loaded
            ; sec_activation_gap_count
            ; sec_activation_owner_gap_count
            }
        }
    | _ -> Error "Skill evidence coverage must be an object"
;;
