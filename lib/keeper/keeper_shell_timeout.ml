let env_float name default =
  match Sys.getenv_opt name with
  | Some s -> (match float_of_string_opt s with Some f -> f | None -> default)
  | None -> default

let io_timeout_sec = env_float "MASC_KEEPER_IO_TIMEOUT_SEC" 30.0
let read_timeout_sec = env_float "MASC_KEEPER_READ_TIMEOUT_SEC" 15.0
let user_timeout_max_sec = env_float "MASC_KEEPER_USER_TIMEOUT_MAX_SEC" 180.0

(* Floor for gh op timeout_sec. GitHub API + gh auth handshake is
   usually 3-10s; previous floors (1s, then 5s) produced 41
   gh_command_timed_out rejections in 2 days, every single one at
   timeout_sec=5 (#8688). [Timeout_floor.Tool_dispatch] keeps keepers
   from requesting a sub-network-latency timeout without masking
   genuine hangs. *)
let gh_min_timeout_sec =
  Timeout_floor.default_sec Timeout_floor.Tool_dispatch
;;

(* Public shell metadata timeout used by git-status helpers. *)
let git_meta_timeout_sec = env_float "MASC_KEEPER_GIT_META_TIMEOUT_SEC" 5.0

(* Floor applied to caller-supplied [timeout_sec] for keeper_bash when
   the command runs through the *native* (non-Docker) executor. *)
let keeper_bash_native_min_timeout_sec =
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

let typed_stage_needs_tool_dispatch_floor fields =
  match string_field "executable" fields with
  | None -> false
  | Some executable ->
    let argv = string_list_field "argv" fields in
    String.equal executable "git"
    || String.equal executable "rg"
    || String.equal executable "find"
    || executable_is_dune_local executable
    || (String.equal executable "grep" && List.exists arg_has_recursive_flag argv)
;;

let rec keeper_bash_args_need_tool_dispatch_floor = function
  | `Assoc fields ->
    typed_stage_needs_tool_dispatch_floor fields
    ||
    (match List.assoc_opt "pipeline" fields, List.assoc_opt "stages" fields with
     | Some (`List stages), _
     | _, Some (`List stages) ->
       List.exists keeper_bash_args_need_tool_dispatch_floor stages
     | _other -> false)
  | _other -> false
;;

let keeper_bash_min_timeout_sec_for_args args =
  if keeper_bash_args_need_tool_dispatch_floor args
  then Timeout_floor.default_sec Timeout_floor.Tool_dispatch
  else keeper_bash_native_min_timeout_sec
;;

let clamp_shell_timeout
      ?(min_sec = Timeout_floor.default_sec Timeout_floor.Native_shell)
      ~default
      args
  =
  Safe_ops.json_float ~default "timeout_sec" args
  |> fun n -> max min_sec (min user_timeout_max_sec n)
