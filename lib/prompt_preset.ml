(* Prompt presets — one named snapshot of the three operator-owned surfaces
   that a prompt campaign changes together (#32777):

   - prompt overrides, [.masc/prompt_overrides.json]. This is the durable
     operator layer: the managed prompt files under [.masc/config/prompts]
     are re-synced from the binary at every boot, so a preset that copied
     them would be undone by the next start.
   - each keeper's [keeper.instructions] in [.masc/config/keepers/<name>.toml].
   - [\[runtime.assignments\]] and [\[runtime.exact_output_lanes.*\]] of
     runtime.toml — keeper routing, and the librarian / judge lanes.

   A preset lives under [<base>/.masc/presets/<name>/]: [manifest.json],
   [prompt_overrides.json] (the same envelope as the live file),
   [runtime.json], and [instructions/<keeper>.txt].

   A restore writes the three surfaces through their existing paths, so they
   take effect at three different moments; the report names each:
   overrides at once, instructions at the keeper's next up, runtime through
   the runtime.toml commit path (which re-publishes the exact-output lanes in
   process). The current state is saved first as [_autosave-<stamp>]. *)

let ( let* ) = Result.bind

module Override = Prompt_override_persistence

type lane =
  { id : string
  ; slots : string list
  ; cli_slots : string list
  }

type snapshot =
  { name : string
  ; description : string
  ; created_at : string
  ; prompt_overrides : Override.entry list
  ; instructions : (string * string) list
  ; assignments : (string * string) list
  ; lanes : lane list
  }

type manifest =
  { preset_name : string
  ; preset_description : string
  ; preset_created_at : string
  ; override_count : int
  ; keepers : string list
  ; assignment_count : int
  ; lane_count : int
  }

type listing =
  { presets : manifest list
  ; unreadable : (string * string) list
  }

type part_result =
  { applied : string list
  ; skipped : (string * string) list
  }

type runtime_result =
  | Runtime_unchanged
  | Runtime_committed
  | Runtime_failed of string

type restore_report =
  { restored : string
  ; autosave : string
  ; prompt_overrides_result : part_result
  ; instructions_result : part_result
  ; runtime_result : runtime_result
  }

let schema_version = 1
let manifest_file = "manifest.json"
let overrides_file = "prompt_overrides.json"
let runtime_file = "runtime.json"
let instructions_dir = "instructions"
let instructions_extension = ".txt"
let autosave_prefix = "_autosave-"

let is_valid_name name =
  (not (String.equal name ""))
  && (not (String.equal name "."))
  && (not (String.equal name ".."))
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       name
;;

let presets_dir ~base_path =
  Filename.concat (Config_dir_resolver.masc_root ~base_path) "presets"
;;

let preset_dir ~base_path name = Filename.concat (presets_dir ~base_path) name

let runtime_toml_path ~base_path =
  Config_dir_resolver.runtime_toml_path_for_base_path ~base_path
;;

let now_iso () = Time_codec.rfc3339_of_unix (Unix.gettimeofday ())

(* [YYYYMMDDTHHMMSSZ], a stamp that is also a valid preset name segment. *)
let compact_stamp () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf
    "%04d%02d%02dT%02d%02d%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
;;

(* The filesystem boundary raises; a preset call answers with [Error]. *)
let guard f =
  match f () with
  | value -> value
  | exception Sys_error message -> Error message
  | exception Unix.Unix_error (error, operation, argument) ->
    Error (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
;;

(* ── JSON ──────────────────────────────────────────────────────────── *)

let strings values = `List (List.map (fun v -> `String v) values)

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (name ^ " must be a string")
  | None -> Error (name ^ " missing")
;;

let int_field fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error (name ^ " must be an integer")
  | None -> Error (name ^ " missing")
;;

let string_list_field fields name =
  match List.assoc_opt name fields with
  | Some (`List items) ->
    List.fold_left
      (fun acc item ->
        let* acc = acc in
        match item with
        | `String value -> Ok (value :: acc)
        | _ -> Error (name ^ " must hold strings"))
      (Ok [])
      items
    |> Result.map List.rev
  | Some _ -> Error (name ^ " must be a list")
  | None -> Error (name ^ " missing")
;;

let json_of_string text =
  match Yojson.Safe.from_string text with
  | json -> Ok json
  | exception Yojson.Json_error message -> Error ("invalid JSON: " ^ message)
;;

let manifest_of_snapshot (s : snapshot) =
  { preset_name = s.name
  ; preset_description = s.description
  ; preset_created_at = s.created_at
  ; override_count = List.length s.prompt_overrides
  ; keepers = List.map fst s.instructions
  ; assignment_count = List.length s.assignments
  ; lane_count = List.length s.lanes
  }
