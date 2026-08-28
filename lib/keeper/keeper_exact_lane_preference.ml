(** See keeper_exact_lane_preference.mli. *)

type t =
  { keeper_name : string
  ; lane_id : string
  ; slot_id : string
  ; actor : string
  ; changed_at : string
  }

module Owner = struct
  type t = string * string

  let compare = Stdlib.compare
end

module Owners = Set.Make (Owner)

let path ~base_path =
  Filename.concat
    (Keeper_gate_path.dir ~base_path)
    "keeper-exact-lane-preferences.json"
;;

let nonblank_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok (String.trim value)
  | Some _ | None ->
    Error (Printf.sprintf "keeper exact-lane preference is missing %s" key)
;;

let to_json row =
  `Assoc
    [ "keeper_name", `String row.keeper_name
    ; "lane_id", `String row.lane_id
    ; "slot_id", `String row.slot_id
    ; "updated_by", `String row.actor
    ; "updated_at", `String row.changed_at
    ]
;;

let of_json = function
  | `Assoc fields ->
    let expected =
      [ "keeper_name"; "lane_id"; "slot_id"; "updated_by"; "updated_at" ]
      |> List.sort String.compare
    in
    let actual = List.map fst fields |> List.sort String.compare in
    if actual <> expected
    then Error "keeper exact-lane preference fields do not match current schema"
    else
      let open Result.Syntax in
      let* keeper_name = nonblank_field fields "keeper_name" in
      let* lane_id = nonblank_field fields "lane_id" in
      let* slot_id = nonblank_field fields "slot_id" in
      let* actor = nonblank_field fields "updated_by" in
      let+ changed_at = nonblank_field fields "updated_at" in
      { keeper_name; lane_id; slot_id; actor; changed_at }
  | _ -> Error "keeper exact-lane preference must be an object"
;;

let parse_rows rows =
  let rec loop owners kept = function
    | [] -> Ok (List.rev kept)
    | json :: rest ->
      let open Result.Syntax in
      let* row = of_json json in
      let owner = row.keeper_name, row.lane_id in
      if Owners.mem owner owners
      then
        Error
          (Printf.sprintf
             "duplicate keeper exact-lane preference keeper=%S lane=%S"
             row.keeper_name
             row.lane_id)
      else loop (Owners.add owner owners) (row :: kept) rest
  in
  loop Owners.empty [] rows
;;

let all ~base_path =
  let file = path ~base_path in
  if not (Sys.file_exists file)
  then Ok []
  else
    match Safe_ops.read_json_file_safe file with
    | Error detail ->
      Error (Printf.sprintf "keeper exact-lane preferences read failed: %s" detail)
    | Ok (`List rows) -> parse_rows rows
    | Ok _ -> Error "keeper exact-lane preferences must be a list"
;;

let find ~base_path ~keeper_name ~lane_id =
  Result.map
    (List.find_opt (fun row ->
       String.equal row.keeper_name keeper_name
       && String.equal row.lane_id lane_id))
    (all ~base_path)
;;

let prefer ~slots ~slot_id_of ~preferred =
  match List.partition (fun slot -> String.equal (slot_id_of slot) preferred) slots with
  | [], _ ->
    Error
      (Printf.sprintf
         "this Keeper is set to use slot %S first, which this lane does not offer. The lane offers: %s"
         preferred
         (match List.map slot_id_of slots with
          | [] -> "nothing"
          | offered -> String.concat ", " offered))
  | chosen, rest -> Ok (chosen @ rest)
;;

let apply ~base_path ~keeper_name ~lane_id
      (resolved : Runtime_exact_output_registry.resolved_lane)
  =
  let open Result.Syntax in
  let* preference = find ~base_path ~keeper_name ~lane_id in
  match preference with
  | None -> Ok resolved
  | Some preference ->
    let+ selected_slots =
      prefer
        ~slots:resolved.selected_slots
        ~slot_id_of:(fun (slot : Runtime_exact_output_registry.selected_slot) ->
          slot.slot_id)
        ~preferred:preference.slot_id
    in
    { resolved with Runtime_exact_output_registry.selected_slots }
;;

let validate_admitted_slot ~lane_id ~slot_id =
  let open Result.Syntax in
  let* registry =
    Runtime_exact_output_registry.current ()
    |> Result.map_error Runtime_exact_output_registry.publication_error_to_string
  in
  let* resolved =
    Runtime_exact_output_registry.resolve_lane registry ~lane_id
    |> Result.map_error Runtime_exact_output_registry.lane_resolution_error_to_string
  in
  let+ (_ : Runtime_exact_output_registry.selected_slot list) =
    prefer
      ~slots:resolved.selected_slots
      ~slot_id_of:(fun (slot : Runtime_exact_output_registry.selected_slot) ->
        slot.slot_id)
      ~preferred:slot_id
  in
  ()
;;

let set (config : Workspace.config) ~actor ~keeper_name ~lane_id slot_id =
  let keeper_name = String.trim keeper_name in
  let lane_id = String.trim lane_id in
  let actor = String.trim actor in
  if String.equal keeper_name ""
  then Error "keeper_name must be non-empty"
  else if String.equal lane_id ""
  then Error "lane_id must be non-empty"
  else if String.equal actor ""
  then Error "actor must be non-empty"
  else
    let base_path = config.base_path in
    let open Result.Syntax in
    let* rows = all ~base_path in
    let changed_at = Masc_domain.now_iso () in
    let without =
      List.filter
        (fun row ->
           not
             (String.equal row.keeper_name keeper_name
              && String.equal row.lane_id lane_id))
        rows
    in
    let current =
      Option.map
        (fun slot_id ->
           { keeper_name
           ; lane_id
           ; slot_id = String.trim slot_id
           ; actor
           ; changed_at
           })
        slot_id
    in
    (match current with
     | Some row when String.equal row.slot_id "" ->
       Error "slot_id must be a non-empty string or null"
     | Some _ | None ->
       let rows =
         match current with
         | None -> without
         | Some row -> without @ [ row ]
       in
       let dir = Keeper_gate_path.dir ~base_path in
       Fs_compat.mkdir_p dir;
       (match
          Fs_compat.save_file_atomic
            (path ~base_path)
            (Yojson.Safe.pretty_to_string (`List (List.map to_json rows)))
        with
        | Error detail ->
          Error
            (Printf.sprintf
               "keeper exact-lane preference write failed: %s"
               detail)
        | Ok () ->
          Audit_log.log_action config ~agent_id:actor
            ~action:(Audit_log.Custom "keeper_exact_lane_preference_set")
            ~details:
              (`Assoc
                 [ "keeper_name", `String keeper_name
                 ; "lane_id", `String lane_id
                 ; ( "slot_id"
                   , match slot_id with
                     | Some slot_id -> `String slot_id
                     | None -> `Null )
                 ; "changed_at", `String changed_at
                 ; "actor", `String actor
                 ])
            ~outcome:Audit_log.Success ();
          Ok current))
;;
