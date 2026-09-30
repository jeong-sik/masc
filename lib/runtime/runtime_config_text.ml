(** Comment-preserving runtime config text edits and route references.
    File observations, locking, validation and publication belong to Runtime. *)

open Result.Syntax

let runtime_table = Runtime_toml_namespace.(key Runtime)
let egress_table = Runtime_toml_namespace.(key Egress)
let assignments_table = Runtime_toml_namespace.(path Runtime) "assignments"
let fusion_presets_table = Runtime_toml_namespace.(path Fusion) "presets"

let contains_newline s =
  String.exists (function
    | '\n' | '\r' -> true
    | _ -> false)
    s
;;


let assignment_line ~keeper_name ~runtime_id =
  Printf.sprintf
    "\"%s\" = \"%s\""
    (Toml_line_editor.escape_string keeper_name)
    (Toml_line_editor.escape_string runtime_id)
;;



let is_runtime_assignments_header = Toml_line_editor.is_table ~path:(runtime_table ^ ".assignments")
let is_runtime_header = Toml_line_editor.is_table ~path:runtime_table


let replace_or_append_assignment section_lines ~keeper_name ~runtime_id =
  let line = assignment_line ~keeper_name ~runtime_id in
  let rec loop acc = function
    | [] -> List.rev_append acc [ line ]
    | existing :: rest ->
      (match Toml_line_editor.key_of_line existing with
       | Some key when String.equal key keeper_name ->
         List.rev_append acc (line :: rest)
       | _ -> loop (existing :: acc) rest)
  in
    loop [] section_lines
;;

let remove_assignment section_lines ~keeper_name =
  List.filter
    (fun existing ->
      match Toml_line_editor.key_of_line existing with
      | Some key when String.equal key keeper_name -> false
      | _ -> true)
    section_lines
;;

let replace_or_append_runtime_scalar section_lines ~key ~runtime_id =
  let line = Toml_line_editor.scalar_line ~key ~value:runtime_id in
  let rec loop acc = function
    | [] -> List.rev_append acc [ line ]
    | existing :: rest ->
      (match Toml_line_editor.key_of_line existing with
       | Some existing_key when String.equal existing_key key ->
         List.rev_append acc (line :: rest)
       | _ -> loop (existing :: acc) rest)
  in
  loop [] section_lines
;;

let replace_or_append_runtime_string_array section_lines ~key ~values =
  let line = Toml_line_editor.string_array_line ~key ~values in
  let rec loop acc = function
    | [] -> List.rev_append acc [ line ]
    | existing :: rest ->
      (match Toml_line_editor.key_of_line existing with
       | Some existing_key when String.equal existing_key key ->
         List.rev_append acc (line :: rest)
       | _ -> loop (existing :: acc) rest)
  in
  loop [] section_lines
;;

let remove_runtime_scalar section_lines ~key =
  List.filter
    (fun existing ->
      match Toml_line_editor.key_of_line existing with
      | Some existing_key when String.equal existing_key key -> false
      | _ -> true)
    section_lines
;;

let append_runtime_section lines ~key ~runtime_id =
  let section = [ "[" ^ runtime_table ^ "]"; Toml_line_editor.scalar_line ~key ~value:runtime_id ] in
  match List.rev lines with
  | [] -> section
  | last :: _ when String.equal (String.trim last) "" -> lines @ section
  | _ -> lines @ ("" :: section)
;;

let append_runtime_string_array_section lines ~key ~values =
  let section = [ "[" ^ runtime_table ^ "]"; Toml_line_editor.string_array_line ~key ~values ] in
  match List.rev lines with
  | [] -> section
  | last :: _ when String.equal (String.trim last) "" -> lines @ section
  | _ -> lines @ ("" :: section)
;;

let append_runtime_assignments_section lines ~keeper_name ~runtime_id =
  let section =
    [ "[" ^ assignments_table ^ "]"; assignment_line ~keeper_name ~runtime_id ]
  in
  match List.rev lines with
  | [] -> section
  | last :: _ when String.equal (String.trim last) "" -> lines @ section
  | _ -> lines @ ("" :: section)
;;

let update_runtime_assignment_text content ~keeper_name ~runtime_id =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  let updated_lines =
    match Toml_line_editor.find_index is_runtime_assignments_header lines with
    | None -> append_runtime_assignments_section lines ~keeper_name ~runtime_id
    | Some header_index ->
      let before, from_header = Toml_line_editor.split_at header_index lines in
      (match from_header with
       | [] -> append_runtime_assignments_section lines ~keeper_name ~runtime_id
       | header :: after_header ->
         let section_lines, after_section =
           match Toml_line_editor.find_index Toml_line_editor.is_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> Toml_line_editor.split_at next_header_index after_header
         in
         before
         @ (header
            :: replace_or_append_assignment
                 section_lines
                 ~keeper_name
                 ~runtime_id)
         @ after_section)
  in
  Toml_line_editor.join_lines updated_lines ~trailing_newline:true
