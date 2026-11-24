open Masc_tui_core

let default_scheme = "http"
let default_host = "127.0.0.1"
let default_port = 8935

type config = {
  scheme : string;
  host : string;
  port : int;
  base_path : string;
  workspace : string;
  theme : Theme.preset;
  lang : Say.lang;
  theme_explicit : bool;
  lang_explicit : bool;
  auto_start : bool;
}

type info_action =
  | Print_version of string
  | Print_build_commit of string option
  | Print_help of string

type parse_outcome =
  | Run of config
  | Info of info_action
  | Parse_error of string

let help_text =
  String.concat "\n"
    [
      "Usage: masc-tui [OPTIONS]";
      "";
      "MASC interactive terminal UI.";
      "";
      "Options:";
      "  --port <int>                  MASC server port (1..65535; default: 8935)";
      "  --host <host>                 MASC server host (default: 127.0.0.1)";
      "  --url <http://host[:port]>    Full server base URL (http or https)";
      "  --base-path <path>            Workspace base path (.masc lives below it)";
      "  --base <path>                 Alias for --base-path";
      "  --workspace <name>            Workspace display name (default: basename of base path)";
      "  --theme <midnight|arcade|paper|mono>";
      "                                Color theme preset (default: midnight)";
      "  --lang <ko|en>                UI language (default: ko)";
      "  --no-auto-start               Do not auto-start a local masc server when offline";
      "  --version                     Print build version (and short commit SHA) and exit";
      "  --build-commit                Print embedded Git commit SHA and exit";
      "  -h, --help                    Display this help message and exit";
    ]

let parse_theme raw =
  match String.lowercase_ascii (String.trim raw) with
  | "arcade" -> Some Theme.Arcade_hi
  | "paper" -> Some Theme.Paper_light
  | other -> Theme.preset_of_name other

let parse_lang raw = Say.lang_of_code raw

let parse_port raw =
  let trimmed = String.trim raw in
  match int_of_string_opt trimmed with
  | Some port when port >= 1 && port <= 65535 -> Ok port
  | Some _ | None ->
      Error
        (Printf.sprintf "invalid --port %S: expected integer in 1..65535" raw)

let has_whitespace_or_ctl s =
  let len = String.length s in
  let rec loop i =
    if i = len then false
    else
      let code = Char.code s.[i] in
      if code <= 0x20 || code = 0x7F then true else loop (i + 1)
  in
  loop 0

let strip_trailing_slashes s =
  let rec loop n =
    if n > 0 && Char.equal s.[n - 1] '/' then loop (n - 1) else n
  in
  String.sub s 0 (loop (String.length s))

let parse_host_port authority =
  let len = String.length authority in
  if len = 0 then Error "URL host must not be empty"
  else if Char.equal authority.[0] '[' then
    match String.index_opt authority ']' with
    | None -> Error "unterminated IPv6 host in --url"
    | Some close_idx ->
        let host = String.sub authority 0 (close_idx + 1) in
        if close_idx + 1 = len then Ok (host, None)
        else if Char.equal authority.[close_idx + 1] ':' then
          let port_str =
            String.sub authority (close_idx + 2) (len - close_idx - 2)
          in
          match parse_port port_str with
          | Ok p -> Ok (host, Some p)
          | Error _ ->
              Error
                (Printf.sprintf "invalid port %S in --url: expected 1..65535"
                   port_str)
        else Error "unexpected characters after IPv6 host in --url"
  else
    match String.rindex_opt authority ':' with
    | None -> Ok (authority, None)
    | Some colon_idx ->
        let host = String.sub authority 0 colon_idx in
        let port_str =
          String.sub authority (colon_idx + 1) (len - colon_idx - 1)
        in
        if String.equal host "" then Error "URL host must not be empty"
        else
          match parse_port port_str with
          | Ok p -> Ok (host, Some p)
          | Error _ ->
              Error
                (Printf.sprintf "invalid port %S in --url: expected 1..65535"
                   port_str)

let parse_url raw =
  let trimmed = strip_trailing_slashes (String.trim raw) in
  if String.equal trimmed "" || has_whitespace_or_ctl trimmed then
    Error (Printf.sprintf "invalid --url %S" raw)
  else
    let scheme_and_rest =
      if String.starts_with ~prefix:"http://" trimmed then
        Ok ("http", String.sub trimmed 7 (String.length trimmed - 7))
      else if String.starts_with ~prefix:"https://" trimmed then
        Ok ("https", String.sub trimmed 8 (String.length trimmed - 8))
      else
        Error
          (Printf.sprintf "invalid --url %S: scheme must be http:// or https://"
             raw)
    in
    match scheme_and_rest with
    | Error _ as err -> err
    | Ok (scheme, authority) -> (
        if String.contains authority '/' || String.contains authority '?' then
          Error
            (Printf.sprintf
               "invalid --url %S: path or query is not allowed in server base URL"
               raw)
        else
          match parse_host_port authority with
          | Ok (host, port_opt) -> Ok (scheme, host, port_opt)
          | Error _ as err -> err)

