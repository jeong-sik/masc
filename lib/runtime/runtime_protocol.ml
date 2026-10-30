(** Shared protocol declarations for parsing and the structured runtime editor. *)

type editor_transport =
  | Endpoint
  | Command

type editor_semantics =
  | Http_provider
  | Official_client

type editor_credential_policy =
  | Credentials_optional
  | Credentials_forbidden
  | Credentials_file_required

type editor_protocol =
  { protocol : string
  ; transport : editor_transport
  ; semantics : editor_semantics
  ; credential_policy : editor_credential_policy
  ; requires_non_interactive : bool
  ; provider_fields : string list
  ; required_provider_fields : string list
  }

type protocol_declaration =
  { protocol : string
  ; api_format : Runtime_schema.api_format
  ; editor : editor_protocol option
  }

let http_editor protocol =
  Some
    { protocol
    ; transport = Endpoint
    ; semantics = Http_provider
    ; credential_policy = Credentials_optional
    ; requires_non_interactive = false
    ; provider_fields = []
    ; required_provider_fields = []
    }
;;

let official_client_editor protocol =
  Some
    { protocol
    ; transport = Command
    ; semantics = Official_client
    ; credential_policy = Credentials_forbidden
    ; requires_non_interactive = true
    ; provider_fields = [ "account-home" ]
    ; required_provider_fields = []
    }
;;

let muse_serve_protocol = "muse-serve"
let muse_serve_editor =
  Option.map (fun (editor : editor_protocol) ->
    { editor with required_provider_fields = ["account-home"] })
    (official_client_editor muse_serve_protocol)

let antigravity_editor =
  Some
    { protocol = "antigravity-cli"
    ; transport = Command
    ; semantics = Official_client
    ; credential_policy = Credentials_file_required
    ; requires_non_interactive = true
    ; provider_fields = [ "agent"; "effort"; "timeout-s" ]
    ; required_provider_fields = [ "timeout-s" ]
    }
;;

let hidden_protocol protocol api_format =
  { protocol; api_format; editor = None }
;;

let http_protocol protocol api_format =
  { protocol; api_format; editor = http_editor protocol }
;;

let official_client_protocol protocol api_format =
  { protocol; api_format; editor = official_client_editor protocol }
;;

let protocol_declarations =
  [ hidden_protocol "messages-cli" Runtime_schema.Messages_api
  ; http_protocol "messages-http" Runtime_schema.Messages_api
  ; hidden_protocol "openai-compatible-cli" Runtime_schema.Chat_completions_api
  ; http_protocol
      "openai-compatible-http"
      Runtime_schema.Chat_completions_api
  ; http_protocol "ollama-http" Runtime_schema.Ollama_api
  ; http_protocol "gemini-http" Runtime_schema.Gemini_api
  ; http_protocol "vertex-gemini" Runtime_schema.Vertex_gemini_api
  ; official_client_protocol
      "codex-app-server"
      Runtime_schema.Codex_app_server_runtime
  ; official_client_protocol "claude-code" Runtime_schema.Claude_code_runtime
  ; { protocol = "antigravity-cli"
    ; api_format = Runtime_schema.Antigravity_cli_runtime
    ; editor = antigravity_editor
    }
  ; { protocol = muse_serve_protocol
    ; api_format = Runtime_schema.Muse_serve_runtime
    ; editor = muse_serve_editor
    }
  ]
;;

let protocol_declaration protocol =
  List.find_opt
    (fun declaration -> String.equal declaration.protocol protocol)
    protocol_declarations
;;

let editor_protocols = List.filter_map (fun declaration -> declaration.editor) protocol_declarations

let unknown_protocol_error s =
  Printf.sprintf
    "unknown protocol %S: expected one of %s"
    s
    (String.concat ", " (List.map (fun declaration -> declaration.protocol) protocol_declarations))
;;

let resolve protocol =
  match protocol_declaration protocol with
  | Some declaration -> Ok (declaration.protocol, declaration.api_format)
  | None -> Error (unknown_protocol_error protocol)
;;

let api_format_of_protocol protocol = Result.map snd (resolve protocol)
;;
