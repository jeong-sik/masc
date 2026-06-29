type exec_result = {
  stdout : string;
  stderr : string;
  exit_code : int;
}

type error = Unsupported_backend of string

let unsupported_message =
  "masc.exec_policy Sandbox_backend.run is disabled; use \
   Masc.Keeper_sandbox_runner/Keeper_sandbox_docker"

let error_message = function
  | Unsupported_backend message -> message

let run (_ : Typed_capabilities.safe Typed_capabilities.verified_ir)
    (_env : Eio_unix.Stdenv.base) : (exec_result, error) result =
  Error (Unsupported_backend unsupported_message)
