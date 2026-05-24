type result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  ; error : string option
  }

let quote_argv argv = String.concat " " (List.map Filename.quote argv)

let run_argv
      ~(config : Coord.config)
      ~(meta : Keeper_types.keeper_meta)
      ~timeout_sec
      ~actor
      ~summary
      ~env
      ~host_cwd
      ~route_cwd
      ~backend_cwd
      ~trust
      argv
  =
  let command_text = quote_argv argv in
  let routed =
    Keeper_sandbox_runner.run_command_with_status
      ~config
      ~meta
      ~timeout_sec
      ~host:
        { actor
        ; raw_source = command_text
        ; summary
        ; env
        ; cwd = Some host_cwd
        ; argv
        }
      ~backend:
        { route_cwd
        ; cwd = backend_cwd
        ; command_text
        ; git_creds_enabled = true
        ; network_mode = Network_inherit
        ; trust
        }
  in
  { status = routed.status
  ; output = routed.output
  ; via = routed.via
  ; error = routed.backend_error
  }
;;
