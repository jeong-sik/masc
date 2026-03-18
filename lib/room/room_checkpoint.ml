(** Room checkpoint and restore *)

type t = Yojson.Safe.t

let capture ~room_state ~tasks ~agents =
  `Assoc
    [ ("version", `Int 1)
    ; ("timestamp", `Float (Time_compat.now ()))
    ; ("room_state", room_state)
    ; ("tasks", tasks)
    ; ("agents", agents)
    ]

let get_field checkpoint key =
  match checkpoint with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let timestamp checkpoint =
  match get_field checkpoint "timestamp" with
  | Some (`Float f) -> f
  | _ -> 0.0

let room_state checkpoint = get_field checkpoint "room_state"
let tasks checkpoint = get_field checkpoint "tasks"
let agents checkpoint = get_field checkpoint "agents"

let to_string checkpoint =
  Yojson.Safe.to_string checkpoint

let of_string s =
  match Yojson.Safe.from_string s with
  | json ->
    (match get_field json "version" with
     | Some (`Int 1) -> Some json
     | _ -> None)
  | exception Yojson.Json_error _ -> None

(** Compare two JSON values, returning changed fields. *)
let diff a b =
  let fields_a = match a with `Assoc f -> f | _ -> [] in
  let fields_b = match b with `Assoc f -> f | _ -> [] in
  let changes = List.filter_map (fun (key, va) ->
    match List.assoc_opt key fields_b with
    | Some vb when Yojson.Safe.equal va vb -> None
    | Some vb -> Some (key, `Assoc [("before", va); ("after", vb)])
    | None -> Some (key, `Assoc [("before", va); ("after", `Null)])
  ) fields_a in
  let additions = List.filter_map (fun (key, vb) ->
    match List.assoc_opt key fields_a with
    | Some _ -> None
    | None -> Some (key, `Assoc [("before", `Null); ("after", vb)])
  ) fields_b in
  `Assoc (changes @ additions)
