(* Fusion 설정 쓰기 (구현). 계약: fusion_config_edit.mli *)

type operation =
  | Set_settings of Fusion_config_writer.settings
  | Upsert_preset of Fusion_policy.preset
  | Delete_preset of string
  | Rename_preset of
      { from : string
      ; target : string
      }

let ( let* ) = Result.bind

let object_fields = function
  | `Assoc fields -> Ok fields
  | _ -> Error "operation must be a JSON object"
;;

let exact_keys ~kind ~keys fields =
  match
    ( List.find_opt (fun (key, _) -> not (List.mem key keys)) fields
    , List.find_opt (fun key -> not (List.mem_assoc key fields)) keys )
  with
  | Some (key, _), _ -> Error (Printf.sprintf "%s has an unknown key %S" kind key)
  | None, Some key -> Error (Printf.sprintf "%s is missing %S" kind key)
  | None, None -> Ok ()
;;

let string_field ~kind key fields =
  match List.assoc_opt key fields with
  | Some (`String text) -> Ok text
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" kind key)
  | None -> Error (Printf.sprintf "%s is missing %S" kind key)
;;

let operation_of_yojson json =
  let* fields = object_fields json in
  let* kind = string_field ~kind:"operation" "kind" fields in
  let rest = List.remove_assoc "kind" fields in
  match kind with
  | "set_settings" ->
    let* () =
      exact_keys ~kind ~keys:[ "enabled"; "default_preset"; "staged_judge_group_size" ] rest
    in
    let* enabled =
      match List.assoc_opt "enabled" rest with
      | Some (`Bool value) -> Ok value
      | _ -> Error "set_settings.enabled must be a boolean"
    in
    let* default_preset = string_field ~kind "default_preset" rest in
    let* staged_judge_group_size =
      match List.assoc_opt "staged_judge_group_size" rest with
      | Some (`Int value) -> Ok value
      | _ -> Error "set_settings.staged_judge_group_size must be an integer"
    in
    Ok (Set_settings { Fusion_config_writer.enabled; default_preset; staged_judge_group_size })
  | "upsert_preset" ->
    let* () = exact_keys ~kind ~keys:[ "preset" ] rest in
    let* preset =
      match List.assoc_opt "preset" rest with
      | Some preset -> Fusion_config_json.preset_of_yojson preset
      | None -> Error "upsert_preset is missing \"preset\""
    in
    Ok (Upsert_preset preset)
  | "delete_preset" ->
    let* () = exact_keys ~kind ~keys:[ "name" ] rest in
    let* name = string_field ~kind "name" rest in
    Ok (Delete_preset name)
  | "rename_preset" ->
    let* () = exact_keys ~kind ~keys:[ "from"; "to" ] rest in
    let* from = string_field ~kind "from" rest in
    let* target = string_field ~kind "to" rest in
    Ok (Rename_preset { from; target })
  | other -> Error (Printf.sprintf "unknown operation kind %S" other)
;;

let operation_label = function
  | Set_settings _ -> "set_settings"
  | Upsert_preset preset -> "upsert_preset " ^ preset.Fusion_policy.name
  | Delete_preset name -> "delete_preset " ^ name
  | Rename_preset { from; target } -> Printf.sprintf "rename_preset %s -> %s" from target
;;

type route_problem =
  | Route_missing
  | Route_catalog_missing of string

type error =
  | Configuration_unavailable of string
  | Configuration_changed
  | Preset_invalid of
      { preset : string
      ; invalid : Fusion_policy.Validated_preset.invalid
      }
  | Route_unresolved of
      { preset : string
      ; route : string
      ; problem : route_problem
      }
  | Name_invalid of string
  | Default_preset_deleted of string
  | Edit_refused of Fusion_config_writer.error
  | Fusion_invalid of Fusion_config.config_error list
  | Configuration_rejected of string

let invalid_message = Fusion_policy.Validated_preset.invalid_to_string

let invalid_code : Fusion_policy.Validated_preset.invalid -> string = function
  | No_panel_models -> "no_panel_models"
  | Missing_prompt -> "missing_prompt"
  | Missing_judge_model -> "missing_judge_model"
  | Duplicate_panelist _ -> "duplicate_panelist"
  | Bad_max_output_tokens _ -> "bad_max_output_tokens"
  | Bad_timeout_s _ -> "bad_timeout_s"
  | Judge_panel_prompt_missing -> "judge_panel_prompt_missing"
  | Duplicate_judge _ -> "duplicate_judge"
  | Min_answered_below_min _ | Min_answered_above_max _ -> "min_answered_out_of_range"
;;

let error_code = function
  | Configuration_unavailable _ -> "configuration_unavailable"
  | Configuration_changed -> "configuration_changed"
  | Preset_invalid _ -> "preset_invalid"
  | Route_unresolved _ -> "route_unresolved"
  | Name_invalid _ -> "name_invalid"
  | Default_preset_deleted _ -> "default_preset_deleted"
  | Edit_refused _ -> "edit_refused"
  | Fusion_invalid _ -> "fusion_invalid"
  | Configuration_rejected _ -> "configuration_rejected"
;;

