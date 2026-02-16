type role =
  | Dm
  | Player
  | Neutral

type profile = {
  hearth_hint: string option;
  role: role;
  start_token: string option;
  start_signals: string list;
}

let trim_lower (s : string) : string =
  String.trim s |> String.lowercase_ascii

let validate_name (name : string) : bool =
  let re = Str.regexp "^[A-Za-z0-9._-]+$" in
  name <> "" && Str.string_match re name 0

let contains_ci (haystack : string) (needle : string) : bool =
  let hay = String.lowercase_ascii haystack in
  let ndl = String.lowercase_ascii (String.trim needle) in
  ndl <> ""
  &&
  try
    let _ = Str.search_forward (Str.regexp_string ndl) hay 0 in
    true
  with Not_found ->
    false

let parse_lines (text : string) : string list =
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let parse_kv_line (line : string) : (string * string) option =
  let try_delim delim =
    try
      let idx = String.index line delim in
      let key = String.sub line 0 idx |> String.trim |> String.lowercase_ascii in
      let value =
        String.sub line (idx + 1) (String.length line - idx - 1) |> String.trim
      in
      if key = "" || value = "" then None else Some (key, value)
    with Not_found ->
      None
  in
  match try_delim ':' with
  | Some kv -> Some kv
  | None -> try_delim '='

let parse_kvs (text : string) : (string * string) list =
  parse_lines text
  |> List.filter_map parse_kv_line

let find_kv (kvs : (string * string) list) (key : string) : string option =
  let key = String.lowercase_ascii (String.trim key) in
  kvs
  |> List.rev
  |> List.find_map (fun (k, v) ->
         if k = key then Some v else None)

let parse_csv (raw : string) : string list =
  raw
  |> Str.split (Str.regexp "[,;|]+")
  |> List.map String.trim
  |> List.filter (fun s -> s <> "")

let dedup_ci (items : string list) : string list =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  List.filter
    (fun item ->
      let key = trim_lower item in
      if key = "" || Hashtbl.mem seen key then
        false
      else (
        Hashtbl.replace seen key ();
        true))
    items

let role_of_string (raw : string) : role option =
  match trim_lower raw with
  | "dm" | "master" | "director" | "gm" | "진행자" -> Some Dm
  | "player" | "party" | "member" | "플레이어" | "파티" -> Some Player
  | "neutral" | "observer" | "none" -> Some Neutral
  | _ -> None

let infer_role ~(name : string) ~(goal : string) ~(instructions : string) : role =
  match role_of_string instructions with
  | Some role -> role
  | None ->
      let text = name ^ "\n" ^ goal ^ "\n" ^ instructions in
      if
        contains_ci text "role:dm"
        || contains_ci text "role=dm"
        || contains_ci text "dm"
        || contains_ci text "진행자"
      then
        Dm
      else if
        contains_ci text "role:player"
        || contains_ci text "role=player"
        || contains_ci text "player"
        || contains_ci text "플레이어"
      then
        Player
      else
        Neutral

let start_token_from_env () : string option =
  match Sys.getenv_opt "MASC_KEEPER_REACTIVE_START_TOKEN" with
  | Some v ->
      let t = String.trim v in
      if t = "" then None else Some t
  | None -> Some "[START]"

let start_signals_from_env ~(fallback_token : string option) : string list =
  let defaults =
    let base = [ "start"; "시작" ] in
    match fallback_token with
    | Some tok -> tok :: base
    | None -> base
  in
  match Sys.getenv_opt "MASC_KEEPER_REACTIVE_START_SIGNALS" with
  | Some v ->
      let parsed = parse_csv v in
      if parsed = [] then defaults else parsed
  | None -> defaults

let role_is_dm (role : role) : bool =
  match role with
  | Dm -> true
  | Player | Neutral -> false

let text_has_start_signal (profile : profile) (text : string) : bool =
  List.exists (fun signal -> contains_ci text signal) profile.start_signals

let profile_of_text ~(name : string) ~(goal : string) ~(instructions : string) : profile =
  let kvs = parse_kvs goal @ parse_kvs instructions in
  let hearth_hint =
    match find_kv kvs "hearth" with
    | Some h when validate_name h -> Some h
    | _ -> None
  in
  let role =
    match find_kv kvs "role" with
    | Some raw -> (
        match role_of_string raw with
        | Some role -> role
        | None -> infer_role ~name ~goal ~instructions)
    | None -> infer_role ~name ~goal ~instructions
  in
  let start_token =
    match find_kv kvs "reactive_start_token" with
    | Some raw ->
        let t = String.trim raw in
        if t = "" then None else Some t
    | None -> start_token_from_env ()
  in
  let start_signals =
    match find_kv kvs "reactive_start_signals" with
    | Some raw ->
        let parsed = parse_csv raw in
        if parsed = [] then start_signals_from_env ~fallback_token:start_token else parsed
    | None -> start_signals_from_env ~fallback_token:start_token
  in
  let start_signals =
    match start_token with
    | Some tok when not (List.exists (fun s -> trim_lower s = trim_lower tok) start_signals) ->
        tok :: start_signals
    | _ -> start_signals
  in
  {
    hearth_hint;
    role;
    start_token;
    start_signals = dedup_ci start_signals;
  }
