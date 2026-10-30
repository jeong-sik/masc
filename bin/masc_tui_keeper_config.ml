(* Pure projection for the Keeper settings surface and its $EDITOR round-trip.
   Keeping this apart from HTTP makes the important promise testable: the
   editor starts from observed values, while the PATCH contains only values the
   operator actually changed. *)

let member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let member_path path json =
  List.fold_left
    (fun current key -> Option.bind current (member key))
    (Some json) path

type editable_field =
  | Direct of string * string list
  | Skill_selection

let editable_fields =
  [ Direct ("runtime_id", [ "execution"; "selected_runtime_id" ])
  ; Direct ("mention_targets", [ "workspace"; "mention_targets" ])
  ; Direct ("board_interests", [ "workspace"; "board_interests" ])
  ; Direct ("activation_mode", [ "activation_mode" ])
  ; Direct ("input_policy", [ "input_policy" ])
  ; Direct ("max_context_override", [ "max_context_override" ])
  ; Direct ("sandbox_profile", [ "sandbox_profile" ])
  ; Direct ("remote_endpoint", [ "remote_endpoint" ])
  ; Direct ("network_mode", [ "network_mode" ])
  ; Direct ("instructions", [ "prompt"; "instructions" ])
  ; Skill_selection
  ]

let editable_field_name = function
  | Direct (name, _) -> name
  | Skill_selection -> "skills"

(* The read contract represents the default selection as [names: null], while
   the write contract represents it as an empty [skills] object. Normalize at
   this projection boundary so every value shown in the editor is also a valid
   partial update. *)
