open Result.Syntax
module Requirement = Resource_requirement

let label = "Gecko profile"

let protect ~label path run =
  try run () with Unix.Unix_error (error, call, _) ->
    Error (Printf.sprintf "%s %s: %s failed: %s" label path call (Unix.error_message error))

let checked ~label path =
  let* _ = Requirement.lstat ~label Requirement.private_directory path in
  Requirement.canonical ~label path

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