let error_message = function
  | Configuration_unavailable detail -> "runtime.toml could not be read: " ^ detail
  | Configuration_changed ->
    "runtime.toml changed after it was read; reload the settings and apply again"
  | Preset_invalid { preset; invalid } ->
    Printf.sprintf "preset %s %s" preset (invalid_message invalid)
  | Route_unresolved { preset; route; problem = Route_missing } ->
    Printf.sprintf "preset %s names %s, which is not a loaded lane or runtime" preset route
  | Route_unresolved { preset; route; problem = Route_catalog_missing detail } ->
    Printf.sprintf "preset %s names %s, whose catalog entry is missing (%s)" preset route
      detail
  | Name_invalid name -> Printf.sprintf "preset name %S is empty or padded with spaces" name
  | Default_preset_deleted name ->
    Printf.sprintf
      "preset %s is the default of an enabled [fusion]; choose another default first" name
  | Edit_refused error -> Fusion_config_writer.error_message error
  | Fusion_invalid errors ->
    "fusion config invalid: "
    ^ String.concat "; " (List.map Fusion_config.config_error_message errors)
  | Configuration_rejected detail -> detail
;;

let error_to_yojson error =
  let details =
    match error with
    | Preset_invalid { preset; invalid } ->
      [ "preset", `String preset; "reason", `String (invalid_code invalid) ]
    | Route_unresolved { preset; route; problem } ->
      [ "preset", `String preset
      ; "route", `String route
      ; ( "reason"
        , `String
            (match problem with
             | Route_missing -> "route_missing"
             | Route_catalog_missing _ -> "route_catalog_missing") )
      ]
    | Name_invalid name -> [ "preset", `String name ]
    | Default_preset_deleted name -> [ "preset", `String name ]
    | Fusion_invalid errors ->
      [ "messages", `List (List.map (fun e -> `String (Fusion_config.config_error_message e)) errors) ]
    | Configuration_unavailable _ | Configuration_changed | Edit_refused _
    | Configuration_rejected _ -> []
  in
  `Assoc
    ([ "code", `String (error_code error); "message", `String (error_message error) ]
     @ details)
;;

(* ── checks before the lock ────────────────────────────────────────────── *)

let valid_name name =
  (not (String.equal name "")) && String.equal (String.trim name) name
;;

(* Every seat must resolve now, the way a run will resolve it. A route that
   does not would fail every run with Unknown_route; saving it would only move
   the error from the settings screen to the run. The seats are the ones
   [Runtime.route_references] reports to the lane editor. *)
let check_routes (preset : Fusion_policy.preset) =
  List.fold_left
    (fun acc (_seat, route) ->
       let* () = acc in
       match Runtime.resolve_assignment (String.trim route) with
       | `Lane _ -> Ok ()
       | `Missing -> Error (Route_unresolved { preset = preset.name; route; problem = Route_missing })
       | `Unavailable missing ->
         Error
           (Route_unresolved
              { preset = preset.name
              ; route
              ; problem =
                  Route_catalog_missing (Runtime.missing_catalog_model_to_string missing)
              }))
    (Ok ()) (Fusion_policy.preset_seat_routes preset)
;;

(* ── the edit ──────────────────────────────────────────────────────────── *)

exception Refused of error

let refused = function
  | Ok text -> text
  | Error error -> raise (Refused (Edit_refused error))
;;

(* Deleting the default of an enabled [fusion] would leave a file that does
   not load. Asked of the file read under the lock. *)
let delete_checked contents name =
  match Otoml.Parser.from_string_result contents with
  | Error detail -> raise (Refused (Configuration_unavailable detail))
  | Ok toml ->
    (match
       ( Otoml.find_result toml Otoml.get_boolean [ "fusion"; "enabled" ]
       , Otoml.find_result toml Otoml.get_string [ "fusion"; "default_preset" ] )
     with
     | Ok true, Ok default when String.equal default name ->
       raise (Refused (Default_preset_deleted name))
     | (Ok _ | Error _), (Ok _ | Error _) ->
       refused (Fusion_config_writer.delete_preset contents ~name))
;;

(* The checks that need no lock, then the edit to run under it. An upsert
   reaches the writer as the preset its validation returned. *)
let prepare = function
  | Upsert_preset preset ->
    let name = preset.Fusion_policy.name in
    let* () = if valid_name name then Ok () else Error (Name_invalid name) in
    let* validated =
      Fusion_policy.Validated_preset.of_preset preset
      |> Result.map_error (fun invalid -> Preset_invalid { preset = name; invalid })
    in
    let* () = check_routes preset in
    Ok (fun contents -> refused (Fusion_config_writer.upsert_preset contents validated))
  | Rename_preset { from; target } ->
    if valid_name target
    then Ok (fun contents -> refused (Fusion_config_writer.rename_preset contents ~from ~target))
    else Error (Name_invalid target)
  | Set_settings settings ->
    Ok (fun contents -> refused (Fusion_config_writer.set_settings contents settings))
  | Delete_preset name -> Ok (fun contents -> delete_checked contents name)
;;

let check_fusion text =
  match Otoml.Parser.from_string_result text with
  | Error detail -> raise (Refused (Configuration_rejected detail))
  | Ok toml ->
    (match Fusion_config.of_toml toml with
     | Ok _ -> ()
     | Error errors -> raise (Refused (Fusion_invalid errors)))
;;

let apply ~runtime_config_path ~expected_revision operation =
  let* write = prepare operation in
  let edit contents =
    let observation = Runtime.config_observation ~path:runtime_config_path contents in
    let revision = Runtime.config_source_revision_to_string observation.source_revision in
    if not (String.equal revision expected_revision) then raise (Refused Configuration_changed);
    let text = write contents in
    check_fusion text;
    text
  in
  match Runtime.edit_config_text ~runtime_config_path edit with
  | Ok receipt -> Ok receipt
  | Error detail -> Error (Configuration_rejected detail)
  | exception Refused error -> Error error
;;
