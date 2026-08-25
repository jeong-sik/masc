(** The assertion-kind mirror, compared against its owner.

    [Tool_schemas_workspace_core] lives in masc_tool_schemas and the handler
    lives in masc, so the schema library cannot reach the owner and hand-copies
    the vocabulary:

      let assertion_kind_enum_strings = [ "task_claimed"; "current_task_set" ]

    Its header says [test_types.ml :: assertion_kind_ssot] keeps that in sync.
    There is no test_types.ml. Adding a kind breaks compilation in
    [assertion_kind_to_string], which forces the owner's list to grow, and
    nothing then makes the copy grow with it — [masc_check] would keep
    advertising the old set while the handler accepted the new one.

    The copy is a plain list in another library, so this compares the
    observable end: the [enum] array [masc_check] publishes, against
    [Workspace_assertions.valid_assertion_strings]. *)

open Alcotest

(* Every enum array anywhere in a schema, at any nesting depth. The assertion
   enum sits under items of an array property, not at the top level. *)
let rec enum_arrays (json : Yojson.Safe.t) : string list list =
  match json with
  | `Assoc fields ->
    List.concat_map
      (fun (key, value) ->
        match key, value with
        | "enum", `List items ->
          let strings =
            List.filter_map (function `String s -> Some s | _ -> None) items
          in
          if strings = [] then [] else [ strings ]
        | _ -> enum_arrays value)
      fields
  | `List items -> List.concat_map enum_arrays items
  | _ -> []
;;

let check_schema () =
  match
    List.find_opt
      (fun (t : Masc_domain.tool_schema) -> String.equal t.name "masc_check")
      Tool_schemas_workspace_core.schemas
  with
  | Some schema -> schema
  | None -> failf "masc_check is not among Tool_schemas_workspace_core.schemas"
;;

let owner = Masc.Workspace_assertions.valid_assertion_strings

(* A guard that finds no enum passes for the wrong reason. *)
let test_schema_publishes_an_enum () =
  let enums = enum_arrays (check_schema ()).input_schema in
  check bool "masc_check publishes at least one enum" true (enums <> []);
  check bool "the owner list is non-empty" true (owner <> [])
;;

let test_published_enum_matches_the_owner () =
  let enums = enum_arrays (check_schema ()).input_schema in
  if not (List.exists (fun e -> e = owner) enums)
  then
    failf
      "no enum in masc_check equals Workspace_assertions.valid_assertion_strings \
       (%s).\n\
       The hand-copied assertion_kind_enum_strings has drifted.\n\
       Published enums: %s"
      (String.concat "|" owner)
      (String.concat "  /  " (List.map (String.concat "|") enums))
;;

(* Every advertised kind must be one the handler's parser recognises, so a copy
   that grows a value the handler rejects fails here too. *)
let test_every_advertised_kind_parses () =
  List.iter
    (fun kind ->
      match Masc.Workspace_assertions.assertion_kind_of_string_lenient kind with
      | Some _ -> ()
      | None -> failf "advertised assertion %S is not one the handler accepts" kind)
    owner
;;


(* ── masc_check argument parsing ──────────────────────────────────────

   [handle_check] reads an optional [assertions: [<string>...]] array. The
   parse used [List.filter_map] over the items, so an element that was not a
   JSON string was discarded before it reached [check_assertion] and never
   appeared in the response. [all_passed] was then computed over the
   survivors, which is the answer to a narrower question than the caller
   asked.

   [check_assertion] already has the right shape for input it does not
   understand: an unrecognised *name* comes back with [passed = false] plus
   [expected_assertions]. These pin the same treatment for an element of the
   wrong *type*. *)

let temp_dir_seq = ref 0

let temp_dir () =
  incr temp_dir_seq;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-assert-%d-%d" (Unix.getpid ()) !temp_dir_seq)
  in
  Unix.mkdir dir 0o700;
  dir

let with_ctx f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir dir with Unix.Unix_error _ -> ())
    (fun () ->
      let config = Masc.Workspace.default_config dir in
      f { Masc.Workspace_types.config; agent_name = "test-agent" })

let state_all_true : Masc.Workspace_assertions.agent_state =
  { task_claimed = true; current_task_set = true }

let check_with args =
  with_ctx (fun ctx ->
    let result =
      Masc.Workspace_assertions.handle_check
        ~inspect_state:(fun _ -> state_all_true)
        ~tool_name:"masc_check" ~start_time:0.0 ctx args
    in
    Yojson.Safe.from_string (Tool_result.message result))

let reported_assertions json =
  match Yojson.Safe.Util.member "assertions" json with
  | `List items ->
    List.map
      (fun item -> Yojson.Safe.Util.(member "assertion" item |> to_string))
      items
  | _ -> []

let all_passed json =
  match Yojson.Safe.Util.member "all_passed" json with
  | `Bool b -> b
  | _ -> failwith "all_passed missing"

let test_non_string_element_is_reported () =
  let json =
    check_with
      (`Assoc [ "assertions", `List [ `String "task_claimed"; `Int 42 ] ])
  in
  check int "both elements are accounted for" 2
    (List.length (reported_assertions json));
  check bool "an element it could not read cannot pass" false (all_passed json)

let test_only_non_string_elements_do_not_become_defaults () =
  let json = check_with (`Assoc [ "assertions", `List [ `Int 42 ] ]) in
  check int "the one element the caller sent is the one reported" 1
    (List.length (reported_assertions json));
  check bool "not silently answered with the defaults" false (all_passed json)

let () =
  Alcotest.run
    "Assertion kind mirror"
    [ ( "mirror"
      , [ test_case "the schema publishes an enum" `Quick test_schema_publishes_an_enum
        ; test_case "the published enum matches the owner" `Quick
            test_published_enum_matches_the_owner
        ; test_case "every advertised kind parses" `Quick
            test_every_advertised_kind_parses
        ] )
    ; ( "argument parsing"
      , [ test_case "a non-string element is reported, not dropped" `Quick
            test_non_string_element_is_reported
        ; test_case "unreadable elements do not become the defaults" `Quick
            test_only_non_string_elements_do_not_become_defaults
        ] )
    ]
;;