;;

(* [\[egress.keepers.<name>\]] as text, so a keeper's allowlist can be written
   by the same call that puts the keeper in the policy lane. Two files edited
   by hand is how the two halves come apart, and an allowlist that does not
   match its keeper's mode fails silently in the direction that looks like
   permission.

   The table is replaced wholesale rather than merged: an allowlist is the
   complete statement of what a keeper may reach, so a write that kept
   unnamed entries would mean an operator could not remove one. *)
let egress_keepers_table = [ egress_table; "keepers" ]

(* Quoted, like an assignment row's key: a keeper name carries dots
   (edgar.a.poe is live), and [egress.keepers.edgar.a.poe] would be a path
   into nested tables rather than one keeper. Unquoted, the loader reads
   "a" as an unknown key under keeper "edgar" and refuses the file. *)
let egress_keepers_header keeper_name =
  Printf.sprintf
    "[%s.\"%s\"]"
    (String.concat "." egress_keepers_table)
    (Toml_line_editor.escape_string keeper_name)
;;

let egress_allow_line allow =
  Printf.sprintf
    "allow = [%s]"
    (allow
     |> List.map (fun entry -> Printf.sprintf "\"%s\"" (Toml_line_editor.escape_string entry))
     |> String.concat ", ")
;;

(* The file has two authors, so the header is recognised by what the TOML
   grammar reads out of it rather than by its spelling: this writer quotes
   the key; an operator's hand may not, may space the brackets, may
   single-quote, may leave a note on the line. The loader reads every one of
   those as the path egress, keepers, name, and so does this, which is what
   keeps one keeper at one table. [\[\[egress.keepers.<name>\]\]] is not the
   keeper's table: the loader refuses an array of tables as a keeper, so the
   writer leaves it as the table boundary it is. *)
let is_egress_keeper_header ~keeper_name line =
  match Toml_line_editor.header_of_line line with
  | Some (Toml_line_editor.Table path) ->
    List.equal String.equal path (egress_keepers_table @ [ keeper_name ])
  | Some (Toml_line_editor.Table_array _) | None -> false
;;

let update_egress_allow_text content ~keeper_name ~allow =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  let section = [ egress_keepers_header keeper_name; egress_allow_line allow ] in
  let updated_lines =
    match Toml_line_editor.find_index (is_egress_keeper_header ~keeper_name) lines with
    | None ->
      (match List.rev lines with
       | [] -> section
       | last :: _ when String.equal (String.trim last) "" -> lines @ section
       | _ -> lines @ ("" :: section))
    | Some header_index ->
      let before, from_header = Toml_line_editor.split_at header_index lines in
      (match from_header with
       | [] -> lines @ section
       | _ :: after_header ->
         let _replaced, after_section =
           match Toml_line_editor.find_index Toml_line_editor.is_table_header after_header with
           | None -> after_header, []
           | Some next -> Toml_line_editor.split_at next after_header
         in
         before @ section @ after_section)
  in
  Toml_line_editor.join_lines updated_lines ~trailing_newline:true
;;

let remove_egress_allow_text content ~keeper_name =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  let updated_lines =
    match Toml_line_editor.find_index (is_egress_keeper_header ~keeper_name) lines with
    | None -> lines
    | Some header_index ->
      let before, from_header = Toml_line_editor.split_at header_index lines in
      (match from_header with
       | [] -> lines
       | _ :: after_header ->
         let _dropped, after_section =
           match Toml_line_editor.find_index Toml_line_editor.is_table_header after_header with
           | None -> after_header, []
           | Some next -> Toml_line_editor.split_at next after_header
         in
         before @ after_section)
  in
  Toml_line_editor.join_lines updated_lines ~trailing_newline:true
;;

