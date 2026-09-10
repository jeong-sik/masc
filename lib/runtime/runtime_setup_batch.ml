type revision = Revision of string
type error = Invalid_selection | Invalid_configuration | Changed_configuration
  | Configuration_unavailable | Validation_failed | Verification_failed of string
  | Write_failed | Rollback_failed | Lock_unavailable
type readiness = Not_probed | Verified
type receipt = { runtime_id:string; runtime_ids:string list; models:string list;
                 readiness:readiness }
let ( let* ) = Result.bind
let error_message = function
  | Invalid_selection -> "Select a default from the selected runtimes."
  | Invalid_configuration -> "The workspace runtime configuration is invalid."
  | Changed_configuration -> "Configuration changed; refresh the selection before saving."
  | Configuration_unavailable -> "The workspace configuration could not be read."
  | Validation_failed -> "Selected runtime configuration did not pass validation."
  | Verification_failed _ -> "A selected runtime did not pass response and tool verification."
  | Write_failed -> "Configuration could not be saved; previous configuration was restored."
  | Rollback_failed -> "Configuration restoration was incomplete; inspect the workspace before retrying."
  | Lock_unavailable -> "Another configuration operation is active; retry after it finishes."
let revision_to_string (Revision value) = value
let revision_of_string value =
  if String.length value = 64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) value
  then Ok (Revision value) else Error Changed_configuration
let safe_id value = value <> "" && String.trim value = value
  && not (String.exists (function '\000'..'\031'|'\127' -> true | _ -> false) value)
let unique values = List.fold_left (fun acc v -> if List.mem v acc then acc else acc @ [v]) [] values
let json_object = function
  | `Assoc fields when List.length (unique (List.map fst fields)) = List.length fields -> Some fields
  | _ -> None
let paths base =
  let config = Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "config" in
  config, Filename.concat config Config_dir_resolver.runtime_toml_filename, Filename.concat config "agent-core-models-overlay.toml"
let read root path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root path with
  | Ok value -> Ok value | Error _ -> Error Configuration_unavailable
let snapshot base =
  let root,runtime,overlay = paths base in
  let* first = read root runtime in
  let* second = read root overlay in
  match first with None -> Error Configuration_unavailable | Some _ -> Ok (first,second)
let content = function None -> "" | Some (file:Fs_compat.owned_regular_file_contents) -> file.content
let revision (first,second) =
  let item = function None -> `Null | Some (file:Fs_compat.owned_regular_file_contents) -> `String file.content in
  Revision (Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string (`List [item first;item second])))))
let same_file a b = match a,b with
  | None,None -> true
  | Some (a:Fs_compat.owned_regular_file_contents),Some b -> a.content=b.content
    && Fs_compat.equal_owned_regular_file_snapshot a.snapshot b.snapshot
  | _ -> false
let same (a,b) (c,d) = same_file a c && same_file b d
let io action = try action () with Unix.Unix_error _ | Sys_error _ -> Error Configuration_unavailable
let observe ~base_path = io (fun () -> let* files = snapshot (Unix.realpath base_path) in Ok (revision files))
let stage_env base =
  let config,_,_ = paths base in
  let replaced = ["MASC_BASE_PATH";"MASC_CONFIG_DIR"] in
  let kept = Unix.environment () |> Array.to_list |> List.filter (fun value ->
    let key = match String.index_opt value '=' with None -> value | Some n -> String.sub value 0 n in
    not (List.mem key replaced)) in
  Array.of_list (kept @ ["MASC_BASE_PATH="^base;"MASC_CONFIG_DIR="^config])
let run ~binary ~base args =
  match Process_eio.run_argv_with_status_split_or_refusal ~env:(stage_env base)
          (binary :: args) with
  | Ok (Unix.WEXITED 0,stdout,_) -> Ok stdout
  | Ok _ | Error _ -> Error Validation_failed
