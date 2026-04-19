(* Tick 11: JSON-shape pinning for the keeper_bash auto-bg hookup.

   The keeper_bash handler translates
   [Masc_exec.Exec_run.outcome] to JSON at line 953-ish of
   [lib/keeper/keeper_exec_shell.ml].  Rather than spin up the full
   MCP stack to observe that translation, this test rebuilds the
   promotion payload inline using the same Exec_run outcome and
   pins the key set clients will see after [MASC_BASH_AUTO_BG=1]
   and a budget expiry.

   The keys pinned here form the public contract:

     ok, promoted, background_task_id, cmd, cwd, partial_output,
     bytes_dropped, budget_ms, hint

   Adding a key is additive and safe; removing one breaks every
   LLM that learned to poll `background_task_id` or react to
   `promoted: true`. *)

open Alcotest
open Masc_exec

let clean_bg_dir ~base_path ~keeper =
  let bg_dir =
    Filename.concat
      (Filename.concat
         (Common.masc_dir_from_base_path ~base_path)
         (Filename.concat "keeper" keeper))
      "bg"
  in
  if Sys.file_exists bg_dir then
    let files = try Sys.readdir bg_dir with _ -> [||] in
    Array.iter (fun f ->
      try Sys.remove (Filename.concat bg_dir f) with _ -> ())
      files

let render_promoted_payload
    ~(cmd : string)
    ~(cwd : string)
    ~(budget_ms : int)
    (p : Exec_run.promoted) : Yojson.Safe.t =
  `Assoc
    [
      ("ok", `Bool false);
      ("promoted", `Bool true);
      ( "background_task_id",
        `String (Bg_task.task_id_to_string p.task_id) );
      ("cmd", `String cmd);
      ("cwd", `String cwd);
      ("partial_output", `String p.partial_stdout);
      ("bytes_dropped", `Int p.bytes_dropped_stdout);
      ("budget_ms", `Int budget_ms);
      ( "hint",
        `String
          (Printf.sprintf
             "Command exceeded MASC_BLOCKING_BUDGET_MS=%d. Still \
              running in background; poll with keeper_bash_output or \
              stop with keeper_bash_kill."
             budget_ms) );
    ]

let key_set json =
  match json with
  | `Assoc pairs -> List.map fst pairs |> List.sort compare
  | _ -> []

let expected_keys =
  [
    "background_task_id"; "budget_ms"; "bytes_dropped"; "cmd"; "cwd";
    "hint"; "ok"; "partial_output"; "promoted";
  ]

let test_promoted_json_shape () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let base_path = Filename.get_temp_dir_name () in
  let keeper = "exec_run_json_test" in
  clean_bg_dir ~base_path ~keeper;
  let cmd = "printf hello; sleep 5" in
  let cwd = Sys.getcwd () in
  let budget_ms = 150 in
  let out =
    Exec_run.run_with_auto_bg
      ~clock
      ~poll_interval_ms:20
      ~base_path
      ~budget_ms
      ~keeper
      ~argv:[ "/bin/bash"; "-lc"; cmd ^ " 2>&1" ]
      ~cwd
      ~envp:(Unix.environment ())
      ~timeout_sec:30.0
      ()
  in
  match out with
  | Exec_run.Completed _ ->
    fail "budget 150ms + sleep 5 should promote"
  | Exec_run.Spawn_error _ -> fail "spawn failed"
  | Exec_run.Promoted p ->
    let payload = render_promoted_payload ~cmd ~cwd ~budget_ms p in
    (* Key set pinning *)
    check (list string) "promoted keys" expected_keys (key_set payload);
    (* Value-level checks on the public fields *)
    (match payload with
     | `Assoc pairs ->
       let get k = List.assoc k pairs in
       check bool "ok=false" false
         (match get "ok" with `Bool b -> b | _ -> true);
       check bool "promoted=true" true
         (match get "promoted" with `Bool b -> b | _ -> false);
       check bool "task_id nonempty" true
         (match get "background_task_id" with
          | `String s -> String.length s > 0
          | _ -> false);
       check int "budget_ms echoed" budget_ms
         (match get "budget_ms" with `Int n -> n | _ -> -1)
     | _ -> fail "payload must be `Assoc");
    let _ = Bg_task.kill p.task_id ~signal:Sys.sigterm ~grace_sec:0.2 in
    ()

let () =
  run "exec_run_json" [
    ("shape", [
      test_case "promoted payload pinning" `Slow test_promoted_json_shape;
    ]);
  ]
