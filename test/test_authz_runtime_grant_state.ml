(* The grants that the Runtime grant records add up to: that an id names one
   grant for good, and what the queries answer over the grants a log holds. No
   files, clock, or network. *)

open Authz_types
open Authz_records
module G = Authz_runtime_grant_state

let get = function
  | Ok value -> value
  | Error _ -> Alcotest.fail "fixture id rejected by Authz_id"
;;

let grant_id text = get (Grant_id.of_string text)
let runtime_id text = get (Runtime_id.of_string text)
let human text = Principal.Human (get (User_id.of_string text))
let alice = human "alice"
let bob = human "bob"

let grant
      ?(id = "grant-1")
      ?(runtime = "runtime-1")
      ?(grantee = alice)
      ?(effects = [ Effect.Read_state ])
      ?(status = Grant_status.Active)
      ?(kind = Runtime_grant.Self)
      ()
  =
  { Runtime_grant.id = grant_id id
  ; runtime_id = runtime_id runtime
  ; grantee
  ; allowed_effects = Effect.Set.of_list effects
  ; status
  ; kind
  }
;;

let add_ok t grant =
  match G.add t grant with
  | Ok t -> t
  | Error refusal -> Alcotest.failf "refused: %s" (G.refusal_to_string refusal)
;;

let check_refused label t grant expected =
  match G.add t grant with
  | Ok _ -> Alcotest.failf "%s: the grant was taken" label
  | Error refusal -> Alcotest.(check string) label expected (G.refusal_to_string refusal)
;;

let ids pairs = List.map (fun (id, _) -> Grant_id.to_string id) pairs

let check_ids label pairs expected =
  Alcotest.(check (list string)) label expected (ids pairs)
;;

let effects_text set = String.concat "," (List.map Effect.to_string (Effect.Set.elements set))

let kind_text = function
  | Runtime_grant.Self -> "self"
  | Runtime_grant.Delegated { expires_at = None } -> "delegated"
  | Runtime_grant.Delegated { expires_at = Some deadline } ->
    Printf.sprintf "delegated until %g" deadline
;;

let status_text = function
  | Grant_status.Active -> "active"
  | Grant_status.Revoked -> "revoked"
  | Grant_status.Purged -> "purged"
;;

let grant_text (grant : Runtime_grant.t) =
  Printf.sprintf
    "%s of %s to %s %s %s [%s]"
    (Grant_id.to_string grant.id)
    (Runtime_id.to_string grant.runtime_id)
    (Principal.to_string grant.grantee)
    (status_text grant.status)
    (kind_text grant.kind)
    (effects_text grant.allowed_effects)
;;

let find_text t id =
  match G.find t (grant_id id) with
  | None -> "none"
  | Some grant -> grant_text grant
;;

let check_found label t id expected =
  Alcotest.(check string) label expected (find_text t id)
;;

let test_empty () =
  let t = G.empty in
  check_found "no grant" t "grant-1" "none";
  Alcotest.(check bool) "no id" false (G.mem t (grant_id "grant-1"));
  check_ids "no grant of a runtime" (G.of_runtime t (runtime_id "runtime-1")) [];
  check_ids "no grant of a principal" (G.of_grantee t alice) []
;;

let test_found_as_recorded () =
  let t =
    add_ok
      G.empty
      (grant
         ~effects:[ Effect.Read_state; Effect.Use_tool ]
         ~kind:(Runtime_grant.Delegated { expires_at = Some 1750. })
         ~status:Grant_status.Revoked
         ())
  in
  Alcotest.(check bool) "named" true (G.mem t (grant_id "grant-1"));
  check_found
    "as recorded"
    t
    "grant-1"
    "grant-1 of runtime-1 to human:alice revoked delegated until 1750 [read_state,use_tool]"
;;

let test_one_id_one_grant () =
  let t = add_ok G.empty (grant ()) in
  check_refused
    "named before"
    t
    (grant ~grantee:bob ())
    "the grant grant-1 was named before";
  (* The refusal left the grant the log has. *)
  check_found "unchanged" t "grant-1" "grant-1 of runtime-1 to human:alice active self [read_state]"
;;

