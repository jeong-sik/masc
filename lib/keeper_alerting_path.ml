(** Keeper_alerting path safety and tool output helpers. *)

let project_root_of_config (config : Room.config) : string =
  let base = config.base_path in
  if Filename.basename base = ".masc" then Filename.dirname base else base

let starts_with ~(prefix : string) (s : string) : bool =
  let lp = String.length prefix in
  String.length s >= lp && String.sub s 0 lp = prefix

let normalize_path_for_check (path : string) : string =
  try Unix.realpath path
  with Unix.Unix_error _ ->
    let parent = Filename.dirname path in
    let parent_norm =
      try Unix.realpath parent
      with Unix.Unix_error _ -> parent
    in
    Filename.concat parent_norm (Filename.basename path)

let resolve_keeper_target_path ~(config : Room.config) ~(raw_path : string)
    : (string, string) result =
  let raw = String.trim raw_path in
  if raw = "" then Error "path_required"
  else
    let root = project_root_of_config config in
    let candidate =
      if Filename.is_relative raw then Filename.concat root raw else raw
    in
    let root_norm = normalize_path_for_check root in
    let target_norm = normalize_path_for_check candidate in
    let allowed =
      target_norm = root_norm
      || starts_with ~prefix:(root_norm ^ "/") target_norm
    in
    if allowed then Ok candidate
    else
      Error
        (Printf.sprintf
           "path_outside_project_root: %s (root=%s)"
           target_norm
           root_norm)

let truncate_tool_output ?(max_len = 12000) (s : string) : string =
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "\n...[truncated]"

let process_status_to_json (st : Unix.process_status) : Yojson.Safe.t =
  match st with
  | Unix.WEXITED code ->
      `Assoc [("kind", `String "exit"); ("code", `Int code)]
  | Unix.WSIGNALED sig_num ->
      `Assoc [("kind", `String "signaled"); ("signal", `Int sig_num)]
  | Unix.WSTOPPED sig_num ->
      `Assoc [("kind", `String "stopped"); ("signal", `Int sig_num)]

let is_weather_text (s : string) : bool =
  let h = String.lowercase_ascii s in
  let n = String.lowercase_ascii "weather" in
  let has_weather =
    try let _ = Str.search_forward (Str.regexp_string n) h 0 in true
    with Not_found -> false
  in
  has_weather
  || (try let _ = Str.search_forward (Str.regexp_string "\xeb\x82\xa0\xec\x94\xa8") s 0 in true with Not_found -> false)

let extract_user_messages (ctx_work : Context_manager.working_context) : string list =
  ctx_work.messages
  |> List.filter_map (fun (m : Llm_client.message) ->
       if m.role = Llm_client.User then
         let c = String.trim m.content in
         if c = "" then None else Some c
       else
         None)
