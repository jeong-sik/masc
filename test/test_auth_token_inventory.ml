(* What `masc token prune` is allowed to delete.

   The dangerous direction is one-way: classifying a live credential as expired
   deletes a working bearer, while classifying an expired one as live leaves
   something that already authenticates nothing. These cases pin that asymmetry
   rather than the formatting. *)

open Alcotest
module Inv = Auth_token_inventory

let cred ?expires_at ?(role = Types_auth.Worker) name : Types_auth.agent_credential =
  { id = None
  ; agent_id = None
  ; agent_name = name
  ; token = "0000000000000000000000000000000000000000000000000000000000000000"
  ; role
  ; created_at = "2026-01-01T00:00:00Z"
  ; expires_at
  }

(* 2026-09-05T00:00:00Z, so the fixtures read as dates rather than epochs. *)
let now = 1788480000.

let test_no_expiry_is_never () =
  check bool "--no-expiry never expires" true
    (Inv.classify ~now (cred "worker") = Inv.Never)

let test_past_stamp_is_expired () =
  check bool "a passed stamp is expired" true
    (Inv.is_expired (Inv.classify ~now (cred ~expires_at:"2026-08-01T00:00:00Z" "old")))

let test_future_stamp_is_live () =
  check bool "a future stamp is live" false
    (Inv.is_expired (Inv.classify ~now (cred ~expires_at:"2027-01-01T00:00:00Z" "new")))

(* An expiry nothing can parse is not evidence the credential is dead. Reading
   it as dead would let a prune delete a bearer that still works. *)
let test_unreadable_stamp_is_not_expired () =
  check bool "unparseable expiry survives a prune" false
    (Inv.is_expired (Inv.classify ~now (cred ~expires_at:"whenever" "odd")))

let test_prune_takes_only_expired () =
  let creds =
    [ cred "never"
    ; cred ~expires_at:"2026-08-01T00:00:00Z" "expired-a"
    ; cred ~expires_at:"2027-01-01T00:00:00Z" "live"
    ; cred ~expires_at:"whenever" "unreadable"
    ; cred ~expires_at:"2026-07-01T00:00:00Z" "expired-b"
    ]
  in
  check (list string) "only the two passed stamps"
    [ "expired-a"; "expired-b" ]
    (Inv.expired ~now creds
     |> List.map (fun (c : Types_auth.agent_credential) -> c.agent_name))

(* Expired first, because that is the set an operator opens the listing for,
   and stable within each group so two runs agree. *)
let test_ordering_puts_expired_first () =
  let creds =
    [ cred "zeta"; cred ~expires_at:"2026-08-01T00:00:00Z" "omega"; cred "alpha" ]
  in
  check (list string) "expired, then by name"
    [ "omega"; "alpha"; "zeta" ]
    (Inv.ordered ~now creds
     |> List.map (fun (c : Types_auth.agent_credential) -> c.agent_name))

let test_row_reports_the_raw_secret_on_disk () =
  let c = cred ~role:Types_auth.Admin "ops" in
  let present = Inv.row ~now ~raw_present:true c in
  let absent = Inv.row ~now ~raw_present:false c in
  check bool "names the agent" true
    (Astring.String.is_infix ~affix:"ops" present);
  check bool "names the role" true
    (Astring.String.is_infix ~affix:"admin" present);
  check bool "says the secret is on disk" true
    (Astring.String.is_infix ~affix:"raw token on disk" present);
  check bool "says when it is not" true
    (Astring.String.is_infix ~affix:"no raw token file" absent)

let () =
  run "Auth token inventory"
    [ ( "classify"
      , [ test_case "no expiry is never" `Quick test_no_expiry_is_never
        ; test_case "past stamp is expired" `Quick test_past_stamp_is_expired
        ; test_case "future stamp is live" `Quick test_future_stamp_is_live
        ; test_case "unreadable stamp is not expired" `Quick
            test_unreadable_stamp_is_not_expired
        ] )
    ; ( "prune set"
      , [ test_case "takes only expired" `Quick test_prune_takes_only_expired
        ; test_case "ordering puts expired first" `Quick
            test_ordering_puts_expired_first
        ] )
    ; ( "row"
      , [ test_case "reports the raw secret on disk" `Quick
            test_row_reports_the_raw_secret_on_disk
        ] )
    ]
