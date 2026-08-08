(** Opaque identity of one resolved OAS provider binding. *)

module PC = Llm_provider.Provider_config
module PK = Llm_provider.Provider_kind
module Secret = Llm_provider.Secret

type transport =
  | Http
  | Injected

type provider_identity =
  | Registered of string
  | Unregistered of PC.provider_kind

type auth_scheme =
  | No_auth
  | Api_key
  | Setup_token
  | Provider_defined

type t =
  { provider : provider_identity
  ; model_id : Llm_provider.Model_id.t
  ; transport : transport
  ; endpoint : Uri.t
  ; request_path : Uri.t
  ; auth_scheme : auth_scheme
  ; credential_scope : string option
  ; credential_identity : Secret.identity option
  }

let canonical_uri value = Uri.of_string value |> Uri.canonicalize

let provider_and_binding config =
  match config.PC.provider_id with
  | Some provider_id ->
    (match Provider_runtime_binding.find provider_id with
     | Some binding -> Registered binding.id, Some binding
     | None -> Registered (String.trim provider_id |> String.lowercase_ascii), None)
  | None -> Unregistered config.PC.kind, None
;;

let auth_scheme_of_binding (binding : Provider_runtime_binding.t) =
  match binding.auth with
  | Provider_runtime_binding.No_auth -> No_auth
  | Provider_runtime_binding.Api_key_env _ -> Api_key
  | Provider_runtime_binding.Setup_token_env _ -> Setup_token
;;

let transport_for_call ~injected = if injected then Injected else Http

let of_provider_config ~transport config =
  let open Result_syntax in
  let provider, binding = provider_and_binding config in
  let auth_scheme, credential_scope =
    match binding with
    | Some binding -> auth_scheme_of_binding binding, binding.credential_scope
    | None -> (if Secret.is_empty config.PC.api_key then No_auth else Api_key), None
  in
  let+ model_id = Llm_provider.Model_id.of_string config.PC.model_id in
  { provider
  ; model_id
  ; transport
  ; endpoint = canonical_uri config.PC.base_url
  ; request_path = canonical_uri config.PC.request_path
  ; auth_scheme
  ; credential_scope
  ; credential_identity = Secret.identity config.PC.api_key
  }
;;

let equal_provider left right =
  match left, right with
  | Registered left, Registered right -> String.equal left right
  | Unregistered left, Unregistered right -> left = right
  | Registered _, Unregistered _ | Unregistered _, Registered _ -> false
;;

let equal_credential left right =
  match left, right with
  | None, None -> true
  | Some left, Some right -> Secret.equal_identity left right
  | None, Some _ | Some _, None -> false
;;

let equal left right =
  equal_provider left.provider right.provider
  && Llm_provider.Model_id.equal left.model_id right.model_id
  && left.transport = right.transport
  && Uri.equal left.endpoint right.endpoint
  && Uri.equal left.request_path right.request_path
  && left.auth_scheme = right.auth_scheme
  && Option.equal String.equal left.credential_scope right.credential_scope
  && equal_credential left.credential_identity right.credential_identity
;;

let hash_provider = function
  | Registered id -> Hashtbl.hash (0, id)
  | Unregistered kind -> Hashtbl.hash (1, PK.to_string kind)
;;

let hash_credential = function
  | None -> None
  | Some identity -> Some (Secret.hash_identity identity)
;;

let hash identity =
  Hashtbl.hash
    ( hash_provider identity.provider
    , Llm_provider.Model_id.hash identity.model_id
    , identity.transport
    , Uri.to_string identity.endpoint
    , Uri.to_string identity.request_path
    , identity.auth_scheme
    , identity.credential_scope
    , hash_credential identity.credential_identity )
;;

let has_credential_identity identity = Option.is_some identity.credential_identity

let transport_to_string = function
  | Http -> "http"
  | Injected -> "injected"
;;

let auth_scheme_to_string = function
  | No_auth -> "none"
  | Api_key -> "api_key"
  | Setup_token -> "setup_token"
  | Provider_defined -> "provider_defined"
;;

let redacted_uri uri =
  let redacted_query =
    match Uri.query uri with
    | [] -> []
    | _ -> [ "<redacted>", [ "<redacted>" ] ]
  in
  uri
  |> fun uri ->
  Uri.with_userinfo uri None
  |> fun uri ->
  Uri.with_query uri redacted_query
  |> fun uri -> Uri.with_fragment uri None |> Uri.to_string
;;

let provider_to_yojson = function
  | Registered id -> `Assoc [ "registration", `String "registered"; "id", `String id ]
  | Unregistered kind ->
    `Assoc [ "registration", `String "unregistered"; "kind", `String (PK.to_string kind) ]
;;

let option_string_to_yojson = function
  | Some value -> `String value
  | None -> `Null
;;

type redacted_snapshot =
  { provider : provider_identity
  ; model_id : Llm_provider.Model_id.t
  ; transport : transport
  ; endpoint : string
  ; request_path : string
  ; auth_scheme : auth_scheme
  ; credential_scope : string option
  ; credential_fingerprint : Secret.Identity_fingerprint.t option
  }

let redacted_snapshot (identity : t) =
  { provider = identity.provider
  ; model_id = identity.model_id
  ; transport = identity.transport
  ; endpoint = redacted_uri identity.endpoint
  ; request_path = redacted_uri identity.request_path
  ; auth_scheme = identity.auth_scheme
  ; credential_scope = identity.credential_scope
  ; credential_fingerprint =
      Option.map Secret.Identity_fingerprint.of_identity identity.credential_identity
  }
;;

