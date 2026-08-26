(** Every path mounted into a keeper container belongs to a store MASC writes.

    Keepers name absolute paths under [.masc] 1,593 times in a week, and the
    obvious repair is to mount what they reach for. Read frequency puts
    [official-clients/antigravity/<keeper>/] first at 396 reads -- the provider
    CLI's private HOME, holding its OAuth token and login keychain. Mounting by
    frequency would have handed those to every keeper container.

    Frequency is not priority. Provenance is.

    A content scan was tried instead and it cannot do this job. A Slack bot
    token and a task id have the same shape: [xoxb-1234-5678-abc] against
    [sk-342-verify-...]. A matcher loose enough to catch the token reported
    twelve task ids out of the live backlog; tightening the character class to
    silence those stopped it seeing Slack tokens at all, because those are
    hyphen-separated too. Neither length nor character class separates them, and
    a threshold tuned until today's data passes is a heuristic standing where a
    boundary belongs.

    So the assertion here is on provenance. Each mount carries a
    {!Masc.Keeper_sandbox_runtime_setup.mount_warrant} naming the store it comes
    from, and the match below is exhaustive: a new variant stops this file
    compiling until someone writes down what it holds. That is the gate --
    [traces/] writes authorization headers out verbatim and is not board, task
    or goal state, so it cannot arrive as one more line in a list of paths. *)

open Alcotest
module Setup = Masc.Keeper_sandbox_runtime_setup

(* Exhaustive on purpose. Adding a warrant breaks compilation here, which is the
   whole reason the warrant is a closed sum rather than a string. *)
let what_it_holds : Setup.mount_warrant -> string = function
  | Setup.Board_store -> "posts, comments, votes and reactions the board writes"
  | Setup.Task_store -> "the task list, its backlog, and the current claim"
  | Setup.Goal_store -> "goals and the events that move them"
;;

let test_every_warrant_says_what_it_holds () =
  List.iter
    (fun warrant ->
       check
         bool
         (Printf.sprintf "%s is described" (Setup.mount_warrant_to_string warrant))
         true
         (String.length (what_it_holds warrant) > 0))
    [ Setup.Board_store; Setup.Task_store; Setup.Goal_store ]
;;

(* Every mount is warranted, and the warrant matches the file it covers. The
   pairing is what a reviewer reads: a board file under [Task_store] would mean
   the list drifted from the stores it claims to project. *)
let test_mounts_are_warranted () =
  let expected_prefix = function
    | Setup.Board_store -> "board_"
    | Setup.Task_store -> ""
    | Setup.Goal_store -> "goal"
  in
  let starts_with prefix text =
    String.length text >= String.length prefix
    && String.sub text 0 (String.length prefix) = prefix
  in
  check
    bool
    "there are mounts to check"
    true
    (Setup.docker_workspace_state_mounts <> []);
  List.iter
    (fun (warrant, _kind, rel_path) ->
       check
         bool
         (Printf.sprintf
            "%s is %s (%s)"
            rel_path
            (Setup.mount_warrant_to_string warrant)
            (what_it_holds warrant))
         true
         (starts_with (expected_prefix warrant) rel_path))
    Setup.docker_workspace_state_mounts
;;

(* The stores a keeper is given, and nothing beside them. These four subtrees
   are the measured read demand that is deliberately refused; naming them here
   is what keeps the refusal a decision rather than an omission. *)
let refused =
  [ "official-clients", "the provider CLI's private HOME: OAuth token, keychain"
  ; "traces", "writes authorization headers verbatim"
  ; "tool_blobs", "arbitrary tool payloads, no schema MASC owns"
  ; "logs", "flat and shared, so no per-keeper boundary exists"
  ]
;;

let test_refused_subtrees_are_not_mounted () =
  List.iter
    (fun (subtree, reason) ->
       List.iter
         (fun (_warrant, _kind, rel_path) ->
            check
              bool
              (Printf.sprintf "%s stays out (%s)" subtree reason)
              false
              (String.equal rel_path subtree))
         Setup.docker_workspace_state_mounts)
    refused
;;

let () =
  run
    "keeper sandbox mount warrant"
    [ ( "provenance"
      , [ test_case
            "every warrant says what it holds"
            `Quick
            test_every_warrant_says_what_it_holds
        ; test_case "mounts are warranted" `Quick test_mounts_are_warranted
        ; test_case
            "refused subtrees are not mounted"
            `Quick
            test_refused_subtrees_are_not_mounted
        ] )
    ]
;;
