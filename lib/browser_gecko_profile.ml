open Result.Syntax
module Requirement = Resource_requirement
module Profile = Private_browser_profile

let lock_name = ".parentlock"
let label = "Gecko profile"
let root_label = "Gecko profile root"
let instance_label = "Gecko instance profiles"

let root ~lane_addon_root = Filename.concat lane_addon_root "gecko-profiles"

let protect ~label path run =
  try run () with Unix.Unix_error (error, call, _) ->
    Error (Printf.sprintf "%s %s: %s failed: %s" label path call (Unix.error_message error))

let ensure_directory path = try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let checked ~label path =
  let* _ = Requirement.lstat ~label Requirement.private_directory path in
  Requirement.canonical ~label path

let is_masc_name text = match Uuidm.of_string text with
  | Some uuid -> String.equal (Uuidm.to_string uuid) text
  | None -> false

(* Resolve the parent only: a symlinked root is refused, not followed. *)
let resolved root = Filename.concat (Unix.realpath (Filename.dirname root)) (Filename.basename root)

let prepare_instance ~root ~instance_id =
  if not (is_masc_name instance_id) then
    Error (Printf.sprintf "%s require a canonical instance UUID; it is %S" instance_label instance_id)
  else protect ~label:root_label root (fun () ->
    ensure_directory root;
    let root = resolved root in
    let* () = checked ~label:root_label root in
    let instance = Filename.concat root instance_id in
    ensure_directory instance;
    let* () = checked ~label:instance_label instance in
    Ok instance)

let existing_root root = protect ~label:root_label root (fun () ->
  match Unix.lstat root with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | _ ->
    let root = resolved root in
    let* () = checked ~label:root_label root in
    Ok (Some root))

let check_instance instance = protect ~label:instance_label instance (fun () -> checked ~label:instance_label instance)

