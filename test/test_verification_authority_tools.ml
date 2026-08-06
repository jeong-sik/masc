(* RFC-0361 D1: the completion authority's read-only lookup surface.

   The properties under test are the ones that decide whether a judge can be
   trusted with the surface at all: it cannot read outside the producer's root,
   it cannot be handed a name it silently ignores, and it reports failure
   instead of a clean-looking empty answer. *)

module VAT = Masc.Verification_authority_tools
module AR = Masc.Task.Anti_rationalization

let temp_base_path () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-vat-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o700)
;;

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)
;;

(* A surface bound to a producer whose root exists and holds [files]. *)
let with_surface files f =
  let base_path = temp_base_path () in
  let surface = VAT.create ~base_path ~producer:"test-producer" in
  let root = VAT.ownership_root surface in
  mkdir_p root;
  List.iter
    (fun (relative, contents) -> write_file (Filename.concat root relative) contents)
    files;
  f surface root
;;

let dispatch_result surface ~name ~args = VAT.dispatch surface ~name ~args

let test_read_file_returns_content () =
  with_surface [ "lib/answer.ml", "let answer = 42\n" ] (fun surface _root ->
    match
      dispatch_result surface ~name:"verification_read_file"
        ~args:(`Assoc [ "path", `String "lib/answer.ml" ])
    with
    | Error detail -> Alcotest.failf "expected a read, got error: %s" detail
    | Ok output ->
      Alcotest.(check bool)
        "content is present"
        true
        (Astring.String.is_infix ~affix:"let answer = 42" output))
;;

let test_read_file_outside_root_is_rejected () =
  with_surface [ "inside.txt", "in\n" ] (fun surface root ->
    (* A sibling of the producer root, reachable only by escaping it. *)
    write_file (Filename.concat (Filename.dirname root) "outside.txt") "out\n";
    match
      dispatch_result surface ~name:"verification_read_file"
        ~args:(`Assoc [ "path", `String "../outside.txt" ])
    with
    | Ok output -> Alcotest.failf "escape should not read; got %s" output
    | Error _ -> ())
;;

(* A judge that calls a name this surface does not offer must be told so. A
   dropped call would read to the model as a tool that returned nothing. *)
let test_unknown_tool_name_is_an_error () =
  with_surface [] (fun surface _root ->
    match dispatch_result surface ~name:"verification_write_file" ~args:(`Assoc []) with
    | Ok output -> Alcotest.failf "unknown tool should not succeed; got %s" output
    | Error detail ->
      Alcotest.(check bool)
        "names the offered tools"
        true
        (Astring.String.is_infix ~affix:"verification_read_file" detail))
;;

(* Every advertised schema must reach an implementation. Advertising a name
   dispatch does not know would put a tool in the model's list that always
   fails. *)
let test_every_schema_name_dispatches () =
  with_surface [] (fun surface _root ->
    List.iter
      (fun (schema : Masc_domain.tool_schema) ->
         match dispatch_result surface ~name:schema.name ~args:(`Assoc []) with
         | Ok _ -> ()
         | Error detail ->
           Alcotest.(check bool)
             (Printf.sprintf "%s is not reported as unknown" schema.name)
             false
             (Astring.String.is_infix ~affix:"unknown tool" detail))
      (VAT.schemas surface))
;;

(* RFC-0361 D2. The prompt states what the evaluator can see, and the two
   surfaces are different claims. Rendering the toolless text for a
   tool-carrying review is the exact gap D1 exists to close. *)
let test_prompt_states_the_available_surface () =
  with_surface [] (fun surface _root ->
    let request : AR.review_request =
      { agent_name = "test-producer"
      ; task_title = "t"
      ; task_description = "d"
      ; completion_notes = "n"
      ; task_id = "task-1"
      ; evidence_refs = []
      }
    in
    let render lookup =
      match AR.build_prompt ~lookup request with
      | Ok prompt -> prompt
      | Error detail -> Alcotest.failf "prompt render failed: %s" detail
    in
    let without = render AR.No_lookup_surface in
    let with_tools =
      render
        (AR.Lookup_tools
           { schemas = VAT.schemas surface; dispatch = VAT.dispatch surface })
    in
    Alcotest.(check bool)
      "toolless prompt says the snapshot is the only proof"
      true
      (Astring.String.is_infix ~affix:"You have no tool that opens anything else" without);
    Alcotest.(check bool)
      "toolless prompt does not advertise a tool"
      false
      (Astring.String.is_infix ~affix:"verification_read_file" without);
    Alcotest.(check bool)
      "tool prompt names the tools"
      true
      (Astring.String.is_infix ~affix:"verification_read_file" with_tools);
    Alcotest.(check bool)
      "tool prompt does not deny having tools"
      false
      (Astring.String.is_infix
         ~affix:"You have no tool that opens anything else"
         with_tools))
;;