let verification ~binary ~base id =
  let* text = match run ~binary ~base ["runtime-verify";"--base-path";base;id] with
    | Ok value -> Ok value | Error _ -> Error (Verification_failed id) in
  let valid = try
    match json_object (Yojson.Safe.from_string text) with
    | None -> false
    | Some fields ->
      let field k = List.assoc_opt k fields in
      field "schema" = Some (`String "masc.runtime_verification.v1")
      && field "runtime_id" = Some (`String id) && field "status" = Some (`String "verified")
      && (match Option.bind (field "checks") json_object with
          | Some checks -> List.assoc_opt "response" checks = Some (`Bool true)
                           && List.assoc_opt "tool_roundtrip" checks = Some (`Bool true)
          | None -> false)
    with Yojson.Json_error _ -> false in
  if valid then Ok () else Error (Verification_failed id)
let write path mode text =
  Fs_compat.write_file_atomic_strict_staged path ~write:(fun channel ->
    Unix.fchmod (Unix.descr_of_out_channel channel) mode;
    output_string channel text)
let mode = function None -> 0o600 | Some (file:Fs_compat.owned_regular_file_contents) -> file.snapshot.permissions
let with_stage action =
  Eio.Switch.run (fun sw ->
    let root = Filename.temp_dir "masc-runtime-setup-" "" |> Unix.realpath in
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
    let masc = Common.masc_dir_from_base_path ~base_path:root in
    Unix.mkdir masc 0o700;
    Unix.mkdir (Filename.concat masc "config") 0o700;
    action root)
let publish_using ~write changes =
  let rec restore = function
    | [] -> true
    | (path,original)::rest ->
      let restored = try match original with
        | None -> Unix.unlink path; true
        | Some file -> (match write path (mode original) file.Fs_compat.content with Ok () -> true | Error _ -> false)
        with Unix.Unix_error _ | Sys_error _ -> false in
      let remaining = restore rest in restored && remaining in
  let rec commit written = function
    | [] -> Ok ()
    | (path,original,text)::rest ->
      match write path (mode original) text with
      | Ok () -> commit ((path,original)::written) rest
      | Error failure ->
        let written = match failure.Fs_compat.stage with
          | Fs_compat.Before_rename -> written
          | Fs_compat.After_rename -> (path,original)::written in
        if restore written then Error Write_failed else Error Rollback_failed in
  (* Cancellation cannot interrupt the two replacements or their rollback. *)
  Eio.Cancel.protect (fun () -> commit [] changes)
let configure_locked ~binary ~base ~expected_revision ~specs ~selected ~verify =
  let* original = snapshot base in
  if revision original <> expected_revision then Error Changed_configuration else
  let first,second = original in
  let* parsed = match Runtime_toml.parse_string (content first) with
    | Ok value -> Ok value | Error _ -> Error Invalid_configuration in
  let existing = List.map Runtime.id_of_binding parsed.Runtime_schema.bindings in
  let rendered = List.map Runtime_setup_spec.render specs in
  let additions = List.fold_left (fun acc (row:Runtime_setup_spec.rendered) ->
    if List.mem row.runtime_id existing || List.exists (fun (r:Runtime_setup_spec.rendered) -> r.runtime_id=row.runtime_id) acc
    then acc else acc @ [row]) [] rendered in
  let available = existing @ List.map (fun (r:Runtime_setup_spec.rendered) -> r.runtime_id) additions in
  if not (List.for_all (fun id -> List.mem id available) selected) then Error Invalid_selection else
  let added = String.concat "" (List.map (fun (r:Runtime_setup_spec.rendered) -> r.runtime_toml) additions) in
  let overlay_added = String.concat "" (List.map (fun (r:Runtime_setup_spec.rendered) -> r.model_overlay_toml) additions) in
  let runtime_text = content first ^ (if added="" then "" else "\n" ^ added) in
  let overlay_text = content second ^ overlay_added in
  let* validated = with_stage (fun stage ->
    let _,runtime,overlay = paths stage in
    let stage_write path text = match write path 0o600 text with
      | Ok () -> Ok () | Error _ -> Error Configuration_unavailable in
    let* () = stage_write runtime runtime_text in
    let* () = stage_write overlay overlay_text in
    match selected with
    | [] -> Error Invalid_selection
    | primary::fallbacks ->
      let args = ["runtime-default-set";"--base-path";stage;primary;"--setup-lanes";"--setup-imp"]
        @ List.concat_map (fun id -> ["--fallback-runtime";id]) fallbacks in
      let* _ = run ~binary ~base:stage args in
      let rec probes = function [] -> Ok () | id::tail -> let* () = verification ~binary ~base:stage id in probes tail in
      let* () = if verify then probes selected else Ok () in
      let* files = snapshot stage in Ok (content (fst files))) in
  let* current = snapshot base in
  if not (same original current) then Error Changed_configuration else
  let _,runtime,overlay = paths base in
  let changes = (if overlay_added="" then [] else [overlay,second,overlay_text]) @ [runtime,first,validated] in
  let* () = publish_using ~write changes in
  match selected with
  | [] -> Error Invalid_selection
  | primary::_ -> Ok {runtime_id=primary;runtime_ids=selected;
      models=List.map Runtime_setup_spec.model_id specs; readiness=(if verify then Verified else Not_probed)}
let configure ~binary ~base_path ~expected_revision ~specs ~runtime_ids ~default_runtime_id ~verify () =
  if runtime_ids=[] || not (List.for_all safe_id runtime_ids)
     || not (List.mem default_runtime_id runtime_ids) then Error Invalid_selection else
  io (fun () ->
    let base = Unix.realpath base_path and binary = Unix.realpath binary in
    let _,runtime,_ = paths base in
    let selected = default_runtime_id :: List.filter ((<>) default_runtime_id) (unique runtime_ids) in
    (* Keep typed operation failures separate from the lock's string diagnostics. *)
    match Runtime.with_config_lock ~runtime_config_path:runtime (fun () ->
      Ok (configure_locked ~binary ~base ~expected_revision ~specs ~selected ~verify)) with
    | Ok result -> result | Error _ -> Error Lock_unavailable)
let receipt_json receipt = `Assoc [
  "runtime_id",`String receipt.runtime_id;
  "runtime_ids",`List (List.map (fun s -> `String s) receipt.runtime_ids);
  "models",`List (List.map (fun s -> `String s) receipt.models);
  "configured",`Bool true;"validation",`String "passed";
  "readiness",`String (match receipt.readiness with Verified -> "verified" | Not_probed -> "not_probed")]

module For_testing = struct
  let publish ~replace ~files =
    let rec originals = function
      | [] -> Ok []
      | (path,text)::rest ->
        let* original = read (Filename.dirname path) path in
        let* tail = originals rest in Ok ((path,original,text)::tail) in
    let* changes = originals files in
    publish_using ~write:replace changes
end
