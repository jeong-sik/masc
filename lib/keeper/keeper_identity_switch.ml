(** See keeper_identity_switch.mli. *)

type off_row = {
  keeper_name : string;
  provider_id : string;
  actor : string;
  changed_at : string;
}

let path ~base_path =
  Filename.concat
    (Filename.concat (Common.masc_dir_from_base_path ~base_path) "identity")
    "disabled.json"
;;

let row_json row =
  `Assoc
    [ "keeper_name", `String row.keeper_name
    ; "provider_id", `String row.provider_id
    ; "updated_by", `String row.actor
    ; "updated_at", `String row.changed_at
    ]
;;

let row_of_json = function
  | `Assoc fields ->
    let string_field key =
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None ->
        Error (Printf.sprintf "identity switch row is missing %s" key)
    in
    (match string_field "keeper_name", string_field "provider_id" with
     | Error detail, _ | _, Error detail -> Error detail
     | Ok keeper_name, Ok provider_id ->
       let or_unknown = function Ok value -> value | Error _ -> "" in
       Ok
         { keeper_name
         ; provider_id
         ; actor = or_unknown (string_field "updated_by")
         ; changed_at = or_unknown (string_field "updated_at")
         })
  | _ -> Error "identity switch row must be an object"
;;

(* An unreadable file is an error rather than an empty list. Reading it as
   "nothing is switched off" would hand a keeper the tools an operator turned
   off, and an unreadable file must not be the quiet way back to them. *)
let disabled_rows ~base_path =
  let file = path ~base_path in
  if not (Sys.file_exists file)
  then Ok []
  else
    match Safe_ops.read_json_file_safe file with
    | Error detail ->
      Error (Printf.sprintf "identity switch store read failed: %s" detail)
    | Ok (`List rows) ->
      List.fold_left
        (fun acc row ->
          match acc, row_of_json row with
          | Error detail, _ -> Error detail
          | Ok _, Error detail -> Error detail
          | Ok kept, Ok parsed -> Ok (parsed :: kept))
        (Ok [])
        rows
      |> Result.map List.rev
    | Ok _ -> Error "identity switch store must be a list"
;;

let is_disabled ~base_path ~keeper_name ~provider_id =
  match disabled_rows ~base_path with
  | Error _ as error -> error
  | Ok rows ->
    Ok
      (List.exists
         (fun row ->
           String.equal row.keeper_name keeper_name
           && String.equal row.provider_id provider_id)
         rows)
;;

let disabled_providers_for_keeper ~base_path ~keeper_name =
  match disabled_rows ~base_path with
  | Error _ as error -> error
  | Ok rows ->
    Ok
      (List.filter_map
         (fun row ->
           if String.equal row.keeper_name keeper_name
           then Some row.provider_id
           else None)
         rows)
;;

let set (config : Workspace.config) ~actor ~keeper_name ~provider_id ~enabled =
  let base_path = config.base_path in
  match disabled_rows ~base_path with
  | Error _ as error -> error
  | Ok rows ->
    let currently_disabled =
      List.exists
        (fun row ->
          String.equal row.keeper_name keeper_name
          && String.equal row.provider_id provider_id)
        rows
    in
    let already_as_requested = enabled = not currently_disabled in
    if already_as_requested
    then Ok ()
    else (
      let changed_at = Masc_domain.now_iso () in
      let without =
        List.filter
          (fun row ->
            not
              (String.equal row.keeper_name keeper_name
               && String.equal row.provider_id provider_id))
          rows
      in
      (* Removing rather than storing a synonym for "on": the file is then
         also the list of switches an operator has actually thrown, and a
         screen showing it does not have to filter. *)
      let rows =
        if enabled
        then without
        else without @ [ { keeper_name; provider_id; actor; changed_at } ]
      in
      let file = path ~base_path in
      Fs_compat.mkdir_p (Filename.dirname file);
      match
        Fs_compat.save_file_atomic
          file
          (Yojson.Safe.pretty_to_string (`List (List.map row_json rows)))
      with
      | Error detail ->
        Error (Printf.sprintf "identity switch store write failed: %s" detail)
      | Ok () ->
        Audit_log.log_action
          config
          ~agent_id:actor
          ~action:(Audit_log.Custom "keeper_identity_switch_set")
          ~details:
            (`Assoc
               [ "keeper_name", `String keeper_name
               ; "provider_id", `String provider_id
               ; "enabled", `Bool enabled
               ; "changed_at", `String changed_at
               ; "actor", `String actor
               ])
          ~outcome:Audit_log.Success
          ();
        Ok ())
;;
