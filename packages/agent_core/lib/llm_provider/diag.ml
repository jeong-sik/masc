type level =
  | Debug
  | Info
  | Warn
  | Error

let level_to_string = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"
;;

let debug_env_var = "AGENT_CORE_LLM_PROVIDER_DEBUG"
let cascade_diag_env_var = "AGENT_CORE_CASCADE_DIAG"

let debug_enabled () =
  Env_parse.bool_env debug_env_var || Env_parse.bool_env cascade_diag_env_var
;;

let default_sink (lvl : level) ~ctx msg =
  match lvl with
  | Debug when not (debug_enabled ()) -> ()
  | _ ->
    Printf.eprintf
      "[llm_provider] [%s] [%s] %s\n%!"
      (level_to_string lvl)
      ctx
      (Secret_redactor.redact_string msg)
;;

let _sink : (level -> ctx:string -> string -> unit) Atomic.t = Atomic.make default_sink
let set_sink s = Atomic.set _sink s

let with_sink sink f =
  let previous = Atomic.get _sink in
  Atomic.set _sink sink;
  Fun.protect ~finally:(fun () -> Atomic.set _sink previous) f
;;

let emit lvl ctx fmt = Printf.ksprintf (fun msg -> (Atomic.get _sink) lvl ~ctx msg) fmt
let debug ctx fmt = emit Debug ctx fmt
let info ctx fmt = emit Info ctx fmt
let warn ctx fmt = emit Warn ctx fmt
let error ctx fmt = emit Error ctx fmt

let%test "debug_enabled reads AGENT_CORE_LLM_PROVIDER_DEBUG at call time" =
  Env_parse.with_env cascade_diag_env_var "" (fun () ->
    Env_parse.with_env debug_env_var "" (fun () ->
      (not (debug_enabled ()))
      &&
      (Unix.putenv debug_env_var "1";
       debug_enabled ())))
;;

let%test "debug_enabled reads AGENT_CORE_CASCADE_DIAG alias at call time" =
  Env_parse.with_env debug_env_var "" (fun () ->
    Env_parse.with_env cascade_diag_env_var "" (fun () ->
      (not (debug_enabled ()))
      &&
      (Unix.putenv cascade_diag_env_var "true";
       debug_enabled ())))
;;

let%test "debug_enabled rejects invalid values and accepts normalized values" =
  Env_parse.with_env debug_env_var "maybe" (fun () ->
    Env_parse.with_env cascade_diag_env_var "  On " (fun () -> debug_enabled ()))
;;

let%test "debug_enabled sees combined false values as disabled" =
  Env_parse.with_env debug_env_var "0" (fun () ->
    Env_parse.with_env cascade_diag_env_var "off" (fun () -> not (debug_enabled ())))
;;

let%test "Env_parse.with_env restores original truthy value" =
  Env_parse.with_env cascade_diag_env_var "" (fun () ->
    Env_parse.with_env debug_env_var "yes" (fun () ->
      Env_parse.with_env debug_env_var "0" (fun () -> not (debug_enabled ()))
      && debug_enabled ()))
;;