let editable_field_value json = function
  | Direct (_, path) -> member_path path json
  | Skill_selection -> (
    match member_path [ "skills"; "names" ] json with
    | Some `Null -> Some (`Assoc [])
    | Some (`List names) -> Some (`Assoc [ "names", `List names ])
    | Some _ | None -> None)

let editable_snapshot json =
  `Assoc
    (List.filter_map
       (fun field ->
         Option.map
           (fun value -> editable_field_name field, value)
           (editable_field_value json field))
       editable_fields)

let editor_stem json =
  editable_snapshot json |> Yojson.Safe.pretty_to_string |> fun text -> text ^ "\n"

let editable_field_names = List.map editable_field_name editable_fields

(* Control key, not a setting: the server refuses a patch that lowers
   [max_context_override] unless it carries this flag, and its refusal tells
   the operator to re-send with it. Without accepting the key here that
   instruction was impossible to follow — [patch_of_edit] answered
   "unknown keeper setting(s): confirm_context_shrink" and the TUI had no way
   at all to shrink a keeper's context window. It stays out of
   [editable_fields] so it never appears in the editor stem or the view: the
   operator types it only when the server has asked for it. SSOT for the name
   is the server's [confirm_context_shrink_field]. *)
let confirm_context_shrink_field = "confirm_context_shrink"

let is_lowercase_sha256 = String_util.is_lowercase_sha256_hex

let exact_keys expected fields =
  List.length fields = List.length expected
  && List.for_all (fun key -> List.mem_assoc key fields) expected

(* The wire shape is parsed ONCE into these closed types; validation is the
   parser and rendering is a total function over the result. The previous
   arrangement kept four validate_* and four render_* functions matching the
   same JSON in parallel — the same value was matched up to three times, and
   the render side re-decided validity with the diagnostics erased. *)
type manifest_revision =
  | Manifest_missing
  | Manifest_sha256 of string

type runtime_assignment =
  | Assignment_absent
  | Assignment_assigned of string

type runtime_assignment_revision =
  | Runtime_config_missing
  | Runtime_config_present of
      { source_revision : string
      ; assignment : runtime_assignment
      }

type config_revision =
  { manifest : manifest_revision
  ; runtime_assignment : runtime_assignment_revision
  }

(* The server answers {state:"unavailable", detail} in place of the revision
   pair when it could not read it (dashboard_http_keeper_snapshot). That is
   an answer to show, not an invalid document. *)
type config_revision_state =
  | Revision of config_revision
  | Revision_unavailable of string

let manifest_revision_of_json = function
  | `Assoc [ ("state", `String "missing") ] -> Ok Manifest_missing
  | `Assoc fields when exact_keys [ "state"; "value" ] fields ->
    (match List.assoc_opt "state" fields, List.assoc_opt "value" fields with
     | Some (`String "sha256"), Some (`String value)
       when is_lowercase_sha256 value -> Ok (Manifest_sha256 value)
     | _ -> Error "keeper config manifest revision is invalid")
  | _ -> Error "keeper config manifest revision is invalid"

let runtime_assignment_of_json = function
  | `Assoc [ ("state", `String "missing") ] -> Ok Assignment_absent
  | `Assoc fields when exact_keys [ "state"; "runtime_id" ] fields ->
    (match List.assoc_opt "state" fields, List.assoc_opt "runtime_id" fields with
     | Some (`String "assigned"), Some (`String runtime_id)
       when String.trim runtime_id <> "" -> Ok (Assignment_assigned runtime_id)
     | _ -> Error "keeper runtime assignment state is invalid")
  | _ -> Error "keeper runtime assignment state is invalid"

let runtime_assignment_revision_of_json = function
  | `Assoc [ ("state", `String "runtime_config_missing") ] ->
    Ok Runtime_config_missing
  | `Assoc fields
    when exact_keys [ "state"; "source_revision"; "assignment" ] fields ->
    (match
       List.assoc_opt "state" fields,
       List.assoc_opt "source_revision" fields,
       List.assoc_opt "assignment" fields
     with
     | ( Some (`String "runtime_config_present")
       , Some (`String source_revision)
       , Some assignment )
       when is_lowercase_sha256 source_revision ->
       Result.map
         (fun assignment ->
           Runtime_config_present { source_revision; assignment })
         (runtime_assignment_of_json assignment)
     | _ -> Error "keeper runtime assignment revision is invalid")
  | _ -> Error "keeper runtime assignment revision is invalid"

let config_revision_state_of_json = function
  | `Assoc fields when exact_keys [ "state"; "detail" ] fields ->
    (match List.assoc_opt "state" fields, List.assoc_opt "detail" fields with
     | Some (`String "unavailable"), Some (`String detail) ->
       Ok (Revision_unavailable detail)
     | _ -> Error "keeper config revision is invalid")
  | `Assoc fields
    when exact_keys [ "manifest"; "runtime_assignment" ] fields ->
    (match
       List.assoc_opt "manifest" fields,
       List.assoc_opt "runtime_assignment" fields
     with
     | Some manifest, Some runtime_assignment ->
       Result.bind
         (manifest_revision_of_json manifest)
         (fun manifest ->
           Result.map
             (fun runtime_assignment -> Revision { manifest; runtime_assignment })
             (runtime_assignment_revision_of_json runtime_assignment))
     | _ -> Error "keeper config revision is incomplete")
  | _ -> Error "keeper config revision is invalid"

let expected_config_revision before =
  match member "config_revision" before with
  | Some revision ->
    (match config_revision_state_of_json revision with
     | Ok (Revision _) -> Ok revision
     | Ok (Revision_unavailable detail) ->
       (* Posting the unavailable marker as a CAS expected value can only
          fail later with a worse message; stop with the server's own. *)
       Error ("keeper config revision is unavailable: " ^ detail)
     | Error _ as error -> error)
  | None -> Error "keeper config revision was not observed"

let expected_runtime_assignment_revision before =
  Result.bind
    (expected_config_revision before)
    (fun revision ->
      match member "runtime_assignment" revision with
      | Some runtime_assignment -> Ok runtime_assignment
      | None -> Error "keeper runtime assignment revision was not observed")

type prior_assignment =
  | Prior_assigned of string
  | Prior_workspace_default

(* The assignment a write was fenced on, read from the same revision the
   request carries as [expected_assignment_revision]. A missing config file and
   a present file with no assignment both leave the Keeper on the workspace
   default. Anything else the revision says is not guessed at. *)
let prior_runtime_assignment revision =
  match member "state" revision with
  | Some (`String "runtime_config_missing") -> Ok Prior_workspace_default
  | Some (`String "runtime_config_present") ->
    (match member_path [ "assignment"; "state" ] revision with
     | Some (`String "missing") -> Ok Prior_workspace_default
     | Some (`String "assigned") ->
       (match member_path [ "assignment"; "runtime_id" ] revision with
        | Some (`String runtime_id) when String.trim runtime_id <> "" ->
          Ok (Prior_assigned runtime_id)
        | Some _ | None -> Error "assigned runtime revision has no runtime_id")
     | Some _ | None -> Error "runtime assignment revision has no readable assignment state")
  | Some _ | None -> Error "runtime assignment revision has no readable state"

type runtime_assignment_unchanged = {
  revision : Yojson.Safe.t;
  warnings : Masc_tui_runtime_config_receipt.lock_warning list;
  response : Yojson.Safe.t;
}

type runtime_assignment_write =
  | Assignment_committed of Masc_tui_runtime_config_receipt.t
  | Assignment_unchanged of runtime_assignment_unchanged

