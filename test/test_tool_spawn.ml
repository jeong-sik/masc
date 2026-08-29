(** RFC spawn-a-process-that-outlives-the-call §3.6: the tool surface.

    [Spawn_registry] is tested on its own. What is asserted here is the part a
    caller sees -- the shape of each answer, and that a failure says what to do
    next rather than only that something went wrong. *)

module Spawn = Tool_spawn

let with_eio f =
  Eio_main.run
  @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()
;;

(* Larger than anything these tests produce. *)
let ample_bytes = 1 lsl 16

(* Long enough that reaching it means something is wrong. Nothing waits for it. *)
let generous_bound_sec = 30.

let context ~sw =
  match Spawn_registry.create ~run:"tool-test" ~output_limit_bytes:ample_bytes with
  | Some registry -> { Spawn.registry; sw }
  | None -> Alcotest.fail "the registry arguments must be accepted"
;;

let call ctx ~name args =
  match Spawn.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> Alcotest.failf "%s must be dispatched here" name
;;

let data_of result = Tool_result.data result

let field result key =
  match Yojson.Safe.Util.member key (data_of result) with
  | `Null -> Alcotest.failf "the answer has no %s: %s" key (Yojson.Safe.to_string (data_of result))
  | value -> value
;;

let string_field result key =
  match field result key with
  | `String value -> value
  | other -> Alcotest.failf "%s must be a string, got %s" key (Yojson.Safe.to_string other)
;;

