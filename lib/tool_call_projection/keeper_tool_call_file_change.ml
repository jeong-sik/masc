type location =
  | In_repo of {
      repo_id : string;
      relative_path : string;
    }
  | In_bundle of { bundle_path : string }
  | At_absolute_path of { path : string }

type kind =
  | Edited of {
      before : string;
      after : string;
      replace_all : bool;
    }
  | Written of { content : string }

type t = {
  at : float;
  keeper : string;
  turn : int option;
  task_id : string option;
  execution_id : string option;
  line_evidence : Keeper_file_change_evidence.t option;
  location : location;
  kind : kind;
  succeeded : bool;
}

type unreadable_reason =
  | Input_exceeded_log_budget
  | Malformed of string

type classification =
  | Not_a_file_change
  | File_change of t
  | Unreadable of unreadable_reason

(* What the row says it ran. Three answers, because two of them are ordinary
   and one is a defect, and collapsing them would bury the defect. *)
type named_tool =
  | Handler of Keeper_tool_descriptor.runtime_handler
  | Not_descriptor_backed
      (** Composition-surface tools carry no descriptor id at all — see
          {!Keeper_tool_call_log.log_call}. They do not write files. *)
  | Unknown_descriptor of string
      (** A descriptor id this build does not define. *)

(* Which tool the call ran, as the descriptor registry defines it rather than
   as the row spells it. The log carries both a display name ("Edit") and the
   descriptor id its route evidence recorded ("agent.edit_file"); only the
   second is the registry's own key, and only the registry knows which handler
   sits behind it. Matching the display name here would put a second, drifting
   copy of the tool table in this module. *)
