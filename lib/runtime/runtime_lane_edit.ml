module Text = Runtime_config_text
open Result.Syntax

type exact_slot_list = Catalog_slots | Cli_slots

let exact_slot_list_key = function
  | Catalog_slots -> "slots"
  | Cli_slots -> "cli_slots"

let exact_slot_list_admitting api_format =
  match Runtime_schema.api_format_output_schema_channel api_format with
  | Runtime_schema.No_output_schema_channel -> None
  | Runtime_schema.Holds_output_schema ->
    Some
      (match api_format with
       | Runtime_schema.Codex_app_server_runtime
       | Runtime_schema.Antigravity_cli_runtime
       | Runtime_schema.Claude_code_runtime
       | Runtime_schema.Muse_serve_runtime -> Cli_slots
       | Runtime_schema.Messages_api
       | Runtime_schema.Chat_completions_api
       | Runtime_schema.Ollama_api
       | Runtime_schema.Gemini_api
       | Runtime_schema.Vertex_gemini_api -> Catalog_slots)

type exact_slot_move = Move_slot_up | Move_slot_down | Move_slot_first
type table_operation = Rename_table | Remove_table

type error =
  | Invalid_input of string
  | Lane_exists of string
  | Lane_absent of string
  | Lane_name_unchanged of string
  | Lane_name_conflict of string
  | Lane_table_unaddressable of { lane_id : string; operation : table_operation }
  | Lane_in_use of { lane_id : string; references : Text.route_reference list }
  | Reference_edit_refused of string
  | Exact_lane_unaddressable of Standalone_lane.t
  | Slot_already_declared of { lane_id : string; slot : string; list : exact_slot_list }
  | Slot_requires_cli of { lane_id : string; slot : string }
  | Slot_has_no_schema_channel of { lane_id : string; slot : string }
  | Slot_absent of { lane_id : string; slot : string; declared : string list }
  | Last_slot of { lane_id : string; slot : string }
  | Slot_at_boundary of { lane_id : string; slot : string; move : exact_slot_move }
  | Replacement_already_declared of string
  | Replacement_changes_group

let exact_lane_table_path lane = Runtime_schema.exact_lane_table_name (Runtime_schema.Builtin lane)

let error_to_string = function
  | Invalid_input detail | Reference_edit_refused detail -> detail
  | Lane_exists lane_id -> Printf.sprintf "lane %S already exists" lane_id
  | Lane_absent lane_id ->
    Printf.sprintf "lane %S is not declared in [runtime.lanes]" lane_id
  | Lane_name_unchanged lane_id -> Printf.sprintf "lane %S already has that name" lane_id
  | Lane_name_conflict lane_id ->
    Printf.sprintf
      "the file already declares %S; renaming onto it would declare the lane twice"
      lane_id
  | Lane_table_unaddressable { lane_id; operation } ->
    Printf.sprintf
      "lane %S is not written as its own [runtime.lanes] table, so it cannot be %s here"
      lane_id (match operation with Rename_table -> "renamed" | Remove_table -> "removed")
  | Lane_in_use { lane_id; references } ->
    Printf.sprintf "lane %S is in use by %s" lane_id
      (String.concat ", " (List.map Text.route_reference_to_string references))
  | Exact_lane_unaddressable lane ->
    Printf.sprintf
      "exact-output lane %s is not written as its own [%s] table, so it cannot be edited here"
      (Standalone_lane.to_id lane) (exact_lane_table_path lane)
  | Slot_already_declared { lane_id; slot; list } ->
    Printf.sprintf "%s is already a %sslot of %s" slot
      (match list with Catalog_slots -> "" | Cli_slots -> "CLI ") lane_id
  | Slot_requires_cli { lane_id; slot } ->
    Printf.sprintf "%s is an official client, so it can only be a CLI slot of %s"
      slot lane_id
  | Slot_has_no_schema_channel { lane_id; slot } ->
    Printf.sprintf
      "%s has no output-schema channel, and every exact-output call hands its client \
       a JSON Schema to answer to, so %s cannot list it"
      slot lane_id
  | Slot_absent { lane_id; slot; declared } ->
    Printf.sprintf "%s is not a slot of %s; the lane declares %s" slot lane_id
      (match declared with [] -> "none" | _ :: _ -> String.concat ", " declared)
  | Last_slot { lane_id; slot } ->
    Printf.sprintf "%s is the last slot of %s; an exact-output lane needs at least one"
      slot lane_id
  | Slot_at_boundary { lane_id; slot; move } ->
    Printf.sprintf "%s is already %s in %s" slot
      (match move with Move_slot_up | Move_slot_first -> "first" | Move_slot_down -> "last")
      lane_id
  | Replacement_already_declared replacement -> replacement ^ " is already declared in this lane"
  | Replacement_changes_group ->
    "Replace a candidate within its HTTP or CLI group; add a candidate to change groups"

