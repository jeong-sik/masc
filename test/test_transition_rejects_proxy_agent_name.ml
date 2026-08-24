(** [masc_transition] declares [agent_name] and transitions [ctx.agent_name].

    A caller naming someone else had its argument silently dropped, and the
    refusal it read back names the caller — so it looked like the caller's own
    state was in the way. taskmaster spent 34 recorded calls that way trying to
    claim for rondo, sangsu, analyst and lane-smith (#26847).

    The other 871 recorded calls name the caller itself, which is why the
    mismatch is refused rather than the parameter. *)

open Alcotest
module Tool = Masc.Task.Tool

let with_temp_workspace f =
  let path = Filename.temp_file "transition-proxy-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () ->
       let config = Masc.Workspace.default_config path in
       ignore (Masc.Workspace.init config ~agent_name:(Some "fixture"));
       f config)
;;

let transition config ~caller ~requested =
  let ctx : Tool.context = { config; agent_name = caller; sw = None } in
  let args =
    `Assoc
      [ ("task_id", `String "task-001")
      ; ("action", `String "claim")
      ; ("agent_name", `String requested)
      ]
  in
  Tool.handle_transition ~tool_name:"masc_transition" ~start_time:0.0 ctx args
;;

let message result = Tool_result.message result

let test_naming_another_agent_is_refused () =
  with_temp_workspace (fun config ->
    let result = transition config ~caller:"taskmaster" ~requested:"keeper-rondo-agent" in
    check
      bool
      "the refusal names the requested agent, not a task-state problem"
      true
      (String_util.contains_substring (message result) "keeper-rondo-agent");
    check
      bool
      "the refusal says the caller cannot act for another agent"
      true
      (String_util.contains_substring (message result) "calling agent only"))
;;

(* 871 of 905 recorded calls pass the caller's own name; refusing those would
   break every current caller to catch 34. *)
let test_naming_yourself_is_not_refused () =
  with_temp_workspace (fun config ->
    let result = transition config ~caller:"taskmaster" ~requested:"taskmaster" in
    check
      bool
      "naming yourself is not a proxy refusal"
      false
      (String_util.contains_substring (message result) "calling agent only"))
;;

(* "keeper-rondo-agent" and "rondo" are one actor; only the spelling differs. *)
let test_a_spelling_difference_is_not_a_proxy () =
  with_temp_workspace (fun config ->
    let result =
      transition config ~caller:"rondo" ~requested:"keeper-rondo-agent"
    in
    check
      bool
      "an alias of the caller is not a proxy refusal"
      false
      (String_util.contains_substring (message result) "calling agent only"))
;;

let () =
  run
    "transition-rejects-proxy-agent-name"
    [ ( "agent_name"
      , [ test_case "naming another agent is refused" `Quick
            test_naming_another_agent_is_refused
        ; test_case "naming yourself is not refused" `Quick
            test_naming_yourself_is_not_refused
        ; test_case "a spelling difference is not a proxy" `Quick
            test_a_spelling_difference_is_not_a_proxy
        ] )
    ]
;;
