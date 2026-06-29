type exec_result = {
  stdout : string;
  stderr : string;
  exit_code : int;
}

let unsupported_stderr =
  "masc.exec_policy Sandbox_backend.run is not a production sandbox executor; use \
   Masc.Keeper_sandbox_runner/Keeper_sandbox_docker"
;;

let run (_ : Typed_capabilities.safe Typed_capabilities.verified_ir)
    (_env : Eio_unix.Stdenv.base) : exec_result =
  { stdout = ""; stderr = unsupported_stderr; exit_code = 126 }
