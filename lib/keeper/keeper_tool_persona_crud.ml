(** Keeper_tool_persona_crud — masc_persona_create and masc_persona_update handlers. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
let personas_dir () =
  match Sys.getenv_opt "MASC_PERSONAS_DIR" with
  | Some d -> d
  | None ->
      let base = match Sys.getenv_opt "MASC_BASE" with
        | Some b -> b
        | None -> Config_dir_resolver.base_path_or_cwd ()
      in
      Filename.concat base "personas"

(** Reject any [persona_name] that is not a single, self-contained path
    component. [Filename.basename ".." = ".."] and [Filename.basename "." =
    "."] (verified against the OCaml 5.4 stdlib), so the basename-equality
    check alone does not stop "." / ".." — they must be rejected explicitly.
    Mirrors the [Filename.basename target = target] guard already used in
    [Auth_credential_base.redirect_target_file] for the same class of
    problem: without this, [persona_name] flows unsanitized into
    [Filename.concat] and can escape [personas_dir ()]. *)
let validate_persona_name persona_name : (unit, string) result =
  if String.trim persona_name = "" then
    Error "persona_name must not be empty"
  else if persona_name = "." || persona_name = ".." then
    Error "persona_name must not be '.' or '..'"
  else if Filename.basename persona_name <> persona_name then
    Error "persona_name must not contain path separators"
  else Ok ()

let profile_path persona_name =
  Filename.concat (personas_dir ()) (Filename.concat persona_name "profile.json")

let persona_exists persona_name =
  Fs_compat.file_exists (profile_path persona_name)

let read_profile persona_name =
  let path = profile_path persona_name in
  if not (Fs_compat.file_exists path) then
    Error ("Persona '" ^ persona_name ^ "' not found at " ^ path)
  else
    match Fs_compat.load_file_opt path with
    | Some content ->
        (try Ok (Yojson.Safe.from_string content)
         with Yojson.Json_error msg ->
           Error ("Invalid JSON in " ^ path ^ ": " ^ msg))
    | None -> Error ("Failed to read " ^ path)

let write_profile persona_name json =
  let dir = Filename.concat (personas_dir ()) persona_name in
  let path = Filename.concat dir "profile.json" in
  match
    try
      Fs_compat.mkdir_p dir;
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Error detail -> Error ("Failed to create " ^ dir ^ ": " ^ detail)
  | Ok () ->
    let tmp = path ^ ".tmp" in
    let content = Yojson.Safe.to_string ~std:true json in
    (match Fs_compat.save_file_atomic tmp content with
     | Error msg -> Error ("Failed to write " ^ path ^ ": " ^ msg)
     | Ok () ->
       (try
          Fs_compat.rename tmp path;
          Ok (ok_assoc [("persona_name", `String persona_name); ("path", `String path)])
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Error ("Failed to rename tmp file: " ^ Printexc.to_string exn)))

let validate_create_args args =
  match reject_removed_keeper_input_keys ~tool_name:"masc_persona_create" args with
  | Error detail -> [ detail ]
  | Ok () ->
    let persona_name = get_string_opt args "persona_name" in
    let display_name = get_string_opt args "display_name" in
    (match persona_name, display_name with
     | None, _ -> [ "Missing required field: persona_name" ]
     | _, None -> [ "Missing required field: display_name" ]
     | Some pn, Some dn ->
       (match validate_persona_name pn with
        | Error msg -> [ msg ]
        | Ok () ->
          if String.trim dn = "" then [ "display_name must not be empty" ] else []))

let profile_from_create_args args =
  let persona_name = get_string args "persona_name" "" in
  let display_name = get_string args "display_name" "" in
  let role = get_string_opt args "role" in
  let trait = get_string_opt args "trait" in
  let goal = get_string_opt args "goal" in
  let instructions = get_string_opt args "instructions" in
  let mention_targets = get_string_list args "mention_targets" in
  let proactive_enabled = get_bool_opt args "proactive_enabled" in
  let auto_handoff = get_bool_opt args "auto_handoff" in
  `Assoc ([
    ("persona_name", `String persona_name);
    ("display_name", `String display_name);
    ("created_at", `String (Printf.sprintf "%.0f" (Unix.time ())));
  ]
  @ (match role with Some v -> [("role", `String v)] | None -> [])
  @ (match trait with Some v -> [("trait", `String v)] | None -> [])
  @ (match goal with Some v -> [("goal", `String v)] | None -> [])
  @ (match instructions with Some v -> [("instructions", `String v)] | None -> [])
  @ (if mention_targets = [] then [] else [("mention_targets", `List (List.map (fun s -> `String s) mention_targets))])
  @ (match proactive_enabled with Some v -> [("proactive_enabled", `Bool v)] | None -> [])
  @ (match auto_handoff with Some v -> [("auto_handoff", `Bool v)] | None -> []))

