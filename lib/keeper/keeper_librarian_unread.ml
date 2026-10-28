module Refusal = Keeper_librarian_input_refusal
module Window = Runtime_model_input_tail_window
open Result.Syntax

type source =
  | Atom of
      { trace_id : string
      ; history_start_boundary_line : int
      ; atom : int
      ; message_in_atom : int
      ; message_sha256 : string
      }
  | Official_turn of
      { turn_ref : Ids.Turn_ref.t
      ; boundary_line : int
      ; message_in_turn : int
      ; message_sha256 : string
      }

type t = { source : source; reasons : Refusal.t list }

let message_digest message =
  Agent_core.Checkpoint.message_to_json message |> Yojson.Safe.to_string
  |> Agent_core_sha256.digest_string |> Agent_core_sha256.to_hex

let validate_source source =
  let valid_digest = String_util.is_lowercase_sha256_hex in
  match source with
  | Atom {trace_id;history_start_boundary_line;atom;message_in_atom;message_sha256} ->
    if String.trim trace_id = "" || history_start_boundary_line < 1
       || atom < 0 || message_in_atom < 0 || not (valid_digest message_sha256)
    then Error "invalid unread atom message identity" else Ok ()
  | Official_turn {turn_ref;boundary_line;message_in_turn;message_sha256} ->
    if String.trim (Ids.Turn_ref.trace_id turn_ref) = ""
       || Ids.Turn_ref.absolute_turn turn_ref < 1 || boundary_line < 1
       || message_in_turn < 0 || not (valid_digest message_sha256)
    then Error "invalid unread official-turn message identity" else Ok ()

let validate {source;reasons} =
  let* () = if reasons <> [] && reasons = Refusal.union reasons [] then Ok ()
    else Error "unread message requires a nonempty canonical named refusal set" in
  validate_source source

module Atom_positions = Map.Make (struct type t = int * int let compare = compare end)

let atom_messages messages =
  let _, _, indexed = List.fold_left (fun (last, index, indexed) (message, label) ->
    match label with
    | Window.Pinned -> last, index, indexed
    | Window.Atom atom ->
      let index = if last = Some atom then index + 1 else 0 in
      Some atom, index, Atom_positions.add (atom, index) message indexed)
    (None, 0, Atom_positions.empty) (fst (Window.annotate messages)) in
  indexed

let sources_for_atom_range ~trace_id ~history_start_boundary_line ~start_atom ~end_atom ~messages =
  let _, count = Window.annotate messages in
  if start_atom < 0 || end_atom <= start_atom || end_atom > count then Error "invalid complete atom source range"
  else
    let sources = Atom_positions.bindings (atom_messages messages)
      |> List.filter_map (fun ((atom,message_in_atom),message) ->
        if atom >= start_atom && atom < end_atom then
          Some (Atom {trace_id;history_start_boundary_line;atom;message_in_atom;
            message_sha256=message_digest message}) else None) in
    let* () = List.fold_left (fun result source -> let* () = result in validate_source source) (Ok ()) sources in
    Ok sources

let for_atom ~trace_id ~history_start_boundary_line ~atom ~message_in_atom ~messages ~reasons =
  match Atom_positions.find_opt (atom, message_in_atom) (atom_messages messages) with
  | None -> Error "unread atom message is absent from the selected checkpoint"
  | Some message ->
    let value = {source=Atom {trace_id;history_start_boundary_line;atom;message_in_atom;
      message_sha256=message_digest message};reasons=Refusal.union reasons []} in
    let* () = validate value in Ok value

let for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages ~reasons =
  if message_in_turn < 0 then Error "negative official message index" else
  match List.nth_opt messages message_in_turn with
  | None -> Error "unread official message is absent from the selected turn"
  | Some message ->
    let value = {source=Official_turn {turn_ref;boundary_line;message_in_turn;
      message_sha256=message_digest message};reasons=Refusal.union reasons []} in
    let* () = validate value in Ok value

let source_to_json = function
    | Atom {trace_id;history_start_boundary_line;atom;message_in_atom;message_sha256} ->
      `Assoc ["kind", `String "atom"; "trace_id", `String trace_id;
        "history_start_boundary_line", `Int history_start_boundary_line;
        "atom", `Int atom; "message_in_atom", `Int message_in_atom;
        "message_sha256", `String message_sha256]
    | Official_turn {turn_ref;boundary_line;message_in_turn;message_sha256} ->
      `Assoc ["kind", `String "official_turn"; "turn_ref", Ids.Turn_ref.to_yojson turn_ref;
        "boundary_line", `Int boundary_line; "message_in_turn", `Int message_in_turn;
        "message_sha256", `String message_sha256]

