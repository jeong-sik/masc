(** Keeper_tool_persona_crud — masc_persona_create and masc_persona_update handlers. *)

open Tool_args
open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
(* Write/read personas at the same location the loaders read from. The list
   loader (Keeper_types_profile_persona) resolves persona roots exclusively
   through Config_dir_resolver.personas_dirs (MASC_PERSONAS_DIR, else the
   resolved CONFIG_ROOT/personas); its own comment warns that MASC_BASE/cwd
   fallbacks "make the dashboard lie about the actual source of truth". Using
   the resolver's primary root keeps create/update/delete consistent with what
   masc_persona_list shows. The legacy fallback only runs when the resolver
   disowns every root (no MASC_PERSONAS_DIR and a Missing/Invalid config root),
   so a first create still lands somewhere writable. *)
let personas_dir () =
  match Config_dir_resolver.personas_dirs () with
  | dir :: _ -> dir
  | [] ->
      (match Sys.getenv_opt "MASC_PERSONAS_DIR" with
       | Some d -> d
       | None ->
           let base = match Sys.getenv_opt "MASC_BASE" with
             | Some b -> b
             | None -> Config_dir_resolver.base_path_or_cwd ()
           in
           Filename.concat base "personas")

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
  (try Fs_compat.mkdir_p dir with _ -> ());
  let tmp = path ^ ".tmp" in
  let content = Yojson.Safe.to_string ~std:true json in
  match Fs_compat.save_file_atomic tmp content with
  | Error msg -> Error ("Failed to write " ^ path ^ ": " ^ msg)
  | Ok () ->
      (try
         Fs_compat.rename tmp path;
         Ok (ok_assoc [("persona_name", `String persona_name); ("path", `String path)])
       with exn ->
         Error ("Failed to rename tmp file: " ^ Printexc.to_string exn))

let validate_create_args args =
  let persona_name = get_string_opt args "persona_name" in
  let display_name = get_string_opt args "display_name" in
  match persona_name, display_name with
  | None, _ -> ["Missing required field: persona_name"]
  | _, None -> ["Missing required field: display_name"]
  | Some pn, Some dn ->
      (match validate_persona_name pn with
       | Error msg -> [msg]
       | Ok () -> if String.trim dn = "" then ["display_name must not be empty"] else [])

