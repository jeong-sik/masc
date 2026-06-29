type exec_result = {
  stdout : string;
  stderr : string;
  exit_code : int;
}

type error = Unsupported_backend of string

val error_message : error -> string

val run :
  Typed_capabilities.safe Typed_capabilities.verified_ir ->
  Eio_unix.Stdenv.base ->
  (exec_result, error) result
