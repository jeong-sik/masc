open Masc_mcp

let usage =
  {|Usage: masc-keeper-feature-proof [OPTIONS]

Options:
  --base-path PATH        Runtime workspace root (default: MASC_BASE_PATH)
  --n N                  Tool-quality recent sample size (default: 5000)
  --window-hours HOURS   Use a time-window sample instead of recent N
  --threshold PCT        Required tool success threshold (default: 80.0)
  --strict               Exit 2 when any feature is warn/fail
  -h, --help             Print this help
|}

type config = {
  base_path : string option;
  n : int;
  window_hours : float option;
  threshold : float;
  strict : bool;
}

let error msg =
  prerr_endline msg;
  prerr_endline usage;
  exit 1

let env_base_path () =
  match Sys.getenv_opt "MASC_BASE_PATH" with
  | Some path when String.trim path <> "" -> Some (String.trim path)
  | _ -> None

let initial_config () =
  {
    base_path = env_base_path ();
    n = 5000;
    window_hours = None;
    threshold = 80.0;
    strict = false;
  }

let parse_int_arg name value =
  match int_of_string_opt value with
  | Some n when n > 0 -> n
  | _ -> error (Printf.sprintf "invalid %s: %S" name value)

let parse_float_arg name value =
  match float_of_string_opt value with
  | Some n when n > 0.0 -> n
  | _ -> error (Printf.sprintf "invalid %s: %S" name value)

let rec parse_args argv index cfg =
  if index >= Array.length argv then cfg
  else
    match argv.(index) with
    | "-h" | "--help" ->
        print_endline usage;
        exit 0
    | "--strict" -> parse_args argv (index + 1) { cfg with strict = true }
    | "--base-path" when index + 1 < Array.length argv ->
        parse_args argv (index + 2)
          { cfg with base_path = Some argv.(index + 1) }
    | "--n" when index + 1 < Array.length argv ->
        parse_args argv (index + 2)
          { cfg with n = parse_int_arg "--n" argv.(index + 1) }
    | "--window-hours" when index + 1 < Array.length argv ->
        parse_args argv (index + 2)
          {
            cfg with
            window_hours =
              Some (parse_float_arg "--window-hours" argv.(index + 1));
          }
    | "--threshold" when index + 1 < Array.length argv ->
        parse_args argv (index + 2)
          { cfg with threshold = parse_float_arg "--threshold" argv.(index + 1) }
    | arg -> error (Printf.sprintf "unknown or incomplete argument: %S" arg)

let resolve_base_path cfg =
  match cfg.base_path with
  | Some path when String.trim path <> "" -> String.trim path
  | _ -> error "--base-path is required when MASC_BASE_PATH is unset"

let status json =
  Yojson.Safe.Util.member "status" json
  |> Yojson.Safe.Util.to_string_option
  |> Option.value ~default:"fail"

let main () =
  let cfg = parse_args Sys.argv 1 (initial_config ()) in
  let base_path = resolve_base_path cfg in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Keeper_tool_call_log.init ~base_path ();
  let coord_config = Coord.default_config base_path in
  let json =
    Dashboard_keeper_feature_proof.json
      ~config:coord_config
      ~n:cfg.n
      ?window_hours:cfg.window_hours
      ~success_threshold_pct:cfg.threshold
      ()
  in
  print_endline (Yojson.Safe.pretty_to_string json);
  if cfg.strict && not (String.equal (status json) "pass") then exit 2

let () = main ()