(* A persona profile.json is read by two loaders that pull from two distinct
   locations, verified against config/personas/*/profile.json:

     - persona identity, top level: ["name"] (display name), ["role"],
       ["trait"] — read by
       [Keeper_types_profile_persona.persona_summary_of_profile_json];
     - keeper template defaults, nested under ["keeper"]: ["goal"],
       ["instructions"], ["mention_targets"], ["proactive_enabled"],
       ["tool_denylist"] — read by
       [Keeper_types_profile_persona_defaults.load_from_path], which only ever
       inspects the ["keeper"] member.

   Earlier this tool wrote every field at the top level under different keys
   (["display_name"] instead of ["name"]; the keeper-template fields at the
   top level instead of under ["keeper"]). Neither loader reads that shape, so
   the display name showed the directory name and every keeper-template field
   was silently dropped — spawning a keeper from a tool-created persona then
   failed with "goal is required". These helpers write the shape the loaders
   actually read. Fields that no reader consumes (previously [persona_name],
   [display_name] as a separate key, [created_at], [auto_handoff]) are not
   persisted. *)

let keeper_defaults_fields args : (string * Yojson.Safe.t) list =
  let goal = get_string_opt args "goal" in
  let instructions = get_string_opt args "instructions" in
  let mention_targets = get_string_list args "mention_targets" in
  let tool_denylist = get_string_list args "tool_denylist" in
  let proactive_enabled = get_bool_opt args "proactive_enabled" in
  (match goal with Some v -> [("goal", `String v)] | None -> [])
  @ (match instructions with Some v -> [("instructions", `String v)] | None -> [])
  @ (if mention_targets = [] then [] else [("mention_targets", `List (List.map (fun s -> `String s) mention_targets))])
  @ (if tool_denylist = [] then [] else [("tool_denylist", `List (List.map (fun s -> `String s) tool_denylist))])
  @ (match proactive_enabled with Some v -> [("proactive_enabled", `Bool v)] | None -> [])

let profile_from_create_args args =
  (* The public arg is [display_name] (required by [validate_create_args]);
     it is persisted as the top-level ["name"] the summary loader reads. *)
  let display_name = get_string args "display_name" "" in
  let role = get_string_opt args "role" in
  let trait = get_string_opt args "trait" in
  let keeper_fields = keeper_defaults_fields args in
  `Assoc ([ ("name", `String display_name) ]
  @ (match role with Some v -> [("role", `String v)] | None -> [])
  @ (match trait with Some v -> [("trait", `String v)] | None -> [])
  @ (if keeper_fields = [] then [] else [("keeper", `Assoc keeper_fields)]))

(* Merge [updates] into [base], preserving [base] key order: an update replaces
   the value in place, and keys absent from [base] are appended in [updates]
   order. *)
let merge_assoc base updates =
  let merged =
    List.map
      (fun (k, v) ->
        match List.assoc_opt k updates with Some uv -> (k, uv) | None -> (k, v))
      base
  in
  let base_keys = List.map fst base in
  let new_items = List.filter (fun (k, _) -> not (List.mem k base_keys)) updates in
  merged @ new_items

(** Merge [args] into [existing_json]. Returns [Error] rather than
    fabricating a placeholder persona when [existing_json] is not a JSON
    object — a persisted profile that failed to parse as an object means
    something else already corrupted it (disk, manual edit, prior bug),
    and papering over it with a fresh object would silently rewrite the
    caller's data on every future update.

    Updates are routed to the same two layers the loaders read: identity
    fields ([display_name] -> top-level ["name"], [role], [trait]) stay at
    the top level, and keeper-template fields ([goal], [instructions],
    [mention_targets], [tool_denylist], [proactive_enabled]) merge into the
    nested ["keeper"] object. Only fields present in [args] change. *)
let merge_update_args_into_profile existing_json args : (Yojson.Safe.t, string) result =
  match existing_json with
  | `Assoc existing ->
      let str_update key =
        match get_string_opt args key with Some v -> Some (`String v) | None -> None
      in
      let bool_update key =
        match get_bool_opt args key with Some v -> Some (`Bool v) | None -> None
      in
      let list_update key =
        match get_string_list args key with
        | [] -> None
        | xs -> Some (`List (List.map (fun s -> `String s) xs))
      in
      let field name = function Some v -> [(name, v)] | None -> [] in
      (* The public arg [display_name] updates the top-level ["name"] key. *)
      let top_updates =
        field "name" (str_update "display_name")
        @ field "role" (str_update "role")
        @ field "trait" (str_update "trait")
      in
      let keeper_updates =
        field "goal" (str_update "goal")
        @ field "instructions" (str_update "instructions")
        @ field "mention_targets" (list_update "mention_targets")
        @ field "tool_denylist" (list_update "tool_denylist")
        @ field "proactive_enabled" (bool_update "proactive_enabled")
      in
      let existing_keeper =
        match List.assoc_opt "keeper" existing with
        | Some (`Assoc kv) -> kv
        | _ -> []
      in
      let merged_keeper = merge_assoc existing_keeper keeper_updates in
      let merged_top = merge_assoc existing top_updates in
      let with_keeper =
        if merged_keeper = [] then merged_top
        else merge_assoc merged_top [("keeper", `Assoc merged_keeper)]
      in
      Ok (`Assoc with_keeper)
  | other ->
      Error
        (Printf.sprintf "Corrupt persona profile: expected a JSON object, got %s"
           (Json_util.kind_name other))

(* The [*_json] handlers build a Yojson result; [tool_result_of_json] projects
   it into the keeper [tool_result] the tool surface expects. A result carrying
   an ["error"]/["errors"] field is an error verdict, otherwise success —
   mirroring the ok_assoc/error_assoc shapes these handlers emit. *)
let tool_result_of_json (json : Yojson.Safe.t) : tool_result =
  let is_error =
    match json with
    | `Assoc fields ->
        List.exists (fun (k, _) -> k = "error" || k = "errors") fields
    | _ -> false
  in
  let body = Yojson.Safe.to_string ~std:true json in
  if is_error then tool_result_error body else tool_result_ok body

let handle_persona_create_json args =
  let errors = validate_create_args args in
  if errors <> [] then
    error_assoc [("errors", `List (List.map (fun e -> `String e) errors))]
  else
    let persona_name = get_string args "persona_name" "" in
    if persona_exists persona_name then
      error_assoc
        [("error", `String ("Persona '" ^ persona_name ^ "' already exists. Use masc_persona_update to modify it."))]
    else
      let profile = profile_from_create_args args in
      match write_profile persona_name profile with
      | Ok result -> result
      | Error msg -> error_assoc [("error", `String msg)]

let handle_persona_update_json args =
  let persona_name = get_string_opt args "persona_name" in
  match persona_name with
  | None -> error_assoc [("error", `String "Missing required field: persona_name")]
  | Some pn ->
      (match validate_persona_name pn with
       | Error msg -> error_assoc [("error", `String msg)]
       | Ok () ->
           if not (persona_exists pn) then
             error_assoc
               [("error", `String ("Persona '" ^ pn ^ "' does not exist. Use masc_persona_create first."))]
           else
             (match read_profile pn with
              | Error msg -> error_assoc [("error", `String msg)]
              | Ok existing_json ->
                  (match merge_update_args_into_profile existing_json args with
                   | Error msg -> error_assoc [("error", `String msg)]
                   | Ok updated ->
                       (match write_profile pn updated with
                        | Ok result -> result
                        | Error msg -> error_assoc [("error", `String msg)]))))

let handle_persona_create _ctx args : tool_result =
  tool_result_of_json (handle_persona_create_json args)

let handle_persona_update _ctx args : tool_result =
  tool_result_of_json (handle_persona_update_json args)

(* Remove the whole persona directory (profile.json plus any AGENT.md /
   metrics siblings) so no orphaned files survive the delete. [remove_tree]
   ignores missing paths and does not follow symlinks; the [validate_persona_name]
   guard keeps [persona_name] a single path component under [personas_dir ()],
   so the removal target cannot escape that directory. *)
let delete_persona_dir persona_name : (Yojson.Safe.t, string) result =
  let dir = Filename.concat (personas_dir ()) persona_name in
  try
    Fs_compat.remove_tree dir;
    Ok
      (ok_assoc
         [ ("persona_name", `String persona_name)
         ; ("deleted", `Bool true)
         ; ("path", `String dir)
         ])
  with exn ->
    Error ("Failed to delete persona directory " ^ dir ^ ": " ^ Printexc.to_string exn)

let handle_persona_delete_json args =
  match get_string_opt args "persona_name" with
  | None -> error_assoc [("error", `String "Missing required field: persona_name")]
  | Some pn ->
      (match validate_persona_name pn with
       | Error msg -> error_assoc [("error", `String msg)]
       | Ok () ->
           if not (persona_exists pn) then
             error_assoc [("error", `String ("Persona '" ^ pn ^ "' does not exist."))]
           else
             (match delete_persona_dir pn with
              | Ok result -> result
              | Error msg -> error_assoc [("error", `String msg)]))

let handle_persona_delete _ctx args : tool_result =
  tool_result_of_json (handle_persona_delete_json args)