let git_in dir args =
  let quoted = List.map Filename.quote args |> String.concat " " in
  let command =
    Printf.sprintf
      "cd %s && git %s >/dev/null 2>&1"
      (Filename.quote dir)
      quoted
  in
  match Sys.command command with
  | 0 -> ()
  | code -> Alcotest.failf "git %s failed with %d" quoted code
;;

(* A checkout with one committed file, so a later edit is the only thing that
   can differ from the commit. *)
let init_repo dir =
  mkdir_p dir;
  git_in dir [ "init"; "--quiet" ];
  git_in dir [ "config"; "user.email"; "test@example.invalid" ];
  git_in dir [ "config"; "user.name"; "test" ];
  write_file (Filename.concat dir "committed.ml") "let committed = true\n";
  git_in dir [ "add"; "committed.ml" ];
  git_in dir [ "commit"; "--quiet"; "-m"; "initial" ]
;;

let git_status_of surface ~path =
  dispatch_result surface ~name:"verification_git_status"
    ~args:(`Assoc [ "path", `String path ])
;;

(* The task-136 shape: the work is present in the tree and reads back exactly
   as submitted, but nothing committed it, so the next task's cleanup discards
   it. Reading the file cannot distinguish this from finished work. *)
let test_uncommitted_work_is_named () =
  with_surface [] (fun surface root ->
    let repo = Filename.concat root "checkout" in
    init_repo repo;
    write_file (Filename.concat repo "aria.ml") "let aria_label = \"close\"\n";
    match git_status_of surface ~path:"checkout" with
    | Error detail -> Alcotest.failf "expected a status, got error: %s" detail
    | Ok output ->
      Alcotest.(check bool)
        "the uncommitted file is named"
        true
        (Astring.String.is_infix ~affix:"aria.ml" output);
      Alcotest.(check bool)
        "the answer does not claim the tree is clean"
        false
        (Astring.String.is_infix ~affix:"working tree clean" output))
;;

let test_committed_work_reports_clean () =
  with_surface [] (fun surface root ->
    let repo = Filename.concat root "checkout" in
    init_repo repo;
    match git_status_of surface ~path:"checkout" with
    | Error detail -> Alcotest.failf "expected a status, got error: %s" detail
    | Ok output ->
      Alcotest.(check bool)
        "a committed tree reports clean"
        true
        (Astring.String.is_infix ~affix:"working tree clean" output))
;;

let test_git_status_outside_root_is_rejected () =
  with_surface [] (fun surface root ->
    let outside = Filename.concat (Filename.dirname root) "outside-repo" in
    init_repo outside;
    match git_status_of surface ~path:"../outside-repo" with
    | Ok output -> Alcotest.failf "escape should not report status; got %s" output
    | Error detail ->
      Alcotest.(check bool)
        "the rejection names the boundary"
        true
        (Astring.String.is_infix ~affix:"outside" (String.lowercase_ascii detail)))
;;

let test_git_status_on_a_missing_directory_is_an_error () =
  with_surface [] (fun surface _root ->
    match git_status_of surface ~path:"no-such-checkout" with
    | Ok output ->
      Alcotest.failf "a missing directory must not read as clean; got %s" output
    | Error detail ->
      Alcotest.(check bool)
        "the error says the directory is absent rather than clean"
        false
        (Astring.String.is_infix ~affix:"clean" detail))
;;

let test_git_status_on_a_non_repository_is_an_error () =
  with_surface [ "plain/file.txt", "not a repo\n" ] (fun surface _root ->
    match git_status_of surface ~path:"plain" with
    | Ok output ->
      Alcotest.failf "a non-repository must not read as clean; got %s" output
    | Error detail ->
      Alcotest.(check bool)
        "a Git failure is not reported as a clean tree"
        false
        (Astring.String.is_infix ~affix:"clean" detail))
;;

let () =
  Random.self_init ();
  Alcotest.run
    "verification authority tools"
    [ ( "containment"
      , [ Alcotest.test_case "read file returns content" `Quick
            test_read_file_returns_content
        ; Alcotest.test_case "read outside root is rejected" `Quick
            test_read_file_outside_root_is_rejected
        ; Alcotest.test_case "git status outside root is rejected" `Quick
            test_git_status_outside_root_is_rejected
        ] )
    ; ( "durability"
      , [ Alcotest.test_case "uncommitted work is named" `Quick
            test_uncommitted_work_is_named
        ; Alcotest.test_case "committed work reports clean" `Quick
            test_committed_work_reports_clean
        ; Alcotest.test_case "missing directory is an error" `Quick
            test_git_status_on_a_missing_directory_is_an_error
        ; Alcotest.test_case "non-repository is an error" `Quick
            test_git_status_on_a_non_repository_is_an_error
        ] )
    ; ( "dispatch"
      , [ Alcotest.test_case "unknown tool name is an error" `Quick
            test_unknown_tool_name_is_an_error
        ; Alcotest.test_case "every schema name dispatches" `Quick
            test_every_schema_name_dispatches
        ] )
    ; ( "prompt"
      , [ Alcotest.test_case "prompt states the available surface" `Quick
            test_prompt_states_the_available_surface
        ] )
    ]
;;
