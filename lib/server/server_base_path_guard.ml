(** Shared startup guard for server runtime base paths. *)

type canonicalization_error =
  { base_path : string
  ; cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

let startup_root ~cli_base_path = Workspace_root.resolve_current ~flag:cli_base_path

let exit_on_no_workspace = function
  | Ok root -> root
  | Error error ->
    Printf.eprintf "[FATAL] Server refused to start without a workspace.\n%s\n"
      (Workspace_root.error_message error);
    exit 1

let canonicalize_existing base_path =
  match Unix.realpath base_path with
  | canonical -> Ok canonical
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception ((Unix.Unix_error _ | Sys_error _) as cause) ->
    Error
      { base_path
      ; cause
      ; backtrace = Printexc.get_raw_backtrace ()
      }
;;

let format_canonicalization_error { base_path; cause; backtrace = _ } =
  Printf.sprintf
    "[FATAL] Could not establish canonical BasePath identity for %S: %s"
    base_path
    (Printexc.to_string cause)
;;
