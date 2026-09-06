(** The tool-name prefix vocabulary, and the [keeper_] / [masc_] boundary
    inside it.

    Two prefixes carry almost every tool, one rule separates them, and it was
    never written down. Measured 2026-09-03 over the 88 tools that actually
    reach a Keeper's request:

    - [keeper_] (41) is a thing this Keeper does or owns — its memory, its
      spawns, its artifacts, its claim on a task, its clock.
    - [masc_] (47) is the shared workspace plane — the board every Keeper
      reads, the goals, the schedules, the run records, the other Keepers.

    The pairs that make it a rule rather than a habit split across the line
    for the same noun. [keeper_task_claim] is this Keeper taking a task;
    [masc_task_history] is the shared record of who took what.
    [keeper_library_read] is this Keeper reading; [masc_library_add] writes
    to the shelf everyone shares.

    Both prefixes are called by Keepers, so the boundary is not "who calls
    it" — 102,159 [keeper_] calls against 56,954 [masc_] calls over 31 days,
    every one from a Keeper. Reading it as a caller axis is what files a
    Keeper's own act under [masc_], which is how [masc_ask] got its name.

    {1 What this test can and cannot hold}

    Whether a given tool is a Keeper's act or a shared store is a judgement,
    and a test that guessed it from the name would reject correct names on a
    pattern. So this does not classify.

    What it does hold is the vocabulary: the set of prefixes is closed. A new
    tool arrives under [keeper_] or [masc_] — or under one of the four
    capitalised builtins and the [tool_] runtime handlers, which are named
    for other reasons documented below — and a fifth spelling has to be a
    decision someone makes here rather than a file someone adds. *)

open Alcotest

(* Resolved against the checkout rather than the working directory. The
   stanza's [(deps ...)] stage this directory into dune's own runtest action,
   so a relative path found it there -- and nowhere else. The targeted CI
   runner executes the binary straight out of [_build/default/test], where
   every case died on [Sys_error "config/tools: No such file or directory"],
   which is a report about a working directory wearing the name of a report
   about tool names.

   [DUNE_SOURCEROOT] is what dune sets to the workspace root, and it is how
   every other suite that reads source finds it. The deps stay: they are what
   makes a new tool re-run this test. *)
let tools_dir =
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when Sys.file_exists root -> root
    | Some _ | None -> Sys.getcwd ()
  in
  Filename.concat root "config/tools"

(* [tool_] is not a third namespace. These five are the runtime handlers the
   catalog marks hidden from the public MCP schema surface; a Keeper reaches
   them through the capitalised public names beside them. Listing them keeps
   the closed set honest instead of widening the rule to fit them. *)
let runtime_handler_prefix = "tool_"

(* The builtins whose public name is a bare capitalised verb. They predate
   the two-prefix split and are the names the model has always emitted. *)
let bare_builtins = [ "Read"; "Write"; "Edit"; "Grep"; "Execute" ]

let allowed_prefixes = [ "keeper_"; "masc_"; runtime_handler_prefix ]

let tool_names () =
  Sys.readdir tools_dir
  |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".toml")
  |> List.map (fun f -> Filename.remove_extension f)
  |> List.sort compare
;;

let has_prefix ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix
;;

let classify name =
  if List.mem name bare_builtins
  then None
  else List.find_opt (fun p -> has_prefix ~prefix:p name) allowed_prefixes
;;

(* The closed set. A tool whose name starts with neither an allowed prefix
   nor a bare builtin fails here, and the fix is to decide which side of the
   boundary it belongs on rather than to widen this list. *)
let test_prefix_vocabulary_is_closed () =
  let names = tool_names () in
  check bool "the directory has tools" true (List.length names > 100);
  let unclassified =
    List.filter (fun n -> classify n = None && not (List.mem n bare_builtins)) names
  in
  check (list string) "no tool outside the vocabulary" [] unclassified
;;

(* The guard has to fail on the thing it claims to catch. Without this a
   widened [allowed_prefixes], or a [classify] that answered [Some] for
   everything, would leave the test above passing on an empty promise. *)
let test_a_new_spelling_would_fail () =
  check
    bool
    "an unfamiliar prefix is not classified"
    true
    (classify "agent_do_something" = None);
  check
    bool
    "a bare lowercase verb is not classified"
    true
    (classify "search" = None);
  check
    bool
    "a real tool still classifies"
    true
    (classify "keeper_task_claim" = Some "keeper_")
;;

(* Every declared tool names itself. The prefix rule is about the filename,
   and a [name] field that drifts from it would move the tool to the other
   side of the boundary while this file still read the old one. *)
let test_declared_name_matches_the_file () =
  let mismatched =
    tool_names ()
    |> List.filter_map (fun n ->
      let contents = In_channel.with_open_bin (Filename.concat tools_dir (n ^ ".toml")) In_channel.input_all in
      let declared =
        contents
        |> String.split_on_char '\n'
        |> List.find_opt (fun line -> has_prefix ~prefix:"name = \"" line)
      in
      match declared with
      | Some line ->
        let body = String.sub line 8 (String.length line - 8) in
        (match String.index_opt body '"' with
         | Some i when String.sub body 0 i = n -> None
         | Some i -> Some (n ^ " declares " ^ String.sub body 0 i)
         | None -> Some (n ^ " has an unterminated name"))
      | None -> Some (n ^ " declares no name"))
  in
  check (list string) "filename is the tool name" [] mismatched
;;

let () =
  run
    "Tool name prefix boundary"
    [ ( "vocabulary"
      , [ test_case
            "the prefix vocabulary is closed"
            `Quick
            test_prefix_vocabulary_is_closed
        ; test_case
            "a new spelling would fail"
            `Quick
            test_a_new_spelling_would_fail
        ; test_case
            "the declared name matches the file"
            `Quick
            test_declared_name_matches_the_file
        ] )
    ]
;;
