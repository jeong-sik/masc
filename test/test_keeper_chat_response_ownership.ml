open Alcotest

module Ownership = Masc.Keeper_chat_response_ownership
module Events = Masc.Keeper_chat_events

let observed generation scope =
  Events.Observed_response {response_generation=generation; response_scope=scope}

let admitted = function
  | Ownership.Admitted next -> next
  | Preserved_unobserved _ | Stale -> fail "expected an admitted response"

let preserved = function
  | Ownership.Preserved_unobserved next -> next
  | Admitted _ | Stale -> fail "expected unobserved response bytes"

let test_values_keep_their_own_response_frontier () =
  let initial = Ownership.create () in
  let first = Ownership.admit initial (observed 1 2) |> admitted in
  let newer = Ownership.admit first (observed 1 4) |> admitted in
  let from_first = Ownership.admit first (observed 1 3) in
  let from_newer = Ownership.admit newer (observed 1 3) in
  check bool "earlier value keeps its own frontier" true
    (match from_first with Ownership.Admitted _ -> true | Preserved_unobserved _ | Stale -> false);
  check bool "newer value rejects an older owner" true (from_newer = Ownership.Stale);
  let from_initial = Ownership.admit initial (observed 0 0) in
  check bool "initial value was not mutated" true
    (match from_initial with Ownership.Admitted _ -> true | Preserved_unobserved _ | Stale -> false)

let test_unobserved_scope_and_attempt_retirement () =
  let owned = Ownership.admit (Ownership.create ()) (observed 2 4) |> admitted in
  let awaiting = Ownership.admit owned (Events.Unobserved_scope (Some 6)) |> preserved in
  let awaiting = Ownership.admit awaiting (Events.Unobserved_scope None) |> preserved in
  let old_scope = Ownership.admit awaiting (observed 2 5) in
  check bool "an older observed scope is refused" true (old_scope = Ownership.Stale);
  let current = Ownership.admit awaiting (observed 2 6) |> admitted in
  let retired = Ownership.retire_attempt current in
  let previous = Ownership.admit retired (observed 2 6) in
  let next = Ownership.admit retired (observed 3 0) in
  let still_current = Ownership.admit current (observed 2 6) in
  check bool "retired response cannot append" true (previous = Ownership.Stale);
  check bool "new attempt can append" true
    (match next with Ownership.Admitted _ -> true | Preserved_unobserved _ | Stale -> false);
  check bool "retirement leaves the old value intact" true
    (match still_current with Ownership.Admitted _ -> true | Preserved_unobserved _ | Stale -> false)

let () =
  run "keeper_chat_response_ownership"
    [ "ownership", [
        test_case "values keep their own frontier" `Quick test_values_keep_their_own_response_frontier;
        test_case "unobserved scope and retirement" `Quick test_unobserved_scope_and_attempt_retirement;
      ] ]
