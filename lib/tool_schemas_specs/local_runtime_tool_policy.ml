open Masc_domain

type operation =
  | Verify
  | Ollama_probe
  | Systemone_decide

type t =
  { required_permission : permission
  ; read_only : bool
  ; idempotent : bool
  }

let operation_id = function
  | Verify -> "verify"
  | Ollama_probe -> "ollama_probe"
  | Systemone_decide -> "systemone_decide"
;;

let execution_policy = function
  | Verify ->
    (* The contract check issues one real chat-completion per selected
       discovery endpoint. That can load a model and changes warm/cache state. *)
    { required_permission = CanAdmin
    ; read_only = false
    ; idempotent = false
    }
  | Ollama_probe ->
    (* [/api/generate] can load a model and changes warm/cache state. *)
    { required_permission = CanAdmin
    ; read_only = false
    ; idempotent = false
    }
  | Systemone_decide ->
    (* [/v1/systemone] answers typed questions without changing any server
       state, so any agent that can speak on the workspace may ask one. The
       cloud backend still spends Ollama usage credits per input token, which
       is why this is not read_only: approval staging sees the call. *)
    { required_permission = CanBroadcast
    ; read_only = false
    ; idempotent = true
    }
;;