let update_runtime_scalar_text content ~key ~runtime_id =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  let updated_lines =
    match Toml_line_editor.find_index is_runtime_header lines, runtime_id with
    | None, None -> lines
    | None, Some runtime_id -> append_runtime_section lines ~key ~runtime_id
    | Some header_index, _ ->
      let before, from_header = Toml_line_editor.split_at header_index lines in
      (match from_header with
       | [] ->
         (match runtime_id with
          | None -> lines
          | Some runtime_id -> append_runtime_section lines ~key ~runtime_id)
       | header :: after_header ->
         let section_lines, after_section =
           match Toml_line_editor.find_index Toml_line_editor.is_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> Toml_line_editor.split_at next_header_index after_header
         in
         let next_section_lines =
           match runtime_id with
           | None -> remove_runtime_scalar section_lines ~key
           | Some runtime_id -> replace_or_append_runtime_scalar section_lines ~key ~runtime_id
         in
         before @ (header :: next_section_lines) @ after_section)
  in
  Toml_line_editor.join_lines updated_lines ~trailing_newline:true
;;

let update_runtime_string_array_text content ~key ~values =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  let updated_lines =
    match Toml_line_editor.find_index is_runtime_header lines with
    | None -> append_runtime_string_array_section lines ~key ~values
    | Some header_index ->
      let before, from_header = Toml_line_editor.split_at header_index lines in
      (match from_header with
       | [] -> append_runtime_string_array_section lines ~key ~values
       | header :: after_header ->
         let section_lines, after_section =
           match Toml_line_editor.find_index Toml_line_editor.is_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> Toml_line_editor.split_at next_header_index after_header
         in
         before
         @ (header :: replace_or_append_runtime_string_array section_lines ~key ~values)
         @ after_section)
  in
  Toml_line_editor.join_lines updated_lines ~trailing_newline:true
;;

let remove_runtime_assignment_text content ~keeper_name =
  let lines, _trailing_newline = Toml_line_editor.split_lines content in
  let updated_lines =
    match Toml_line_editor.find_index is_runtime_assignments_header lines with
    | None -> lines
    | Some header_index ->
      let before, from_header = Toml_line_editor.split_at header_index lines in
      (match from_header with
       | [] -> lines
       | header :: after_header ->
         let section_lines, after_section =
           match Toml_line_editor.find_index Toml_line_editor.is_table_header after_header with
           | None -> after_header, []
           | Some next_header_index -> Toml_line_editor.split_at next_header_index after_header
         in
         before @ (header :: remove_assignment section_lines ~keeper_name) @ after_section)
  in
  Toml_line_editor.join_lines updated_lines ~trailing_newline:true
;;

(* A place in runtime.toml that names a lane. [resolve_assignment] reads a lane
   before a runtime of the same id, and each of these is resolved that way: a
   keeper's route is its assignment or, without one, the default, and a Fusion
   run resolves each seat when it reaches it. [\[runtime\].media_failover] and
   [verifier_exact] slots name runtimes only and never reach a lane, so they
   are not here. *)
type route_reference =
  | Keeper_assignment of string
  | Default_runtime
  | Fusion_seat of
      { preset : string
      ; seat : Fusion_policy.seat_kind
      }

let route_reference_to_string = function
  | Keeper_assignment keeper_name -> Printf.sprintf "[%s].%s" assignments_table keeper_name
  | Default_runtime -> "[runtime].default, which every keeper without an assignment walks"
  | Fusion_seat { preset; seat } ->
    Printf.sprintf "[%s.%s].%s" fusion_presets_table preset (Fusion_policy.seat_kind_key seat)
;;

(* [\[runtime.lanes."<id>"\]] is written by table path, not by the [\[runtime\]]
   array writer above: the candidates live in their own table, one per lane.

   The id is quoted exactly when TOML requires it: a bare key is
   [A-Za-z0-9_-] and every runtime id carries a dot, so in practice this
   quotes. Either spelling names the same table to [Toml_line_editor.is_table],
   which compares the key path the grammar reads, so the choice is only what
   the operator sees in the file. *)