let resource_guard_prefs =
  [ "browser.tabs.unloadOnLowMemory", `Bool true
  ; "dom.ipc.processPriorityManager.enabled", `Bool true
  ; "dom.ipc.reportProcessHangs", `Bool true
  ; "dom.max_chrome_script_run_time", `Int 20
  ; "dom.max_script_run_time", `Int 20
  ; "threads.lower_mainthread_priority_in_background.enabled", `Bool true
  ; "widget.windows.window_occlusion_tracking.enabled", `Bool true
  ]

let resource_guard_keys = List.map fst resource_guard_prefs

let poisoned_prefs_keys =
  "remote.prefs.recommended.applied" :: resource_guard_keys

let parse_pref_line_key line =
  let trimmed = String.trim line in
  let after_call =
    if String.starts_with ~prefix:"user_pref(" trimmed then
      Some (String.sub trimmed 10 (String.length trimmed - 10))
    else if String.starts_with ~prefix:"pref(" trimmed then
      Some (String.sub trimmed 5 (String.length trimmed - 5))
    else
      None
  in
  match after_call with
  | None -> None
  | Some rest ->
    let rest = String.trim rest in
    if String.length rest >= 2 && Char.equal rest.[0] '"' then
      match String.index_from_opt rest 1 '"' with
      | None -> None
      | Some close_quote ->
        let key = String.sub rest 1 (close_quote - 1) in
        let tail =
          String.sub rest (close_quote + 1) (String.length rest - close_quote - 1)
          |> String.trim
        in
        if not (String.starts_with ~prefix:"," tail) then None
        else begin
          (* The key alone never licenses deleting the whole line: a line may
             carry several user_pref statements or a trailing comment. Accept
             the key only when this call closes exactly once and nothing but
             the terminating semicolon follows it; otherwise the caller must
             keep the original line verbatim. *)
          let tail =
            String.trim (String.sub tail 1 (String.length tail - 1))
          in
          let len = String.length tail in
          let depth = ref 0 and in_string = ref false and escaped = ref false in
          let closed_at = ref None in
          let i = ref 0 in
          while !i < len && Option.is_none !closed_at do
            let c = tail.[!i] in
            if !in_string then begin
              if !escaped then escaped := false
              else if Char.equal c '\\' then escaped := true
              else if Char.equal c '"' then in_string := false
            end
            else begin
              match c with
              | '"' -> in_string := true
              | '(' -> incr depth
              | ')' -> if !depth = 0 then closed_at := Some !i else decr depth
              | _ -> ()
            end;
            incr i
          done;
          let single_statement =
            match !closed_at with
            | None -> false
            | Some at ->
              let after =
                String.trim (String.sub tail (at + 1) (len - at - 1))
              in
              String.length after >= 1
              && Char.equal after.[0] ';'
              && String.equal
                   (String.trim (String.sub after 1 (String.length after - 1)))
                   ""
          in
          if single_statement then Some key else None
        end
    else None

let split_lines_without_trailing_empty text =
  let raw = String.split_on_char '\n' text in
  match List.rev raw with
  | "" :: rev_rest -> List.rev rev_rest
  | _ -> raw

let ensure_resource_guards ~profile =
  let* () = protect ~label profile (fun () -> checked ~label profile) in
  let user_js_path = Filename.concat profile "user.js" in
  let* existing_user_js =
    Fs_compat.load_owned_regular_file ~ownership_root:profile user_js_path
    |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string
  in
  let preserved_lines =
    match existing_user_js with
    | None -> []
    | Some current ->
      split_lines_without_trailing_empty current
      |> List.filter (fun line ->
        match parse_pref_line_key line with
        | Some key -> not (List.mem key resource_guard_keys)
        | None -> true)
  in
  let guard_lines =
    List.map
      (fun (key, value) ->
         Printf.sprintf "user_pref(%S, %s);" key (Yojson.Safe.to_string value))
      resource_guard_prefs
  in
  let desired_user_js =
    String.concat "\n" (preserved_lines @ guard_lines) ^ "\n"
  in
  let* () =
    match existing_user_js with
    | Some current when String.equal current desired_user_js -> Ok ()
    | Some _ | None ->
      Fs_compat.save_file_atomic_strict user_js_path desired_user_js
  in
  let prefs_js_path = Filename.concat profile "prefs.js" in
  let* existing_prefs_js =
    Fs_compat.load_owned_regular_file ~ownership_root:profile prefs_js_path
    |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string
  in
  match existing_prefs_js with
  | None -> Ok ()
  | Some current ->
    let lines = split_lines_without_trailing_empty current in
    let kept_lines =
      List.filter
        (fun line ->
           match parse_pref_line_key line with
           | Some key -> not (List.mem key poisoned_prefs_keys)
           | None -> true)
        lines
    in
    if List.length kept_lines = List.length lines then
      Ok ()
    else
      let cleaned =
        match kept_lines with
        | [] -> ""
        | _ -> String.concat "\n" kept_lines ^ "\n"
      in
      Fs_compat.save_file_atomic_strict prefs_js_path cleaned

let create ~instance =
  let path = Filename.concat instance Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ())) in
  let* path = protect ~label path (fun () -> Unix.mkdir path 0o700; Ok path) in
  match ensure_resource_guards ~profile:path with
  | Ok () -> Ok path
  | Error _ as error ->
    ignore (Profile.remove ~label path);
    error

type removal =
  | Removed
  | In_use

let remove_locked path = Profile.remove ~label ~last:lock_name path

let remove_if_free path =
  let* lock_file = Profile.open_lock ~profile:path ~name:lock_name in
  Fun.protect ~finally:(fun () -> Profile.close_lock lock_file) (fun () ->
    match Profile.inspect lock_file with
    | Profile.Held_by holder -> Profile.release holder; Ok In_use
    | Profile.Changing -> Ok In_use
    | Profile.Unreadable detail -> Error detail
    | Profile.Unlocked ->
      let* taken = Profile.lock lock_file in
      match taken with
      | Profile.Held_elsewhere -> Ok In_use
      | Profile.Locked ->
        let* () = remove_locked path in
        Ok Removed)