let expand_tilde ~env path =
  let len = String.length path in
  if len = 0 || not (Char.equal path.[0] '~') then path
  else if len = 1 then
    match env "HOME" with Some h when not (String.equal h "") -> h | Some _ | None -> path
  else if Char.equal path.[1] '/' then
    match env "HOME" with
    | Some h when not (String.equal h "") ->
        Filename.concat h (String.sub path 2 (len - 2))
    | Some _ | None -> path
  else path

let nonblank_opt = function
  | None -> None
  | Some s ->
      let t = String.trim s in
      if String.equal t "" then None else Some t

let split_long_opt arg =
  if String.starts_with ~prefix:"--" arg then
    match String.index_opt arg '=' with
    | Some idx ->
        ( String.sub arg 0 idx
        , Some (String.sub arg (idx + 1) (String.length arg - idx - 1)) )
    | None -> (arg, None)
  else (arg, None)

type draft = {
  scheme : string option;
  host : string option;
  url_port : int option;
  explicit_port : int option;
  base_path : string option;
  workspace : string option;
  theme : Theme.preset option;
  lang : Say.lang option;
  auto_start : bool;
}

let empty_draft =
  {
    scheme = None;
    host = None;
    url_port = None;
    explicit_port = None;
    base_path = None;
    workspace = None;
    theme = None;
    lang = None;
    auto_start = true;
  }

let take_value flag inline_opt rest =
  match inline_opt with
  | Some v -> Ok (v, rest)
  | None -> (
      match rest with
      | v :: tail -> Ok (v, tail)
      | [] -> Error (Printf.sprintf "option %s requires a value" flag))

let default_cwd () =
  match Sys.getcwd () with
  | d -> d
  | exception Sys_error _ -> "."

let short_commit_opt = function
  | None -> None
  | Some sha ->
      let trimmed = String.trim sha in
      let len = String.length trimmed in
      if len = 0 then None
      else if len <= 8 then Some trimmed
      else Some (String.sub trimmed 0 8)

let format_version ~version ~build_commit =
  match short_commit_opt build_commit with
  | Some short -> Printf.sprintf "%s (%s)" version short
  | None -> version