let table_path_under prefix id =
  let bare =
    String.for_all
      (function 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true | _ -> false)
      id
  in
  if bare && not (String.equal id "")
  then Printf.sprintf "%s.%s" prefix id
  else
    (* [escape_string] escapes the contents; the quotes are the caller's. *)
    Printf.sprintf "%s.\"%s\"" prefix (Toml_line_editor.escape_string id)
;;

let lane_table_path lane_id = table_path_under (runtime_table ^ ".lanes") lane_id

let validated_lane_id lane_id =
  let lane_id = String.trim lane_id in
  if String.equal lane_id ""
  then Error "lane id must not be empty"
  else if contains_newline lane_id
  then Error "lane id must not contain newlines"
  else Ok lane_id
;;

let validated_lane_candidates runtime_ids =
  let runtime_ids = List.map String.trim runtime_ids in
  if runtime_ids = []
  then
    (* An empty list is not "no failover", it is a lane that resolves to
       nothing. Removing a lane is a different edit than emptying it. *)
    Error "a lane needs at least one candidate"
  else if List.exists (String.equal "") runtime_ids
  then Error "runtime_ids must not contain empty entries"
  else if List.exists contains_newline runtime_ids
  then Error "runtime_ids must not contain newlines"
  else Ok runtime_ids
;;

let lane_is_declared (config : Runtime_schema.config) lane_id =
  List.exists
    (fun (decl : Runtime_schema.lane_decl) -> String.equal decl.id lane_id)
    config.lane_decls
;;

let write_lane_candidates ~content ~lane_id ~runtime_ids =
  Toml_line_editor.edit_table_multiline_array
    content
    ~path:(lane_table_path lane_id)
    ~key:"candidates"
    ~values:runtime_ids
;;

(* Every place the config names a lane, with the route it names. The Fusion
   seats come from [Fusion_config.seat_routes_of_toml], which reads them
   without validating the presets. *)
let route_references (config : Runtime_schema.config) seats =
  List.map (fun (keeper_name, target) -> Keeper_assignment keeper_name, target)
    config.keeper_assignments
  @ (match config.default_runtime_id with
     | Some id -> [ Default_runtime, id ]
     | None -> [])
  @ List.map
      (fun (preset, seat, route) -> Fusion_seat { preset; seat }, String.trim route)
      seats
;;

(* A preset naming the lane at two panel seats is one reference to report. *)
let lane_references config seats ~lane_id =
  List.fold_left
    (fun found (reference, route) ->
       if String.equal route lane_id && not (List.mem reference found)
       then found @ [ reference ]
       else found)
    []
    (route_references config seats)
;;

let lane_edit_toml content =
  Result.map_error
    (fun detail -> "runtime config parse failed: " ^ detail)
    (Otoml.Parser.from_string_result content)
;;

(* The seats are read from the text under the lock, without validating the
   presets: a preset that does not validate still names what it names, so an
   error in another preset does not block a lane edit. Only a [fusion] whose
   values have the wrong TOML type hides its seats, and then a lane edit
   refuses rather than leave them pointing at a name that is gone. *)
let lane_fusion_seats toml ~lane_id =
  Fusion_config.seat_routes_of_toml toml
  |> Result.map_error (fun error ->
    Printf.sprintf
      "lane %S cannot be edited while the seats of [fusion] cannot be read (%s): \
       they may name the lane. Fix [fusion] first"
      lane_id
      (Fusion_config.config_error_message error))
;;

(* A seat is a route, so a rename rewrites every preset with a seat on the
   lane through the Fusion writer, in the same text as the header. The writer
   takes validated presets, so this needs [fusion] to load -- but only when a
   seat names the lane; otherwise [fusion] is not read. A preset the writer
   cannot address refuses the rename, and the refusal says the lane rename is
   what reached it. *)
let rename_fusion_seats text toml references ~lane_id ~new_lane_id =
  let seat_presets =
    List.filter_map
      (function
        | Fusion_seat { preset; _ } -> Some preset
        | Keeper_assignment _ | Default_runtime -> None)
      references
  in
  match seat_presets with
  | [] -> Ok text
  | _ :: _ ->
    let* (fusion : Fusion_policy.t) =
      Fusion_config.of_toml toml
      |> Result.map_error (fun errors ->
        Printf.sprintf
          "renaming lane %S rewrites Fusion seats that name it, and [fusion] does not \
           load (%s). Fix [fusion] first"
          lane_id
          (String.concat "; " (List.map Fusion_config.config_error_message errors)))
    in
    List.fold_left
      (fun acc validated ->
         let* text = acc in
         let preset = Fusion_policy.Validated_preset.preset validated in
         if not (List.mem preset.name seat_presets)
         then Ok text
         else (
           let rename route =
             if String.equal (String.trim route) lane_id then new_lane_id else route
           in
           let* renamed =
             Fusion_policy.Validated_preset.of_preset
               (Fusion_policy.map_seat_routes rename preset)
             |> Result.map_error (fun invalid ->
               Printf.sprintf "preset %s %s after the rename" preset.name
                 (Fusion_policy.Validated_preset.invalid_to_string invalid))
           in
           Fusion_config_writer.upsert_preset text renamed
           |> Result.map_error (fun error ->
             Printf.sprintf "renaming lane %S rewrites a seat of preset %s, and %s"
               lane_id preset.name (Fusion_config_writer.error_message error))))
      (Ok text)
      fusion.presets
;;
