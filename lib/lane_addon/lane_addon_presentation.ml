type format = Text | Number | Boolean | Json
(* [row_action] comes before [reading] so an unannotated [lane_id] or [label]
   still means a reading's, as it did before row actions existed. *)
type row_action = {
  lane_id : string; label : string;
  fixed : (string * Yojson.Safe.t) list;
  from_row : (string * string list) list;
}
type reading = {
  lane_id : string; path : string list; label : string;
  unit : string option; format : format;
}
type t = { description : string option; readings : reading list; actions : row_action list }
type row_value = Present of Yojson.Safe.t | Absent | Wrong_shape
type reading_refusal = Field_absent | Field_wrong_shape | Format_mismatch
let empty = {description=None; readings=[]; actions=[]}
open Result.Syntax
let text = function
  | `String value when String.trim value <> ""
      && not (String.exists (fun c -> Char.code c < 32 || Char.code c = 127) value) -> Ok value
  | _ -> Error "presentation text must be non-blank and single-line"
let object_ allowed = function
  | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (key,_) -> List.mem key allowed) fields -> Ok fields
  | _ -> Error "unknown or duplicate presentation field"
let get fields key parse = match List.assoc_opt key fields with
  | Some value -> parse value | None -> Error ("missing presentation " ^ key)
let optional fields key = match List.assoc_opt key fields with
  | None | Some `Null -> Ok None | Some value -> Result.map Option.some (text value)
let rec array parse = function
  | `List [] -> Ok []
  | `List (value :: rest) -> let* value = parse value in
      let* rest = array parse (`List rest) in Ok (value :: rest)
  | _ -> Error "presentation requires an array"
let path value =
  let* path = array text value in
  if path=[] then Error "presentation path must not be empty" else Ok path
let reading value =
  let* fields = object_ ["lane_id";"path";"label";"unit";"format"] value in
  let* lane_id = get fields "lane_id" text in
  let* path = get fields "path" path in
  let* label = get fields "label" text in
  let* unit = optional fields "unit" in
  let* format = get fields "format" (function
    | `String "text" -> Ok Text | `String "number" -> Ok Number
    | `String "boolean" -> Ok Boolean | `String "json" -> Ok Json
    | _ -> Error "unknown presentation format") in
  Ok {lane_id;path;label;unit;format}
(* Members name top-level fields of the action object, so they follow the
   same non-blank single-line rule as other presentation text. *)
let members parse = function
  | `Assoc fields when List.length fields=List.length (List.sort_uniq String.compare (List.map fst fields)) ->
      let rec read acc = function
        | [] -> Ok (List.rev acc)
        | (name, value) :: rest ->
            let* name = text (`String name) in
            let* value = parse value in read ((name, value) :: acc) rest in
      read [] fields
  | _ -> Error "presentation action members require an object without duplicate names"
let row_action value =
  let* fields = object_ ["lane_id";"label";"fixed";"from_row"] value in
  let* lane_id = get fields "lane_id" text in
  let* label = get fields "label" text in
  let* fixed = get fields "fixed" (members Lane_addon_json.canonical) in
  let* from_row = get fields "from_row" (members path) in
  (* An action that reads nothing from its row is not a row action. *)
  let* () = if from_row=[] then Error "presentation action reads no value from the row" else Ok () in
  match List.find_opt (fun (name,_) -> List.mem_assoc name from_row) fixed with
  | Some (name,_) -> Error ("presentation action member is both fixed and read from the row: " ^ name)
  | None -> Ok {lane_id;label;fixed;from_row}
let has_duplicates compare values =
  List.length values <> List.length (List.sort_uniq compare values)
let of_json value =
  let* fields = object_ ["description";"readings";"actions"] value in
  let* description = optional fields "description" in
  let* readings = match List.assoc_opt "readings" fields with
    | None -> Ok [] | Some value -> array reading value in
  let* actions = match List.assoc_opt "actions" fields with
    | None -> Ok [] | Some value -> array row_action value in
  let compare_identity (l1, p1) (l2, p2) =
    let c = String.compare l1 l2 in
    if c <> 0 then c else List.compare String.compare p1 p2
  in
  let compare_label (l1, n1) (l2, n2) =
    let c = String.compare l1 l2 in if c <> 0 then c else String.compare n1 n2 in
  if has_duplicates compare_identity (List.map (fun (r : reading) -> r.lane_id,r.path) readings)
  then Error "duplicate presentation reading"
  else if has_duplicates compare_label (List.map (fun (a : row_action) -> a.lane_id,a.label) actions)
  then Error "duplicate presentation action label in one lane"
  else Ok {description;readings;actions}
let strings values = `List (List.map (fun s -> `String s) values)
let row_action_to_json (a : row_action) =
  `Assoc ["lane_id",`String a.lane_id; "label",`String a.label; "fixed",`Assoc a.fixed;
    "from_row",`Assoc (List.map (fun (name,path) -> name, strings path) a.from_row)]
(* [actions] is written only when a package declares one, so a package
   without row actions keeps the declaration revision it had before the key
   existed. *)
let to_json t =
  let optional = function None -> `Null | Some value -> `String value in
  `Assoc (["description",optional t.description; "readings",`List (List.map (fun (r : reading) ->
    `Assoc ["lane_id",`String r.lane_id;"path",strings r.path;
      "label",`String r.label;"unit",optional r.unit;"format",`String (match r.format with
        Text -> "text" | Number -> "number" | Boolean -> "boolean" | Json -> "json")]) t.readings)]
    @ (match t.actions with [] -> [] | actions -> ["actions",`List (List.map row_action_to_json actions)]))
let resolve path fields =
  let rec step value = function
    | [] -> Present value
    | key :: rest -> (match value with
      | `Assoc values -> (match List.assoc_opt key values with
        | Some value -> step value rest | None -> Absent)
      | _ -> Wrong_shape) in
  step fields path
let row_value path fields = match resolve path fields with
  | Present `Null -> Wrong_shape
  | (Present _ | Absent | Wrong_shape) as value -> value
let value (reading : reading) fields =
  let* value = match resolve reading.path fields with
    | Present value -> Ok value
    | Absent -> Error Field_absent
    | Wrong_shape -> Error Field_wrong_shape in
  match reading.format,value with
  | Text,`String _ | Number,(`Int _ | `Intlit _) | Boolean,`Bool _ | Json,_ -> Ok value
  | Number,`Float number when Float.is_finite number -> Ok value
  | (Text | Number | Boolean), _ -> Error Format_mismatch
