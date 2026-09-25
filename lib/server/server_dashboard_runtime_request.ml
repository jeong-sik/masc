(** Dashboard runtime configuration request decoding. *)

type runtime_route_lane =
  | Runtime_default
  | Runtime_media_failover
  | Runtime_named_lane of string
      (** A name {!Runtime.resolve_assignment} knows: a declared
          [\[runtime.lanes."<id>"\]] lane, whose name is the operator's own
          (RFC-0457), or a configured runtime id, whose order a [set] writes as
          a lane of that id. *)
  | Runtime_exact_lane of Runtime.exact_lane
      (** A [\[runtime.exact_output_lanes.<id>\]] walk order, one of the
          closed set {!Runtime.exact_lane} (verifier_exact, librarian_exact,
          ...). The "exact/" prefix keeps the name space disjoint from
          conversation-lane names. *)

let exact_route_prefix = "exact/"

let runtime_route_lane_to_string = function
  | Runtime_default -> "default"
  | Runtime_media_failover -> "media_failover"
  | Runtime_named_lane lane_id -> lane_id
  | Runtime_exact_lane lane -> exact_route_prefix ^ Standalone_lane.to_id lane

(* Which name space a route string belongs to, before anything is resolved.
   Creating or renaming a lane asks only this: the name must land in the
   conversation-lane space, whether or not a lane of that name exists yet. *)
type route_name_space =
  | Default_route
  | Media_failover_route
  | Exact_route of string
  | Lane_route

let route_name_space = function
  | "default" -> Default_route
  | "media_failover" -> Media_failover_route
  | lane when String.starts_with ~prefix:exact_route_prefix lane ->
    let prefix_length = String.length exact_route_prefix in
    Exact_route (String.sub lane prefix_length (String.length lane - prefix_length))
  | _ -> Lane_route

