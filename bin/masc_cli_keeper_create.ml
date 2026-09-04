(** Implementation of the [masc keeper-create] declaration and its answer. See
    the interface for what each value promises. *)

type booleans =
  { autoboot : bool option
  ; proactive : bool option
  }

type flags =
  { name : string
  ; instructions : string
  ; sandbox_profile : string
  ; network_mode : string option
  ; remote_endpoint : string option
  ; mention_targets : string list
  ; skills : string list option
  ; max_context_override : int option
  ; booleans : booleans
  }

let trimmed_nonempty raw =
  let value = String.trim raw in
  if String.equal value "" then None else Some value
;;

let spellings values = String.concat ", " values

(* The two sentences below are the only hand-written description of what the
   modes do; the list of spellings is rendered from the typed owner, so a
   third mode reaches this message without an edit. They describe behaviour
   and stop there: which of the two a keeper wants is the operator's to
   decide, and a command that guessed it from the instructions text would be
   guessing at exactly the field this refusal exists to stop it guessing. *)
let missing_network_mode_message =
  String.concat
    "\n"
    [ Printf.sprintf
        "masc keeper-create: --network-mode is required (%s)."
        (spellings Keeper_types_profile_sandbox.valid_network_mode_strings)
    ; "  none     the guest has no network. A web search, a git push, or any \
       HTTP call inside it fails."
    ; "  inherit  the guest uses the host network."
    ; "Nothing was created."
    ]
;;

let missing_name_message =
  "masc keeper-create: --name is required. Nothing was created."
;;

let missing_sandbox_profile_message =
  Printf.sprintf
    "masc keeper-create: --sandbox-profile is required (%s). Nothing was created."
    (spellings Keeper_types_profile_sandbox.valid_sandbox_profile_strings)
;;

let string_list_json values = `List (List.map (fun value -> `String value) values)

let declaration_of_flags (flags : flags) : (Yojson.Safe.t, string) result =
  match trimmed_nonempty flags.name with
  | None -> Error missing_name_message
  | Some name ->
    (match trimmed_nonempty flags.sandbox_profile with
     | None -> Error missing_sandbox_profile_message
     | Some sandbox_profile ->
       (match flags.network_mode with
        | None -> Error missing_network_mode_message
        | Some network_mode ->
          let instructions =
            match trimmed_nonempty flags.instructions with
            | None -> []
            | Some text -> [ "instructions", `String text ]
          in
          let remote_endpoint =
            match flags.remote_endpoint with
            | None -> []
            | Some endpoint -> [ "remote_endpoint", `String endpoint ]
          in
          let mention_targets =
            match flags.mention_targets with
            | [] -> []
            | targets -> [ "mention_targets", string_list_json targets ]
          in
          let skills =
            match flags.skills with
            | None -> []
            | Some names -> [ "skills", `Assoc [ "names", string_list_json names ] ]
          in
          let max_context_override =
            match flags.max_context_override with
            | None -> []
            | Some value -> [ "max_context_override", `Int value ]
          in
          let autoboot_enabled =
            match flags.booleans.autoboot with
            | None -> []
            | Some value -> [ "autoboot_enabled", `Bool value ]
          in
          let proactive_enabled =
            match flags.booleans.proactive with
            | None -> []
            | Some value -> [ "proactive_enabled", `Bool value ]
          in
          Ok
            (`Assoc
                ([ "name", `String name
                 ; "sandbox_profile", `String sandbox_profile
                 ; "network_mode", `String network_mode
                 ]
                 @ instructions
                 @ remote_endpoint
                 @ mention_targets
                 @ skills
                 @ max_context_override
                 @ autoboot_enabled
                 @ proactive_enabled))))
;;

let form_stem = Masc.Keeper_turn_up_args.creation_stem

let flag_alternative =
  "In a script or a pipe, pass the declaration as flags: --name, \
   --sandbox-profile, --network-mode, --instructions."
;;

let form_input_refusal ~stdin_is_tty ~editor =
  if not stdin_is_tty
  then
    Some
      (String.concat
         "\n"
         [ "masc keeper-create --edit needs a terminal."
         ; flag_alternative
         ; "Nothing was created."
         ])
  else (
    match editor with
    | Some _ -> None
    | None ->
      Some
        (String.concat
           "\n"
           [ "masc keeper-create --edit needs $EDITOR or $VISUAL set."
           ; flag_alternative
           ; "Nothing was created."
           ]))
;;

