let shell_ir_path_jail_env_key = "MASC_SHELL_IR_PATH_JAIL_ENABLED"
let shell_ir_path_jail_reported = Atomic.make false

let shell_ir_path_jail_env_configured ?(getenv = Sys.getenv_opt) () =
  match Option.bind (getenv shell_ir_path_jail_env_key) String_util.trim_to_option with
  | None -> false
  | Some _ -> true

let report_shell_ir_path_jail_if_set ?(source = "runtime") () =
  if
    shell_ir_path_jail_env_configured ()
    && not (Atomic.exchange shell_ir_path_jail_reported true)
  then (
    Log.Keeper.warn
      "retired env knob ignored env=%s; Shell IR path jail is permanent and \
       cannot be disabled at runtime"
      shell_ir_path_jail_env_key;
    Otel_metric_store.inc_counter
      (Keeper_metrics.to_string Keeper_metrics.ShellIrEffectTotal)
      ~labels:[ "kind", "retired_path_jail_env_ignored"; "source", source ]
      ())

module For_testing = struct
  let shell_ir_path_jail_env_configured = shell_ir_path_jail_env_configured
end