let test_of_runtime_in_id_order () =
  let t =
    G.empty
    |> fun t -> add_ok t (grant ~id:"grant-2" ())
    |> fun t -> add_ok t (grant ~id:"grant-1" ())
    |> fun t -> add_ok t (grant ~id:"grant-3" ~runtime:"runtime-2" ())
  in
  (* The log named grant-2 first, so that is the order of its grants: an id is
     an arbitrary safe string and does not sort by time. *)
  check_ids "runtime-1" (G.of_runtime t (runtime_id "runtime-1")) [ "grant-2"; "grant-1" ];
  check_ids "runtime-2" (G.of_runtime t (runtime_id "runtime-2")) [ "grant-3" ];
  check_ids "no such runtime" (G.of_runtime t (runtime_id "runtime-3")) []
;;

let test_of_grantee () =
  let t =
    G.empty
    |> fun t -> add_ok t (grant ~id:"grant-1" ())
    |> fun t -> add_ok t (grant ~id:"grant-2" ~grantee:bob ())
    |> fun t ->
    add_ok t (grant ~id:"grant-3" ~grantee:(Principal.Service (get (Service_id.of_string "ci"))) ())
  in
  check_ids "alice" (G.of_grantee t alice) [ "grant-1" ];
  check_ids "bob" (G.of_grantee t bob) [ "grant-2" ];
  check_ids
    "a service holds none of a person's"
    (G.of_grantee t (Principal.Service (get (Service_id.of_string "ci"))))
    [ "grant-3" ]
;;

let test_find_for_pair () =
  let t =
    G.empty
    |> fun t -> add_ok t (grant ~id:"grant-1" ())
    |> fun t -> add_ok t (grant ~id:"grant-2" ~grantee:bob ())
    |> fun t -> add_ok t (grant ~id:"grant-3" ~runtime:"runtime-2" ())
  in
  let found t ~grantee ~runtime =
    G.find_for t ~grantee ~runtime_id:(runtime_id runtime)
    |> Option.map (fun grant -> Grant_id.to_string grant.Runtime_grant.id)
  in
  Alcotest.(check (option string)) "alice on runtime-1" (Some "grant-1")
    (found t ~grantee:alice ~runtime:"runtime-1");
  Alcotest.(check (option string)) "bob on runtime-1" (Some "grant-2")
    (found t ~grantee:bob ~runtime:"runtime-1");
  Alcotest.(check (option string)) "alice on runtime-2" (Some "grant-3")
    (found t ~grantee:alice ~runtime:"runtime-2");
  Alcotest.(check (option string)) "bob on runtime-2 is absent" None
    (found t ~grantee:bob ~runtime:"runtime-2");
  (* A pair the log named twice reads as the id it named last. *)
  let twice = add_ok t (grant ~id:"grant-4" ()) in
  Alcotest.(check (option string)) "the last id the log named wins" (Some "grant-4")
    (found twice ~grantee:alice ~runtime:"runtime-1")
;;

(* A newer record that closed the pair does not hide the grant that is still
   live, and the live one is answered even when its id sorts first. *)
let test_find_for_prefers_the_live_grant () =
  let t =
    G.empty
    |> fun t -> add_ok t (grant ~id:"grant-a" ())
    |> fun t -> add_ok t (grant ~id:"grant-z" ~status:Grant_status.Revoked ())
  in
  let found t =
    G.find_for t ~grantee:alice ~runtime_id:(runtime_id "runtime-1")
    |> Option.map (fun grant -> Grant_id.to_string grant.Runtime_grant.id)
  in
  Alcotest.(check (option string)) "the live grant, not the newer revoked one" (Some "grant-a")
    (found t);
  (* With nothing live, the last record the log named is answered. *)
  let closed =
    G.empty
    |> fun t -> add_ok t (grant ~id:"grant-a" ~status:Grant_status.Revoked ())
    |> fun t -> add_ok t (grant ~id:"grant-b" ~status:Grant_status.Purged ())
  in
  Alcotest.(check (option string)) "the last record of a closed pair" (Some "grant-b")
    (found closed)
;;

let () =
  Alcotest.run
    "authz_runtime_grant_state"
    [ ( "grant state"
      , [ Alcotest.test_case "an empty state holds no grant" `Quick test_empty
        ; Alcotest.test_case "a grant is found as its record says" `Quick test_found_as_recorded
        ; Alcotest.test_case "an id names one grant for good" `Quick test_one_id_one_grant
        ; Alcotest.test_case "the grants of a runtime follow their ids" `Quick test_of_runtime_in_id_order
        ; Alcotest.test_case "the grants of a principal" `Quick test_of_grantee
        ; Alcotest.test_case "the grant of one principal on one runtime" `Quick
            test_find_for_pair
        ; Alcotest.test_case "the live grant is answered first" `Quick
            test_find_for_prefers_the_live_grant
        ] )
    ]
;;
