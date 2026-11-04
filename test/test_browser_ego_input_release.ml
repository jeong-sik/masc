open Alcotest
open Masc
module Input = Browser_ego_input
let ok = function Ok value -> value | Error detail -> fail detail
let hold input ~command_id =
  ok (Input.within_command input ~command_id (fun () ->
    Input.begin_holding input ~scope:Input.Page_scope ~page_label:"p2")) |> ok
let no_windows = match Browser_ego_release.judge [0,Browser_ego_release.answer_of_json (`Assoc [])] with
  | Browser_ego_release.Settled (Browser_ego_release.Released proof) -> proof
  | Browser_ego_release.Settled Browser_ego_release.No_hold | Browser_ego_release.Unconfirmed _ -> fail "a clean receipt did not release"

(* An unconfirmed release is reported, and the next input still starts. *)
let unconfirmed_input_never_refuses_the_next () =
  let input = Input.create ~space_id:51 in
  check string "a new connection starts settled" "command_settled" (Input.readiness_wire input);
  let first = hold input ~command_id:"first" in
  check string "an input with no settlement is reported" "release_uncertain" (Input.readiness_wire input);
  check bool "the status names it" true (Input.status input = Input.Uncertain first);
  let second = hold input ~command_id:"second" in
  check bool "the next holding input starts anyway" true (Input.status input = Input.Uncertain second);
  ok (Input.not_started input ~generation:second.generation);
  check bool "an input that never started restores the earlier unconfirmed one" true
    (Input.status input = Input.Ready (Input.Release_uncertain first));
  check string "which is still reported" "release_uncertain" (Input.readiness_wire input);
  let third = hold input ~command_id:"third" in
  ok (Input.command_settled input ~generation:third.generation no_windows);
  check bool "a settled input reports settled" true (Input.status input = Input.Ready Input.Command_settled);
  check string "and says so" "command_settled" (Input.readiness_wire input)

let generations_are_exact () =
  let input = Input.create ~space_id:51 in
  let pending = hold input ~command_id:"original" in
  check bool "a stale generation cannot settle" true
    (Result.is_error (Input.command_settled input ~generation:"stale" no_windows));
  check bool "a stale generation cannot roll back" true
    (Result.is_error (Input.not_started input ~generation:"stale"));
  check bool "both leave the exact pending input" true (Input.status input = Input.Uncertain pending)

let commands_do_not_overlap () =
  let input = Input.create ~space_id:51 in
  check bool "holding needs its command scope" true
    (Result.is_error (Input.begin_holding input ~scope:Input.Page_scope ~page_label:"p1"));
  let nested = ok (Input.within_command input ~command_id:"outer" (fun () ->
    Input.within_command input ~command_id:"inner" (fun () -> ()))) in
  check bool "a second command on the same connection is refused" true (Result.is_error nested);
  check bool "the next command starts once the earlier one ended" true
    (Result.is_ok (Input.within_command input ~command_id:"after" (fun () -> ())))

let () = run "Ego input readiness" ["observation",[
  test_case "an unconfirmed input never refuses the next" `Quick unconfirmed_input_never_refuses_the_next;
  test_case "generations are exact" `Quick generations_are_exact;
  test_case "commands do not overlap" `Quick commands_do_not_overlap]]