let parse ?(version = Build_version.current)
    ?(build_commit = Build_commit_generated.commit)
    ?(env = Sys.getenv_opt) ?cwd argv =
  let rec loop acc = function
    | [] -> Ok acc
    | arg :: rest -> (
        let flag, inline_opt = split_long_opt arg in
        match flag with
        | "--version" ->
            Error (`Info (Print_version (format_version ~version ~build_commit)))
        | "--build-commit" -> Error (`Info (Print_build_commit build_commit))
        | "--help" | "-h" -> Error (`Info (Print_help help_text))
        | "--no-auto-start" -> (
            match inline_opt with
            | None -> loop { acc with auto_start = false } rest
            | Some _ ->
                Error (`Err "option --no-auto-start does not take a value"))
        | "--port" -> (
            match take_value flag inline_opt rest with
            | Error msg -> Error (`Err msg)
            | Ok (raw, tail) -> (
                match parse_port raw with
                | Ok port -> loop { acc with explicit_port = Some port } tail
                | Error msg -> Error (`Err msg)))
        | "--host" -> (
            match take_value flag inline_opt rest with
            | Error msg -> Error (`Err msg)
            | Ok (raw, tail) ->
                let h = String.trim raw in
                if String.equal h "" || has_whitespace_or_ctl h then
                  Error (`Err (Printf.sprintf "invalid --host %S" raw))
                else loop { acc with host = Some h } tail)
        | "--url" -> (
            match take_value flag inline_opt rest with
            | Error msg -> Error (`Err msg)
            | Ok (raw, tail) -> (
                match parse_url raw with
                | Ok (scheme, host, url_port) ->
                    loop
                      {
                        acc with
                        scheme = Some scheme;
                        host = Some host;
                        url_port;
                      }
                      tail
                | Error msg -> Error (`Err msg)))
        | "--base-path" | "--base" -> (
            match take_value flag inline_opt rest with
            | Error msg -> Error (`Err msg)
            | Ok (raw, tail) ->
                let trimmed = String.trim raw in
                if String.equal trimmed "" then
                  Error (`Err (Printf.sprintf "%s must not be empty" flag))
                else loop { acc with base_path = Some trimmed } tail)
        | "--workspace" -> (
            match take_value flag inline_opt rest with
            | Error msg -> Error (`Err msg)
            | Ok (raw, tail) ->
                let trimmed = String.trim raw in
                if String.equal trimmed "" then
                  Error (`Err "--workspace must not be empty")
                else loop { acc with workspace = Some trimmed } tail)
        | "--theme" -> (
            match take_value flag inline_opt rest with
            | Error msg -> Error (`Err msg)
            | Ok (raw, tail) -> (
                match parse_theme raw with
                | Some theme -> loop { acc with theme = Some theme } tail
                | None ->
                    Error
                      (`Err
                        (Printf.sprintf
                           "invalid --theme %S: expected midnight, arcade, paper, or mono"
                           raw))))
        | "--lang" -> (
            match take_value flag inline_opt rest with
            | Error msg -> Error (`Err msg)
            | Ok (raw, tail) -> (
                match parse_lang raw with
                | Some lang -> loop { acc with lang = Some lang } tail
                | None ->
                    Error
                      (`Err
                        (Printf.sprintf "invalid --lang %S: expected ko or en"
                           raw))))
        | "--reasoning" ->
            Error
              (`Err
                "option --reasoning was removed in MASC TUI v2.5: toggle reasoning at runtime with Toggle_thinking (Ctrl-R); configure tool detail with /tools compact|results|full")
        | "--tool-view" ->
            Error
              (`Err
                "option --tool-view was removed in MASC TUI v2.5: switch tool detail at runtime with /tools compact|results|full (and Toggle_thinking for reasoning)")
        | other ->
            Error (`Err (Printf.sprintf "unknown argument: %s" other)))
  in
  match loop empty_draft argv with
  | Error (`Info action) -> Info action
  | Error (`Err msg) -> Parse_error msg
  | Ok d -> (
      let scheme = Option.value ~default:default_scheme d.scheme in
      let host =
        match d.host with
        | Some h -> h
        | None -> (
            match nonblank_opt (env "MASC_HOST") with
            | Some h -> h
            | None -> default_host)
      in
      let port_res =
        match d.explicit_port with
        | Some p -> Ok p
        | None -> (
            match d.url_port with
            | Some p -> Ok p
            | None -> (
                match d.scheme with
                | Some "https" -> Ok 443
                | Some "http" -> Ok 80
                | Some _ | None -> (
                    match nonblank_opt (env "MASC_HTTP_PORT") with
                    | Some raw -> parse_port raw
                    | None -> (
                        match nonblank_opt (env "MASC_PORT") with
                        | Some raw -> parse_port raw
                        | None -> Ok default_port))))
      in
      match port_res with
      | Error msg -> Parse_error msg
      | Ok port ->
          let raw_base =
            match d.base_path with
            | Some p -> p
            | None -> (
                match nonblank_opt (env "MASC_BASE_PATH") with
                | Some p -> p
                | None -> (
                    match cwd with Some c -> c | None -> default_cwd ()))
          in
          let base_path = expand_tilde ~env raw_base in
          let workspace =
            match d.workspace with
            | Some w -> w
            | None ->
                let bn = Filename.basename base_path in
                if String.equal bn "" || String.equal bn "." || String.equal bn "/"
                then "default"
                else bn
          in
          let theme = Option.value ~default:Theme.Midnight d.theme in
          let lang = Option.value ~default:Say.Lang_ko d.lang in
          Run
            {
              scheme;
              host;
              port;
              base_path;
              workspace;
              theme;
              lang;
              theme_explicit = Option.is_some d.theme;
              lang_explicit = Option.is_some d.lang;
              auto_start = d.auto_start;
            })

type tty_check =
  | Tty_ok
  | Non_tty of { reason : string; exit_code : int }

let check_tty_pure ~stdin_is_tty ~stdout_is_tty ~term_env =
  let term =
    term_env
    |> Option.value ~default:""
    |> String.lowercase_ascii
    |> String.trim
  in
  if (not stdin_is_tty) || (not stdout_is_tty) || String.equal term "dumb" then
    Non_tty
      {
        reason =
          "masc-tui requires interactive TTY stdin/stdout and TERM other than dumb";
        exit_code = 2;
      }
  else Tty_ok

let check_tty () =
  check_tty_pure
    ~stdin_is_tty:(Unix.isatty Unix.stdin)
    ~stdout_is_tty:(Unix.isatty Unix.stdout)
    ~term_env:(Sys.getenv_opt "TERM")

type cli_dispatch =
  | Start of config
  | Exit of int

let argv_tail arr =
  let n = Array.length arr in
  if n <= 1 then [] else Array.to_list (Array.sub arr 1 (n - 1))

let parse_and_dispatch ?(argv = Sys.argv) ?(out_channel = stdout)
    ?(err_channel = stderr) () =
  match parse (argv_tail argv) with
  | Run cfg -> Start cfg
  | Info (Print_version ver) ->
      output_string out_channel (ver ^ "\n");
      flush out_channel;
      Exit 0
  | Info (Print_build_commit (Some commit)) ->
      output_string out_channel (commit ^ "\n");
      flush out_channel;
      Exit 0
  | Info (Print_build_commit None) ->
      output_string err_channel "build commit is not embedded\n";
      flush err_channel;
      Exit 1
  | Info (Print_help text) ->
      output_string out_channel (text ^ "\n");
      flush out_channel;
      Exit 0
  | Parse_error msg ->
      output_string err_channel ("masc-tui: " ^ msg ^ "\n");
      output_string err_channel "Run 'masc-tui --help' for usage.\n";
      flush err_channel;
      Exit 2
