(* RFC tools-as-shell-commands — the split between a declared shell path
   and the positional words that follow it, against the real crunched tool
   tree (the three read-only tools PR-1 declares).

   The rewrite itself is covered from the other side: PR-1a's dispatch
   tests already lock the delegated round trip, and the conversion needs a
   full turn context to build, which a unit test does not have. *)

let () =
  let module K = Masc.Keeper_shell_tool_command in
  assert (
    K.split_words [ "board"; "post"; "get"; "p-1" ]
    = Some ("masc_board_post_get", [ "p-1" ]));
  assert (K.split_words [ "board"; "list" ] = Some ("masc_board_list", []));
  assert (K.split_words [ "time"; "now" ] = Some ("keeper_time_now", []));
  (* The path alone splits fine; the argument count is the schema's word,
     not the split's. *)
  assert (
    K.split_words [ "board"; "post"; "get" ]
    = Some ("masc_board_post_get", []));
  (* Undeclared paths answer None — the closed surface, not a guess. *)
  assert (K.split_words [ "board" ] = None);
  assert (K.split_words [ "execute"; "script" ] = None);
  assert (K.split_words [ "unknown"; "thing" ] = None);
  (* A longer declared path must not be shadowed by a shorter one. *)
  assert (
    K.split_words [ "board"; "post"; "get"; "p-9"; "extra" ]
    = Some ("masc_board_post_get", [ "p-9"; "extra" ]))

let () =
  (match Masc.Keeper_tool_runtime.descriptor_for_internal "masc_board_post_get" with
   | None -> assert false
   | Some descriptor ->
     (* Positional words land on the schema's required parameters, in the
        order the schema states them. *)
     (match
        Masc.Keeper_shell_tool_command.args_json_of_words ~descriptor [ "p-123" ]
      with
      | Ok (`Assoc [ ("post_id", `String "p-123") ]) -> ()
      | Ok _ | Error _ -> assert false);
     (match Masc.Keeper_shell_tool_command.args_json_of_words ~descriptor [] with
      | Error message ->
        (* "shell command takes 1 argument, got 0" *)
        assert (String.length message > 0)
      | Ok _ -> assert false);
     (* A schema with no required key states zero required parameters, so
        an optional-only tool answers the path alone.  This is the review
        finding that made [masc board list] and [masc time now] work. *)
     (match Masc.Keeper_tool_runtime.descriptor_for_internal "masc_board_list" with
      | None -> assert false
      | Some list_descriptor -> (
        match
          Masc.Keeper_shell_tool_command.args_json_of_words
            ~descriptor:list_descriptor
            []
        with
        | Ok (`Assoc []) -> ()
        | Ok _ | Error _ -> assert false)))

(* The surface a lane with no turn has (#32730). The host replays an approved
   effect with no descriptor lookup and no dispatch, so it cannot route a
   [masc] line. Before this it passed no surface at all and the runtime's
   absent case ran the line: routing lives in the IR's sandbox field, so an
   unrouted line is not refused, it execs a host program named [masc]. *)
let () =
  let module K = Masc.Keeper_shell_tool_command in
  let simple name args =
    match Masc_exec.Exec_program.of_string name with
    | Error (`Unknown detail) -> failwith ("test fixture: " ^ detail)
    | Ok program ->
      Masc_exec.Shell_ir.Simple
        { bin = program
        ; args =
            List.map
              (fun a -> Masc_exec.Shell_ir.Lit (a, Masc_exec.Shell_ir.default_meta))
              args
        ; env = []
        ; cwd = None
        ; redirects = []
        ; sandbox = Masc_exec.Sandbox_target.host ()
        }
  in
  (match K.refuse_reserved_command (simple "masc" [ "board"; "list" ]) with
   | Error _ -> ()
   | Ok _ -> assert false);
  (* A pipeline hides one just as well. *)
  (match
     K.refuse_reserved_command
       (Masc_exec.Shell_ir.Pipeline
          [ simple "ls" []; simple "masc" [ "board"; "list" ] ])
   with
   | Error _ -> ()
   | Ok _ -> assert false);
  (* Everything else is the lane's ordinary work and passes through. *)
  (match K.refuse_reserved_command (simple "ls" [ "-la" ]) with
   | Ok _ -> ()
   | Error _ -> assert false)

let () =
  print_endline "[test_keeper_shell_tool_command] all tests passed"