type edit =
  | Create_lane of { lane_id : string; runtime_ids : string list }
  | Rename_lane of { lane_id : string; new_lane_id : string }
  | Remove_lane of string
  | Set_exact_slots of { lane : Standalone_lane.t; slots : string list }
  | Append_exact_slot of { lane : Standalone_lane.t; slot : string }
  | Drop_exact_slot of { lane : Standalone_lane.t; slot : string }
  | Move_exact_slot of { lane : Standalone_lane.t; slot : string; move : exact_slot_move }
  | Replace_exact_slot of { lane : Standalone_lane.t; slot : string; replacement : string }

let invalid_input detail = Invalid_input detail

let create ~lane_id ~runtime_ids =
  let* lane_id = Text.validated_lane_id lane_id |> Result.map_error invalid_input in
  let* runtime_ids = Text.validated_lane_candidates runtime_ids |> Result.map_error invalid_input in
  Ok (Create_lane { lane_id; runtime_ids })

let rename ~lane_id ~new_lane_id =
  let* lane_id = Text.validated_lane_id lane_id |> Result.map_error invalid_input in
  let* new_lane_id = Text.validated_lane_id new_lane_id |> Result.map_error invalid_input in
  if String.equal lane_id new_lane_id then Error (Lane_name_unchanged lane_id)
  else Ok (Rename_lane { lane_id; new_lane_id })

let remove ~lane_id =
  let* lane_id = Text.validated_lane_id lane_id |> Result.map_error invalid_input in
  Ok (Remove_lane lane_id)

let set_exact_slots ~lane ~slots =
  let slots = List.map String.trim slots in
  if slots = [] then Error (Invalid_input "an exact-output lane needs at least one slot")
  else if List.exists (String.equal "") slots then Error (Invalid_input "slots must not contain empty entries")
  else if List.exists Text.contains_newline slots then Error (Invalid_input "slots must not contain newlines")
  else Ok (Set_exact_slots { lane; slots })

let validated_slot slot =
  let slot = String.trim slot in
  if String.equal slot "" then Error (Invalid_input "slot must not be empty")
  else if Text.contains_newline slot then Error (Invalid_input "slot must not contain newlines")
  else Ok slot

let append_exact_slot ~lane ~slot =
  let* slot = validated_slot slot in
  Ok (Append_exact_slot { lane; slot })

let drop_exact_slot ~lane ~slot =
  let* slot = validated_slot slot in
  Ok (Drop_exact_slot { lane; slot })

let move_exact_slot ~lane ~slot ~move =
  let* slot = validated_slot slot in
  Ok (Move_exact_slot { lane; slot; move })

let replace_exact_slot ~lane ~slot ~replacement =
  let replacement = String.trim replacement in
  if String.equal replacement "" || Text.contains_newline replacement
  then Error (Invalid_input "replacement must be a non-empty runtime id without newlines")
  else
    let* slot = validated_slot slot in
    Ok (Replace_exact_slot { lane; slot; replacement })

let reference_edit result = Result.map_error (fun detail -> Reference_edit_refused detail) result

let plan_create ~content config ~lane_id ~runtime_ids =
  if Text.lane_is_declared config lane_id then Error (Lane_exists lane_id)
  else Ok (Text.write_lane_candidates ~content ~lane_id ~runtime_ids)