let decode_unchanged_runtime_assignment_response json =
  let open Result.Syntax in
  match json with
  | `Assoc fields when exact_keys ["ok";"applied";"assignment_revision";"warnings"] fields ->
      (match List.assoc_opt "ok" fields, List.assoc_opt "applied" fields,
             List.assoc_opt "assignment_revision" fields, List.assoc_opt "warnings" fields with
       | Some (`Bool true), Some (`Bool false), Some revision, Some (`List warnings) ->
           let* _ = runtime_assignment_revision_of_json revision in
           let rec decode acc = function
             | [] -> Ok (List.rev acc)
             | `Assoc fields :: rest when exact_keys ["code";"detail"] fields ->
                 (match List.assoc_opt "code" fields,List.assoc_opt "detail" fields with
                  | Some (`String code),Some (`String detail) ->
                      decode ({Masc_tui_runtime_config_receipt.code;detail} :: acc) rest
                  | _ -> Error "malformed assignment lock warning")
             | _ -> Error "malformed assignment lock warning" in
           let* warnings = decode [] warnings in
           Ok {revision;warnings;response=json}
       | _ -> Error "runtime assignment response is not an unchanged write")
  | _ -> Error "runtime assignment response must be an object"

type runtime_assignment_post_error =
  | Assignment_revision_conflict of Yojson.Safe.t
  | Assignment_auth_refused of { status : int; body : string }
  | Assignment_outcome_unconfirmed of string

let decode_runtime_assignment_answer ~status ~body =
  let unknown detail = Error (Assignment_outcome_unconfirmed detail) in
  if status = 401 || status = 403 then Error (Assignment_auth_refused {status;body})
  else match Yojson.Safe.from_string body with
  | exception Yojson.Json_error detail -> unknown (Printf.sprintf "HTTP %d: invalid assignment response: %s" status detail)
  | json when status >= 200 && status < 300 ->
      let decoded = match member "applied" json with
        | Some (`Bool false) ->
            decode_unchanged_runtime_assignment_response json
            |> Result.map (fun unchanged -> Assignment_unchanged unchanged)
        | None -> Masc_tui_runtime_config_receipt.decode json |> Result.map (fun receipt -> Assignment_committed receipt)
        | Some _ -> Error "unexpected assignment applied discriminator" in
      decoded |> Result.map_error (fun detail -> Assignment_outcome_unconfirmed detail)
  | json when status = 409 ->
      let uncertain () = unknown (Printf.sprintf "HTTP %d: %s" status body) in
      (match json with
       | `Assoc fields when exact_keys ["ok";"error"] fields ->
           (match member "ok" json,member "error" json with
            | Some (`Bool false),Some (`Assoc error) when exact_keys ["code";"expected";"observed"] error ->
                (match List.assoc_opt "code" error,List.assoc_opt "expected" error,List.assoc_opt "observed" error with
                 | Some (`String "runtime_assignment_revision_conflict"),Some expected,Some observed ->
                     (match runtime_assignment_revision_of_json expected,runtime_assignment_revision_of_json observed with
                      | Ok _,Ok _ -> Error (Assignment_revision_conflict json)
                      | Error _,_ | _,Error _ -> uncertain ())
                 | _ -> uncertain ())
            | _ -> uncertain ())
       | _ -> uncertain ())
  | _ -> unknown (Printf.sprintf "HTTP %d: %s" status body)

let config_write_warning_codes json =
  match member "config_write" json with
  | Some (`Assoc fields)
    when exact_keys [ "revision"; "applied"; "warnings" ] fields ->
    (match
       List.assoc_opt "revision" fields,
       List.assoc_opt "applied" fields,
       List.assoc_opt "warnings" fields
     with
     | Some revision, Some (`Bool _), Some (`List warnings) ->
       (* A write receipt's revision is the pair the write produced; the
          unavailable marker there is a contract violation, matching the
          dashboard's reading of the same receipt. *)
       Result.bind
         (match config_revision_state_of_json revision with
          | Ok (Revision _) -> Ok ()
          | Ok (Revision_unavailable detail) ->
            Error ("config write revision is unavailable: " ^ detail)
          | Error _ as error -> error)
         (fun () ->
           let rec decode acc = function
             | [] -> Ok (List.rev acc)
             | `Assoc warning_fields :: rest
               when exact_keys [ "code"; "detail" ] warning_fields ->
               (match
                  List.assoc_opt "code" warning_fields,
                  List.assoc_opt "detail" warning_fields
                with
                | Some (`String code), Some (`String detail)
                  when String.trim code <> "" && String.trim detail <> "" ->
                  decode (code :: acc) rest
                | _ -> Error "config durability warning is malformed")
             | _ -> Error "config durability warning is malformed"
           in
           decode [] warnings)
     | _ -> Error "config_write receipt is malformed")
  | Some _ -> Error "config_write receipt is malformed"
  | None -> Error "config_write receipt is missing"

