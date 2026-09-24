type sign_in =
  | Known of bool
  | Unreported

type scopes =
  | Listed of string list
  | Not_listed_by_github
  | Scopes_unreported

type reading = {
  sign_in : sign_in;
  login : string option;
  error : string option;
  scopes : scopes;
}

type probe_scope =
  | Host_process
  | Remote_endpoint
  | Probe_scope_unknown

type t = {
  hostname : string;
  config_dir : string option;
  token_env_names : string list;
  stored : reading option;
  effective : reading option;
  probe_scope : probe_scope;
}

let string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let strings items =
  List.filter_map (function `String value -> Some value | _ -> None) items

let decode_reading = function
  | Some (`Assoc fields) ->
    (* A missing key is not a negative answer. This read "not signed in"
       for a server that left the key out or changed its type, which is the
       opposite of the truth for a Keeper that is signed in, and the
       operator's next move on that row is to sign in again. *)
    let sign_in =
      match List.assoc_opt "authenticated" fields with
      | Some (`Bool value) -> Known value
      | Some _ | None -> Unreported
    in
    let scopes =
      match List.assoc_opt "scopes" fields with
      | Some (`List items) -> Listed (strings items)
      | Some `Null -> Not_listed_by_github
      | Some _ | None -> Scopes_unreported
    in
    Some
      { sign_in
      ; login = string_field fields "login"
      ; error = string_field fields "error"
      ; scopes
      }
  | Some _ | None -> None

let decode (json : Yojson.Safe.t) : t option =
  match json with
  | `Assoc fields -> (
    match string_field fields "hostname" with
    | None -> None
    | Some hostname ->
      let token_env_names =
        match List.assoc_opt "projected_token_env_names" fields with
        | Some (`List items) -> strings items
        | Some _ | None -> []
      in
      let probe_scope =
        match string_field fields "effective_probe_scope" with
        | Some "host_process_credential_only" -> Host_process
        | Some "endpoint_process_only" -> Remote_endpoint
        | Some _ | None -> Probe_scope_unknown
      in
      Some
        { hostname
        ; config_dir = string_field fields "config_dir"
        ; token_env_names
        ; stored = decode_reading (List.assoc_opt "stored" fields)
        ; effective = decode_reading (List.assoc_opt "effective" fields)
        ; probe_scope
        })
  | _ -> None

let scopes_text = function
  | Listed [] -> " \xc2\xb7 scopes: (none)"
  | Listed scopes -> " \xc2\xb7 scopes: " ^ String.concat ", " scopes
  | Not_listed_by_github -> " \xc2\xb7 scopes: not listed by GitHub"
  (* Say nothing rather than the wrong one of the two readings above. *)
  | Scopes_unreported -> ""

let reading_text reading =
  let scopes = scopes_text reading.scopes in
  match reading.sign_in, reading.login, reading.error with
  | Known true, Some who, _ -> "signed in as " ^ who ^ scopes
  | Known true, None, _ -> "signed in" ^ scopes
  | Known false, _, Some message -> "not signed in (" ^ message ^ ")"
  | Known false, _, None -> "not signed in"
  | Unreported, _, Some message -> "sign-in not reported (" ^ message ^ ")"
  | Unreported, _, None -> "sign-in not reported"

let effective_label = function
  | Host_process -> "effective (this host)"
  | Remote_endpoint -> "effective (remote endpoint)"
  | Probe_scope_unknown -> "effective"

let lines t =
  let row label text = [ "  " ^ label ^ ": " ^ text ] in
  let optional_row label = function
    | Some reading -> row label (reading_text reading)
    | None -> []
  in
  let effective_label = effective_label t.probe_scope in
  (* The second reading is here to show a difference: what the keeper's
     config stores, against what this host resolves from it. They agree on
     every keeper whose login is plain, and then the two rows are the same
     sentence twice -- on the live roster code-reviewer drew "signed in as
     pangyo-preachers · scopes: gist, read:org, repo, workflow" on both.
     Agreement is one row carrying both labels, so a reader is never left
     wondering whether the effective side was read at all; a difference is
     still two rows. The drawn sentences are what is compared, since the
     repetition being removed is a repetition of what is drawn. *)
  let identity_rows =
    match t.stored, t.effective with
    | Some stored, Some effective
      when String.equal (reading_text stored) (reading_text effective) ->
        row ("stored and " ^ effective_label) (reading_text stored)
    | Some _, _ | None, _ ->
        optional_row "stored" t.stored @ optional_row effective_label t.effective
  in
  let token_env_row =
    match t.token_env_names with
    | [] -> "  token env: (none)"
    | names -> "  token env: " ^ String.concat ", " names
  in
  [ Printf.sprintf "GitHub (%s)" t.hostname ]
  @ identity_rows
  @ [ token_env_row ]
  @ (match t.config_dir with Some dir -> [ "  config: " ^ dir ] | None -> [])

let view_lines ~sanitize json =
  let drawn =
    match decode json with
    | Some t -> lines t
    (* A shape this reader does not know is drawn whole, so the tab never
       shows less than the payload carried. *)
    | None -> Yojson.Safe.pretty_to_string json |> String.split_on_char '\n'
  in
  List.map sanitize drawn
