(** Keeper_identity — centralized keeper identity helpers. *)

let generate_trace_id () : string =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let hash = Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFFF in
  Printf.sprintf "trace-%d-%05x" ts hash

let sanitize_name (name : string) : string =
  String.map
    (fun c ->
      if
        (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9')
        || c = '-'
        || c = '_'
        || c = '.'
      then c
      else '_')
    name

let keeper_git_author ~(keeper_name : string) : string =
  let safe = sanitize_name keeper_name in
  Printf.sprintf "%s (MASC Keeper)" safe

let keeper_git_email ~(keeper_name : string) : string =
  let safe = sanitize_name keeper_name in
  Printf.sprintf "%s@masc.local" safe

let git_env_for_keeper ~(keeper_name : string) : string array =
  let author = keeper_git_author ~keeper_name in
  let email = keeper_git_email ~keeper_name in
  let base_env = Unix.environment () in
  let filtered =
    Array.to_list base_env
    |> List.filter (fun s ->
           not (String.starts_with ~prefix:"GIT_AUTHOR_" s)
           && not (String.starts_with ~prefix:"GIT_COMMITTER_" s))
  in
  let overrides =
    [
      "GIT_AUTHOR_NAME=" ^ author;
      "GIT_AUTHOR_EMAIL=" ^ email;
      "GIT_COMMITTER_NAME=" ^ author;
      "GIT_COMMITTER_EMAIL=" ^ email;
    ]
  in
  Array.of_list (filtered @ overrides)

let keeper_name_from_agent_name agent_name =
  let prefix = "keeper-" and suffix = "-agent" in
  let plen = String.length prefix and slen = String.length suffix in
  let alen = String.length agent_name in
  if alen > plen + slen
     && String.sub agent_name 0 plen = prefix
     && String.sub agent_name (alen - slen) slen = suffix
  then
    let keeper_name = String.sub agent_name plen (alen - plen - slen) in
    if Keeper_config.validate_name keeper_name then Some keeper_name else None
  else if Nickname.is_generated_nickname agent_name
          && Keeper_config.validate_name agent_name
  then
    Some agent_name
  else
    None

let is_keeper_agent_alias agent_name =
  let prefix = "keeper-" and suffix = "-agent" in
  let plen = String.length prefix and slen = String.length suffix in
  let alen = String.length agent_name in
  alen > plen + slen
  && String.sub agent_name 0 plen = prefix
  && String.sub agent_name (alen - slen) slen = suffix

let canonical_keeper_name_from_agent_name agent_name =
  let trimmed = String.trim agent_name in
  match keeper_name_from_agent_name trimmed with
  | Some keeper_name when is_keeper_agent_alias trimmed -> Some keeper_name
  | Some _ when Nickname.is_generated_nickname trimmed -> (
      match Nickname.extract_agent_type trimmed with
      | Some candidate when Keeper_config.validate_name candidate -> Some candidate
      | _ -> None)
  | Some keeper_name -> Some keeper_name
  | None ->
      if Nickname.is_generated_nickname trimmed
      then
        match Nickname.extract_agent_type trimmed with
        | Some candidate when Keeper_config.validate_name candidate -> Some candidate
        | _ -> None
      else
        None

let canonical_keeper_name raw_name =
  let trimmed = String.trim raw_name in
  let prefix = "keeper-" in
  let plen = String.length prefix in
  let alen = String.length trimmed in
  if trimmed = "" then None
  else
    match canonical_keeper_name_from_agent_name trimmed with
    | Some _ as canonical -> canonical
    | None when alen > plen && String.sub trimmed 0 plen = prefix ->
        let candidate = String.sub trimmed plen (alen - plen) in
        if Keeper_config.validate_name candidate then Some candidate else None
    | None ->
        if Keeper_config.validate_name trimmed then Some trimmed else None

let explicit_keeper_name raw_name =
  let trimmed = String.trim raw_name in
  let prefix = "keeper-" in
  let plen = String.length prefix in
  let alen = String.length trimmed in
  if trimmed = "" then None
  else if alen > plen && String.sub trimmed 0 plen = prefix then
    let candidate = String.sub trimmed plen (alen - plen) in
    if Keeper_config.validate_name candidate then Some candidate else None
  else if Keeper_config.validate_name trimmed then Some trimmed
  else None

type parsed_identity = {
  keeper_name : string;
  agent_name : string;
  trace_id : string option;
}

let parse_json_identity json =
  let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
  let trace_id = Safe_ops.json_string_opt "trace_id" json in
  let raw_keeper_name =
    match Safe_ops.json_string_opt "keeper_name" json with
    | Some v when String.trim v <> "" -> Some v
    | _ -> Safe_ops.json_string_opt "name" json
  in
  let keeper_name =
    match raw_keeper_name with
    | Some value when String.trim value <> "" ->
        (match explicit_keeper_name value with
         | Some name -> name
         | None -> String.trim value)
    | _ ->
        (match canonical_keeper_name_from_agent_name agent_name with
         | Some name -> name
         | None -> String.trim agent_name)
  in
  { keeper_name; agent_name; trace_id }
