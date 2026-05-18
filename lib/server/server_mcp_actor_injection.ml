(** Inject or replace [_agent_name] in MCP [tools/call] arguments.
    For authenticated dashboard sessions, the HTTP-layer token owner is the
    canonical caller identity, so a stale browser-supplied [_agent_name]
    must be overwritten. The legacy argument-scoped [token] is also removed
    when HTTP auth is present so stale MCP bodies cannot override the
    transport token. Legacy [agent_name] is left untouched because some tools
    use it as a domain argument rather than caller identity. *)
let inject_agent_name_into_body ?(rewrite_existing = false) ?(strip_token = false)
    ~agent_name body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    let method_name = member "method" json |> to_string_option in
    match method_name with
    | Some "tools/call" ->
        let params = member "params" json in
        let args = member "arguments" params in
        let existing_agent =
          Option.bind
            (member "_agent_name" args |> to_string_option)
            (fun value ->
              let trimmed = String.trim value in
              if String.equal trimmed "" then
                None
              else
                Some trimmed)
        in
        let existing_legacy_agent =
          Option.bind
            (member "agent_name" args |> to_string_option)
            (fun value ->
              let trimmed = String.trim value in
              if String.equal trimmed "" then
                None
              else
                Some trimmed)
        in
        let new_args =
          match args with
          | `Assoc fields ->
              let normalized_fields =
                let fields =
                  if rewrite_existing then
                    List.filter
                      (fun (key, _) -> not (String.equal key "_agent_name"))
                      fields
                  else
                    fields
                in
                if strip_token then
                  List.filter (fun (key, _) -> not (String.equal key "token")) fields
                else
                  fields
              in
              let should_inject =
                rewrite_existing
                || (Option.is_none existing_agent
                   && Option.is_none existing_legacy_agent)
              in
              if should_inject then
                `Assoc (("_agent_name", `String agent_name) :: normalized_fields)
              else
                args
          | _ -> args
        in
        if new_args = args then
          body_str
        else
          let new_params =
            match params with
            | `Assoc fields ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                       if k = "arguments" then
                         (k, new_args)
                       else
                         (k, v))
                     fields)
            | _ -> params
          in
          let new_json =
            match json with
            | `Assoc fields ->
                `Assoc
                  (List.map
                     (fun (k, v) ->
                       if k = "params" then
                         (k, new_params)
                       else
                         (k, v))
                     fields)
            | _ -> json
          in
          Yojson.Safe.to_string new_json
    | _ -> body_str
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> body_str

let reduce ~actor ~auth_token body_str =
  match actor with
  | None -> body_str
  | Some agent ->
      inject_agent_name_into_body
        ~rewrite_existing:(Option.is_some auth_token)
        ~strip_token:(Option.is_some auth_token)
        ~agent_name:agent body_str