let spawn_handle ctx argv =
  let result =
    call ctx ~name:"keeper_spawn"
      (`Assoc [ "argv", `List (List.map (fun a -> `String a) argv) ])
  in
  Alcotest.(check string) "a spawn is running" "running" (string_field result "status");
  string_field result "handle"
;;

let test_a_spawn_answers_with_a_handle_and_the_output_follows () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  let handle = spawn_handle ctx [ "printf"; "hello" ] in
  let waited =
    call ctx ~name:"keeper_spawn_wait"
      (`Assoc
          [ "handle", `String handle
          ; "until", `String "exit"
          ; "timeout_sec", `Float generous_bound_sec
          ])
  in
  Alcotest.(check string) "it exited" "exited" (string_field waited "status");
  let read =
    call ctx ~name:"keeper_spawn_read" (`Assoc [ "handle", `String handle ])
  in
  Alcotest.(check string) "the output is there" "hello" (string_field read "bytes")
;;

let test_a_bound_that_is_reached_says_so_and_keeps_the_handle () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  let handle = spawn_handle ctx [ "sleep"; "60" ] in
  let waited =
    call ctx ~name:"keeper_spawn_wait"
      (`Assoc
          [ "handle", `String handle
          ; "until", `String "exit"
          ; "timeout_sec", `Float 0.05
          ])
  in
  (* Not an error: the process is still there, and the answer hands the handle
     back so a caller can read it or wait again with a longer bound. *)
  Alcotest.(check string) "the bound is reported" "timed_out" (string_field waited "status");
  Alcotest.(check string) "and the handle comes back" handle (string_field waited "handle");
  ignore (call ctx ~name:"keeper_spawn_stop" (`Assoc [ "handle", `String handle ]))
;;

let test_a_wait_ends_when_the_program_speaks () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  let handle = spawn_handle ctx [ "sh"; "-c"; "printf ready; exec sleep 60" ] in
  let waited =
    call ctx ~name:"keeper_spawn_wait"
      (`Assoc
          [ "handle", `String handle
          ; "until", `String "output_contains"
          ; "needle", `String "ready"
          ; "timeout_sec", `Float generous_bound_sec
          ])
  in
  Alcotest.(check string) "it matched" "matched" (string_field waited "status");
  ignore (call ctx ~name:"keeper_spawn_stop" (`Assoc [ "handle", `String handle ]))
;;

(* --- what a caller gets wrong --- *)

let error_message result =
  match Yojson.Safe.Util.member "message" (data_of result) with
  | `String message -> message
  | _ -> Alcotest.failf "a refusal must carry a message: %s" (Yojson.Safe.to_string (data_of result))
;;

let test_a_handle_that_names_nothing_says_what_to_do () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  let result =
    call ctx ~name:"keeper_spawn_read" (`Assoc [ "handle", `String "other-run-1" ])
  in
  let message = error_message result in
  (* "It failed" leaves a caller retrying the same call. Naming the next move
     is the difference. *)
  Alcotest.(check bool)
    ("the message names spawning again -- got: " ^ message)
    true
    (Astring.String.is_infix ~affix:"spawn again" message)
;;

let test_text_that_is_not_a_handle_is_named_as_such () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  let message =
    error_message (call ctx ~name:"keeper_spawn_stop" (`Assoc [ "handle", `String "nonsense" ]))
  in
  Alcotest.(check bool)
    ("a malformed handle is not a missing process -- got: " ^ message)
    true
    (Astring.String.is_infix ~affix:"is not a handle" message)
;;

let test_argv_must_be_strings () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  let message =
    error_message
      (call ctx ~name:"keeper_spawn" (`Assoc [ "argv", `List [ `String "echo"; `Int 3 ] ]))
  in
  (* Dropping the 3 and running [echo] would be a different command than the
     caller wrote. *)
  Alcotest.(check bool)
    ("the entry is named -- got: " ^ message)
    true
    (Astring.String.is_infix ~affix:"must be a string" message)
;;

let test_output_contains_needs_its_needle () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  let handle = spawn_handle ctx [ "sleep"; "60" ] in
  let message =
    error_message
      (call ctx ~name:"keeper_spawn_wait"
         (`Assoc
             [ "handle", `String handle
             ; "until", `String "output_contains"
             ; "timeout_sec", `Float generous_bound_sec
             ]))
  in
  Alcotest.(check bool)
    ("the missing field is named -- got: " ^ message)
    true
    (Astring.String.is_infix ~affix:"needle" message);
  ignore (call ctx ~name:"keeper_spawn_stop" (`Assoc [ "handle", `String handle ]))
;;

let test_another_tool_is_not_this_one () =
  with_eio
  @@ fun () ->
  Eio.Switch.run
  @@ fun sw ->
  let ctx = context ~sw in
  Alcotest.(check bool)
    "dispatch answers None for a name it does not own"
    true
    (Option.is_none (Spawn.dispatch ctx ~name:"masc_schedule_list" ~args:(`Assoc [])))
;;

(* --- the surface a keeper is actually offered --- *)

(* Measured rather than assumed: the four are in the descriptor list a keeper
   model is shown, not only in the schema module that declares them. Three
   times in one session a thing was built, tested, and never registered --
   green the whole way, and doing nothing. This is the assertion that would
   have caught it. *)
let test_a_keeper_is_offered_all_four () =
  let module TD = Masc.Keeper_tool_descriptor in
  let offered =
    List.map (fun d -> d.TD.internal_name) (TD.model_visible_descriptors ())
  in
  List.iter
    (fun name ->
       Alcotest.(check bool)
         ("a keeper is offered " ^ name)
         true
         (List.exists (String.equal name) offered))
    [ "keeper_spawn"; "keeper_spawn_read"; "keeper_spawn_wait"; "keeper_spawn_stop" ]
;;

(* The descriptor list above is what the registry says it will offer. This one
   pins [expected_model_tool_names], which folds descriptors, skills, and
   compositions into a list of names.

   That list is not the set a turn opens with. It is one side of a comparison
   in [keeper_run_tools_setup.ml]: the other side is [all_tool_names], built
   from the bundle the turn actually carries, and a disagreement writes one
   error line and lets the turn run on. So a tool can go missing from a live
   Keeper with this suite green -- what is pinned here is only that the four
   survive the descriptor-to-name fold.

   Pinning that half is still worth doing, because #30294 lost the four on
   this side while the declaration suite above stayed green. Asserting the
   other half needs a different test over [all_tool_names], and the fact that
   a mismatch is only logged is worth its own look.

   The empty catalog is the tight case rather than a shortcut: the four come
   from [descriptor_names], and a catalog only appends composition and async
   control names on top. Surviving the fold with nothing to append means
   surviving it with anything to append. *)
let test_the_boot_projection_keeps_all_four () =
  let module TD = Masc.Keeper_tool_descriptor in
  let empty_catalog = Masc.Keeper_skill_catalog.empty in
  let projected =
    Masc.Keeper_run_tools_setup.expected_model_tool_names
        ~identity_index_names:[]
      ~skill_catalog:empty_catalog
      ~model_visible_descriptors:(TD.model_visible_descriptors ())
      ()
  in
  List.iter
    (fun name ->
       Alcotest.(check bool)
         ("the boot projection keeps " ^ name)
         true
         (List.exists (String.equal name) projected))
    [ "keeper_spawn"; "keeper_spawn_read"; "keeper_spawn_wait"; "keeper_spawn_stop" ]
;;

let () =
  Alcotest.run
    "tool_spawn"
    [ ( "answers"
      , [ Alcotest.test_case
            "a spawn answers with a handle and the output follows"
            `Quick
            test_a_spawn_answers_with_a_handle_and_the_output_follows
        ; Alcotest.test_case
            "a bound that is reached says so and keeps the handle"
            `Quick
            test_a_bound_that_is_reached_says_so_and_keeps_the_handle
        ; Alcotest.test_case
            "a wait ends when the program speaks"
            `Quick
            test_a_wait_ends_when_the_program_speaks
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case
            "a handle that names nothing says what to do"
            `Quick
            test_a_handle_that_names_nothing_says_what_to_do
        ; Alcotest.test_case
            "text that is not a handle is named as such"
            `Quick
            test_text_that_is_not_a_handle_is_named_as_such
        ; Alcotest.test_case "argv must be strings" `Quick test_argv_must_be_strings
        ; Alcotest.test_case
            "output_contains needs its needle"
            `Quick
            test_output_contains_needs_its_needle
        ; Alcotest.test_case
            "another tool is not this one"
            `Quick
            test_another_tool_is_not_this_one
        ] )
    ; ( "surface"
      , [ Alcotest.test_case
            "a keeper is offered all four"
            `Quick
            test_a_keeper_is_offered_all_four
        ; Alcotest.test_case
            "the boot projection keeps all four"
            `Quick
            test_the_boot_projection_keeps_all_four
        ] )
    ]
;;