type runtime_sync =
  | Lane_restarted
  | Deferred_until_turn_end

let runtime_sync_of_response json =
  match member "runtime_sync" json with
  | Some (`String "lane_restarted") -> Ok Lane_restarted
  | Some (`String "deferred_until_turn_end") -> Ok Deferred_until_turn_end
  | Some _ -> Error "runtime_sync is not a known success state"
  | None -> Error "runtime_sync is missing"

let config_write_status_message ~keeper_name json =
  Result.bind (runtime_sync_of_response json) (fun runtime_sync ->
    let timing =
      match runtime_sync with
      | Lane_restarted -> ""
      | Deferred_until_turn_end ->
        " (a turn is running; the next turn uses the new settings)"
    in
    Result.map
      (function
        | [] -> "system", keeper_name ^ ": changed settings applied" ^ timing
        | warning_codes ->
          ( "error"
          , Printf.sprintf
              "%s: settings applied with %d config durability warning(s): %s%s"
              keeper_name
              (List.length warning_codes)
              (String.concat ", " warning_codes)
              timing ))
      (config_write_warning_codes json))

type edit_refusal =
  | Fix_in_editor of string
  | Cannot_send of string

let edit_refusal_to_string = function
  | Fix_in_editor detail | Cannot_send detail -> detail

let activation_values =
  Masc.Keeper_activation_mode.all
  |> List.map Masc.Keeper_activation_mode.to_string
  |> String.concat " | "

(* The server parses activation_mode with the same [of_string] and refuses
   anything else with one status line. Parsing it here, before the request,
   turns that refusal into something the operator can fix where they typed
   it. No alias: the value set stays the server's closed set. *)
let activation_refusal edited_fields =
  match List.assoc_opt "activation_mode" edited_fields with
  | None -> None
  | Some (`String raw) when Option.is_some (Masc.Keeper_activation_mode.of_string raw) ->
    None
  | Some value ->
    Some
      (* The allowed set leads: a status line cuts the tail at the terminal
         width, and the set is what the operator needs to read. *)
      (Printf.sprintf "activation_mode must be %s, not %s" activation_values
         (Yojson.Safe.to_string value))

let patch_of_edit ~before ~after =
  match after with
  | `Assoc edited_fields ->
      let unknown =
        edited_fields
        |> List.filter_map (fun (key, _) ->
               if List.mem key editable_field_names
                  || String.equal key confirm_context_shrink_field
               then None
               else Some key)
      in
      if unknown <> [] then
        Error
          (Fix_in_editor
             ("unknown keeper setting(s): " ^ String.concat ", " unknown))
      else
        (match activation_refusal edited_fields with
        | Some reason -> Error (Fix_in_editor reason)
        | None ->
        let before_fields =
          match editable_snapshot before with
          | `Assoc fields -> fields
          | _ -> assert false
        in
        let changed =
          edited_fields
          |> List.filter (fun (key, value) ->
                 String.equal key confirm_context_shrink_field
                 ||
                 match List.assoc_opt key before_fields with
                 | Some old_value -> not (Yojson.Safe.equal value old_value)
                 | None -> true)
        in
        (* The confirm flag alone is not an edit. Sending it on its own would
           post a patch that changes nothing and still burn a revision. *)
        let settings_changed =
          List.filter
            (fun (key, _) -> not (String.equal key confirm_context_shrink_field))
            changed
        in
        if settings_changed = []
        then Ok (`Assoc [])
        else
          expected_config_revision before
          |> Result.map (fun revision ->
                 `Assoc (("expected_config_revision", revision) :: changed))
          |> Result.map_error (fun detail -> Cannot_send detail))
  | _ -> Error (Fix_in_editor "keeper settings must remain a JSON object")

(* The editor reopens on a refusal the operator can fix, with the reason as a
   [//] line on top: Yojson reads line comments, so the reopened text parses
   exactly as the operator left it. Earlier refusal lines are dropped first,
   so a second refusal replaces the first instead of stacking above it. *)
let reopened_stem ~reason edited =
  let one_line = String.map (function '\n' | '\r' -> ' ' | c -> c) reason in
  let rec drop_refusals = function
    | line :: rest when String.starts_with ~prefix:"//" (String.trim line) ->
      drop_refusals rest
    | lines -> lines
  in
  let body = String.split_on_char '\n' edited |> drop_refusals |> String.concat "\n" in
  "// " ^ one_line ^ "\n" ^ body

let remote_endpoint_names snapshot =
  match member "remote_ssh_endpoints" snapshot with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "state" fields with
     | Some (`String "unavailable") ->
       let detail = match List.assoc_opt "detail" fields with
         | Some (`String detail) -> detail
         | Some _ | None -> "endpoint registry is unavailable" in
       Error detail
     | Some (`String "available") ->
       (match List.assoc_opt "endpoints" fields with
        | Some (`List endpoints) ->
          List.fold_left
            (fun result endpoint ->
               let open Result.Syntax in
               let* names = result in
               match member "name" endpoint with
               | Some (`String name) when String.trim name <> "" && not (List.mem name names) ->
                 Ok (name :: names)
               | Some _ | None -> Error "endpoint registry has an invalid or duplicate name")
            (Ok []) endpoints
          |> Result.map List.rev
        | Some _ | None -> Error "endpoint registry has no endpoint list")
     | Some _ | None -> Error "endpoint registry has an unknown state")
  | Some _ | None -> Error "endpoint registry was not observed; refresh Keeper settings"

