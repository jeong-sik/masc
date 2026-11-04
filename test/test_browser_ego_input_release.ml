open Alcotest
open Masc
module Input = Browser_ego_input
let ok = function Ok value -> value | Error detail -> fail detail
let hold input ~command_id ~now =
  ok (Input.within_command input ~command_id (fun () ->
    Input.begin_holding input ~now ~scope:Input.Page_scope ~tab_id:4 ~page_label:"p2" ~operation:"target_click")) |> ok
let no_windows = match Browser_ego_release.judge [0,Browser_ego_release.answer_of_json (`Assoc [])] with
  | Browser_ego_release.Settled (Browser_ego_release.Released proof) -> proof
  | Browser_ego_release.Settled Browser_ego_release.No_hold | Browser_ego_release.Unconfirmed _ -> fail "a clean receipt did not release"

(* An unconfirmed release is reported, and the next input still starts. *)
let unconfirmed_input_never_refuses_the_next () =
  let input = Input.create ~space_id:51 in
  check string "a new connection starts settled" "command_settled" (Input.provenance input);
  let first = hold input ~command_id:"first" ~now:100. in
  check string "an input with no settlement is reported" "release_uncertain" (Input.provenance input);
  check bool "the status names it" true (Input.status input = Input.Uncertain first);
  let second = hold input ~command_id:"second" ~now:200. in
  check bool "the next holding input starts anyway" true (Input.status input = Input.Uncertain second);
  ok (Input.not_started input ~generation:second.generation);
  check bool "an input that never started restores the earlier unconfirmed one" true
    (Input.status input = Input.Ready (Input.Release_uncertain first));
  check string "which is still reported" "release_uncertain" (Input.provenance input);
  let third = hold input ~command_id:"third" ~now:300. in
  ok (Input.command_settled input ~generation:third.generation no_windows);
  check bool "a settled input reports settled" true (Input.status input = Input.Ready Input.Command_settled);
  check string "and says so" "command_settled" (Input.provenance input)

let generations_are_exact () =
  let input = Input.create ~space_id:51 in
  let pending = hold input ~command_id:"original" ~now:100. in
  check bool "a stale generation cannot settle" true
    (Result.is_error (Input.command_settled input ~generation:"stale" no_windows));
  check bool "a stale generation cannot roll back" true
    (Result.is_error (Input.not_started input ~generation:"stale"));
  check bool "both leave the exact pending input" true (Input.status input = Input.Uncertain pending);
  check bool "it carries when it was taken" true (pending.held_at = 100.)

let commands_do_not_overlap () =
  let input = Input.create ~space_id:51 in
  check bool "holding needs its command scope" true
    (Result.is_error (Input.begin_holding input ~now:1. ~scope:Input.Page_scope ~tab_id:1 ~page_label:"p1" ~operation:"x"));
  let nested = ok (Input.within_command input ~command_id:"outer" (fun () ->
    Input.within_command input ~command_id:"inner" (fun () -> ()))) in
  check bool "a second command on the same connection is refused" true (Result.is_error nested);
  check bool "the running marker is released afterwards" false (Input.busy input)

let () = run "Ego input readiness" ["observation",[
  test_case "an unconfirmed input never refuses the next" `Quick unconfirmed_input_never_refuses_the_next;
  test_case "generations are exact" `Quick generations_are_exact;
  test_case "commands do not overlap" `Quick commands_do_not_overlap]]
