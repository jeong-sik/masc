type outcome =
  | Started of string
  | Script_missing of string list
  | Spawn_failed of string

let script_name = "start-masc.sh"

(* Where the script can be. MASC_START_SCRIPT is the operator's escape hatch;
   the executable-relative path covers a dune build tree, where the binary sits
   at <repo>/_build/default/bin/. An installed binary lands in the opam bin
   directory and reaches neither, which is why the miss reports what it tried
   instead of failing silently. *)
let candidate_paths () =
  let from_env =
    match Sys.getenv_opt "MASC_START_SCRIPT" with
    | Some path when path <> "" -> [ path ]
    | Some _ | None -> []
  in
  let from_executable =
    let bin_dir = Filename.dirname Sys.executable_name in
    let up n dir =
      let rec climb dir = function
        | 0 -> dir
        | n -> climb (Filename.dirname dir) (n - 1)
      in
      climb dir n
    in
    (* bin -> default -> _build -> repo *)
    [ Filename.concat (up 3 bin_dir) script_name
    ; Filename.concat bin_dir script_name
    ]
  in
  from_env @ from_executable

let executable path =
  match Unix.access path [ Unix.X_OK ] with
  | () -> true
  | exception Unix.Unix_error _ -> false

let log_path ~base_path =
  Filename.concat base_path (Filename.concat ".masc" "tui-server-start.log")

(* The TUI holds the terminal in raw mode, so the script's own stdout would land
   in the middle of a frame. Everything it prints goes to the log instead, and
   the exit status of the spawn is what the operator sees. *)
let spawn ~script ~base_path ~port =
  let log = log_path ~base_path in
  (try
     let dir = Filename.dirname log in
     if not (Sys.file_exists dir) then Unix.mkdir dir 0o755
   with Unix.Unix_error _ -> ());
  match
    Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644
  with
  | exception Unix.Unix_error (err, _, _) ->
      Spawn_failed (Printf.sprintf "cannot open %s: %s" log (Unix.error_message err))
  | fd -> (
      let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0o644 in
      let argv =
        [| script; "--base-path"; base_path; "--port"; string_of_int port |]
      in
      match Unix.create_process script argv devnull fd fd with
      | exception Unix.Unix_error (err, _, _) ->
          Unix.close fd;
          Unix.close devnull;
          Spawn_failed (Unix.error_message err)
      | _pid ->
          Unix.close fd;
          Unix.close devnull;
          Started script)

let start ~base_path ~port =
  let candidates = candidate_paths () in
  match List.find_opt executable candidates with
  | None -> Script_missing candidates
  | Some script -> spawn ~script ~base_path ~port

let describe = function
  | Started script -> Printf.sprintf "server start requested: %s" script
  | Spawn_failed detail -> Printf.sprintf "server start failed: %s" detail
  | Script_missing candidates ->
      Printf.sprintf
        "server start script not found; set MASC_START_SCRIPT (tried: %s)"
        (String.concat ", " candidates)
;;
