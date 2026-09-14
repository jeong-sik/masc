module Validation = Masc.Lane_addon_action
type field = {path:string list; schema:Yojson.Safe.t; required:bool; value:Yojson.Safe.t option}
type t = {schema:Yojson.Safe.t;fields:field list;cursor:int;draft:string option;reviewing:bool;
          array_editor:array_editor option}
and array_editor = {item_schema:Yojson.Safe.t;items:Yojson.Safe.t list;item_cursor:int;
                    child:(int option * t) option}
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
        | Some value -> Some value | None -> if required then member "const" schema else None in
      [{path;schema;required;value}]
let create ~schema ~initial =
  let* () = Validation.validate_value_schema schema in
  let fields = fields ~initial ~required:true [] schema in
  Ok {schema;fields;cursor=0;draft=None;reviewing=false;array_editor=None}
let rec put path value root = match path with
  | [] -> value
  | key :: rest ->
      let fields = match root with `Assoc fields -> fields | _ -> [] in
      let child = Option.value ~default:(`Assoc []) (List.assoc_opt key fields) in
      `Assoc ((key,put rest value child) :: List.remove_assoc key fields)
(* Populate required structure only inside objects already present. Optional
   objects become present through explicit field input, never a nested const. *)
let rec complete schema input =
  match member "const" schema,member "type" schema,member "properties" schema,input with
  | None,Some (`String "object"),Some (`Assoc properties),`Assoc values ->
      let required = match member "required" schema with Some (`List names) -> names | _ -> [] in
      `Assoc (List.filter_map (fun (key,child) ->
        let value = match List.assoc_opt key values with
          | Some value -> Some value
          | None when List.mem (`String key) required ->
              (match member "const" child with
               | Some value -> Some value
               | None when member "type" child=Some (`String "object") -> Some (`Assoc [])
               | None -> None)
          | None -> None in
        Option.map (fun value -> key,complete child value) value) properties)
  | _ -> input
let replace form value = {form with fields=List.mapi (fun i (field : field) ->
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
  let* () = if Option.is_some form.array_editor then Error "Finish or cancel the array editor first" else Ok () in
  let* form = commit form in
  let result = List.fold_left (fun root (field : field) ->
    Option.fold ~none:root ~some:(fun value -> put field.path value root) field.value)
      (`Assoc []) form.fields |> complete form.schema in
  Validation.validate_value ~schema:form.schema ~name:"Lane input" result
let editable (field : field) = match field.value with
  | None -> "" | Some (`String text) -> text | Some value -> Yojson.Safe.to_string value
let object_items schema =
  match choices schema,member "type" schema,member "items" schema with
  | None,Some (`String "array"),Some item_schema
    when member "type" item_schema=Some (`String "object") && Option.is_none (choices item_schema) -> Some item_schema
  | _ -> None
let rec insert_text ~text form =
  if form.reviewing then form else
  match form.array_editor with
  | Some ({child=Some (index,child);_} as editor) ->
      {form with array_editor=Some {editor with child=Some (index,insert_text ~text child)}}
  | Some _ -> form
  | None -> match List.nth_opt form.fields form.cursor with
    | None -> form
    | Some field when Option.is_some (choices field.schema) -> form
    | Some field ->
        {form with draft=Some (Option.value ~default:(editable field) form.draft ^ text)}
let rec handle ~key form =
  match form.array_editor with
  | Some editor -> handle_array ~key form editor
  | None -> handle_field ~key form
and handle_field ~key form =
  let selected = List.nth_opt form.fields form.cursor in
  match key with
  | "esc" when form.reviewing -> Ok (Updated {form with reviewing=false})
  | "esc" -> Ok Cancel
  | "\r" | "\n" | "enter" when form.reviewing -> Result.map (fun json -> Submit json) (value form)
  | "\019" -> let* form = commit form in let* _ = value form in Ok (Updated {form with reviewing=true})
  | _ when form.reviewing -> Ok (Updated form)
  | "\005" ->
      let* form = commit form in
      (match List.nth_opt form.fields form.cursor with
       | Some field ->
           (match object_items field.schema with
            | None -> Error "This field uses direct text or JSON input"
            | Some item_schema ->
                let* items = match field.value with None -> Ok [] | Some (`List items) -> Ok items
                  | Some _ -> Error "Array value must be an array" in
                Ok (Updated {form with array_editor=Some {item_schema;items;item_cursor=0;child=None}}))
       | None -> Error "No selected array field")
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
and handle_array ~key form editor =
  let update editor = Ok (Updated {form with array_editor=Some editor}) in
  match editor.child with
  | Some (index,child) ->
      let* event = handle ~key child in
      (match event with
       | Cancel -> update {editor with child=None}
       | Updated child -> update {editor with child=Some (index,child)}
       | Submit value ->
           let items,item_cursor = match index with
             | None -> editor.items @ [value],List.length editor.items
             | Some index -> List.mapi (fun i old -> if i=index then value else old) editor.items,index in
           update {editor with items;item_cursor;child=None})
  | None ->
      match key with
      | "esc" -> Ok (Updated {form with array_editor=None})
      | "a" -> let* child = create ~schema:editor.item_schema ~initial:(`Assoc []) in
          update {editor with child=Some (None,child)}
      | "e" | "enter" | "\r" | "\n" ->
          (match List.nth_opt editor.items editor.item_cursor with
           | None -> Error "Add an item first (a)"
           | Some initial -> let* child = create ~schema:editor.item_schema ~initial in
               update {editor with child=Some (Some editor.item_cursor,child)})
      | "d" ->
          let items = List.filteri (fun index _ -> index<>editor.item_cursor) editor.items in
          update {editor with items;item_cursor=max 0 (min editor.item_cursor (List.length items-1))}
      | "j" | "down" | "k" | "up" ->
          let delta = if key="j" || key="down" then 1 else -1 in
          update {editor with item_cursor=max 0 (min (List.length editor.items-1) (editor.item_cursor+delta))}
      | "\019" ->
          let* field = match List.nth_opt form.fields form.cursor with Some field -> Ok field
            | None -> Error "No selected array field" in
          let* value = Validation.validate_value ~schema:field.schema ~name:(String.concat "." field.path) (`List editor.items) in
          Ok (Updated (replace {form with array_editor=None} (Some value)))
      | _ -> update editor
let rec lines form =
  match form.array_editor with
  | Some editor ->
      let name = match List.nth_opt form.fields form.cursor with
        | Some field -> String.concat "." field.path | None -> "Array" in
      (match editor.child with
       | Some (index,child) ->
           (name ^ (match index with None -> " · New item" | Some index -> Printf.sprintf " · Edit item %d" (index+1)))
           :: "Item review saves into this local array; it does not submit an action." :: lines child
       | None ->
           [name ^ " · Array items";"a:add  e/Enter:edit  d:remove  j/k:select  Ctrl-S:apply array  Esc:discard array edits";
            Printf.sprintf "%d items · applying validates minItems/maxItems" (List.length editor.items)] @
           (match List.nth_opt editor.items editor.item_cursor with
            | None -> ["No items. a adds an explicit item."]
            | Some value -> Printf.sprintf "Selected item %d/%d" (editor.item_cursor+1) (List.length editor.items)
                :: String.split_on_char '\n' (Yojson.Safe.pretty_to_string value)))
  | None ->
  if form.reviewing then
    ["Review input · Enter:submit once · Esc:edit · PageUp/PageDown:scroll"] @
      (match value form with Ok value -> String.split_on_char '\n' (Yojson.Safe.pretty_to_string value) | Error error -> [error])
  else ["Tab/Up/Down:field · Left/Right:choice · Ctrl-E:array items · Ctrl-U:unset · Ctrl-S:review · Esc:cancel";
        Printf.sprintf "Field %d/%d · PageUp/PageDown:scroll" (form.cursor+1) (List.length form.fields)] @
    List.filter_map (fun (index,(field : field)) -> if index<>form.cursor then None else Some (
      let name = match member "title" field.schema with Some (`String title) -> title
        | _ -> String.concat "." field.path in
      (if index=form.cursor then "> " else "  ") ^ name ^ (if field.required then " *" else "") ^ ": " ^
      (match form.draft with
       | Some draft when index=form.cursor -> Yojson.Safe.to_string (`String draft)
       | _ -> Option.fold ~none:"(unset)" ~some:Yojson.Safe.to_string field.value)))
      (List.mapi (fun index (field : field) -> index,field) form.fields)
