(** See keeper_gate_judge_slot.mli. *)

type t =
  { keeper_name : string
  ; slot_id : string
  ; actor : string
  ; changed_at : string
  }

let to_json row =
  `Assoc
    [ "keeper_name", `String row.keeper_name
    ; "slot_id", `String row.slot_id
    ; "updated_by", `String row.actor
    ; "updated_at", `String row.changed_at
    ]
;;

let of_json = function
  | `Assoc fields ->
    let required key =
      match List.assoc_opt key fields with
      | Some (`String value) when String.trim value <> "" -> Ok value
      | Some _ | None ->
        Error (Printf.sprintf "keeper judge preference is missing %s" key)
    in
    let optional key =
      match List.assoc_opt key fields with
      | Some (`String value) -> value
      | Some _ | None -> ""
    in
    (match required "keeper_name", required "slot_id" with
     | Ok keeper_name, Ok slot_id ->
       Ok
         { keeper_name
         ; slot_id
         ; actor = optional "updated_by"
         ; changed_at = optional "updated_at"
         }
     | Error detail, _ | _, Error detail -> Error detail)
  | _ -> Error "keeper judge preference must be an object"
;;

let all ~base_path =
  let file = Keeper_gate_path.keeper_judge_slots ~base_path in
  if not (Sys.file_exists file)
  then Ok []
  else
    match Safe_ops.read_json_file_safe file with
    | Error detail ->
      Error (Printf.sprintf "keeper judge preferences read failed: %s" detail)
    | Ok (`List rows) ->
      List.fold_left
        (fun acc row ->
          match acc, of_json row with
          | Error detail, _ -> Error detail
          | Ok _, Error detail -> Error detail
          | Ok kept, Ok parsed -> Ok (parsed :: kept))
        (Ok []) rows
      |> Result.map List.rev
    | Ok _ -> Error "keeper judge preferences must be a list"
;;

let find ~base_path ~keeper_name =
  Result.map
    (List.find_opt (fun row -> String.equal row.keeper_name keeper_name))
    (all ~base_path)
;;

let prefer ~slots ~slot_id_of ~preferred =
  match List.partition (fun slot -> String.equal (slot_id_of slot) preferred) slots with
  | [], _ ->
    Error
      (Printf.sprintf
         "this Keeper is set to be judged by %S, which this lane does not \
          offer. The lane offers: %s"
         preferred
         (match List.map slot_id_of slots with
          | [] -> "nothing"
          | offered -> String.concat ", " offered))
  | chosen, rest -> Ok (chosen @ rest)
;;

let set (config : Workspace.config) ~actor ~keeper_name slot_id =
  let base_path = config.base_path in
  match all ~base_path with
  | Error detail -> Error detail
  | Ok rows ->
    let changed_at = Masc_domain.now_iso () in
    let without =
      List.filter (fun row -> not (String.equal row.keeper_name keeper_name)) rows
    in
    (* Cleared rather than stored as a synonym for the lane's own order, so
       the file is also the list of Keepers somebody actually pointed
       somewhere. *)
    let current =
      Option.map
        (fun slot_id -> { keeper_name; slot_id; actor; changed_at })
        slot_id
    in
    let rows =
      match current with
      | None -> without
      | Some row -> without @ [ row ]
    in
    let dir = Keeper_gate_path.dir ~base_path in
    Fs_compat.mkdir_p dir;
    (match
       Fs_compat.save_file_atomic
         (Keeper_gate_path.keeper_judge_slots ~base_path)
         (Yojson.Safe.pretty_to_string (`List (List.map to_json rows)))
     with
     | Error detail ->
       Error (Printf.sprintf "keeper judge preference write failed: %s" detail)
     | Ok () ->
       Audit_log.log_action config ~agent_id:actor
         ~action:(Audit_log.Custom "keeper_gate_judge_slot_set")
         ~details:
           (`Assoc
              [ "keeper_name", `String keeper_name
              ; ( "slot_id"
                , match slot_id with
                  | Some slot_id -> `String slot_id
                  | None -> `Null )
              ; "changed_at", `String changed_at
              ; "actor", `String actor
              ])
         ~outcome:Audit_log.Success ();
       Ok current)
;;