let sandbox_patch ~profile snapshot =
  let open Result.Syntax in
  let* revision = expected_config_revision snapshot in
  let* current = match member "sandbox_profile" snapshot with
    | Some (`String value) ->
        (match Keeper_sandbox_config.sandbox_profile_of_string value with
         | Some profile -> Ok profile | None -> Error "unknown observed sandbox profile")
    | Some _ | None -> Error "sandbox profile was not observed" in
  let* observed_endpoint = match member "remote_endpoint" snapshot with
    | Some `Null | None -> Ok None
    | Some (`String name) when String.trim name <> "" -> Ok (Some name)
    | Some _ -> Error "remote endpoint was not observed as a name or null" in
  let* network_mode = match member "network_mode" snapshot with
    | Some (`String raw) ->
      (match Masc.Keeper_types_profile.network_mode_of_string raw with
       | Some mode -> Ok mode
       | None -> Error "unknown observed sandbox network mode")
    | Some _ | None -> Error "sandbox network mode was not observed" in
  let* endpoint = match profile with
    | Keeper_sandbox_config.Docker | Micro_vm -> Ok None
    | Remote_ssh ->
      let* names = remote_endpoint_names snapshot in
      (match observed_endpoint, names with
       | Some name, _ when List.mem name names -> Ok (Some name)
       | Some _, _ -> Error "remote_endpoint is not registered; press e to choose a registered endpoint"
       | None, [ name ] -> Ok (Some name)
       | None, [] -> Error "No SSH endpoints are registered in .masc/config/runtime.toml"
       | None, _ :: _ :: _ ->
         Error ("Press e and set remote_endpoint to one of: " ^ String.concat ", " names)) in
  let endpoint_json = function None -> `Null | Some name -> `String name in
  let effective_network_mode =
    match Masc.Keeper_types_profile.network_mode_rejection profile network_mode with
    | None -> network_mode
    | Some _ -> Masc.Keeper_types_profile.default_network_mode_for_profile profile
  in
  let changes =
    (if current = profile then [] else
       [ "sandbox_profile", `String (Keeper_sandbox_config.sandbox_profile_to_string profile) ])
    @ (if observed_endpoint = endpoint then [] else
         [ "remote_endpoint", endpoint_json endpoint ])
    @ (if effective_network_mode = network_mode then [] else
         [ "network_mode", `String
             (Masc.Keeper_types_profile.network_mode_to_string effective_network_mode) ]) in
  match changes with
  | [] -> Ok None
  | _ :: _ -> Ok (Some (`Assoc (("expected_config_revision",revision) :: changes)))

let reopen_edit_on_current ~before ~edited ~current =
  let open Result.Syntax in
  let* after = match Yojson.Safe.from_string edited with
    | json -> Ok json
    | exception Yojson.Json_error detail -> Error (Fix_in_editor detail) in
  let* patch = patch_of_edit ~before ~after in
  let* _ = expected_config_revision current |> Result.map_error (fun detail -> Cannot_send detail) in
  match patch, editable_snapshot current with
  | `Assoc changes, `Assoc fields ->
      (* A fresh revision needs a fresh shrink decision too. The retained
         request still carries the complete original text and confirmation. *)
      let fields = List.fold_left (fun fields (key,value) ->
        if String.equal key "expected_config_revision"
           || String.equal key confirm_context_shrink_field then fields
        else (key,value) :: List.remove_assoc key fields) fields changes in
      Ok (reopened_stem
        ~reason:"Current settings reloaded; your changed values retained. Review before saving."
        (Yojson.Safe.pretty_to_string (`Assoc fields)))
  | _ -> Error (Cannot_send "settings recovery requires object projections")