;;

let manifest_to_json (m : manifest) : Yojson.Safe.t =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "name", `String m.preset_name
    ; "description", `String m.preset_description
    ; "created_at", `String m.preset_created_at
    ; "override_count", `Int m.override_count
    ; "keepers", strings m.keepers
    ; "assignment_count", `Int m.assignment_count
    ; "lane_count", `Int m.lane_count
    ]
;;

let manifest_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let* version = int_field fields "schema_version" in
    if version <> schema_version
    then
      Error
        (Printf.sprintf
           "manifest schema_version %d, this build reads %d"
           version
           schema_version)
    else
      let* preset_name = string_field fields "name" in
      let* preset_description = string_field fields "description" in
      let* preset_created_at = string_field fields "created_at" in
      let* override_count = int_field fields "override_count" in
      let* keepers = string_list_field fields "keepers" in
      let* () =
        match List.find_opt (fun keeper -> not (is_valid_name keeper)) keepers with
        | Some keeper -> Error ("manifest keeper name is not a file name: " ^ keeper)
        | None -> Ok ()
      in
      let* assignment_count = int_field fields "assignment_count" in
      let* lane_count = int_field fields "lane_count" in
      Ok
        { preset_name
        ; preset_description
        ; preset_created_at
        ; override_count
        ; keepers
        ; assignment_count
        ; lane_count
        }
  | _ -> Error "manifest must be an object"
;;

