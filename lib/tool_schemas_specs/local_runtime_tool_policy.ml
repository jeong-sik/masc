open Masc_domain

type operation =
  | Verify
  | Ollama_probe

type model_exposure =
  | Keeper_callable
  | Operator_diagnostic

type t =
  { required_permission : permission
  ; read_only : bool
  ; idempotent : bool
  }

let operation_id = function
  | Verify -> "verify"
  | Ollama_probe -> "ollama_probe"
;;

let model_exposure = function
  | Verify -> Operator_diagnostic
  | Ollama_probe -> Operator_diagnostic
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
;;
