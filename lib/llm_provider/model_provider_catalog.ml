(** Provider identity rows embedded in the model catalog TOML.

    This module owns the strict parse boundary for [models.toml] [[providers]]
    rows. Keeping it separate from {!Model_catalog} makes the packaged TOML a
    reusable provider/model catalog surface instead of adding provider-specific
    branches to model capability lookup. *)

module Result_syntax = struct
  let ( let* ) = Result.bind
end

open Result_syntax

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; identity_kinds : Provider_kind.t list
  ; base_url : string
  ; base_url_env : string option
  ; request_path : string
  ; api_key_env : string
  ; default_model : string option
  ; capabilities_base : string option
  ; identity_hosts : string list
  }

let find_string_field ~entry_id key toml =
  match Otoml.find_opt toml Otoml.get_string [ key ] with
  | Some s -> Ok (Some s)
  | None -> Ok None
  | exception Otoml.Type_error _ ->
    Error (Printf.sprintf "provider entry %S field %S expected string" entry_id key)
;;

let non_empty_string_field ~entry_id key toml =
  match find_string_field ~entry_id key toml with
  | Error _ as e -> e
  | Ok None -> Ok None
  | Ok (Some raw) ->
    let value = String.lowercase_ascii (String.trim raw) in
    if value = ""
    then
      Error (Printf.sprintf "provider entry %S field %S must not be empty" entry_id key)
    else Ok (Some value)
;;

let exact_non_empty_string_field ~entry_id key toml =
  match find_string_field ~entry_id key toml with
  | Error _ as e -> e
  | Ok None -> Ok None
  | Ok (Some raw) ->
    let trimmed = String.trim raw in
    if trimmed = ""
    then
      Error (Printf.sprintf "provider entry %S field %S must not be empty" entry_id key)
    else if raw <> trimmed
    then
      Error
        (Printf.sprintf
           "provider entry %S field %S must not have leading or trailing whitespace"
           entry_id
           key)
    else Ok (Some raw)
;;

let canonical_string_opt ~entry_id key ~allowed toml =
  match find_string_field ~entry_id key toml with
  | Error _ as e -> e
  | Ok None -> Ok None
  | Ok (Some raw) ->
    let normalized = String.lowercase_ascii (String.trim raw) in
    if List.mem normalized allowed
    then Ok (Some raw)
    else
      Error
        (Printf.sprintf
           "provider entry %S field %S has unknown value %S (canonical: %s)"
           entry_id
           key
           normalized
           (String.concat ", " allowed))
;;

let string_list_field ~entry_id key toml =
  match Otoml.find_opt toml (Otoml.get_array Otoml.get_string) [ key ] with
  | Some values ->
    let rec loop acc = function
      | [] -> Ok (Some (List.rev acc))
      | raw :: rest ->
        let trimmed = String.trim raw in
        if trimmed = ""
        then
          Error
            (Printf.sprintf
               "provider entry %S field %S must not contain empty strings"
               entry_id
               key)
        else if raw <> trimmed
        then
          Error
            (Printf.sprintf
               "provider entry %S field %S must not contain padded strings"
               entry_id
               key)
        else loop (raw :: acc) rest
    in
    loop [] values
  | None -> Ok None
  | exception Otoml.Type_error _ ->
    Error (Printf.sprintf "provider entry %S field %S expected string array" entry_id key)
;;

let known_keys =
  [ "id"
  ; "aliases"
  ; "kind"
  ; "identity_kinds"
  ; "base_url"
  ; "base_url_env"
  ; "request_path"
  ; "api_key_env"
  ; "default_model"
  ; "capabilities_base"
  ; "identity_hosts"
  ]
;;

let reject_unknown_keys ~entry_id entry_toml =
  match Otoml.list_table_keys_result entry_toml with
  | Error _ -> Ok ()
  | Ok keys ->
    (match List.filter (fun k -> not (List.mem k known_keys)) keys with
     | [] -> Ok ()
     | unknown ->
       Error
         (Printf.sprintf
            "provider entry %S contains unknown field(s): %s"
            entry_id
            (String.concat ", " unknown)))
;;

let required_string ~entry_id key toml =
  match exact_non_empty_string_field ~entry_id key toml with
  | Ok (Some value) -> Ok value
  | Ok None ->
    Error (Printf.sprintf "provider entry %S missing required %S field" entry_id key)
  | Error _ as e -> e
;;

let required_exact_string_allow_empty ~entry_id key toml =
  match find_string_field ~entry_id key toml with
  | Error _ as error -> error
  | Ok None ->
    Error (Printf.sprintf "provider entry %S missing required %S field" entry_id key)
  | Ok (Some raw) ->
    if raw <> String.trim raw
    then
      Error
        (Printf.sprintf
           "provider entry %S field %S must not have leading or trailing whitespace"
           entry_id
           key)
    else Ok raw
;;