let declaration_of_form edited =
  match Yojson.Safe.from_string edited with
  | exception Yojson.Json_error message ->
    Error (Printf.sprintf "the form is not JSON: %s. Nothing was created." message)
  | `Assoc _ as declaration ->
    (match Option.bind (Json_util.assoc_string_opt "name" declaration) trimmed_nonempty with
     | None ->
       Error "the form needs a non-blank \"name\" string. Nothing was created."
     | Some name -> Ok (declaration, name))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error "the form must be a JSON object. Nothing was created."
;;

type outcome =
  | Created of
      { name : string
      ; sandbox_profile : string
      ; network_mode : string
      }
  | Reconfigured of { name : string }
  | Revision_conflict
  | Unauthorized of string
  | Refused of string
  | Unreachable of string

let parsed_body body =
  match Yojson.Safe.from_string body with
  | json -> Some json
  | exception Yojson.Json_error _ -> None
;;

(* The server's own words when it wrote any, the raw body when it did not. A
   body that is not JSON is still what the server said, and hiding it behind a
   sentence of this command's own would cost the operator the only account of
   the refusal there is. *)
let server_message body =
  match parsed_body body with
  | None -> body
  | Some json ->
    (match Json_util.assoc_string_opt "error" json with
     | None -> body
     | Some message -> message)
;;

(* The route names the keeper it acted on in every answer it gives. Without
   that name there is nothing to report the outcome about, and substituting a
   blank one would print a line that reads like a keeper called nothing. *)
let successful_outcome json =
  match Json_util.assoc_string_opt "name" json with
  | None ->
    Refused
      "the server accepted the declaration but its answer names no keeper, so \
       this command cannot say which one it applies to"
  | Some name ->
    (match Json_util.assoc_object_opt "detail" json with
     | None -> Reconfigured { name }
     | Some detail ->
       (match
          ( Json_util.assoc_string_opt "sandbox_profile" detail
          , Json_util.assoc_string_opt "network_mode" detail )
        with
        | Some sandbox_profile, Some network_mode ->
          Created { name; sandbox_profile; network_mode }
        | Some _, None | None, Some _ | None, None -> Reconfigured { name }))
;;

let rejected_outcome ~body json =
  let conflict =
    match Json_util.assoc_object_opt "detail" json with
    | None -> false
    | Some detail ->
      (match Json_util.assoc_string_opt "code" detail with
       | None -> false
       | Some code ->
         String.equal code Masc.Keeper_turn_up_update.config_revision_conflict_code)
  in
  if conflict then Revision_conflict else Refused (server_message body)
;;

let http_unauthorized = 401
let http_forbidden = 403
let http_lowest_success = 200
let http_lowest_redirect = 300

let outcome_of_response ~status ~body =
  if status = http_unauthorized || status = http_forbidden
  then Unauthorized (server_message body)
  else if status >= http_lowest_success && status < http_lowest_redirect
  then (
    match parsed_body body with
    | None ->
      Refused
        (Printf.sprintf
           "the server accepted the declaration but its answer is not JSON: %s"
           body)
    | Some json -> successful_outcome json)
  else (
    match parsed_body body with
    | None -> Refused body
    | Some json -> rejected_outcome ~body json)
;;

let retry_note =
  "Re-running the same command applies the declaration to the keeper of that \
   name; it does not make a second one."
;;

let render = function
  | Created { name; sandbox_profile; network_mode } ->
    ( String.concat
        "\n"
        [ Printf.sprintf "%s: created" name
        ; Printf.sprintf "  sandbox_profile  %s" sandbox_profile
        ; Printf.sprintf "  network_mode     %s" network_mode
        ; "The keeper is live now and its first turn has already started."
        ]
    , 0 )
  | Reconfigured { name } ->
    ( String.concat
        "\n"
        [ Printf.sprintf
            "%s: a keeper of that name already existed, so the server applied \
             this declaration to it instead of creating one."
            name
        ; "The sandbox profile and network mode it landed on are not in that \
           answer; read them from the keeper's TOML."
        ]
    , 0 )
  | Revision_conflict ->
    ( String.concat
        "\n"
        [ "another writer committed to the keeper manifest first, so this call \
           wrote nothing."
        ; "Re-run the same command: it re-reads the manifest and applies only \
           the fields you passed."
        ]
    , 4 )
  | Unauthorized message ->
    ( String.concat
        "\n"
        [ Printf.sprintf "the server refused this command's credential: %s" message
        ; "Run masc login for this workspace, or pass --token."
        ]
    , 1 )
  | Refused message ->
    ( String.concat
        "\n"
        [ message
        ; "The declaration may have been written before this failed."
        ; retry_note
        ]
    , 1 )
  | Unreachable message ->
    ( String.concat
        "\n"
        [ Printf.sprintf "the request did not complete: %s" message
        ; "A refused connection means nothing was sent; a timeout does not, \
           and this command cannot tell the two apart from here."
        ; retry_note
        ]
    , 1 )
;;
