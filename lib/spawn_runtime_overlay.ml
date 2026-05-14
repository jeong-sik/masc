(** Spawn runtime overlay. *)

type binding =
  { canonical_name : string
  ; spawn_key : string
  ; aliases : string list
  }

let normalize_label label = String.trim label |> String.lowercase_ascii

let bindings =
  [ { canonical_name = "llama"
    ; spawn_key = "llama"
    ; aliases = [ "llama"; "llama.cpp"; "llamacpp" ]
    }
  ; { canonical_name = "claude"
    ; spawn_key = "claude"
    ; aliases = [ "claude"; "claude-code"; "claude_code" ]
    }
  ; { canonical_name = "codex"
    ; spawn_key = "codex"
    ; aliases = [ "codex"; "codex-cli"; "codex_cli" ]
    }
  ; { canonical_name = "gemini"
    ; spawn_key = "gemini"
    ; aliases = [ "gemini"; "gemini-cli"; "gemini_cli" ]
    }
  ]
;;

let resolve_binding label =
  let normalized = normalize_label label in
  List.find_opt
    (fun binding ->
       List.exists
         (fun alias -> String.equal (normalize_label alias) normalized)
         binding.aliases)
    bindings
;;

let resolve_spawn_key label = Option.map (fun binding -> binding.spawn_key) (resolve_binding label)
let is_spawnable_agent name = resolve_spawn_key name <> None
let spawnable_canonical_names () = List.map (fun binding -> binding.canonical_name) bindings
let make_local_label model_id = "llama:" ^ model_id

let nonempty_env name =
  match Sys.getenv_opt name with
  | Some raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | None -> None
;;

let explicit_llama_model_id_result () =
  match nonempty_env "LLAMA_DEFAULT_MODEL" with
  | Some model_id -> Ok model_id
  | None ->
    (match nonempty_env "MASC_DEFAULT_PROVIDER", nonempty_env "MASC_DEFAULT_MODEL" with
     | Some provider, Some model_id
       when String.equal (String.lowercase_ascii provider) "llama" -> Ok model_id
     | _ ->
       Error
         "LLAMA_DEFAULT_MODEL is not set; configure LLAMA_DEFAULT_MODEL or \
          MASC_DEFAULT_PROVIDER=llama with MASC_DEFAULT_MODEL")
;;

let add_default_model_arg ~agent_name argv =
  match resolve_binding agent_name with
  | Some { canonical_name = "llama"; _ } ->
    (match explicit_llama_model_id_result () with
     | Ok model_id -> argv @ [ model_id ]
     | Error _ -> argv)
  | Some _ | None -> argv
;;

let bare_ollama_migration_message () =
  "Bare `ollama` without a model requires OLLAMA_DEFAULT_MODEL env var. Use \
   `ollama:<model>` for explicit selection."
;;

let is_bare_ollama_label label =
  String.equal (normalize_label label) "ollama"
  && Env_config_runtime.Ollama.default_model = ""
;;