let to_json {source;reasons} =
  `Assoc ["source", source_to_json source;
    "reasons", `List (List.map (fun cause -> `String (Refusal.to_string cause)) reasons)]

let exact keys fields =
  if List.sort String.compare keys = List.sort String.compare (List.map fst fields)
  then Ok () else Error "unexpected, duplicate or missing unread message fields"
let string key fields = match List.assoc_opt key fields with
  | Some (`String value) -> Ok value | _ -> Error ("unread message field is not a string: " ^ key)
let integer key fields = match List.assoc_opt key fields with
  | Some (`Int value) -> Ok value | _ -> Error ("unread message field is not an integer: " ^ key)

let decode_source = function
  | `Assoc fields ->
    let* kind = string "kind" fields in
    (match kind with
     | "atom" ->
       let* () = exact ["kind";"trace_id";"history_start_boundary_line";"atom";
         "message_in_atom";"message_sha256"] fields in
       let* trace_id = string "trace_id" fields in
       let* history_start_boundary_line = integer "history_start_boundary_line" fields in
       let* atom = integer "atom" fields in
       let* message_in_atom = integer "message_in_atom" fields in
       let* message_sha256 = string "message_sha256" fields in
       Ok (Atom {trace_id;history_start_boundary_line;atom;message_in_atom;message_sha256})
     | "official_turn" ->
       let* () = exact ["kind";"turn_ref";"boundary_line";"message_in_turn";"message_sha256"] fields in
       let* turn_ref = Ids.Turn_ref.of_yojson (List.assoc "turn_ref" fields) in
       let* boundary_line = integer "boundary_line" fields in
       let* message_in_turn = integer "message_in_turn" fields in
       let* message_sha256 = string "message_sha256" fields in
       Ok (Official_turn {turn_ref;boundary_line;message_in_turn;message_sha256})
     | _ -> Error "unknown unread source kind")
  | _ -> Error "unread source must be an object"

let source_of_json json =
  let* source = decode_source json in
  let* () = validate_source source in
  Ok source

let of_json = function
  | `Assoc fields ->
    let* () = exact ["source";"reasons"] fields in
    let* source = source_of_json (List.assoc "source" fields) in
    let* reasons = match List.assoc "reasons" fields with
      | `List causes -> List.fold_left (fun parsed json ->
          let* parsed = parsed in
          match json with
          | `String token -> (match Refusal.of_string token with
              | Some reason -> Ok (reason :: parsed) | None -> Error "unknown unread refusal cause")
          | _ -> Error "unread refusal cause must be a string") (Ok []) causes
          |> Result.map List.rev
      | _ -> Error "unread reasons must be a list" in
    let value = {source;reasons} in
    let* () = validate value in Ok value
  | _ -> Error "unread message must be an object"

let source_key {source;_} = match source with
  | Atom {trace_id;history_start_boundary_line;atom;message_in_atom;_} ->
    `Atom (trace_id, history_start_boundary_line, atom, message_in_atom)
  | Official_turn {turn_ref;boundary_line;message_in_turn;_} ->
    `Official (Ids.Turn_ref.trace_id turn_ref, Ids.Turn_ref.absolute_turn turn_ref,
      boundary_line, message_in_turn)

module Source_key = struct
  type t = [ `Atom of string * int * int * int | `Official of string * int * int * int ]
  let compare = compare
end
module Source_keys = Set.Make (Source_key)

let validate_set values =
  let rec loop previous = function
    | [] -> Ok ()
    | value :: rest ->
      let* () = validate value in
      let key = source_key value in
      if Source_keys.mem key previous then Error "duplicate unread message source coordinates"
      else loop (Source_keys.add key previous) rest in
  loop Source_keys.empty values

let list_to_json values = `List (List.map to_json values)
let list_of_json = function
  | `List entries ->
    let* values = List.fold_left (fun parsed entry ->
      let* values = parsed in let* value = of_json entry in Ok (value :: values)) (Ok []) entries
      |> Result.map List.rev in
    let* () = validate_set values in Ok values
  | _ -> Error "unread messages must be a list"

let validate_atom_bounds ~trace_id ~history_start_boundary_line ~end_atom values =
  let* () = validate_set values in
  List.fold_left (fun checked {source;_} ->
    let* () = checked in
    match source with
    | Atom source ->
      if String.equal source.trace_id trace_id
         && source.history_start_boundary_line = history_start_boundary_line
         && source.atom < end_atom then Ok ()
      else Error "unread message is outside the snapshot history generation or end"
    | Official_turn _ -> Error "official-turn unread message is not checkpoint coverage")
    (Ok ()) values

let validate_atom_history ~trace_id ~history_start_boundary_line ~end_atom ~messages values =
  let* () = validate_atom_bounds ~trace_id ~history_start_boundary_line ~end_atom values in
  if values = [] then Ok () else
  let indexed = atom_messages messages in
  List.fold_left (fun checked {source;_} ->
    let* () = checked in
    match source with
    | Atom {atom;message_in_atom;message_sha256;_} ->
      (match Atom_positions.find_opt (atom, message_in_atom) indexed with
       | Some message when String.equal (message_digest message) message_sha256 -> Ok ()
       | Some _ | None -> Error "unread message does not match its exact checkpoint source")
    | Official_turn _ -> Error "official-turn unread message is not checkpoint coverage")
    (Ok ()) values

module Source_map = Map.Make (Source_key)

let merge previous added =
  let* () = validate_set previous in
  let* () = validate_set added in
  let* indexed = List.fold_left (fun parsed value ->
    let* indexed = parsed in
    let key = source_key value in
    match Source_map.find_opt key indexed with
    | None -> Ok (Source_map.add key value indexed)
    | Some prior ->
      if prior.source <> value.source then Error "unread coordinates name conflicting original hashes"
      else Ok (Source_map.add key
        {prior with reasons=Refusal.union prior.reasons value.reasons} indexed))
    (Ok Source_map.empty) (previous @ added) in
  Ok (List.map snd (Source_map.bindings indexed))