(* Marker column. The glyph carries the editable/read-only split on its own,
   because colour collapses to nothing under NO_COLOR and dim inverts on a
   light background. Colour repeats what the glyph already says. *)
let editable_glyph = "\xe2\x97\x8f"
let read_only_glyph = "\xe2\x97\x8b"

let label_width = 22

let styled code text =
  if String.equal code "" then text else code ^ text ^ Masc_tui_theme.Sgr.reset

(* Notes and values share one column so the eye reads the pane as a table
   rather than as ragged prose. Padding is computed from the visible prefix,
   which the styling codes do not add to. *)
let note_column = label_width + 5

let pad_to_note ~prefix_width = String.make (max 1 (note_column - prefix_width)) ' '

let section title note =
  let heading = styled Masc_tui_theme.Sgr.bold title in
  if String.equal note ""
  then " " ^ heading
  else
    Printf.sprintf " %s%s%s" heading
      (pad_to_note ~prefix_width:(1 + String.length title))
      (styled Masc_tui_theme.Sgr.dim note)

let marked_section glyph colour title note =
  Printf.sprintf " %s %s%s%s"
    (styled colour glyph)
    (styled Masc_tui_theme.Sgr.bold title)
    (pad_to_note ~prefix_width:(3 + String.length title))
    (styled Masc_tui_theme.Sgr.dim note)

let marked_row glyph colour label value =
  Printf.sprintf "  %s %s %s"
    (styled colour glyph)
    (styled colour (Printf.sprintf "%-*s" label_width label))
    value

let editable_row label value = marked_row editable_glyph Masc_tui_theme.Sgr.cyan label value
let read_only_row label value = marked_row read_only_glyph Masc_tui_theme.Sgr.dim label value

let string_value ?(missing = "not observed") = function
  | Some (`String value) when String.trim value <> "" -> value
  | Some (`String _) -> "(empty)"
  | Some `Null -> "default"
  | Some value -> Yojson.Safe.to_string value
  | None -> missing

let bool_value = function
  | Some (`Bool true) -> "on"
  | Some (`Bool false) -> "off"
  | value -> string_value value

let string_list_value = function
  | Some (`List []) -> "none"
  | Some (`List values) ->
      values
      |> List.map (function
           | `String value -> value
           | value -> Yojson.Safe.to_string value)
      |> String.concat ", "
  | value -> string_value value

let int_override_value = function
  | Some `Null -> "default runtime window"
  | Some (`Int value) -> Printf.sprintf "%d tokens" value
  | value -> string_value value

let skill_selection_value = function
  | Some `Null -> "all published Skills"
  | Some (`List []) -> "none"
  | Some (`List names) -> string_list_value (Some (`List names))
  | value -> string_value value

(* A stored field usually ends with a newline, which splits into a trailing
   empty line. Left in, it doubles the gap before the next heading and makes
   the line count in that heading one more than the reader can see. Interior
   blanks are the text's own paragraphs and stay. *)
let rec drop_trailing_blanks = function
  | [] -> []
  | lines ->
    (match List.rev lines with
     | last :: rest when String.trim last = "" -> drop_trailing_blanks (List.rev rest)
     | _ -> lines)

let free_text ~sanitize = function
  | Some (`String text) when String.trim text <> "" ->
    String.split_on_char '\n' text
    |> drop_trailing_blanks
    |> List.map (fun line -> "   " ^ sanitize line)
  | Some _ | None -> [ "   (not declared)" ]

let counted = function
  | [ "   (not declared)" ] -> "not declared"
  | [ _ ] -> "1 line"
  | lines -> Printf.sprintf "%d lines" (List.length lines)

(* The system prompt a turn would send, as the endpoint states it: built, or
   refused with a typed reason (#38354). A shape this reader does not know is
   its own case, drawn as a decode failure, so it can never be mistaken for a
   prompt that is simply not declared. *)
type system_prompt_unavailable_reason =
  | Constitution_unreadable of { path : string }
  | Workspace_unavailable
  | Prompt_unrenderable

type system_prompt_view =
  | System_prompt_available of { effective : string }
  | System_prompt_unavailable of
      { reason : system_prompt_unavailable_reason
      ; detail : string
      }
  | System_prompt_undecodable of string

let system_prompt_view_of_json value =
  let field fields key = List.assoc_opt key fields in
  match value with
  | None -> System_prompt_undecodable "prompt.system_prompt is absent"
  | Some (`Assoc fields) ->
    (match field fields "state" with
     | Some (`String "available") ->
       (match field fields "effective" with
        | Some (`String effective) -> System_prompt_available { effective }
        | Some other ->
          System_prompt_undecodable
            ("available prompt has no effective text: " ^ Yojson.Safe.to_string other)
        | None -> System_prompt_undecodable "available prompt has no effective text")
     | Some (`String "unavailable") ->
       (match field fields "reason", field fields "path", field fields "detail" with
        | Some (`String "constitution_unreadable"), Some (`String path), Some (`String detail) ->
          System_prompt_unavailable { reason = Constitution_unreadable { path }; detail }
        | Some (`String "workspace_unavailable"), None, Some (`String detail) ->
          System_prompt_unavailable { reason = Workspace_unavailable; detail }
        | Some (`String "prompt_unrenderable"), None, Some (`String detail) ->
          System_prompt_unavailable { reason = Prompt_unrenderable; detail }
        | reason, path, detail ->
          let show = function None -> "absent" | Some json -> Yojson.Safe.to_string json in
          System_prompt_undecodable
            (Printf.sprintf "unavailable prompt with reason=%s path=%s detail=%s"
               (show reason) (show path) (show detail)))
     | Some other ->
       System_prompt_undecodable ("unknown prompt state " ^ Yojson.Safe.to_string other)
     | None -> System_prompt_undecodable "prompt.system_prompt has no state")
  | Some other ->
    System_prompt_undecodable ("prompt.system_prompt is " ^ Yojson.Safe.to_string other)

