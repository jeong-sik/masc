module Registry = Keeper_runtime_setting_registry

type change =
  { row : Registry.setting
  ; table : string
  ; key : string
  ; value : Toml_line_editor.value
  }

type error =
  | Unknown_key of string
  | Invalid_value of
      { toml_key : string
      ; expected : string
      }
  | Conflicting_changes of string
  | Table_not_reachable of string
  | Not_valid of string
  | Not_read_back of string
  | Configuration_rejected of string

exception Refused of error

let error_message = function
  | Unknown_key key ->
    Printf.sprintf "%S is not a setting that runtime.toml carries" key
  | Invalid_value { toml_key; expected } ->
    Printf.sprintf "%s takes %s" toml_key expected
  | Conflicting_changes key ->
    Printf.sprintf "%s was given twice, so nothing was written" key
  | Table_not_reachable table ->
    Printf.sprintf
      "%s is written as an inline table or as dotted keys at the top of \
       runtime.toml, which this editor does not edit, so nothing was written. \
       Write it as a [%s] table and run this again"
      table
      table
  | Not_valid detail ->
    "runtime.toml would not load after this change, so nothing was written: "
    ^ detail
  | Not_read_back key ->
    Printf.sprintf
      "%s is not read back with the requested value after the edit, so nothing \
       was written: the line editor and the loader disagree about where it is"
      key
  | Configuration_rejected detail -> "the commit was refused: " ^ detail
;;

let toml_key { table; key; _ } = table ^ "." ^ key
let requires_restart { row; _ } = Registry.requires_restart row

(* [Toml_line_editor] edits a key inside one table, so a registry key has to be
   [<table>.<key>]. A test holds every row to that shape. *)
let split_toml_key toml_key =
  match String.split_on_char '.' toml_key with
  | [ table; key ] -> table, key
  | _ -> invalid_arg (Printf.sprintf "registry key %S is not <table>.<key>" toml_key)
;;

let all_digits text =
  (not (String.equal text ""))
  && String.for_all (function '0' .. '9' -> true | _ -> false) text
;;

let parse_boolean = function
  | "true" -> Some (Toml_line_editor.Bool true)
  | "false" -> Some (Toml_line_editor.Bool false)
  | _ -> None
;;

let parse_integer raw =
  let digits =
    if String.starts_with ~prefix:"-" raw
    then String.sub raw 1 (String.length raw - 1)
    else raw
  in
  if all_digits digits
  then Option.map (fun number -> Toml_line_editor.Int number) (int_of_string_opt raw)
  else None
;;

(* Decimal spelling only. [float_of_string_opt] also reads hexadecimal, [nan],
   [inf] and digits separated by underscores, none of which a TOML float line
   written by this tool should come from. *)
let parse_float raw =
  let decimal = function
    | '0' .. '9' | '.' | '-' | '+' | 'e' | 'E' -> true
    | _ -> false
  in
  if (not (String.equal raw "")) && String.for_all decimal raw
  then (
    match float_of_string_opt raw with
    | Some number when Float.is_finite number -> Some (Toml_line_editor.Float number)
    | Some _ | None -> None)
  else None
;;

let parse_value (kind : Registry.value_kind) raw =
  match kind with
  | Registry.Boolean -> parse_boolean raw
  | Registry.Integer -> parse_integer raw
  | Registry.Float -> parse_float raw
  | Registry.String -> Some (Toml_line_editor.String raw)
;;

let expected_of_kind : Registry.value_kind -> string = function
  | Registry.Boolean -> "true or false"
  | Registry.Integer -> "a whole number"
  | Registry.Float -> "a decimal number"
  | Registry.String -> "text"
;;

let parse ~key ~value =
  match Registry.find_by_toml_key key with
  | None -> Error (Unknown_key key)
  | Some row ->
    (match parse_value row.Registry.value_kind value with
     | None ->
       Error
         (Invalid_value
            { toml_key = key; expected = expected_of_kind row.Registry.value_kind })
     | Some parsed ->
       let table, name = split_toml_key key in
       Ok { row; table; key = name; value = parsed })
;;

let conflicting changes =
  let rec loop seen = function
    | [] -> None
    | change :: rest ->
      let key = toml_key change in
      if List.mem key seen then Some key else loop (key :: seen) rest
  in
  loop [] changes
;;

let apply_change contents { table; key; value; _ } =
  match value with
  | Toml_line_editor.Bool flag ->
    Toml_line_editor.edit_table_bool contents ~path:table ~key ~value:flag
  | Toml_line_editor.Int number ->
    Toml_line_editor.edit_table_int contents ~path:table ~key ~value:number
  | Toml_line_editor.Float number ->
    Toml_line_editor.edit_table_float contents ~path:table ~key ~value:number
  | Toml_line_editor.String text ->
    Toml_line_editor.edit_table_scalar contents ~path:table ~key ~value:(Some text)