(* A name is admitted when the runtime resolver knows it: a declared lane,
   whatever its name, or a configured runtime id. [resolve_assignment] answers
   [`Missing] for anything else, so a typo is refused with the name it could
   not find. An exact-output lane name never reaches that resolver: the prefix
   names which name space the rest of the string belongs to, and the name must
   be one of the exact lanes the server runs ({!Standalone_lane.of_id}), so
   a typo is refused here instead of becoming a table nothing reads. *)
let parse_runtime_route_lane lane =
  match route_name_space lane with
  | Default_route -> Ok Runtime_default
  | Media_failover_route -> Ok Runtime_media_failover
  | Exact_route name ->
    (match Standalone_lane.of_id name with
     | Some exact -> Ok (Runtime_exact_lane exact)
     | None ->
       Error
         (Printf.sprintf
            "unknown exact-output lane: %s (expected one of %s)"
            name
            (String.concat ", " (List.map Standalone_lane.to_id Standalone_lane.all))))
  | Lane_route ->
    (match Runtime.resolve_assignment lane with
     | `Lane _ -> Ok (Runtime_named_lane lane)
     | `Unavailable missing ->
       Error ("Capability catalog entry unavailable: " ^ Runtime.missing_catalog_model_to_string missing)
     | `Missing ->
       Error
         (Printf.sprintf
            "unknown runtime routing lane: %s (not a declared lane or a \
             configured runtime)"
            lane))

type runtime_route_body =
  | Runtime_route_runtime_id of runtime_route_lane * string option
  | Runtime_route_runtime_ids of runtime_route_lane * string list
  | Runtime_route_lane_created of string * string list
  | Runtime_route_lane_removed of string
  | Runtime_route_lane_renamed of string * string
  | Runtime_route_exact_slot_appended of Runtime.exact_lane * string
  | Runtime_route_exact_slot_dropped of Runtime.exact_lane * string
  | Runtime_route_exact_slot_moved of
      Runtime.exact_lane * string * Runtime.exact_slot_move

(* What a routing body asks of a lane. [set], the action a body without one
   names, replaces the order of a lane or route the resolver already knows.
   [create] declares a lane under a name nothing resolves yet, which [set]
   refuses so that a typo cannot become a lane. [remove] deletes a declared
   lane. [append] adds one slot to the end of an exact-output lane as the file
   declares it, read under the write lock: a caller that sent the whole order
   could only send the slots the registry admitted, and a [set] of those
   would delete every declared slot the registry dropped. *)
type runtime_lane_action =
  | Lane_set
  | Lane_create
  | Lane_remove
  | Lane_rename
  | Lane_append
  | Lane_drop
  | Lane_move

let parse_runtime_lane_action json =
  match Json_util.assoc_member_opt "action" json with
  | None | Some `Null -> Ok Lane_set
  | Some (`String "set") -> Ok Lane_set
  | Some (`String "create") -> Ok Lane_create
  | Some (`String "remove") -> Ok Lane_remove
  | Some (`String "rename") -> Ok Lane_rename
  | Some (`String "append") -> Ok Lane_append
  | Some (`String "drop") -> Ok Lane_drop
  | Some (`String "move") -> Ok Lane_move
  | Some (`String other) ->
    Error
      (Printf.sprintf
         "unknown lane action: %s (expected set, create, remove, rename, append, drop \
          or move)"
         other)
  | Some _ -> Error "action must be a string"

let required_string_field json name =
  match Json_util.assoc_member_opt name json with
  | Some (`String value) when not (String.equal (String.trim value) "") ->
    Ok (String.trim value)
  | Some (`String _) -> Error (name ^ " must not be empty")
  | Some _ -> Error (name ^ " must be a string")
  | None -> Error (name ^ " required")

let optional_string_field json name =
  match Json_util.assoc_member_opt name json with
  | None | Some `Null -> Ok None
  | Some (`String value) ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then Ok None else Ok (Some trimmed)
  | Some _ -> Error (name ^ " must be a string or null")

let required_string_array_field json name =
  match Json_util.assoc_member_opt name json with
  | Some (`List values) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest ->
        let trimmed = String.trim value in
        if String.equal trimmed ""
        then Error (name ^ " must not contain empty entries")
        else loop (trimmed :: acc) rest
      | _ :: _ -> Error (name ^ " must be an array of strings")
    in
    loop [] values
  | Some _ -> Error (name ^ " must be an array of strings")
  | None -> Error (name ^ " required")
;;

let parse_set_route_body json lane =
  match parse_runtime_route_lane lane with
  | Error _ as err -> err
  | Ok parsed_lane ->
    (match parsed_lane with
     | Runtime_named_lane _ | Runtime_media_failover | Runtime_exact_lane _ ->
       (match required_string_array_field json "runtime_ids" with
        | Error _ as err -> err
        | Ok runtime_ids -> Ok (Runtime_route_runtime_ids (parsed_lane, runtime_ids)))
     | Runtime_default ->
       (match optional_string_field json "runtime_id" with
        | Error _ as err -> err
        | Ok runtime_id -> Ok (Runtime_route_runtime_id (parsed_lane, runtime_id))))

(* A new lane's name must not read as one of the other routes this endpoint
   edits, an exact/ name included: a lane created under it could never be
   addressed again. Whether the file already declares the lane is decided
   under the write lock ({!Runtime.create_runtime_lane}). *)
let lane_name_of_new_name name =
  match route_name_space name with
  | Lane_route -> Ok name
  | Default_route | Media_failover_route | Exact_route _ ->
    Error (Printf.sprintf "%S names another route, not a lane" name)

let parse_create_route_body json lane =
  match lane_name_of_new_name lane with
  | Error _ as err -> err
  | Ok lane ->
    (match required_string_array_field json "runtime_ids" with
     | Error _ as err -> err
     | Ok runtime_ids -> Ok (Runtime_route_lane_created (lane, runtime_ids)))

(* A rename names the lane it renames and the name it takes. Both are read as
   routing labels: a new name that reads as one of the other routes this
   endpoint edits would be a lane nothing can address. *)
let parse_rename_route_body json lane =
  match parse_runtime_route_lane lane with
  | Ok (Runtime_named_lane lane_id) ->
    (match required_string_field json "to" with
     | Error _ as err -> err
     | Ok new_lane_id ->
       (match lane_name_of_new_name new_lane_id with
        | Error _ as err -> err
        | Ok new_lane_id -> Ok (Runtime_route_lane_renamed (lane_id, new_lane_id))))
  | Ok (Runtime_default | Runtime_media_failover | Runtime_exact_lane _) ->
    Error (Printf.sprintf "%S names another route, not a lane" lane)
  | Error _ as err -> err

let parse_remove_route_body lane =
  match parse_runtime_route_lane lane with
  | Ok (Runtime_named_lane lane_id) -> Ok (Runtime_route_lane_removed lane_id)
  | Ok (Runtime_default | Runtime_media_failover | Runtime_exact_lane _) ->
    Error (Printf.sprintf "%S names another route, not a lane" lane)
  | Error _ as err -> err

(* [drop] and [move] name one slot and let the writer read the declared order
   under the lock, for the reason [append] does: a caller can only see the
   slots the registry admitted, and an order rebuilt from that view deletes
   every declared slot the catalog rejected. *)
let parse_exact_slot_route_body json lane ~build ~verb =
  match parse_runtime_route_lane lane with
  | Ok (Runtime_exact_lane exact) ->
    (match required_string_field json "runtime_id" with
     | Error _ as err -> err
     | Ok runtime_id -> build exact runtime_id)
  | Ok (Runtime_default | Runtime_media_failover | Runtime_named_lane _) ->
    Error
      (Printf.sprintf
         "%S is not an exact-output lane; %s acts on a slot of exact/<name>"
         lane
         verb)
  | Error _ as err -> err

let parse_move_direction json =
  match Json_util.assoc_member_opt "direction" json with
  | Some (`String "up") -> Ok Runtime.Move_slot_up
  | Some (`String "down") -> Ok Runtime.Move_slot_down
  | Some (`String other) ->
    Error (Printf.sprintf "unknown direction: %s (expected up or down)" other)
  | Some _ -> Error "direction must be a string"
  | None -> Error "direction required"

let parse_append_route_body json lane =
  match parse_runtime_route_lane lane with
  | Ok (Runtime_exact_lane exact) ->
    (match required_string_field json "runtime_id" with
     | Error _ as err -> err
     | Ok runtime_id -> Ok (Runtime_route_exact_slot_appended (exact, runtime_id)))
  | Ok (Runtime_default | Runtime_media_failover | Runtime_named_lane _) ->
    Error (Printf.sprintf "%S is not an exact-output lane; append adds a slot to exact/<name>" lane)
  | Error _ as err -> err

let parse_runtime_route_body body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc _ as json ->
      (match required_string_field json "lane", parse_runtime_lane_action json with
       | (Error _ as err), _ -> err
       | Ok _, (Error _ as err) -> err
       | Ok lane, Ok Lane_set -> parse_set_route_body json lane
       | Ok lane, Ok Lane_create -> parse_create_route_body json lane
       | Ok lane, Ok Lane_remove -> parse_remove_route_body lane
       | Ok lane, Ok Lane_rename -> parse_rename_route_body json lane
       | Ok lane, Ok Lane_append -> parse_append_route_body json lane
       | Ok lane, Ok Lane_drop ->
         parse_exact_slot_route_body json lane ~verb:"drop" ~build:(fun exact runtime_id ->
           Ok (Runtime_route_exact_slot_dropped (exact, runtime_id)))
       | Ok lane, Ok Lane_move ->
         parse_exact_slot_route_body json lane ~verb:"move" ~build:(fun exact runtime_id ->
           match parse_move_direction json with
           | Error _ as err -> err
           | Ok move -> Ok (Runtime_route_exact_slot_moved (exact, runtime_id, move))))
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)

let parse_runtime_assignment_body body_str =
  try
    match Yojson.Safe.from_string body_str with
    | `Assoc _ as json ->
      (match required_string_field json "keeper_name" with
       | Error _ as err -> err
       | Ok keeper_name ->
         if not (Keeper_config.validate_name keeper_name)
         then Error (Printf.sprintf "invalid keeper name: %S" keeper_name)
         else (match optional_string_field json "runtime_id" with
          | Error _ as err -> err
          | Ok runtime_id ->
            (match Json_util.assoc_member_opt "expected_assignment_revision" json with
             | None -> Error "expected_assignment_revision required"
             | Some value ->
               Runtime.keeper_assignment_revision_of_yojson value
               |> Result.map (fun expected -> keeper_name, runtime_id, expected))))
    | _ -> Error "JSON object body required"
  with
  | Yojson.Json_error err -> Error ("invalid json: " ^ err)
