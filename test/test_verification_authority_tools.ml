(* Completion-authority descriptor, validation, dispatch, and containment
   contracts. *)

module Keeper_meta_store = Masc.Keeper_meta_store
module Descriptor = Masc.Keeper_tool_descriptor
module VAT = Masc.Verification_authority_tools
module AR = Masc.Task.Anti_rationalization

let producer = "test-producer"

let temp_dir () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-vat-%d-%d" (Unix.getpid ()) (Random.bits ()))
  in
  Unix.mkdir path 0o700;
  path
;;

let rec rm_rf path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
    (try Unix.rmdir path with Unix.Unix_error _ -> ())
  | _ -> (try Unix.unlink path with Unix.Unix_error _ -> ())
  | exception Unix.Unix_error _ -> ()
;;

(* [agent_name] is deliberately omitted: [meta_of_json_fixture] fills in the
   canonical [Keeper_identity.keeper_agent_name], so this fixture cannot drift
   from the identity rule the meta parser enforces.

   [always_allow] is the producer's Gate posture. These cases exercise the
   immediate execution branch. *)
let ensure_producer config name =
  match
    Result.bind
      (Masc_test_deps.meta_of_json_fixture
         (`Assoc [ "name", `String name; "always_allow", `Bool true ]))
      (Keeper_meta_store.replace_snapshot config)
  with
  | Ok _ -> ()
  | Error err -> Alcotest.failf "write keeper meta failed: %s" err
;;

(* A workspace holding one producer keeper, and the surface bound to it. *)
let with_surface f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  (* [tool_execute] submits through the external-effect Gate, which refuses to
     run at all until its durable store exists. Without this the execute cases
     would fail on missing infrastructure and prove nothing about the surface. *)
  (match Masc.Keeper_approval_queue.install_persistence ~base_path:dir with
   | Ok _ -> ()
   | Error err ->
     Alcotest.failf
       "gate store install failed: %s"
       (Masc.Keeper_approval_queue.install_error_to_string err));
  ensure_producer config producer;
  match VAT.create ~config ~producer with
  | Error reason -> Alcotest.failf "surface creation failed: %s" reason
  | Ok surface -> f config surface
;;

(* Create the producer playground used to resolve relative tool paths. *)
let producer_playground (config : Workspace_core.config) =
  let path =
    Keeper_sandbox_config.host_root_abs_of_agent
      ~base_path:
        (Workspace_verification_store.project_root_of_base_path config.base_path)
      ~agent_name:producer
  in
  let rec mkdir_p dir =
    if not (Sys.file_exists dir)
    then (
      mkdir_p (Filename.dirname dir);
      try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
  in
  mkdir_p path;
  path
;;

(* The judge and producer share the descriptor-owned model surface. *)
let test_schemas_are_the_descriptor_schemas () =
  with_surface (fun _config surface ->
    let offered = VAT.schemas surface in
    let names =
      List.map (fun (schema : Masc_domain.tool_schema) -> schema.name) offered
    in
    Alcotest.(check (list string))
      "the surface is read, search, execute"
      [ "tool_read_file"; "tool_search_files"; "tool_execute" ]
      names;
    List.iter
      (fun (schema : Masc_domain.tool_schema) ->
         match Descriptor.descriptors_for_internal schema.name with
         | [ descriptor ] ->
           Alcotest.(check string)
             (schema.name ^ " description is the descriptor's")
             descriptor.Descriptor.description
             schema.description;
           Alcotest.(check bool)
             (schema.name ^ " input schema is the descriptor's")
             true
             (Yojson.Safe.equal descriptor.Descriptor.input_schema schema.input_schema)
         | found ->
           Alcotest.failf
             "%s resolves to %d descriptors; the surface needs exactly one"
             schema.name
             (List.length found))
      offered)
;;

(* A successful read proves descriptor translation reaches the runtime handler;
   a missing required argument must be rejected at the same boundary. *)
let test_read_translates_the_advertised_argument_and_refuses_a_malformed_one () =
  with_surface (fun config surface ->
    let playground = producer_playground config in
    let name = "advertised-argument-probe.txt" in
    let contents = "written by the probe" in
    (try
       Out_channel.with_open_text (Filename.concat playground name) (fun oc ->
         output_string oc contents)
     with
     | Sys_error err -> Alcotest.failf "probe file could not be written: %s" err);
    let read key =
      VAT.dispatch surface ~name:"tool_read_file" ~args:(`Assoc [ key, `String name ])
    in
    let required =
      match
        List.find_opt
          (fun (schema : Masc_domain.tool_schema) ->
             String.equal schema.name "tool_read_file")
          (VAT.schemas surface)
      with
      | Some { input_schema = `Assoc fields; _ } ->
        (match List.assoc_opt "required" fields with
         | Some (`List (`String field :: _)) -> field
         | _ -> Alcotest.fail "tool_read_file advertises no required argument")
      | _ -> Alcotest.fail "tool_read_file is not offered"
    in
    (match read required with
     | Error detail ->
       Alcotest.failf
         "the advertised required argument %S did not reach the handler: %s"
         required
         detail
     | Ok output ->
       Alcotest.(check bool)
         (Printf.sprintf "%S returns the file's contents" required)
         true
         (Astring.String.is_infix ~affix:contents output));
    match VAT.dispatch surface ~name:"tool_read_file" ~args:(`Assoc []) with
    | Ok output ->
      Alcotest.failf
        "a read with no %S resolved instead of being refused, so an unopened \
         file reads as an answer: %s"
        required
        output
    | Error detail ->
      Alcotest.(check bool)
        "the refusal names the missing argument"
        true
        (Astring.String.is_infix ~affix:required detail))
;;

(* A search requires an explicit non-empty pattern. *)
let test_search_refuses_a_call_without_its_required_pattern () =
  with_surface (fun config surface ->
    ignore (producer_playground config);
    (match
       VAT.dispatch surface ~name:"tool_search_files" ~args:(`Assoc [])
     with
     | Ok output ->
       Alcotest.failf
         "a search with no pattern resolved instead of being refused: %s"
         output
     | Error detail ->
       Alcotest.(check bool)
         "the refusal names the missing argument"
         true
         (Astring.String.is_infix ~affix:"pattern" detail));
    match
      VAT.dispatch
        surface
        ~name:"tool_search_files"
        ~args:(`Assoc [ "pattern", `String "advertised" ])
    with
    | Ok _ -> ()
    | Error detail ->
      Alcotest.failf "a search carrying its pattern was refused: %s" detail)
