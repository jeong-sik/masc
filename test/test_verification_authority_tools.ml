(* RFC-0361 D1: the completion authority runs the producer's own tools.

   The properties under test are the ones that decide whether a judge can be
   trusted with the surface: it offers exactly the keeper schemas rather than a
   restatement of them, every advertised name reaches an implementation, a
   producer with no meta yields no surface instead of one that fails on every
   call, and a failed run reaches the model as a failure rather than as output
   that could be mistaken for a clean result. *)

module Keeper_meta_store = Masc.Keeper_meta_store
module Tool_shard = Masc.Tool_shard
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

   [always_allow] is the producer's own Gate posture, and the judge borrows it
   with the meta — [Keeper_tool_execute_runtime] reads
   [meta.always_allow] and nothing else. It is set here because a deferred
   effect is not an answer: the judge is one review with no wake path, so a
   producer that defers gives it a dead end rather than a result. That is the
   real behaviour for a non-always-allow producer and it is stated in the
   surface docs; these cases exercise the branch where the effect runs. *)
let ensure_producer config name =
  match
    Result.bind
      (Masc_test_deps.meta_of_json_fixture
         (`Assoc [ "name", `String name; "always_allow", `Bool true ]))
      (Keeper_meta_store.write_meta config)
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

(* The judge and the producer must read one description of one tool. A schema
   restated here would drift from the catalog, and the copy is always the one
   that drifts. *)
let test_schemas_are_the_keeper_schemas () =
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
         match
           List.find_opt
             (fun (catalog : Masc_domain.tool_schema) ->
                String.equal catalog.name schema.name)
             Tool_shard.all_keeper_tool_schemas
         with
         | None ->
           Alcotest.failf "%s is not in the keeper catalog" schema.name
         | Some catalog ->
           Alcotest.(check string)
             (schema.name ^ " description is the catalog's")
             catalog.description
             schema.description)
      offered)
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

(* Every advertised schema must reach an implementation. Advertising a name
   dispatch does not know would put a tool in the model's list that always
   fails with "unknown tool". *)
let test_every_schema_name_dispatches () =
  with_surface (fun _config surface ->
    List.iter
      (fun (schema : Masc_domain.tool_schema) ->
         match VAT.dispatch surface ~name:schema.name ~args:(`Assoc []) with
         | Ok _ -> ()
         | Error detail ->
           Alcotest.(check bool)
             (Printf.sprintf "%s is not reported as unknown" schema.name)
             false
             (Astring.String.is_infix ~affix:"unknown tool" detail))
      (VAT.schemas surface))
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

(* A run that failed must not read like a run that produced nothing. Handing
   back [raw_output] on both paths would let a build that never started look
   like one with no findings — the exact shape that made task-136 approvable. *)
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

(* RFC-0361 D2. The prompt states what the evaluator can do, and the two
   surfaces are different claims. Rendering the toolless text for a
   tool-carrying review is the exact gap D1 exists to close, and the tool text
   must not repeat the read-only promise this surface no longer keeps. *)
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
      , [ Alcotest.test_case "schemas are the keeper schemas" `Quick
            test_schemas_are_the_keeper_schemas
        ; Alcotest.test_case "unknown producer yields no surface" `Quick
            test_unknown_producer_yields_no_surface
        ] )
    ; ( "dispatch"
      , [ Alcotest.test_case "unknown tool name is an error" `Quick
            test_unknown_tool_name_is_an_error
        ; Alcotest.test_case "every schema name dispatches" `Quick
            test_every_schema_name_dispatches
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