let system_prompt_reason_lines ~sanitize = function
  | Constitution_unreadable { path } ->
    [ "   unavailable: the world constitution ledger could not be read"
    ; "   no turn runs until it reads again"
    ; "   path: " ^ sanitize path
    ]
  | Workspace_unavailable ->
    [ "   unavailable: the endpoint workspace could not be resolved"
    ; "   no turn runs until the endpoint workspace reads again"
    ]
  | Prompt_unrenderable ->
    [ "   unavailable: a prompt is empty or cannot render"
    ; "   no turn runs until the prompt is repaired"
    ]

(* Heading annotation and body for the effective system prompt section. *)
let system_prompt_lines ~sanitize = function
  | System_prompt_available { effective } ->
    let lines = free_text ~sanitize (Some (`String effective)) in
    counted lines, lines
  | System_prompt_unavailable { reason; detail } ->
    ( "unavailable"
    , system_prompt_reason_lines ~sanitize reason @ [ "   detail: " ^ sanitize detail ] )
  | System_prompt_undecodable detail ->
    "decode failed", [ "   could not decode: " ^ sanitize detail ]

(* Total renderers over the parsed types: the JSON was judged once by the
   parser, so nothing here can fail or disagree with validation. *)
let render_manifest_revision = function
  | Manifest_missing -> "manifest=missing"
  | Manifest_sha256 value -> "manifest=sha256:" ^ value

let render_assignment = function
  | Assignment_absent -> "assignment=missing"
  | Assignment_assigned runtime_id -> "assignment=assigned:" ^ runtime_id

let render_runtime_assignment_revision = function
  | Runtime_config_missing -> "runtime=missing"
  | Runtime_config_present { source_revision; assignment } ->
    Printf.sprintf "runtime=present source=sha256:%s %s"
      source_revision
      (render_assignment assignment)

let config_revision_value = function
  | Some revision ->
    (match config_revision_state_of_json revision with
     | Ok (Revision { manifest; runtime_assignment }) ->
       render_manifest_revision manifest
       ^ " | "
       ^ render_runtime_assignment_revision runtime_assignment
     | Ok (Revision_unavailable detail) ->
       "revision unavailable: " ^ detail
     | Error detail -> "invalid composite config revision: " ^ detail)
  | None -> "invalid composite config revision: not observed"

(* One document, but the reader has to be able to answer "will [e] change
   this?" without counting rows against the editor stem. The glyph answers it
   on every line, and the field count in the heading is taken from the same
   snapshot the editor opens rather than from the rows drawn here — two rows
   share one heading (sandbox / network) and one row is derived, so a count of
   rows would be a different number than the one [e] shows. *)
let view_lines ~sanitize json =
  let at path = member_path path json in
  let text value = sanitize (value ()) in
  let editable_value_row label value = editable_row label (text value) in
  let read_only_value_row label value = read_only_row label (text value) in
  let sources = at [ "sources" ] in
  let source path = Option.bind sources (member_path path) in
  let editable_count =
    match editable_snapshot json with `Assoc fields -> List.length fields | _ -> 0
  in
  let prompt key = at [ "prompt"; key ] in
  let instructions = free_text ~sanitize (prompt "instructions") in
  let effective_prompt_summary, effective_prompt =
    system_prompt_lines ~sanitize (system_prompt_view_of_json (prompt "system_prompt"))
  in
  [ Printf.sprintf " %s editable   %s read-only"
      (styled Masc_tui_theme.Sgr.cyan editable_glyph)
      (styled Masc_tui_theme.Sgr.dim read_only_glyph)
  ; ""
  ; section "1. 편집 안내 (edit here)" "$EDITOR JSON form"
  ; "   Press e. Save and close the editor to apply; exit non-zero to cancel."
  ; "   Only changed fields are sent. The server validates before persisting."
  ; ""
  ; section "2. 적용 중인 설정 (effective settings)" (Printf.sprintf "e opens %d fields" editable_count)
  ; editable_value_row "Runtime"
      (fun () -> string_value (at [ "execution"; "selected_runtime_id" ]))
  ; editable_value_row "Activation" (fun () -> string_value (at [ "activation_mode" ]))
  ; editable_value_row "Context policy" (fun () ->
      match at [ "input_policy" ] with
      | Some (`String "small") -> "Small (Agent Core)"
      | Some (`String "wide") -> "Wide (Agent Core)"
      | value -> string_value value)
  ; editable_value_row "Context override"
      (fun () -> int_override_value (at [ "max_context_override" ]))
  ; editable_value_row "Sandbox / network"
      (fun () ->
        Printf.sprintf "%s / %s"
          (string_value (at [ "sandbox_profile" ]))
          (string_value (at [ "network_mode" ])))
  ; editable_value_row "Remote endpoint"
      (fun () -> string_value (at [ "remote_endpoint" ]))
  ; read_only_value_row "Registered SSH endpoints"
      (fun () -> match remote_endpoint_names json with
         | Ok [] -> "none configured"
         | Ok names -> String.concat ", " names
         | Error detail -> detail)
  ; editable_value_row "Mention targets"
      (fun () -> string_list_value (at [ "workspace"; "mention_targets" ]))
  ; editable_value_row "Board interests"
      (fun () ->
        match at [ "workspace"; "board_interests" ] with
        | Some (`List []) -> "Targetless discovery off"
        | value -> string_list_value value)
  ; editable_value_row "Skills"
      (fun () -> skill_selection_value (at [ "skills"; "names" ]))
  ; ""
  ; section "3. 파생 상태 · 리비전 (derived)" "read-only"
  ; read_only_value_row "Config revision"
      (fun () -> config_revision_value (at [ "config_revision" ]))
  ; read_only_value_row "Sandbox roots"
      (fun () -> string_list_value (at [ "sandbox_roots" ]))
  ; ""
  ; section "4. 설정 출처 · 우선순위 (provenance)" "read-only"
  ; read_only_value_row "Live override"
      (fun () -> bool_value (source [ "has_live_override" ]))
  ; read_only_value_row "Override fields"
      (fun () -> string_list_value (source [ "override_fields" ]))
  ; read_only_value_row "Precedence"
      (fun () -> string_list_value (source [ "precedence" ]))
  ; read_only_value_row "Default manifest"
      (fun () -> string_value (source [ "default_manifest_path" ]))
  ; read_only_value_row "Live metadata"
      (fun () -> string_value (source [ "live_meta_path" ]))
  ; ""
  ; marked_section editable_glyph Masc_tui_theme.Sgr.cyan "5. 키퍼 지침 (instructions)"
      (Printf.sprintf "editable \xc2\xb7 %s" (counted instructions))
  ]
  @ instructions
  @ [ ""
    ; marked_section read_only_glyph Masc_tui_theme.Sgr.dim "6. 유효 시스템 프롬프트 (effective system prompt)"
        (Printf.sprintf "read-only \xc2\xb7 %s" effective_prompt_summary)
    ]
  @ effective_prompt
  @ (match sources with
     | None -> []
     | Some value ->
       (* The named provenance rows above pick five fields out of this object.
          The raw block stays because the endpoint decides what else it sends,
          and dropping the rest would quietly narrow what the operator can
          see. *)
       ""
       :: marked_section read_only_glyph Masc_tui_theme.Sgr.dim "7. 원본 출처 JSON (sources)" "read-only \xc2\xb7 raw"
       :: (Yojson.Safe.pretty_to_string value
           |> String.split_on_char '\n'
           |> List.map (fun line -> "   " ^ sanitize line)))
  @ [ ""
    ; section "8. 필드 편집 규칙 (field rules)" ""
    ; "   Skills: {} selects all; {\"names\":[]} selects none; names select exactly."
    ; "   Deleting a field means unchanged. null clears context/wake overrides."
    ]
;;
