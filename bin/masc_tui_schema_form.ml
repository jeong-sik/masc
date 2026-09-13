module Validation = Masc.Lane_addon_action
type field = {path:string list; schema:Yojson.Safe.t; required:bool; value:Yojson.Safe.t option}
type t = {schema:Yojson.Safe.t;fields:field list;cursor:int;draft:string option;reviewing:bool}
type event = Updated of t | Submit of Yojson.Safe.t | Cancel
let ( let* ) = Result.bind
let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let rec at path value = match path with
  | [] -> Some value
  | key :: rest -> Option.bind (member key value) (at rest)
let choices schema = match member "const" schema,member "enum" schema with
  | Some value,_ -> Some [value] | None,Some (`List values) -> Some values | _ -> None
let rec fields ~initial ~required path schema =
  match choices schema,member "type" schema,member "properties" schema with
  | None,Some (`String "object"),Some (`Assoc properties) when properties<>[] ->
      let names = match member "required" schema with Some (`List names) -> names | _ -> [] in
      List.concat_map (fun (key,schema) -> fields ~initial
        ~required:(required && List.mem (`String key) names) (path @ [key]) schema) properties
  | _ ->
      let value = match at path initial with
        | Some value -> Some value | None -> member "const" schema in
      [{path;schema;required;value}]
let create ~schema ~initial =
  let* () = Validation.validate_value_schema schema in
  let fields = fields ~initial ~required:true [] schema in
  Ok {schema;fields;cursor=0;draft=None;reviewing=false}
let rec put path value root = match path with
  | [] -> value
  | key :: rest ->
      let fields = match root with `Assoc fields -> fields | _ -> [] in
      let child = Option.value ~default:(`Assoc []) (List.assoc_opt key fields) in
      `Assoc ((key,put rest value child) :: List.remove_assoc key fields)
let rec skeleton schema =
  match member "type" schema,member "properties" schema with
  | Some (`String "object"),Some (`Assoc properties) ->
      let required = match member "required" schema with Some (`List names) -> names | _ -> [] in
      `Assoc (List.filter_map (fun (key,child) ->
        if List.mem (`String key) required && member "type" child=Some (`String "object")
        then Some (key,skeleton child) else None) properties)
  | _ -> `Assoc []
let replace form value = {form with fields=List.mapi (fun i field ->
  if i=form.cursor then {field with value} else field) form.fields;draft=None;reviewing=false}
let commit form = match form.draft,List.nth_opt form.fields form.cursor with
  | None,_ -> Ok form
  | Some draft,Some field ->
      let* value = if member "type" field.schema=Some (`String "string") then Ok (`String draft)
        else try Ok (Yojson.Safe.from_string draft) with Yojson.Json_error error -> Error error in
      let* value = Validation.validate_value ~schema:field.schema ~name:(String.concat "." field.path) value in
      Ok (replace form (Some value))
  | Some _,None -> Error "no selected form field"
let value form =
  let* form = commit form in
  let result = List.fold_left (fun root field ->
    Option.fold ~none:root ~some:(fun value -> put field.path value root) field.value)
      (skeleton form.schema) form.fields in
  Validation.validate_value ~schema:form.schema ~name:"Lane input" result
let editable field = match field.value with
  | None -> "" | Some (`String text) -> text | Some value -> Yojson.Safe.to_string value
let handle ~key form =
  let selected = List.nth_opt form.fields form.cursor in
  match key with
  | "esc" when form.reviewing -> Ok (Updated {form with reviewing=false})
  | "esc" -> Ok Cancel
  | "\r" | "\n" | "enter" when form.reviewing -> Result.map (fun json -> Submit json) (value form)
  | "\019" -> let* form = commit form in let* _ = value form in Ok (Updated {form with reviewing=true})
  | _ when form.reviewing -> Ok (Updated form)
  | "tab" | "\t" | "down" | "up" | "\r" | "\n" | "enter" ->
      let* form = commit form in
      let delta = if key="up" then -1 else 1 in
      Ok (Updated {form with cursor=max 0 (min (List.length form.fields-1) (form.cursor+delta))})
  | "left" | "right" ->
      (match selected with
       | None -> Ok (Updated form)
       | Some field ->
           let values = match choices field.schema with
             | Some values -> values
             | None when member "type" field.schema=Some (`String "boolean") -> [`Bool false;`Bool true]
             | None -> [] in
           (match values with
            | [] -> Ok (Updated form)
            | _ ->
                let index = Option.value ~default:(-1) (List.find_index (fun value -> Some value=field.value) values) in
                let next = (index + (if key="left" then List.length values-1 else 1)) mod List.length values in
                Ok (Updated (replace form (List.nth_opt values next)))))
  | "\021" -> Ok (Updated (replace form None))
  | "backspace" | "\127" | "\008" ->
      (match selected with None -> Ok (Updated form) | Some field ->
        let text = Option.value ~default:(editable field) form.draft in
        let rec previous i = if i>0 && Char.code text.[i] land 0xc0=0x80 then previous (i-1) else i in
        let text = if text="" then "" else String.sub text 0 (previous (String.length text-1)) in
        Ok (Updated {form with draft=Some text}))
  | text when text<>"" && (String.length text=1 && Char.code text.[0]>=32
      || Char.code text.[0]>=128) ->
      (match selected with None -> Ok (Updated form) | Some field ->
        if Option.is_some (choices field.schema) then Ok (Updated form)
        else Ok (Updated {form with draft=Some (Option.value ~default:(editable field) form.draft ^ text)}))
  | _ -> Ok (Updated form)
let lines form =
  if form.reviewing then
    ["Review input · Enter:submit once · Esc:edit · PageUp/PageDown:scroll"] @
      (match value form with Ok value -> String.split_on_char '\n' (Yojson.Safe.pretty_to_string value) | Error error -> [error])
  else ["Tab/Up/Down:field · Left/Right:choice · Ctrl-U:unset · Ctrl-S:review · Esc:cancel";
        Printf.sprintf "Field %d/%d · PageUp/PageDown:scroll" (form.cursor+1) (List.length form.fields)] @
    List.filter_map (fun (index,field) -> if index<>form.cursor then None else Some (
      let name = match member "title" field.schema with Some (`String title) -> title
        | _ -> String.concat "." field.path in
      (if index=form.cursor then "> " else "  ") ^ name ^ (if field.required then " *" else "") ^ ": " ^
      (if index=form.cursor && Option.is_some form.draft
       then Yojson.Safe.to_string (`String (Option.get form.draft))
       else Option.fold ~none:"(unset)" ~some:Yojson.Safe.to_string field.value)))
      (List.mapi (fun index field -> index,field) form.fields)
