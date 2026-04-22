(** Exec tap — see .mli for the contract.

    Implementation notes:
    - State is an [Atomic.t] so worker domains (Executor_pool) publish
      writer changes without a memory-barrier issue.
    - [record] uses [Unix.gettimeofday] directly to keep the tap usable
      from the Unix fallback path, which may run before Eio.Time is
      initialized.
    - JSON encoding is hand-rolled (single line, trailing newline only).
      Using Yojson would pull the dependency into every callsite.
    - Writer exceptions are swallowed.  Tap must not break production. *)

type call_kind =
  | Exec_gate_decision
  | Process_eio_run_argv
  | Process_eio_run_argv_with_stdin
  | Process_eio_run_argv_with_stdin_and_status
  | Process_eio_run_argv_with_status
  | Unix_create_process
  | Unix_create_process_env
  | Unix_open_process_args_in
  | Unix_open_process_args_full

let kind_to_string = function
  | Exec_gate_decision -> "Exec_gate.decision"
  | Process_eio_run_argv -> "Process_eio.run_argv"
  | Process_eio_run_argv_with_stdin -> "Process_eio.run_argv_with_stdin"
  | Process_eio_run_argv_with_stdin_and_status ->
      "Process_eio.run_argv_with_stdin_and_status"
  | Process_eio_run_argv_with_status -> "Process_eio.run_argv_with_status"
  | Unix_create_process -> "Unix.create_process"
  | Unix_create_process_env -> "Unix.create_process_env"
  | Unix_open_process_args_in -> "Unix.open_process_args_in"
  | Unix_open_process_args_full -> "Unix.open_process_args_full"

type mode =
  | Off
  | On of { writer : string -> unit }

let state : mode Atomic.t = Atomic.make Off

let enabled () =
  match Atomic.get state with
  | Off -> false
  | On _ -> true

let enable ~writer = Atomic.set state (On { writer })

let disable () = Atomic.set state Off

(* ── JSON escape ─────────────────────────────────────────────── *)

let add_json_escaped buf s =
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf "\\\""
      | '\\' -> Buffer.add_string buf "\\\\"
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s

let add_json_string buf s =
  Buffer.add_char buf '"';
  add_json_escaped buf s;
  Buffer.add_char buf '"'

let add_json_array_of_strings buf xs =
  Buffer.add_char buf '[';
  List.iteri
    (fun i s ->
      if i > 0 then Buffer.add_char buf ',';
      add_json_string buf s)
    xs;
  Buffer.add_char buf ']'

let add_json_bool buf value =
  Buffer.add_string buf (if value then "true" else "false")

let env_keys = function
  | None -> None
  | Some arr ->
      let keys =
        Array.to_list arr
        |> List.map (fun s ->
               match String.index_opt s '=' with
               | Some i -> String.sub s 0 i
               | None -> s)
      in
      Some keys

let now_iso8601 () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec
    (int_of_float ((t -. Float.floor t) *. 1000.0))

(* ── record ─────────────────────────────────────────────── *)

type extra_field =
  [ `String of string * string
  | `Bool of string * bool
  ]

let write_line ~kind ~argv ?env ?cwd (extras : extra_field list) =
  match Atomic.get state with
  | Off -> ()
  | On { writer } ->
      let buf = Buffer.create 256 in
      Buffer.add_string buf "{\"ts\":";
      add_json_string buf (now_iso8601 ());
      Buffer.add_string buf ",\"kind\":";
      add_json_string buf (kind_to_string kind);
      Buffer.add_string buf ",\"argv\":";
      add_json_array_of_strings buf argv;
      Buffer.add_string buf ",\"env_keys\":";
      (match env_keys env with
       | None -> Buffer.add_string buf "null"
       | Some keys -> add_json_array_of_strings buf keys);
      Buffer.add_string buf ",\"cwd\":";
      (match cwd with
       | None -> Buffer.add_string buf "null"
       | Some s -> add_json_string buf s);
      List.iter
        (function
          | `String (name, value) ->
            Buffer.add_char buf ',';
            add_json_string buf name;
            Buffer.add_char buf ':';
            add_json_string buf value
          | `Bool (name, value) ->
            Buffer.add_char buf ',';
            add_json_string buf name;
            Buffer.add_char buf ':';
            add_json_bool buf value)
        extras;
      Buffer.add_string buf "}\n";
      let line = Buffer.contents buf in
      (try writer line with _exn -> ())

let record ~kind ~argv ?env ?cwd () =
  write_line ~kind ~argv ?env ?cwd []

let record_gate_decision ~actor ~raw_source ~summary ~gate_mode
    ~gate_verdict ~gate_enforced ~argv ?env ?cwd () =
  write_line ~kind:Exec_gate_decision ~argv ?env ?cwd
    [
      `String ("actor", actor);
      `String ("raw_source", raw_source);
      `String ("summary", summary);
      `String ("gate_mode", gate_mode);
      `String ("gate_verdict", gate_verdict);
      `Bool ("gate_enforced", gate_enforced);
    ]

(* ── install_from_env ─────────────────────────────────────────────── *)

let env_truthy = function
  | "1" | "true" | "yes" | "TRUE" | "YES" -> true
  | _ -> false

let default_out_path = "audits/exec-corpus.jsonl"

let open_append_fd path =
  Unix.openfile path
    [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_CLOEXEC ]
    0o644

let install_from_env () =
  match Sys.getenv_opt "MASC_EXEC_TAP" with
  | Some v when env_truthy v ->
      let out_path =
        match Sys.getenv_opt "MASC_EXEC_TAP_OUT" with
        | Some p when p <> "" -> p
        | _ -> default_out_path
      in
      let result =
        try Ok (open_append_fd out_path)
        with Unix.Unix_error (e, fn, arg) ->
          Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message e))
      in
      (match result with
       | Ok fd ->
           let mu = Mutex.create () in
           let writer line =
             Mutex.lock mu;
             Fun.protect
               ~finally:(fun () -> Mutex.unlock mu)
               (fun () ->
                  let len = String.length line in
                  ignore (Unix.write_substring fd line 0 len : int))
           in
           enable ~writer;
           Printf.eprintf "[exec_tap] enabled \xe2\x86\x92 %s\n%!" out_path
       | Error msg ->
           Printf.eprintf "[exec_tap] disabled: cannot open %s \xe2\x80\x94 %s\n%!"
             out_path msg)
  | _ -> ()
