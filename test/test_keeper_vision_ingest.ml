(* Closed-set invariant for the vision-ingest error surface (#32126).

   [Masc.Keeper_vision_ingest.error_reasons] is what health endpoints aggregate by;
   a reason produced anywhere in the ingest path but missing from the list
   would count in the pipeline counter and vanish from every health surface —
   the exact silence this list exists to end. *)

let in_set reason =
  List.mem reason Masc.Keeper_vision_ingest.error_reasons
;;

(* The eager-path mapping is exported and total; every error outcome it can
   produce must be declared. *)
let test_every_eager_outcome_reason_is_declared () =
  let module KVT = Masc.Keeper_vision_tool in
  let outcomes =
    [ KVT.Vo_empty
    ; KVT.Vo_truncated
    ; KVT.Vo_timeout
    ; KVT.Vo_no_runtime "no schema-capable image runtime configured"
    ; KVT.Vo_invalid_request "bad request"
    ; KVT.Vo_invalid_structured_response "{}"
    ; KVT.Vo_provider
        { failure_class = Tool_result.Runtime_failure
        ; detail = "provider said no"
        }
    ]
  in
  List.iter
    (fun outcome ->
       match Masc.Keeper_vision_ingest.eager_read_eviction_reason_of_outcome outcome with
       | Some reason ->
           if not (in_set reason) then
             Alcotest.failf "undeclared eager eviction reason: %s" reason
       | None -> ())
    outcomes
;;

(* The store-path reasons are call-site literals; pinning them here makes the
   coupling explicit — renaming one means updating the list and the health
   surface together, and forgetting shows up as this test failing. *)
let test_store_path_reasons_are_declared () =
  List.iter
    (fun reason ->
       if not (in_set reason) then
         Alcotest.failf "undeclared store-path eviction reason: %s" reason)
    [ "invalid_source_type"
    ; "bad_base64"
    ; "image_too_large"
    ; "invalid_media_type"
    ; "store_failed"
    ; "eager_read_failed"
    ]
;;

let () =
  Alcotest.run "keeper_vision_ingest"
    [ ( "closed reason set"
      , [ Alcotest.test_case "every eager outcome reason is declared" `Quick
            test_every_eager_outcome_reason_is_declared
        ; Alcotest.test_case "store-path reasons are declared" `Quick
            test_store_path_reasons_are_declared
        ] )
    ]
;;
