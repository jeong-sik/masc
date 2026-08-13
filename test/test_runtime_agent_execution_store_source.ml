(* Keep Runtime_agent's caller-owned execution-store contract present on every
   Agent Core execution strategy without constructing a second store or
   silently dropping the store when streaming or cooperative yield is used. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)
;;

let normalize_whitespace input =
  let output = Buffer.create (String.length input) in
  let pending_space = ref false in
  String.iter
    (function
      | ' ' | '\n' | '\r' | '\t' -> pending_space := Buffer.length output > 0
      | char ->
        if !pending_space then Buffer.add_char output ' ';
        pending_space := false;
        Buffer.add_char output char)
    input;
  Buffer.contents output
;;

let contains haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > haystack_length
    then false
    else if String.sub haystack offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let assert_contains ~label source expected =
  if not (contains source expected)
  then failwith (Printf.sprintf "[%s] expected source to contain %S" label expected)
;;

let resolve_source relative =
  let parent path = Filename.dirname path in
  let project_root = parent (parent (parent (parent Sys.executable_name))) in
  let candidates =
    [ relative; Filename.concat project_root relative; Filename.concat ".." relative ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> normalize_whitespace (read_file path)
  | None ->
    failwith
      (Printf.sprintf
         "could not resolve %s (cwd=%s, exe=%s)"
         relative
         (Sys.getcwd ())
         Sys.executable_name)
;;

let () =
  let implementation = resolve_source "lib/runtime/runtime_agent.ml" in
  let interface = resolve_source "lib/runtime/runtime_agent.mli" in
  assert_contains
    ~label:"stream execution"
    implementation
    "Agent_core.Agent.run_stream_blocks ~sw ?clock ?on_yield ?on_resume ?execution_store ~on_event:cb";
  assert_contains
    ~label:"sync execution"
    implementation
    "Agent_core.Agent.run_blocks ~sw ?clock ?on_yield ?on_resume ?execution_store agent";
  assert_contains
    ~label:"cooperative execution"
    implementation
    "Agent_core.Agent.Advanced.run_blocks ~sw ?clock ?on_yield ?on_resume ?execution_store ~api_strategy";
  assert_contains
    ~label:"string wrapper"
    implementation
    "run_blocks ~sw ~net ~config ?agent_core_checkpoint ?on_event ?on_yield ?on_resume ?execution_store ?agent_ref";
  assert_contains
    ~label:"public interface"
    interface
    "?on_resume:(unit -> unit) -> ?execution_store:Agent_core.Agent.execution_store -> ?agent_ref:Agent_core.Agent.t option ref ->";
  print_endline "test_runtime_agent_execution_store_source: OK"
;;