let named_tool_of_row row =
  match Json_field.assoc row "route_evidence" with
  | Json_field.Field_absent | Json_field.Wrong_shape _ -> Not_descriptor_backed
  | Json_field.Found fields -> (
      match Json_field.string (`Assoc fields) "descriptor_id" with
      | Json_field.Field_absent | Json_field.Wrong_shape _ -> Not_descriptor_backed
      | Json_field.Found id -> (
          match Keeper_tool_descriptor.find_id id with
          | Some d -> Handler d.Keeper_tool_descriptor.runtime_handler
          | None -> Unknown_descriptor id))

(* Every handler is named. A new file-writing tool added to the registry
   should stop this build rather than be classified as a read, which is what
   a [_ -> Not_a_file_change] arm would do silently. *)
let writes_files (handler : Keeper_tool_descriptor.runtime_handler) =
  match handler with
  | Keeper_tool_descriptor.Tool_edit_file | Keeper_tool_descriptor.Tool_write_file -> true
  | Keeper_tool_descriptor.Tool_execute
  | Keeper_tool_descriptor.Tool_search_files
  | Keeper_tool_descriptor.Tool_read_file
  | Keeper_tool_descriptor.Tool_time_now
  | Keeper_tool_descriptor.Tool_lane_status
  | Keeper_tool_descriptor.Tool_tools_list
  | Keeper_tool_descriptor.Tool_capability_search
  | Keeper_tool_descriptor.Tool_context_status
  | Keeper_tool_descriptor.Tool_artifact_read
  | Keeper_tool_descriptor.Tool_memory_search
  | Keeper_tool_descriptor.Tool_memory_retract
  | Keeper_tool_descriptor.Tool_memory_write
  | Keeper_tool_descriptor.Tool_library_search
  | Keeper_tool_descriptor.Tool_library_read
  | Keeper_tool_descriptor.Tool_surface_read
  | Keeper_tool_descriptor.Tool_surface_post
  | Keeper_tool_descriptor.Tool_person_note_set
  | Keeper_tool_descriptor.Tool_ide_annotate
  | Keeper_tool_descriptor.Tool_voice_dispatch
  | Keeper_tool_descriptor.Tool_task_dispatch
  | Keeper_tool_descriptor.Tool_board_dispatch
  | Keeper_tool_descriptor.Tool_masc_task_dispatch
  | Keeper_tool_descriptor.Tool_masc_plan_dispatch
  | Keeper_tool_descriptor.Tool_masc_run_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_dispatch
  | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
  | Keeper_tool_descriptor.Tool_masc_misc_dispatch
  | Keeper_tool_descriptor.Tool_web_search
  | Keeper_tool_descriptor.Tool_web_fetch
  | Keeper_tool_descriptor.Tool_masc_control_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
  | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
  | Keeper_tool_descriptor.Tool_keeper_spawn_dispatch
  | Keeper_tool_descriptor.Tool_keeper_code_query_dispatch
  | Keeper_tool_descriptor.Tool_keeper_webmcp_dispatch
  | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_status
  | Keeper_tool_descriptor.Tool_masc_library_dispatch
  | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch
  | Keeper_tool_descriptor.Tool_analyze_image -> false

let optional_string row key = Json_field.to_option (Json_field.string row key)
let optional_int row key = Json_field.to_option (Json_field.int row key)

let required_string row key =
  match Json_field.string row key with
  | Json_field.Found value -> Ok value
  | Json_field.Field_absent -> Error (Malformed (Printf.sprintf "%s is absent" key))
  | Json_field.Wrong_shape { expected; got } ->
      Error (Malformed (Printf.sprintf "%s is %s, expected %s" key got expected))

(* The target as the write path resolved it, not as the model typed it.
   [input.file_path] is the raw tool argument and carries whichever vocabulary
   the keeper happened to use (#28582); [action_radius.target_path] is the
   resolver's output.

   The resolver's output is mostly bundle-relative and sometimes absolute --
   528 against 40 over 2026-08-22..24 -- so the shape is decided by looking,
   not assumed. *)
let target_path_of_row row =
  match Json_field.assoc row "action_radius" with
  | Json_field.Field_absent -> Error (Malformed "action_radius is absent")
  | Json_field.Wrong_shape { expected; got } ->
      Error (Malformed (Printf.sprintf "action_radius is %s, expected %s" got expected))
  | Json_field.Found fields -> required_string (`Assoc fields) "target_path"

let line_evidence_of_row row =
  match Json_field.assoc row "file_change_evidence" with
  | Json_field.Field_absent -> Ok None
  | Json_field.Wrong_shape { expected; got } ->
    Error
      (Malformed
         (Printf.sprintf "file_change_evidence is %s, expected %s" got expected))
  | Json_field.Found fields ->
    (match Keeper_file_change_evidence.of_yojson (`Assoc fields) with
     | Ok evidence -> Ok (Some evidence)
     | Error detail -> Error (Malformed ("file_change_evidence: " ^ detail)))

let validate_line_evidence ~execution_id ~succeeded kind line_evidence =
  match kind, line_evidence with
  | _, None -> Ok ()
  | _, Some _
    when Option.fold
           ~none:true
           ~some:(fun value -> String.trim value = "")
           execution_id ->
    Error (Malformed "file_change_evidence has no canonical execution_id")
  | _, Some _ when not succeeded ->
    Error (Malformed "failed file change carries completed line evidence")
  | Edited { replace_all = false; _ },
    Some
      (Keeper_file_change_evidence.Edited
        { occurrence_count; occurrences = _ })
    when occurrence_count <> 1 ->
    Error
      (Malformed
         "single Edit carries a file_change_evidence occurrence_count other than one")
  | Edited _, Some (Keeper_file_change_evidence.Edited _)
  | Written _, Some (Keeper_file_change_evidence.Written _) -> Ok ()
  | Edited _, Some (Keeper_file_change_evidence.Written _) ->
    Error (Malformed "edit input carries write file_change_evidence")
  | Written _, Some (Keeper_file_change_evidence.Edited _) ->
    Error (Malformed "write input carries edit file_change_evidence")

(* Where the target sits. A relative target is read as the bundle-relative
   path it is, not rebuilt into an absolute one first: whether the keeper ran
   local or in Docker changes where its bundle sits on disk and nothing about
   the path inside it, so composing an absolute path here would mean picking a
   sandbox flavour this projection has no reason to know.

   An absolute target is reported as one. It is neither a repository address
   nor a path under a bundle root, and calling it either would put a name on
   the file that nothing can resolve. *)
let location_of_target ~target_path =
  if not (Filename.is_relative target_path) then At_absolute_path { path = target_path }
  else
    match Playground_paths.parse_bundle_relative_repo_path target_path with
    | Some (repo_id, relative_path) -> In_repo { repo_id; relative_path }
    | None -> In_bundle { bundle_path = target_path }

let kind_of_input ~(handler : Keeper_tool_descriptor.runtime_handler) input =
  match handler with
  | Keeper_tool_descriptor.Tool_edit_file -> (
      match (required_string input "old_string", required_string input "new_string") with
      | Ok before, Ok after ->
          (* [replace_all] is optional in the tool's own schema, and its
             absence means the call replaced one occurrence. *)
          let replace_all =
            Option.value ~default:false (Json_field.to_option (Json_field.bool input "replace_all"))
          in
          Ok (Edited { before; after; replace_all })
      | Error detail, _ | _, Error detail -> Error detail)
  | Keeper_tool_descriptor.Tool_write_file -> (
      match required_string input "content" with
      | Ok content -> Ok (Written { content })
      | Error detail -> Error detail)
  | Keeper_tool_descriptor.Tool_execute
  | Keeper_tool_descriptor.Tool_search_files
  | Keeper_tool_descriptor.Tool_read_file
  | Keeper_tool_descriptor.Tool_time_now
  | Keeper_tool_descriptor.Tool_lane_status
  | Keeper_tool_descriptor.Tool_tools_list
  | Keeper_tool_descriptor.Tool_capability_search
  | Keeper_tool_descriptor.Tool_context_status
  | Keeper_tool_descriptor.Tool_artifact_read
  | Keeper_tool_descriptor.Tool_memory_search
  | Keeper_tool_descriptor.Tool_memory_retract
  | Keeper_tool_descriptor.Tool_memory_write
  | Keeper_tool_descriptor.Tool_library_search
  | Keeper_tool_descriptor.Tool_library_read
  | Keeper_tool_descriptor.Tool_surface_read
  | Keeper_tool_descriptor.Tool_surface_post
  | Keeper_tool_descriptor.Tool_person_note_set
  | Keeper_tool_descriptor.Tool_ide_annotate
  | Keeper_tool_descriptor.Tool_voice_dispatch
  | Keeper_tool_descriptor.Tool_task_dispatch
  | Keeper_tool_descriptor.Tool_board_dispatch
  | Keeper_tool_descriptor.Tool_masc_task_dispatch
  | Keeper_tool_descriptor.Tool_masc_plan_dispatch
  | Keeper_tool_descriptor.Tool_masc_run_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_dispatch
  | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
  | Keeper_tool_descriptor.Tool_masc_misc_dispatch
  | Keeper_tool_descriptor.Tool_web_search
  | Keeper_tool_descriptor.Tool_web_fetch
  | Keeper_tool_descriptor.Tool_masc_control_dispatch
  | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
  | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
  | Keeper_tool_descriptor.Tool_keeper_spawn_dispatch
  | Keeper_tool_descriptor.Tool_keeper_code_query_dispatch
  | Keeper_tool_descriptor.Tool_keeper_webmcp_dispatch
  | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
  | Keeper_tool_descriptor.Tool_masc_fusion_status
  | Keeper_tool_descriptor.Tool_masc_library_dispatch
  | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch
  | Keeper_tool_descriptor.Tool_analyze_image ->
      (* Unreachable through [classify], which asks [writes_files] first. Named
         so that adding a file-writing handler makes the compiler point here
         too, instead of letting the new tool fall into a wildcard. *)
      Error (Malformed "handler does not write files")

let classify row =
  match named_tool_of_row row with
  | Not_descriptor_backed -> Not_a_file_change
  | Unknown_descriptor id ->
      (* Present but undefined here. It cannot be shown to be a read, so it is
         reported rather than counted as one. *)
      Unreadable (Malformed (Printf.sprintf "descriptor %s is not defined in this build" id))
  | Handler handler ->
      if not (writes_files handler) then Not_a_file_change
      else
        let input =
          match Json_field.assoc row "input" with
          | Json_field.Found fields -> Ok (`Assoc fields)
          | Json_field.Field_absent -> Error (Malformed "input is absent")
          | Json_field.Wrong_shape { got = "string"; _ } ->
              (* The log flattens a call's arguments to a preview string once
                 they serialize past its inline budget
                 ([Keeper_tool_call_log.max_output_len]). A string here is that
                 and only that: nothing else in the writer produces one. The
                 change happened; its text is not on disk to be read back. *)
              Error Input_exceeded_log_budget
          | Json_field.Wrong_shape { expected; got } ->
              Error (Malformed (Printf.sprintf "input is %s, expected %s" got expected))
        in
        let parsed =
          Result.bind input (fun input ->
              Result.bind (kind_of_input ~handler input) (fun kind ->
                  let succeeded =
                    Option.value ~default:false
                      (Json_field.to_option (Json_field.bool row "success"))
                  in
                  let execution_id = optional_string row "execution_id" in
                  Result.bind (line_evidence_of_row row) (fun line_evidence ->
                    Result.bind
                      (validate_line_evidence
                         ~execution_id
                         ~succeeded
                         kind
                         line_evidence)
                      (fun () ->
                        Result.bind (target_path_of_row row) (fun target_path ->
                          Result.bind (required_string row "keeper") (fun keeper ->
                          let at =
                            Option.value ~default:0.
                              (Json_field.to_option (Json_field.float row "ts"))
                          in
                          Ok
                            { at
                            ; keeper
                            ; turn = optional_int row "turn"
                            ; task_id = optional_string row "task_id"
                            ; execution_id
                            ; line_evidence
                            ; location = location_of_target ~target_path
                            ; kind
                            ; succeeded
                            }))))))
        in
        (match parsed with
         | Ok change -> File_change change
         | Error detail -> Unreadable detail)

type tally = {
  changes : t list;
  unreadable_rows : unreadable_row list;
  not_file_changes : int;
  over_budget : int;
  malformed : int;
}

and unreadable_row = {
  ur_location : location option;
  ur_reason : unreadable_reason;
}

let classify_all rows =
  let tally =
    List.fold_left
      (fun tally row ->
        match classify row with
        | File_change change -> { tally with changes = change :: tally.changes }
        | Not_a_file_change -> { tally with not_file_changes = tally.not_file_changes + 1 }
        | Unreadable reason ->
          let ur_location =
            match target_path_of_row row with
            | Ok target_path -> Some (location_of_target ~target_path)
            | Error _ -> None
          in
          { tally with
            unreadable_rows = { ur_location; ur_reason = reason } :: tally.unreadable_rows
          ; over_budget =
              (match reason with
               | Input_exceeded_log_budget -> tally.over_budget + 1
               | Malformed _ -> tally.over_budget)
          ; malformed =
              (match reason with
               | Input_exceeded_log_budget -> tally.malformed
               | Malformed _ -> tally.malformed + 1)
          })
      { changes = []
      ; unreadable_rows = []
      ; not_file_changes = 0
      ; over_budget = 0
      ; malformed = 0
      }
      rows
  in
  { tally with
    changes = List.rev tally.changes
  ; unreadable_rows = List.rev tally.unreadable_rows
  }

let for_repo_file ~repo_id ~relative_path changes =
  List.filter
    (fun change ->
      match change.location with
      | In_repo address ->
        String.equal address.repo_id repo_id
        && String.equal address.relative_path relative_path
      | In_bundle _ | At_absolute_path _ -> false)
    changes

let unreadable_for_repo_file ~repo_id ~relative_path rows =
  List.filter
    (fun row ->
      match row.ur_location with
      | Some (In_repo address) ->
        String.equal address.repo_id repo_id
        && String.equal address.relative_path relative_path
      | Some (In_bundle _ | At_absolute_path _) | None -> false)
    rows

let location_to_json = function
  | In_repo { repo_id; relative_path } ->
      `Assoc
        [ ("kind", `String "repo")
        ; ("repo_id", `String repo_id)
        ; ("path", `String relative_path)
        ]
  | In_bundle { bundle_path } ->
      `Assoc [ ("kind", `String "bundle"); ("path", `String bundle_path) ]
  | At_absolute_path { path } -> `Assoc [ ("kind", `String "absolute"); ("path", `String path) ]

let kind_to_json = function
  | Edited { before; after; replace_all } ->
      `Assoc
        [ ("kind", `String "edit")
        ; ("before", `String before)
        ; ("after", `String after)
        ; ("replace_all", `Bool replace_all)
        ]
  | Written { content } -> `Assoc [ ("kind", `String "write"); ("content", `String content) ]

let optional_json to_json = function None -> `Null | Some value -> to_json value

let to_json change =
  `Assoc
    [ ("at", `Float change.at)
    ; ("keeper", `String change.keeper)
    ; ("turn", optional_json (fun turn -> `Int turn) change.turn)
    ; ("task_id", optional_json (fun id -> `String id) change.task_id)
    ; ("execution_id", optional_json (fun id -> `String id) change.execution_id)
    ; ( "line_evidence"
      , optional_json Keeper_file_change_evidence.to_yojson change.line_evidence )
    ; ("location", location_to_json change.location)
    ; ("change", kind_to_json change.kind)
    ; ("succeeded", `Bool change.succeeded)
    ]