(* A lane shadows a runtime of the same id. Its table, assignments, default
   route and Fusion seats must move together, never as separate writes. The
   text editor's refusal precedes reference reads, which may themselves fail. *)
let plan_rename ~content config ~lane_id ~new_lane_id =
  if not (Text.lane_is_declared config lane_id) then Error (Lane_absent lane_id)
  else if Text.lane_is_declared config new_lane_id then Error (Lane_exists new_lane_id)
  else
    match Toml_line_editor.rename_table content
        ~path:(Text.lane_table_path lane_id) ~to_path:(Text.lane_table_path new_lane_id) with
    | Toml_line_editor.Table_rename_conflict -> Error (Lane_name_conflict new_lane_id)
    | Toml_line_editor.Table_rename_absent ->
      Error (Lane_table_unaddressable { lane_id; operation = Rename_table })
    | Toml_line_editor.Table_renamed renamed ->
      let* toml = Text.lane_edit_toml content |> reference_edit in
      let* seats = Text.lane_fusion_seats toml ~lane_id |> reference_edit in
      let references = Text.lane_references config seats ~lane_id in
      let rename_reference text = function
        | Text.Keeper_assignment keeper_name ->
          Text.update_runtime_assignment_text text ~keeper_name ~runtime_id:new_lane_id
        | Text.Default_runtime ->
          Text.update_runtime_scalar_text text ~key:"default" ~runtime_id:(Some new_lane_id)
        | Text.Fusion_seat _ -> text
      in
      Text.rename_fusion_seats (List.fold_left rename_reference renamed references)
        toml references ~lane_id ~new_lane_id
      |> reference_edit

let plan_remove ~content config ~lane_id =
  if not (Text.lane_is_declared config lane_id) then Error (Lane_absent lane_id)
  else
    let* toml = Text.lane_edit_toml content |> reference_edit in
    let* seats = Text.lane_fusion_seats toml ~lane_id |> reference_edit in
    match Text.lane_references config seats ~lane_id with
    | _ :: _ as references -> Error (Lane_in_use { lane_id; references })
    | [] ->
      (match Toml_line_editor.remove_table content ~path:(Text.lane_table_path lane_id) with
       | Toml_line_editor.Table_removed next -> Ok next
       | Toml_line_editor.Table_absent ->
         Error (Lane_table_unaddressable { lane_id; operation = Remove_table }))

let exact_lane_decl (config : Runtime_schema.config) lane =
  List.find_opt
    (fun (decl : Runtime_schema.exact_output_lane_decl) ->
       Runtime_schema.equal_exact_lane_owner decl.owner (Runtime_schema.Builtin lane))
    config.exact_output_lane_decls

let declared_exact_slots config lane =
  match exact_lane_decl config lane with
  | Some decl -> decl.slot_ids, decl.cli_slot_ids
  | None -> [], []

(* An inline/dotted declaration has no table header the line editor can write
   under. An absent declaration can acquire its own table. *)
let exact_lane_editable ~content config lane =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  match exact_lane_decl config lane with
  | None -> Ok ()
  | Some _ when List.exists (Toml_line_editor.is_table ~path:(exact_lane_table_path lane)) lines -> Ok ()
  | Some _ -> Error (Exact_lane_unaddressable lane)

(* Unknown ids remain catalog candidates. Admission/materialization belongs to
   the whole-file commit; the planner never substitutes the admitted registry. *)
let exact_slot_list_of_new_slot (config : Runtime_schema.config) slot =
  match List.find_opt
      (fun (binding : Runtime_schema.binding) -> String.equal (Runtime_schema.binding_key binding) slot)
      config.bindings with
  | None -> Some Catalog_slots
  | Some binding ->
    (match Runtime_schema.provider_of_id config binding.provider_id with
     | None -> Some Catalog_slots
     | Some provider -> exact_slot_list_admitting provider.api_format)

let write_exact_slots ~content ~lane ~list ~values =
  Toml_line_editor.edit_table_multiline_array content
    ~path:(exact_lane_table_path lane) ~key:(exact_slot_list_key list) ~values

let plan_set_exact_slots ~content config ~lane ~slots =
  let* () = exact_lane_editable ~content config lane in
  let _, cli_slots = declared_exact_slots config lane in
  let lane_id = Standalone_lane.to_id lane in
  match List.find_opt (fun slot -> List.mem slot cli_slots) slots with
  | Some slot -> Error (Slot_already_declared { lane_id; slot; list = Cli_slots })
  | None ->
    let refusal slot =
      match exact_slot_list_of_new_slot config slot with
      | Some Catalog_slots -> None
      | Some Cli_slots -> Some (Slot_requires_cli { lane_id; slot })
      | None -> Some (Slot_has_no_schema_channel { lane_id; slot })
    in
    (match List.find_map refusal slots with
     | Some error -> Error error
     | None -> Ok (write_exact_slots ~content ~lane ~list:Catalog_slots ~values:slots))

let plan_append_exact_slot ~content config ~lane ~slot =
  let* () = exact_lane_editable ~content config lane in
  let slots, cli_slots = declared_exact_slots config lane in
  let lane_id = Standalone_lane.to_id lane in
  if List.exists (String.equal slot) slots
  then Error (Slot_already_declared { lane_id; slot; list = Catalog_slots })
  else if List.exists (String.equal slot) cli_slots
  then Error (Slot_already_declared { lane_id; slot; list = Cli_slots })
  else
    match exact_slot_list_of_new_slot config slot with
    | None -> Error (Slot_has_no_schema_channel { lane_id; slot })
    | Some Catalog_slots ->
      Ok (write_exact_slots ~content ~lane ~list:Catalog_slots ~values:(slots @ [ slot ]))
    | Some Cli_slots ->
      Ok (write_exact_slots ~content ~lane ~list:Cli_slots ~values:(cli_slots @ [ slot ]))

(* Locate and edit only the containing declared list. Keeping the other list
   explicit preserves unadmitted slots and the one-slot floor across transports. *)
let with_declared_exact_slots ~content config ~lane ~slot decide =
  let* () = exact_lane_editable ~content config lane in
  let slots, cli_slots = declared_exact_slots config lane in
  let lane_id = Standalone_lane.to_id lane in
  let located =
    match List.find_index (String.equal slot) slots with
    | Some position -> Some (Catalog_slots, slots, cli_slots, position)
    | None ->
      Option.map (fun position -> Cli_slots, cli_slots, slots, position)
        (List.find_index (String.equal slot) cli_slots)
  in
  match located with
  | None -> Error (Slot_absent { lane_id; slot; declared = slots @ cli_slots })
  | Some (list, declared, other, position) ->
    let* values = decide ~lane_id ~slots:declared ~other ~position in
    Ok (write_exact_slots ~content ~lane ~list ~values)

let plan_drop_exact_slot ~content config ~lane ~slot =
  with_declared_exact_slots ~content config ~lane ~slot
    (fun ~lane_id ~slots ~other ~position ->
       match List.filteri (fun index _ -> index <> position) slots, other with
       | [], [] -> Error (Last_slot { lane_id; slot })
       | remaining, (_ :: _ | []) -> Ok remaining)

let plan_move_exact_slot ~content config ~lane ~slot ~move =
  with_declared_exact_slots ~content config ~lane ~slot
    (fun ~lane_id ~slots ~other:_ ~position ->
       let count = List.length slots in
       let target = match move with
         | Move_slot_up -> position - 1
         | Move_slot_down -> position + 1
         | Move_slot_first -> 0
       in
       if target < 0 || target >= count || (move = Move_slot_first && position = 0)
       then Error (Slot_at_boundary { lane_id; slot; move })
       else match move with
         | Move_slot_first -> Ok (slot :: List.filteri (fun index _ -> index <> position) slots)
         | Move_slot_up | Move_slot_down ->
           let at_position = List.nth slots position
           and at_target = List.nth slots target in
           Ok (List.mapi (fun index declared ->
             if index = position then at_target
             else if index = target then at_position
             else declared) slots))

let plan_replace_exact_slot ~content config ~lane ~slot ~replacement =
  let current = Option.bind (exact_lane_decl config lane) (fun decl ->
    if List.mem slot decl.slot_ids then Some Catalog_slots
    else if List.mem slot decl.cli_slot_ids then Some Cli_slots else None) in
  (* Transport/schema refusal precedes table addressability and duplicate
     checks, including when the named original slot is absent. *)
  match current, exact_slot_list_of_new_slot config replacement with
  | Some current, Some next when current = next ->
    with_declared_exact_slots ~content config ~lane ~slot
      (fun ~lane_id:_ ~slots ~other ~position ->
         if List.mem replacement (slots @ other)
         then Error (Replacement_already_declared replacement)
         else Ok (List.mapi (fun index declared ->
           if index = position then replacement else declared) slots))
  | (Some (Catalog_slots | Cli_slots) | None), None ->
    Error (Slot_has_no_schema_channel { lane_id = Standalone_lane.to_id lane; slot = replacement })
  | (Some (Catalog_slots | Cli_slots) | None), Some (Catalog_slots | Cli_slots) ->
    Error Replacement_changes_group

let plan ~content config = function
  | Create_lane { lane_id; runtime_ids } -> plan_create ~content config ~lane_id ~runtime_ids
  | Rename_lane { lane_id; new_lane_id } -> plan_rename ~content config ~lane_id ~new_lane_id
  | Remove_lane lane_id -> plan_remove ~content config ~lane_id
  | Set_exact_slots { lane; slots } -> plan_set_exact_slots ~content config ~lane ~slots
  | Append_exact_slot { lane; slot } -> plan_append_exact_slot ~content config ~lane ~slot
  | Drop_exact_slot { lane; slot } -> plan_drop_exact_slot ~content config ~lane ~slot
  | Move_exact_slot { lane; slot; move } -> plan_move_exact_slot ~content config ~lane ~slot ~move
  | Replace_exact_slot { lane; slot; replacement } ->
    plan_replace_exact_slot ~content config ~lane ~slot ~replacement
