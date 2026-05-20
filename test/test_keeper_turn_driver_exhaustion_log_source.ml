(** Source guard for cascade exhaustion log severity.

    [require_tool_use] completion-contract violations are deterministic
    provider/model behavior and already have typed handling. They should remain
    visible, but not inflate the operator ERROR stream when every cascade tier
    returns the same contract violation. *)

open Alcotest

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let load_source rel =
  let path = Filename.concat (source_root ()) rel in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "source file not found: %s" path)
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> In_channel.input_all ic)

let contains ~needle haystack =
  let re = Str.regexp_string needle in
  try
    ignore (Str.search_forward re haystack 0);
    true
  with Not_found -> false

let count_occurrences ~needle haystack =
  let nlen = String.length needle in
  if nlen = 0 then 0
  else
    let re = Str.regexp_string needle in
    let rec loop pos acc =
      match Str.search_forward re haystack pos with
      | exception Not_found -> acc
      | _ ->
        let next = Str.match_end () in
        loop next (acc + 1)
    in
    loop 0 0

let window_around ~anchor ~before ~after haystack =
  let re = Str.regexp_string anchor in
  try
    let pos = Str.search_forward re haystack 0 in
    let start = max 0 (pos - before) in
    let limit = min (String.length haystack) (pos + String.length anchor + after) in
    Some (String.sub haystack start (limit - start))
  with Not_found -> None

let target = "lib/keeper/keeper_turn_driver.ml"

let test_completion_contract_exhaustion_is_warn () =
  let src = load_source target in
  let anchor = "log \"cascade %s exhausted: all tiers failed" in
  match window_around ~anchor ~before:260 ~after:120 src with
  | None -> fail "completion-contract severity branch missing"
  | Some block ->
    check bool "contract predicate guards exhaustion log" true
      (contains
         ~needle:"if sdk_error_is_required_tool_contract_violation sdk_err then"
         block);
    check bool "contract exhaustion uses warn" true
      (contains ~needle:"Log.Misc.warn" block);
    check bool "non-contract fallback remains error" true
      (contains ~needle:"else Log.Misc.error" block);
    check bool "guard applies to all-tiers-failed exhaustion log" true
      (contains
         ~needle:"log \"cascade %s exhausted: all tiers failed"
         block)

let test_no_unconditional_error_for_all_tiers_failed () =
  let src = load_source target in
  check int "all-tiers-failed cascade exhaustion is not unconditional ERROR" 0
    (count_occurrences
       ~needle:"Log.Misc.error \"cascade %s exhausted: all tiers failed"
       src)

let () =
  run "keeper_turn_driver_exhaustion_log_source"
    [ ( "completion-contract"
      , [ test_case "contract exhaustion logs warn" `Quick
            test_completion_contract_exhaustion_is_warn
        ; test_case "all-tiers-failed log is guarded" `Quick
            test_no_unconditional_error_for_all_tiers_failed
        ] )
    ]