;;

(* A table reached by dotted keys at the root, or written as an inline table,
   has no header for the line editor to find. It would open a header beside it,
   which TOML 1.0 forbids and Otoml accepts for dotted keys, so the file would
   commit and then fail a strict reader. A table that only has sub-tables
   ([sandbox.network] and no [sandbox]) is not this case: a header for it can
   be opened. *)
let defined_without_a_header contents ~table =
  match Keeper_toml_loader.parse_toml contents with
  | Error _ -> false (* a syntax error is the validation's to report *)
  | Ok doc ->
    let is_direct key =
      String.equal key table
      ||
      match String.split_on_char '.' key with
      | [ owner; _ ] -> String.equal owner table
      | _ -> false
    in
    let has_keys = List.exists (fun (key, _) -> is_direct key) doc in
    let lines, _ = Toml_line_editor.split_lines contents in
    has_keys && not (List.exists (Toml_line_editor.is_table ~path:table) lines)
;;

(* The keys this tool changed that the loader refuses in this text. Other keys
   are not this tool's to judge: an unrelated broken table is the commit's to
   refuse, and it says which. *)
let problems_of_changed_keys text changes =
  match Keeper_runtime_config.validate_source_text text with
  | Error message -> Error message
  | Ok report ->
    let changed = List.map toml_key changes in
    let is_refused (issue : Keeper_runtime_config.validation_issue) =
      match issue.severity with
      | Keeper_runtime_config.Error -> List.mem issue.Keeper_runtime_config.key changed
      | Keeper_runtime_config.Warning -> false
    in
    Ok
      (report.Keeper_runtime_config.issues
       |> List.filter is_refused
       |> List.map (fun (issue : Keeper_runtime_config.validation_issue) ->
         Printf.sprintf "%s: %s" issue.Keeper_runtime_config.key issue.detail))
;;

let read_back doc ({ value; _ } as change) =
  let dotted = toml_key change in
  match value with
  | Toml_line_editor.Bool flag ->
    Option.equal Bool.equal (Keeper_toml_loader.toml_bool_opt doc dotted) (Some flag)
  | Toml_line_editor.Int number ->
    Option.equal Int.equal (Keeper_toml_loader.toml_int_opt doc dotted) (Some number)
  | Toml_line_editor.Float number ->
    Option.equal Float.equal (Keeper_toml_loader.toml_float_opt doc dotted) (Some number)
  | Toml_line_editor.String text ->
    Option.equal String.equal (Keeper_toml_loader.toml_string_opt doc dotted) (Some text)
;;

(* The edited text has to read back as the requested settings before it is
   written. Nothing reads these keys until the server starts, so a value the
   loader refuses, or one the line editor put where the loader does not look,
   would stay quiet until a restart. *)
let checked contents changes =
  List.iter
    (fun change ->
       if defined_without_a_header contents ~table:change.table
       then raise (Refused (Table_not_reachable change.table)))
    changes;
  (* Keep the original line, including its trailing comment and spelling, when
     the loader already reads the requested value. Different changes address
     different keys, so the original document suffices for this comparison. *)
  let original = Result.to_option (Keeper_toml_loader.parse_toml contents) in
  let updated =
    List.fold_left
      (fun text change ->
         match original with
         | Some doc when read_back doc change -> text
         | Some _ | None -> apply_change text change)
      contents
      changes
  in
  (match problems_of_changed_keys updated changes with
   | Error message -> raise (Refused (Not_valid message))
   | Ok (_ :: _ as problems) ->
     raise (Refused (Not_valid (String.concat "; " problems)))
   | Ok [] -> ());
  (match Keeper_toml_loader.parse_toml updated with
   | Error message -> raise (Refused (Not_valid message))
   | Ok doc ->
     List.iter
       (fun change ->
          if not (read_back doc change)
          then raise (Refused (Not_read_back (toml_key change))))
       changes);
  updated
;;

let apply ~runtime_config_path changes =
  match changes with
  | [] -> Ok false
  | _ :: _ ->
    (match conflicting changes with
     | Some key -> Error (Conflicting_changes key)
     | None ->
       let changed = ref false in
       let edit contents =
         let updated = checked contents changes in
         changed := not (String.equal contents updated);
         updated
       in
       (match Runtime.edit_config_text ~runtime_config_path edit with
        | Ok (_ : Runtime.config_commit_receipt) -> Ok !changed
        | Error detail -> Error (Configuration_rejected detail)
        | exception Refused error -> Error error))
;;