let kind_field ~entry_id toml =
  match required_string ~entry_id "kind" toml with
  | Error _ as e -> e
  | Ok raw ->
    (match Provider_kind.of_string raw with
     | Some kind -> Ok kind
     | None ->
       Error
         (Printf.sprintf
            "provider entry %S field \"kind\" has unknown value %S (canonical: %s)"
            entry_id
            (String.lowercase_ascii (String.trim raw))
            (String.concat ", " (List.map Provider_kind.to_string Provider_kind.all))))
;;

let identity_kinds_field ~entry_id ~default toml =
  match string_list_field ~entry_id "identity_kinds" toml with
  | Error _ as error -> error
  | Ok None -> Ok [ default ]
  | Ok (Some []) ->
    Error
      (Printf.sprintf
         "provider entry %S field \"identity_kinds\" must not be empty"
         entry_id)
  | Ok (Some values) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | raw :: rest ->
        (match Provider_kind.of_string raw with
         | Some kind -> loop (kind :: acc) rest
         | None ->
           Error
             (Printf.sprintf
                "provider entry %S field \"identity_kinds\" has unknown value %S \
                 (canonical: %s)"
                entry_id
                raw
                (String.concat ", " (List.map Provider_kind.to_string Provider_kind.all))))
    in
    loop [] values
;;

let parse_entry provider_toml =
  let* id =
    match exact_non_empty_string_field ~entry_id:"<unknown>" "id" provider_toml with
    | Error _ -> Error "provider entry field \"id\" expected exact non-empty string"
    | Ok None -> Error "provider entry missing required \"id\" field"
    | Ok (Some id) -> Ok (String.lowercase_ascii id)
  in
  let* () = reject_unknown_keys ~entry_id:id provider_toml in
  let* kind = kind_field ~entry_id:id provider_toml in
  let* identity_kinds = identity_kinds_field ~entry_id:id ~default:kind provider_toml in
  let* base_url = required_string ~entry_id:id "base_url" provider_toml in
  let* request_path =
    required_exact_string_allow_empty ~entry_id:id "request_path" provider_toml
  in
  let* api_key_env =
    required_exact_string_allow_empty ~entry_id:id "api_key_env" provider_toml
  in
  let* base_url_env =
    exact_non_empty_string_field ~entry_id:id "base_url_env" provider_toml
  in
  let* default_model =
    exact_non_empty_string_field ~entry_id:id "default_model" provider_toml
  in
  let* capabilities_base =
    canonical_string_opt
      ~entry_id:id
      "capabilities_base"
      ~allowed:Capability_vocab.base_label_values
      provider_toml
  in
  let* aliases = string_list_field ~entry_id:id "aliases" provider_toml in
  let* identity_hosts = string_list_field ~entry_id:id "identity_hosts" provider_toml in
  Ok
    { id
    ; aliases = Option.value aliases ~default:[]
    ; kind
    ; identity_kinds
    ; base_url
    ; base_url_env
    ; request_path
    ; api_key_env
    ; default_model
    ; capabilities_base
    ; identity_hosts =
        Option.value identity_hosts ~default:[] |> List.map String.lowercase_ascii
    }
;;

let normalize_url value =
  let trimmed = String.trim value in
  if trimmed = ""
  then trimmed
  else (
    let rec strip_trailing_slash s =
      let len = String.length s in
      if len > 1 && s.[len - 1] = '/'
      then strip_trailing_slash (String.sub s 0 (len - 1))
      else s
    in
    strip_trailing_slash trimmed)
;;

let host_of_url value =
  match Uri.of_string value |> Uri.host with
  | None -> None
  | Some host -> Some (String.lowercase_ascii host)
;;

let resolved_base_url ?getenv entry =
  match entry.base_url_env with
  | None -> entry.base_url
  | Some env_name ->
    (match Cli_common_env.get ?getenv env_name with
     | Some value when String.trim value <> "" -> value
     | Some _ | None -> entry.base_url)
;;

let base_url_matches ?getenv entry base_url =
  let normalized = normalize_url base_url in
  String.equal (normalize_url entry.base_url) normalized
  || String.equal (normalize_url (resolved_base_url ?getenv entry)) normalized
;;

let host_matches entry base_url =
  match host_of_url base_url with
  | None -> false
  | Some host -> List.exists (String.equal host) entry.identity_hosts
;;

let label_of_entry entry =
  let normalized = String.lowercase_ascii (String.trim entry.id) in
  if normalized = "" then None else Some normalized
;;

let provider_label_for_base_url ?getenv entries ~kind ~base_url =
  match
    List.find_opt
      (fun entry ->
         List.mem kind entry.identity_kinds
         && (base_url_matches ?getenv entry base_url || host_matches entry base_url))
      entries
  with
  | None -> None
  | Some entry -> label_of_entry entry
;;

let provider_label_for_endpoint ?getenv entries ~kind ~base_url ~request_path =
  let request_path = String.trim request_path in
  match
    List.find_opt
      (fun entry ->
         List.mem kind entry.identity_kinds
         && String.equal (String.trim entry.request_path) request_path
         && (base_url_matches ?getenv entry base_url || host_matches entry base_url))
      entries
  with
  | None -> None
  | Some entry -> label_of_entry entry
;;
