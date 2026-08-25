(** Turn cleanup has to run when the turn was cancelled.

    Since #15932 put the turn body inside [turn_sw], a cancelled turn cancels
    its own cleanup. [Keeper_registry.mark_turn_finished] writes the registry
    file, and an Eio call made under a cancelled context raises before writing,
    so the turn's [current_turn_observation] stays set and the keeper reads as
    mid-turn after its turn ended. The same shape lost sandbox containers in
    #30590; the inventory of the rest is #30619.

    What this suite pins is the wiring: that these three cleanups go through
    [Eio.Cancel.protect]. That [protect] actually carries an Eio call past a
    cancelled context is a behaviour, and it is pinned by
    [test_keeper_teardown_cancel_protect]. Constructing a live turn here to
    prove it a second time would test Eio, not this code.

    The check is AST-based rather than textual because a docstring naming the
    call would satisfy a substring search — that is what [Ast_grep] exists for
    (RFC-0085 PR-1). *)

open Alcotest

let unified_turn = "lib/keeper/keeper_unified_turn.ml"
let chat_turn = "lib/keeper/keeper_turn.ml"
let protect = "Eio.Cancel.protect"

let protects_in ~module_path ~binding_name =
  Ast_grep.count_calls_in_value_binding ~module_path ~binding_name ~callee:protect
;;

(* Both steps of the unified turn's cleanup reach durable state: one drops the
   event-bus subscription, the other freezes the turn observation. *)
let test_unified_turn_cleanup_is_protected () =
  let found = protects_in ~module_path:unified_turn ~binding_name:"cleanup" in
  check
    int
    "unified turn cleanup protects both unsubscribe and mark_turn_finished"
    2
    found
;;

let test_chat_turn_finish_is_protected () =
  let found = protects_in ~module_path:chat_turn ~binding_name:"finish" in
  check int "chat turn finish protects mark_turn_finished" 1 found
;;

(* The protection only helps if the failure is still reported. A silent
   [Cancelled] arm is what made the container leak invisible for 37 minutes:
   every other exception carried a counter and a WARN, and that one carried
   nothing.

   This is a substring check, and it can only fail in the safe direction — a
   comment naming the pattern makes the suite red rather than letting a real
   silent arm through. *)
let silent_arm = "Eio.Cancel.Cancelled _ -> ()"

let source_of path =
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat root path in
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> In_channel.input_all ic)
;;

let contains ~needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

let test_no_silent_cancelled_arm_remains () =
  List.iter
    (fun path ->
       check
         bool
         (path ^ " reports a cancelled cleanup instead of swallowing it")
         false
         (contains ~needle:silent_arm (source_of path)))
    [ unified_turn; chat_turn ]
;;

let () =
  run
    "keeper turn finish cancel protect"
    [ ( "turn cleanup"
      , [ test_case "unified turn cleanup is protected" `Quick test_unified_turn_cleanup_is_protected
        ; test_case "chat turn finish is protected" `Quick test_chat_turn_finish_is_protected
        ; test_case "no silent cancelled arm remains" `Quick test_no_silent_cancelled_arm_remains
        ] )
    ]
;;