;;

(* [argv] is a process vector, never a shell-line string. *)
let test_execute_refuses_argv_that_is_not_a_process_vector () =
  with_surface (fun _config surface ->
    match
      VAT.dispatch
        surface
        ~name:"tool_execute"
        ~args:(`Assoc [ "argv", `String "echo durable-marker" ])
    with
    | Ok output ->
      Alcotest.failf
        "argv as a bare string resolved instead of being refused: %s"
        output
    | Error detail ->
      Alcotest.(check bool)
        "the refusal names argv"
        true
        (Astring.String.is_infix ~affix:"argv" detail))
;;

(* A judge that calls a name this surface does not offer must be told so. A
   dropped call would read to the model as a tool that returned nothing. *)
let test_unknown_tool_name_is_an_error () =
  with_surface (fun _config surface ->
    match VAT.dispatch surface ~name:"tool_write_file" ~args:(`Assoc []) with
    | Ok output -> Alcotest.failf "unknown tool should not succeed; got %s" output
    | Error detail ->
      Alcotest.(check bool)
        "names the offered tools"
        true
        (Astring.String.is_infix ~affix:"tool_execute" detail))
;;

(* Where the judge's process would run is the safety property this layer owns.
   The keeper runtime resolves it and reports the resolution back, so the
   assertion is on that resolution rather than on process output: whether the
   effect then executes or defers is the Gate's decision, and standing the Gate
   and its Auto Judge up belongs to an integration test, not here.

   The judge borrows the producer's meta, so it borrows the producer's jail. A
   [cwd] of "." must land in the producer's playground — not the host, not
   another keeper's tree, and not the workspace root. *)
let test_execute_resolves_inside_the_producer_playground () =
  with_surface (fun _config surface ->
    let root = VAT.ownership_root surface in
    let report =
      match
        VAT.dispatch
          surface
          ~name:"tool_execute"
          ~args:
            (`Assoc
               [ "argv", `List [ `String "echo"; `String "durable-marker" ]
               ; "cwd", `String "."
               ])
      with
      | Ok output | Error output -> output
    in
    Alcotest.(check bool)
      "the resolved working directory is the producer playground"
      true
      (Astring.String.is_infix ~affix:root report);
    Alcotest.(check bool)
      "the resolution names the playground scope"
      true
      (Astring.String.is_infix ~affix:"playground_root" report))
;;

(* An escape must not resolve. A judge that can point [cwd] outside the
   producer's jail reaches trees no one authorized it to touch, and with write
   capability that is not a read of the wrong file but a change to it. *)