module Redacted_snapshot = struct
  type t = redacted_snapshot

  let equal left right =
    equal_provider left.provider right.provider
    && Llm_provider.Model_id.equal left.model_id right.model_id
    && left.transport = right.transport
    && String.equal left.endpoint right.endpoint
    && String.equal left.request_path right.request_path
    && left.auth_scheme = right.auth_scheme
    && Option.equal String.equal left.credential_scope right.credential_scope
    && Option.equal
         Secret.Identity_fingerprint.equal
         left.credential_fingerprint
         right.credential_fingerprint
  ;;

  let credential_fingerprint_to_yojson = function
    | Some fingerprint -> `String (Secret.Identity_fingerprint.to_string fingerprint)
    | None -> `Null
  ;;

  let to_yojson snapshot =
    `Assoc
      [ "provider", provider_to_yojson snapshot.provider
      ; "model", `String (Llm_provider.Model_id.to_string snapshot.model_id)
      ; "transport", `String (transport_to_string snapshot.transport)
      ; "endpoint", `String snapshot.endpoint
      ; "request_path", `String snapshot.request_path
      ; "auth_scheme", `String (auth_scheme_to_string snapshot.auth_scheme)
      ; "credential_scope", option_string_to_yojson snapshot.credential_scope
      ; ( "credential_fingerprint"
        , credential_fingerprint_to_yojson snapshot.credential_fingerprint )
      ]
  ;;

  let pp formatter snapshot =
    Format.pp_print_string formatter (Yojson.Safe.to_string (to_yojson snapshot))
  ;;

  let exact_non_empty_text ~field value =
    let trimmed = String.trim value in
    if String.equal trimmed ""
    then Error (field ^ " must contain non-whitespace text")
    else if not (String.equal value trimmed)
    then Error (field ^ " must not have surrounding whitespace")
    else Ok value
  ;;

  let provider_of_yojson json =
    let open Result_syntax in
    let* fields =
      Execution_json.object_fields
        ~context:"binding redacted snapshot provider"
        ~required:[ "registration" ]
        ~optional:[ "id"; "kind" ]
        json
    in
    let* registration = Execution_json.string_field "registration" fields in
    match registration with
    | "registered" ->
      let* fields =
        Execution_json.object_fields
          ~context:"registered binding redacted snapshot provider"
          ~required:[ "registration"; "id" ]
          ~optional:[]
          json
      in
      let* id = Execution_json.string_field "id" fields in
      let+ id = exact_non_empty_text ~field:"provider id" id in
      Registered id
    | "unregistered" ->
      let* fields =
        Execution_json.object_fields
          ~context:"unregistered binding redacted snapshot provider"
          ~required:[ "registration"; "kind" ]
          ~optional:[]
          json
      in
      let* kind = Execution_json.string_field "kind" fields in
      (match PK.of_canonical_string kind with
       | Some kind -> Ok (Unregistered kind)
       | None -> Error ("unknown canonical provider kind: " ^ kind))
    | value -> Error ("unknown provider registration: " ^ value)
  ;;

  let transport_of_string = function
    | "http" -> Ok Http
    | "injected" -> Ok Injected
    | value -> Error ("unknown binding transport: " ^ value)
  ;;

  let auth_scheme_of_string = function
    | "none" -> Ok No_auth
    | "api_key" -> Ok Api_key
    | "setup_token" -> Ok Setup_token
    | "provider_defined" -> Ok Provider_defined
    | value -> Error ("unknown binding auth_scheme: " ^ value)
  ;;

  let exact_redacted_uri ~field value =
    let canonical = value |> canonical_uri |> redacted_uri in
    if String.equal value canonical
    then Ok value
    else Error (field ^ " must be a canonical redacted URI")
  ;;

  let credential_fingerprint_of_option = function
    | None -> Ok None
    | Some fingerprint ->
      Result.map
        (fun fingerprint -> Some fingerprint)
        (Secret.Identity_fingerprint.of_string fingerprint)
  ;;

  let of_yojson json =
    let open Result_syntax in
    let* fields =
      Execution_json.object_fields
        ~context:"binding redacted snapshot"
        ~required:
          [ "provider"
          ; "model"
          ; "transport"
          ; "endpoint"
          ; "request_path"
          ; "auth_scheme"
          ; "credential_scope"
          ; "credential_fingerprint"
          ]
        ~optional:[]
        json
    in
    let* provider_json = Execution_json.field "provider" fields in
    let* provider = provider_of_yojson provider_json in
    let* model = Execution_json.string_field "model" fields in
    let* model_id = Llm_provider.Model_id.of_string model in
    let* transport_text = Execution_json.string_field "transport" fields in
    let* transport = transport_of_string transport_text in
    let* endpoint = Execution_json.string_field "endpoint" fields in
    let* endpoint = exact_redacted_uri ~field:"endpoint" endpoint in
    let* request_path = Execution_json.string_field "request_path" fields in
    let* request_path = exact_redacted_uri ~field:"request_path" request_path in
    let* auth_scheme_text = Execution_json.string_field "auth_scheme" fields in
    let* auth_scheme = auth_scheme_of_string auth_scheme_text in
    let* credential_scope =
      Execution_json.option_string_field "credential_scope" fields
    in
    let* credential_fingerprint =
      Execution_json.option_string_field "credential_fingerprint" fields
    in
    let+ credential_fingerprint =
      credential_fingerprint_of_option credential_fingerprint
    in
    { provider
    ; model_id
    ; transport
    ; endpoint
    ; request_path
    ; auth_scheme
    ; credential_scope
    ; credential_fingerprint
    }
  ;;
end

let to_redacted_yojson identity =
  identity |> redacted_snapshot |> Redacted_snapshot.to_yojson
;;