(** Merge [args] into [existing_json]. Returns [Error] rather than
    fabricating a placeholder persona when [existing_json] is not a JSON
    object — a persisted profile that failed to parse as an object means
    something else already corrupted it (disk, manual edit, prior bug),
    and papering over it with [persona_name = "unknown"] would silently
    rewrite the caller's data under the wrong identity on every future
    update. *)
let merge_update_args_into_profile existing_json args : (Yojson.Safe.t, string) result =
  match reject_removed_keeper_input_keys ~tool_name:"masc_persona_update" args with
  | Error _ as error -> error
  | Ok () ->
  match existing_json with
  | `Assoc existing ->
      let removed_fields =
        [ "tool_access"; "tool_denylist" ]
        |> List.filter (fun key -> List.mem_assoc key existing)
      in
      if removed_fields <> [] then
        Error
          (Printf.sprintf
             "removed persona profile fields are no longer supported: %s"
             (String.concat ", " removed_fields))
      else
      let update_field key to_json =
        match get_string_opt args key with
        | Some v -> Some (key, to_json v)
        | None -> None
      in
      let update_bool_field key =
        match get_bool_opt args key with
        | Some v -> Some (key, `Bool v)
        | None -> None
      in
      let update_list_field key =
        let v = get_string_list args key in
        if v = [] then None else Some (key, `List (List.map (fun s -> `String s) v))
      in
      let updates =
        List.filter_map (fun x -> x) [
          update_field "display_name" (fun v -> `String v);
          update_field "role" (fun v -> `String v);
          update_field "trait" (fun v -> `String v);
          update_field "goal" (fun v -> `String v);
          update_field "instructions" (fun v -> `String v);
          update_list_field "mention_targets";
          update_bool_field "proactive_enabled";
          update_bool_field "auto_handoff";
        ]
      in
      let merged =
        List.map (fun (k, v) ->
          match List.find_opt (fun (uk, _) -> uk = k) updates with
          | Some (_, uv) -> (k, uv)
          | None -> (k, v)
        ) existing
      in
      let existing_keys = List.map fst existing in
      let new_items =
        List.filter (fun (k, _) -> not (List.mem k existing_keys)) updates
      in
      Ok (`Assoc (merged @ new_items))
  | other ->
      Error
        (Printf.sprintf "Corrupt persona profile: expected a JSON object, got %s"
           (Json_util.kind_name other))

(* Outcome is carried by [Result], while the payload remains first-class JSON.
   Error-object keys are presentation data and never determine control flow. *)
let tool_result_of_json_result = function
  | Ok data -> tool_result_ok_data data
  | Error data -> tool_result_error_data data

let handle_persona_create_json args =
  let errors = validate_create_args args in
  if errors <> [] then
    Error (error_assoc [("errors", `List (List.map (fun e -> `String e) errors))])
  else
    let persona_name = get_string args "persona_name" "" in
    if persona_exists persona_name then
      Error
        (error_assoc
           [("error", `String ("Persona '" ^ persona_name ^ "' already exists. Use masc_persona_update to modify it."))])
    else
      let profile = profile_from_create_args args in
      match write_profile persona_name profile with
      | Ok result -> Ok result
      | Error msg -> Error (error_assoc [("error", `String msg)])

let handle_persona_update_json args =
  let persona_name = get_string_opt args "persona_name" in
  match persona_name with
  | None ->
      Error
        (error_assoc [("error", `String "Missing required field: persona_name")])
  | Some pn ->
      match validate_persona_name pn with
      | Error msg -> Error (error_assoc [("error", `String msg)])
      | Ok () ->
          if not (persona_exists pn) then
            Error
              (error_assoc
                 [("error", `String ("Persona '" ^ pn ^ "' does not exist. Use masc_persona_create first."))])
          else
            match read_profile pn with
            | Error msg -> Error (error_assoc [("error", `String msg)])
            | Ok existing_json ->
                match merge_update_args_into_profile existing_json args with
                | Error msg -> Error (error_assoc [("error", `String msg)])
                | Ok updated ->
                    match write_profile pn updated with
                    | Ok result -> Ok result
                    | Error msg -> Error (error_assoc [("error", `String msg)])

let handle_persona_create _ctx args : tool_result =
  tool_result_of_json_result (handle_persona_create_json args)

let handle_persona_update _ctx args : tool_result =
  tool_result_of_json_result (handle_persona_update_json args)
