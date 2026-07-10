let shell_ir_path_jail_env_key = "MASC_SHELL_IR_PATH_JAIL_ENABLED"
let memory_os_librarian_global_slot_env_key =
  "MASC_KEEPER_MEMORY_OS_LIBRARIAN_GLOBAL_SLOT"
;;

let shell_ir_path_jail_reported = Atomic.make false
let memory_os_librarian_global_slot_reported = Atomic.make false

let env_configured ?(getenv = Sys.getenv_opt) env_key =
  match Option.bind (getenv env_key) String_util.trim_to_option with
  | None -> false
  | Some _ -> true
;;

let report_if_set ~reported ~env_key ~reason ?(source = "runtime") () =
  if env_configured env_key && not (Atomic.exchange reported true)
  then (
    Log.Keeper.warn "retired env knob ignored env=%s; %s" env_key reason;
    Otel_metric_store.inc_counter
      (Keeper_metrics.to_string Keeper_metrics.RetiredEnvIgnored)
      ~labels:[ "env", env_key; "source", source ]
      ())
;;

let shell_ir_path_jail_env_configured ?getenv () =
  env_configured ?getenv shell_ir_path_jail_env_key
;;

let memory_os_librarian_global_slot_env_configured ?getenv () =
  env_configured ?getenv memory_os_librarian_global_slot_env_key
;;

let report_shell_ir_path_jail_if_set ?(source = "runtime") () =
  report_if_set
    ~reported:shell_ir_path_jail_reported
    ~env_key:shell_ir_path_jail_env_key
    ~reason:"Shell IR path jail is permanent and cannot be disabled at runtime"
    ~source
    ()
;;

let report_memory_os_librarian_global_slot_if_set ?(source = "runtime") () =
  report_if_set
    ~reported:memory_os_librarian_global_slot_reported
    ~env_key:memory_os_librarian_global_slot_env_key
    ~reason:
      "librarian calls are serialized by each Keeper's memory lane; provider capacity and fallback belong to the OAS provider/runtime boundary"
    ~source
    ()
;;

module For_testing = struct
  let shell_ir_path_jail_env_key = shell_ir_path_jail_env_key
  let memory_os_librarian_global_slot_env_key =
    memory_os_librarian_global_slot_env_key
  ;;

  let shell_ir_path_jail_env_configured = shell_ir_path_jail_env_configured
  let memory_os_librarian_global_slot_env_configured =
    memory_os_librarian_global_slot_env_configured
  ;;
end