let test_execute_cannot_escape_the_producer_playground () =
  with_surface (fun _config surface ->
    match
      VAT.dispatch
        surface
        ~name:"tool_execute"
        ~args:
          (`Assoc
             [ "argv", `List [ `String "echo"; `String "escaped" ]
             ; "cwd", `String "../../.."
             ])
    with
    | Ok output ->
      Alcotest.failf "an escaping cwd must not resolve; got %s" output
    | Error detail ->
      Alcotest.(check bool)
        "the rejection does not report a resolved playground scope"
        false
        (Astring.String.is_infix ~affix:"\"scope\":\"playground_root\"" detail))
;;

(* A failed process is a failed lookup result. *)
let test_a_failed_run_is_an_error_not_empty_output () =
  with_surface (fun _config surface ->
    match
      VAT.dispatch
        surface
        ~name:"tool_execute"
        ~args:
          (`Assoc
             [ "argv", `List [ `String "false" ]
             ; "cwd", `String "."
             ])
    with
    | Ok output ->
      Alcotest.failf "a non-zero exit must not resolve as success; got %s" output
    | Error _ -> ())
;;

(* A producer with no keeper meta has no tree to point at. Handing back a
   surface anyway would advertise three tools whose every call fails, which
   reads to the model as a broken tree rather than as an absent one. *)
let test_unknown_producer_yields_no_surface () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf dir);
  let config = Workspace_core.default_config dir in
  ignore (Workspace_core.init config ~agent_name:(Some "test"));
  match VAT.create ~config ~producer:"no-such-producer" with
  | Ok _ -> Alcotest.fail "a producer with no meta must not yield a surface"
  | Error reason ->
    Alcotest.(check bool)
      "the reason names the producer"
      true
      (Astring.String.is_infix ~affix:"no-such-producer" reason)
;;

(* The prompt states the exact tools attached to the review request. *)
let test_prompt_states_the_available_surface () =
  with_surface (fun _config surface ->
    let request : AR.review_request =
      { agent_name = producer
      ; task_title = "t"
      ; task_description = "d"
      ; completion_notes = "n"
      ; task_id = "task-001"
      ; evidence_refs = []
      }
    in
    let render lookup =
      match AR.build_prompt ~lookup request with
      | Ok text -> text
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
      (Astring.String.is_infix ~affix:"tool_execute" without);
    Alcotest.(check bool)
      "tool prompt names the tools"
      true
      (Astring.String.is_infix ~affix:"tool_execute" with_tools);
    Alcotest.(check bool)
      "tool prompt does not deny having tools"
      false
      (Astring.String.is_infix
         ~affix:"You have no tool that opens anything else"
         with_tools);
    Alcotest.(check bool)
      "tool prompt does not promise the surface cannot change anything"
      false
      (Astring.String.is_infix ~affix:"cannot change anything" with_tools);
    Alcotest.(check bool)
      "tool prompt forbids repairing the work under review"
      true
      (Astring.String.is_infix ~affix:"do not repair what you are judging" with_tools))
;;

let () =
  Random.self_init ();
  Alcotest.run
    "verification authority tools"
    [ ( "surface"
      , [ Alcotest.test_case "schemas are the descriptor schemas" `Quick
            test_schemas_are_the_descriptor_schemas
        ; Alcotest.test_case
            "read translates the advertised argument and refuses a malformed one"
            `Quick
            test_read_translates_the_advertised_argument_and_refuses_a_malformed_one
        ; Alcotest.test_case "search refuses a call without its required pattern"
            `Quick test_search_refuses_a_call_without_its_required_pattern
        ; Alcotest.test_case "execute refuses argv that is not a process vector"
            `Quick test_execute_refuses_argv_that_is_not_a_process_vector
        ; Alcotest.test_case "unknown producer yields no surface" `Quick
            test_unknown_producer_yields_no_surface
        ] )
    ; ( "dispatch"
      , [ Alcotest.test_case "unknown tool name is an error" `Quick
            test_unknown_tool_name_is_an_error
        ] )
    ; ( "execution"
      , [ Alcotest.test_case "execute resolves inside the producer playground" `Quick
            test_execute_resolves_inside_the_producer_playground
        ; Alcotest.test_case "execute cannot escape the producer playground" `Quick
            test_execute_cannot_escape_the_producer_playground
        ; Alcotest.test_case "a failed run is an error, not empty output" `Quick
            test_a_failed_run_is_an_error_not_empty_output
        ] )
    ; ( "prompt"
      , [ Alcotest.test_case "prompt states the available surface" `Quick
            test_prompt_states_the_available_surface
        ] )
    ]
;;