let runtime_to_json ~assignments ~lanes : Yojson.Safe.t =
  `Assoc
    [ ( "assignments"
      , `Assoc (List.map (fun (keeper, runtime_id) -> keeper, `String runtime_id) assignments) )
    ; ( "exact_output_lanes"
      , `Assoc
          (List.map
             (fun lane ->
               lane.id, `Assoc [ "slots", strings lane.slots; "cli_slots", strings lane.cli_slots ])
             lanes) )
    ]
;;

let runtime_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    let* assignments =
      match List.assoc_opt "assignments" fields with
      | Some (`Assoc pairs) ->
        List.fold_left
          (fun acc (keeper, value) ->
            let* acc = acc in
            match value with
            | `String runtime_id -> Ok ((keeper, runtime_id) :: acc)
            | _ -> Error ("assignment " ^ keeper ^ " must be a string"))
          (Ok [])
          pairs
        |> Result.map List.rev
      | Some _ -> Error "assignments must be an object"
      | None -> Error "assignments missing"
    in
    let* lanes =
      match List.assoc_opt "exact_output_lanes" fields with
      | Some (`Assoc pairs) ->
        List.fold_left
          (fun acc (id, value) ->
            let* acc = acc in
            match value with
            | `Assoc lane_fields ->
              let* slots = string_list_field lane_fields "slots" in
              let* cli_slots = string_list_field lane_fields "cli_slots" in
              Ok ({ id; slots; cli_slots } :: acc)
            | _ -> Error ("lane " ^ id ^ " must be an object"))
          (Ok [])
          pairs
        |> Result.map List.rev
      | Some _ -> Error "exact_output_lanes must be an object"
      | None -> Error "exact_output_lanes missing"
    in
    Ok (assignments, lanes)
  | _ -> Error "runtime.json must be an object"
;;

let part_to_json ~timing (r : part_result) : Yojson.Safe.t =
  `Assoc
    [ "effect", `String timing
    ; "applied", strings r.applied
    ; ( "skipped"
      , `List
          (List.map
             (fun (key, reason) -> `Assoc [ "key", `String key; "reason", `String reason ])
             r.skipped) )
    ]
;;

let report_to_json (r : restore_report) : Yojson.Safe.t =
  let runtime =
    match r.runtime_result with
    | Runtime_unchanged ->
      `Assoc [ "effect", `String "runtime_commit"; "status", `String "unchanged" ]
    | Runtime_committed ->
      `Assoc [ "effect", `String "runtime_commit"; "status", `String "committed" ]
    | Runtime_failed message ->
      `Assoc
        [ "effect", `String "runtime_commit"
        ; "status", `String "failed"
        ; "error", `String message
        ]
  in
  `Assoc
    [ "restored", `String r.restored
    ; "autosave", `String r.autosave
    ; "prompt_overrides", part_to_json ~timing:"immediate" r.prompt_overrides_result
    ; "instructions", part_to_json ~timing:"keeper_restart" r.instructions_result
    ; "runtime", runtime
    ]
;;

(* ── Capture ───────────────────────────────────────────────────────── *)

let capture_instructions ~base_path =
  let dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  if not (Sys.file_exists dir && Sys.is_directory dir)
  then []
  else
    Keeper_types_profile.discover_keepers_toml dir
    |> List.filter_map (function
      | Keeper_types_profile.Loaded { keeper_name = _; defaults } ->
        (* Keyed by the TOML file name, which is what restore resolves;
           [keeper.name] may differ from it. *)
        (match
           ( defaults.Keeper_types_profile_defaults.manifest_path
           , defaults.Keeper_types_profile_defaults.instructions )
         with
         | Some path, Some text ->
           Some (Filename.remove_extension (Filename.basename path), text)
         | _ -> None)
      | Keeper_types_profile.Invalid _ -> None)
;;

let parse_error_line (e : Runtime_toml.parse_error) =
  e.Runtime_toml.path ^ ": " ^ e.Runtime_toml.message
;;

let runtime_of_text text =
  match Runtime_toml.parse_string text with
  | Error errors -> Error (String.concat "; " (List.map parse_error_line errors))
  | Ok (config : Runtime_schema.config) ->
    let lanes =
      List.map
        (fun (d : Runtime_schema.exact_output_lane_decl) ->
          { id = d.Runtime_schema.id
          ; slots = d.Runtime_schema.slot_ids
          ; cli_slots = d.Runtime_schema.cli_slot_ids
          })
        config.Runtime_schema.exact_output_lane_decls
    in
    Ok (config.Runtime_schema.keeper_assignments, lanes)
;;

let capture_runtime ~base_path =
  let path = runtime_toml_path ~base_path in
  match Fs_compat.load_file_opt path with
  | None -> Ok ([], [])
  | Some text ->
    Result.map_error
      (fun message -> "runtime.toml at " ^ path ^ " does not parse: " ^ message)
      (runtime_of_text text)
;;

let capture ~base_path ~name ~description =
  if not (is_valid_name name)
  then Error ("invalid preset name: " ^ name)
  else
    guard (fun () ->
      let* assignments, lanes = capture_runtime ~base_path in
      Ok
        { name
        ; description
        ; created_at = now_iso ()
          (* Everything the operator saved, not only what is in force. A
             snapshot taken while an override is refused has to carry it, or
             the autosave a restore takes for safety is empty in exactly the
             case it was meant for. *)
        ; prompt_overrides = Prompt_registry.persisted_entries ()
        ; instructions = capture_instructions ~base_path
        ; assignments
        ; lanes
        })
;;

(* ── Files ─────────────────────────────────────────────────────────── *)

let mkdir_p path =
  match Fs_compat.mkdir_p path with
  | () -> Ok ()
  | exception Sys_error message -> Error message
  | exception Unix.Unix_error (error, operation, argument) ->
    Error (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
;;

let instruction_file dir keeper =
  Filename.concat (Filename.concat dir instructions_dir) (keeper ^ instructions_extension)
;;

(* A re-save under the same name must not leave a previous keeper's file
   behind, or [load] would hand it back as part of the preset. *)
let clear_instruction_files dir =
  let instructions = Filename.concat dir instructions_dir in
  if Sys.file_exists instructions && Sys.is_directory instructions
  then
    Fs_compat.read_dir instructions
    |> List.iter (fun file ->
      if Filename.check_suffix file instructions_extension
      then Sys.remove (Filename.concat instructions file))
;;

(* The manifest goes last and the old one goes first, so a save that stops
   midway leaves a directory without a manifest — unreadable to [load] and
   listed under [unreadable] — never an old manifest over new files. *)
let save ~base_path (s : snapshot) =
  if not (is_valid_name s.name)
  then Error ("invalid preset name: " ^ s.name)
  else
    guard (fun () ->
    let dir = preset_dir ~base_path s.name in
    let* () = mkdir_p (Filename.concat dir instructions_dir) in
    let manifest = Filename.concat dir manifest_file in
    if Sys.file_exists manifest then Sys.remove manifest;
    clear_instruction_files dir;
    let* () =
      Override.save ~path:(Filename.concat dir overrides_file) s.prompt_overrides
      |> Result.map_error Override.error_to_string
    in
    let* () =
      Fs_compat.save_file_atomic
        (Filename.concat dir runtime_file)
        (Yojson.Safe.pretty_to_string
           (runtime_to_json ~assignments:s.assignments ~lanes:s.lanes)
         ^ "\n")
    in
    let* () =
      List.fold_left
        (fun acc (keeper, text) ->
          let* () = acc in
          Fs_compat.save_file_atomic (instruction_file dir keeper) text)
        (Ok ())
        s.instructions
    in
    Fs_compat.save_file_atomic
      manifest
      (Yojson.Safe.pretty_to_string (manifest_to_json (manifest_of_snapshot s)) ^ "\n"))
;;

let read_manifest dir =
  match Fs_compat.load_file_opt (Filename.concat dir manifest_file) with
  | None -> Error "manifest.json missing"
  | Some text ->
    let* json = json_of_string text in
    manifest_of_json json
;;

let load ~base_path name =
  if not (is_valid_name name)
  then Error ("invalid preset name: " ^ name)
  else
    guard (fun () ->
    let dir = preset_dir ~base_path name in
    if not (Sys.file_exists (Filename.concat dir manifest_file))
    then Error ("preset not found: " ^ name)
    else
      let* m = read_manifest dir in
      let* prompt_overrides =
        Override.load ~path:(Filename.concat dir overrides_file)
        |> Result.map_error Override.error_to_string
      in
      let* assignments, lanes =
        match Fs_compat.load_file_opt (Filename.concat dir runtime_file) with
        | None -> Error "runtime.json missing"
        | Some text ->
          let* json = json_of_string text in
          runtime_of_json json
      in
      let* instructions =
        List.fold_left
          (fun acc keeper ->
            let* acc = acc in
            match Fs_compat.load_file_opt (instruction_file dir keeper) with
            | Some text -> Ok ((keeper, text) :: acc)
            | None -> Error ("instructions file missing for keeper " ^ keeper))
          (Ok [])
          m.keepers
        |> Result.map List.rev
      in
      Ok
        { name = m.preset_name
        ; description = m.preset_description
        ; created_at = m.preset_created_at
        ; prompt_overrides
        ; instructions
        ; assignments
        ; lanes
        })
;;

let list ~base_path =
  let dir = presets_dir ~base_path in
  if not (Sys.file_exists dir && Sys.is_directory dir)
  then { presets = []; unreadable = [] }
  else (
    match guard (fun () -> Ok (Fs_compat.read_dir dir)) with
    | Error message -> { presets = []; unreadable = [ dir, message ] }
    | Ok names ->
      names
      |> List.fold_left
           (fun acc name ->
             match
               guard (fun () ->
                 if Sys.is_directory (Filename.concat dir name)
                 then Result.map Option.some (read_manifest (Filename.concat dir name))
                 else Ok None)
             with
             | Ok (Some m) -> { acc with presets = m :: acc.presets }
             | Ok None -> acc
             | Error message -> { acc with unreadable = (name, message) :: acc.unreadable })
           { presets = []; unreadable = [] }
      |> fun acc -> { presets = List.rev acc.presets; unreadable = List.rev acc.unreadable })
;;

(* ── Restore ───────────────────────────────────────────────────────── *)

let finish (r : part_result) = { applied = List.rev r.applied; skipped = List.rev r.skipped }

let restore_prompt_overrides ~base_path (entries : Override.entry list) =
  let wanted key =
    List.exists (fun (e : Override.entry) -> String.equal e.Override.key key) entries
  in
  let cleared =
    List.fold_left
      (fun acc (e : Override.entry) ->
        if wanted e.Override.key
        then acc
        else (
          match Prompt_registry.clear_prompt_override_persisted ~base_path e.Override.key with
          | Ok () -> { acc with applied = (e.Override.key ^ " (cleared)") :: acc.applied }
          | Error message -> { acc with skipped = (e.Override.key, message) :: acc.skipped }))
      { applied = []; skipped = [] }
      (* What is in force, not what is saved: a preset that does not mention
         a key must not decide the fate of a refused override the operator is
         still holding. An explicit clear is the only thing that removes
         one. *)
      (Prompt_registry.override_entries ())
  in
  List.fold_left
    (fun acc (e : Override.entry) ->
      match
        Prompt_registry.set_override_persisted
          ~expected_contract_revision:e.Override.contract_revision
          ~base_path
          e.Override.key
          e.Override.value
      with
      | Ok () -> { acc with applied = e.Override.key :: acc.applied }
      | Error (Prompt_registry.Validation_error message)
      | Error (Prompt_registry.Persistence_error message) ->
        { acc with skipped = (e.Override.key, message) :: acc.skipped })
    cleared
    entries
  |> finish
;;

let restore_instructions ~base_path instructions =
  List.fold_left
    (fun acc (keeper, text) ->
      match Config_dir_resolver.keeper_toml_path_opt_for_base_path ~base_path keeper with
      | Some path when Sys.file_exists path ->
        (match
           Keeper_toml_loader.edit_keeper_toml_fields_strict_staged
             ~path
             [ "instructions", Keeper_toml_loader.Set (Keeper_toml_loader.Toml_string text) ]
         with
         | Ok () -> { acc with applied = keeper :: acc.applied }
         | Error failure ->
           { acc with
             skipped =
               (keeper, Fs_compat.atomic_replace_failure_to_string failure) :: acc.skipped
           })
      | Some _ | None -> { acc with skipped = (keeper, "no keeper TOML") :: acc.skipped })
    { applied = []; skipped = [] }
    instructions
  |> finish
;;

let lanes_table_prefix = "runtime.exact_output_lanes."

let lane_holds ~current_lanes lane =
  match List.find_opt (fun current -> String.equal current.id lane.id) current_lanes with
  | Some current -> current.slots = lane.slots && current.cli_slots = lane.cli_slots
  | None -> false
;;

(* Line-level edits of the two tables, so every other line of runtime.toml,
   comments included, survives. Assignment rows go through the runtime's own
   row writer (quoted keys, so a dotted keeper name stays one key). Keepers
   assigned now but absent from the preset lose their row; lanes present in
   the file but absent from the preset are left alone. A lane whose slots
   already match is not rewritten either: the array writer drops comment
   lines inside the block, and the live file keeps its lane notes there. *)
let runtime_text_with ~current_assignments ~current_lanes ~assignments ~lanes content =
  let content =
    List.fold_left
      (fun content (keeper_name, _) ->
        if List.mem_assoc keeper_name assignments
        then content
        else Runtime.remove_runtime_assignment_text content ~keeper_name)
      content
      current_assignments
  in
  let content =
    List.fold_left
      (fun content (keeper_name, runtime_id) ->
        Runtime.update_runtime_assignment_text content ~keeper_name ~runtime_id)
      content
      assignments
  in
  List.fold_left
    (fun content lane ->
      if lane_holds ~current_lanes lane
      then content
      else (
        let path = lanes_table_prefix ^ lane.id in
        let content =
          Toml_line_editor.edit_table_multiline_array content ~path ~key:"slots" ~values:lane.slots
        in
        Toml_line_editor.edit_table_multiline_array
          content
          ~path
          ~key:"cli_slots"
          ~values:lane.cli_slots))
    content
    lanes
;;

(* The preset's routing already holds in the file: the same assignment
   rows, and every preset lane present with the same slots. Compared on the
   parsed values, not the text — the writers reformat rows they touch. *)
let routing_holds ~current_assignments ~current_lanes ~assignments ~lanes =
  let sorted = List.sort compare in
  sorted current_assignments = sorted assignments
  && List.for_all (lane_holds ~current_lanes) lanes
;;

let restore_runtime ~base_path ~assignments ~lanes =
  let path = runtime_toml_path ~base_path in
  match guard (fun () -> Ok (Fs_compat.load_file_opt path)) with
  | Error message -> Runtime_failed message
  | Ok None -> Runtime_failed ("runtime.toml missing at " ^ path)
  | Ok (Some content) ->
    (match runtime_of_text content with
     | Error message -> Runtime_failed ("current runtime.toml does not parse: " ^ message)
     | Ok (current_assignments, current_lanes) ->
       if routing_holds ~current_assignments ~current_lanes ~assignments ~lanes
       then Runtime_unchanged
       else (
         let text =
           runtime_text_with ~current_assignments ~current_lanes ~assignments ~lanes content
         in
         match Runtime.save_config_text ~runtime_config_path:path text with
         | Ok _receipt -> Runtime_committed
         | Error message -> Runtime_failed message))
;;

(* The stamp has one-second resolution; a second restore inside that second
   takes the next free suffix rather than overwriting the first autosave. *)
let fresh_autosave_name ~base_path =
  let stamp = autosave_prefix ^ compact_stamp () in
  let rec pick n =
    let candidate = if n = 0 then stamp else Printf.sprintf "%s-%d" stamp n in
    if Sys.file_exists (preset_dir ~base_path candidate) then pick (n + 1) else candidate
  in
  pick 0
;;

let restore ~base_path name =
  let* target = load ~base_path name in
  let autosave = fresh_autosave_name ~base_path in
  let* current =
    capture ~base_path ~name:autosave ~description:("state before restoring " ^ name)
  in
  let* () = save ~base_path current in
  let prompt_overrides_result = restore_prompt_overrides ~base_path target.prompt_overrides in
  let instructions_result = restore_instructions ~base_path target.instructions in
  let runtime_result =
    restore_runtime ~base_path ~assignments:target.assignments ~lanes:target.lanes
  in
  Ok { restored = name; autosave; prompt_overrides_result; instructions_result; runtime_result }
;;
