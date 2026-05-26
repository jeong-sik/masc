let env_float name default =
  match Sys.getenv_opt name with
  | Some s -> (match float_of_string_opt s with Some f -> f | None -> default)
  | None -> default

let io_timeout_sec = env_float "MASC_KEEPER_IO_TIMEOUT_SEC" 30.0
let read_timeout_sec = env_float "MASC_KEEPER_READ_TIMEOUT_SEC" 15.0
let user_timeout_max_sec = env_float "MASC_KEEPER_USER_TIMEOUT_MAX_SEC" 180.0

let tool_dispatch_min_timeout_sec =
  Timeout_floor.default_sec Timeout_floor.Tool_dispatch
;;

let git_meta_timeout_sec = env_float "MASC_KEEPER_GIT_META_TIMEOUT_SEC" 5.0

let keeper_shell_ir_native_min_timeout_sec =
  Timeout_floor.default_sec Timeout_floor.Native_shell
;;

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _other -> None
;;

let string_list_field name fields =
  match List.assoc_opt name fields with
  | Some (`List values) ->
    List.filter_map
      (function
        | `String value -> Some value
        | _other -> None)
      values
  | _other -> []
;;

let arg_has_recursive_flag arg =
  String.length arg >= 2
  && arg.[0] = '-'
  && (String.contains arg 'r' || String.contains arg 'R')
;;

let executable_is_dune_local executable =
  String.equal executable "dune-local.sh"
  || String.equal executable "scripts/dune-local.sh"
  || String.ends_with ~suffix:"/scripts/dune-local.sh" executable
;;

(* TEL-OK: pure timeout classification; caller records keeper shell execution
   telemetry after the selected timeout is applied. *)
let typed_stage_needs_tool_dispatch_floor fields =
  match string_field "executable" fields with
  | None -> false
  | Some executable ->
    String.equal executable "git"
    || String.equal executable "rg"
    || String.equal executable "find"
    || executable_is_dune_local executable
;;

(* TEL-OK: pure recursive timeout classifier used before execution. *)
let rec keeper_shell_ir_args_need_tool_dispatch_floor = function
  | `Assoc fields ->
    typed_stage_needs_tool_dispatch_floor fields
    ||
    (match List.assoc_opt "pipeline" fields with
     | Some (`List stages) ->
       List.exists keeper_shell_ir_args_need_tool_dispatch_floor stages
     | _other -> false)
  | _other -> false
;;

let keeper_shell_ir_min_timeout_sec_for_args args =
  if keeper_shell_ir_args_need_tool_dispatch_floor args
  then tool_dispatch_min_timeout_sec
  else keeper_shell_ir_native_min_timeout_sec
;;

let clamp_shell_timeout
      ?(min_sec = Timeout_floor.default_sec Timeout_floor.Native_shell)
      ~default
      args
  =
  Safe_ops.json_float ~default "timeout_sec" args
  |> fun n -> max min_sec (min user_timeout_max_sec n)
