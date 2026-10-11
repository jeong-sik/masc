open Alcotest
module Consumer = Masc_tui_child_content
module Read = Masc.Keeper_child_content_read
let keeper="alpha"
let receiver:Read.receiver={receiver_generation="receiver /&+%";session_id="session /&+%";client_uuid="client /&+%"}
let receiver_json (receiver:Read.receiver) = `Assoc ["receiver_generation",`String receiver.receiver_generation;
  "session_id",`String receiver.session_id;"client_uuid",`String receiver.client_uuid]
let coverage=["persistence_failure_history",`String "unavailable";"provider_completeness",`String "unknown";"liveness",`String "unknown"]
let envelope schema fields=`Assoc (("schema",`String schema)::coverage @ fields)
let receipt kind store through=`Assoc ["kind",`String kind;"store_id",`String store;"through_sequence",`Int through]
let inventory mode entries =
  let schema,key,kind=match mode with
    | Consumer.Poll -> "masc.child_content.hints.v1","hints","unchecked"
    | Audit -> "masc.child_content.receivers.v1","receivers","audited" in
  let field=match mode with Consumer.Poll -> "hint" | Audit -> "storage" in
  envelope schema ["keeper_name",`String keeper;"cleanup_failures",`List [];
    key,`List (List.map (fun (receiver,status) -> `Assoc ["receiver",receiver_json receiver;
      field,(match status with Ok (store,through) -> receipt kind store through
        | Error code -> `Assoc ["kind",`String "failed";"error",`String code])]) entries)]
(* Deliberately unprivileged public wire values; neither decoder nor Consumer
   creates Runtime/Binding/Journal private provenance from these fixtures. *)
let observation ?(receiver=receiver) ?(ordinal=1) ?(channel="text") ?(known=false)
    ?(body="body") ?(model="child-model") ?(provider="same-provider-envelope") id =
  let origin=`Assoc ["keeper_name",`String keeper;
    "source",`Assoc ["kind",`String "operation";"operation_id",`String "original-operation"];
    "attempt",`Assoc ["routing_run_id",`String "routing";"runtime_id",`String "claude";"lane_attempt_index",`Int 0];
    "invocation",receiver_json receiver] in
  let provenance=if known then ["parent_occurrence",`Assoc ["call_id",`String "parent";
      "call_envelope_uuid",`String "original-parent-envelope";"call_ordinal",`Int 0]] else [] in
  let attribution=if known then `Assoc ["kind",`String "original_parent_input";
      "evidence",`Assoc ["kind",`String "explicit"]]
    else `Assoc ["kind",`String "parent_input_refused";"reason",`Assoc ["kind",`String "unknown_parent"]] in
  `Assoc (["schema",`String "masc.child_content.v1";"origin",origin;"observation_id",`String id;
    "envelope_uuid",`String provider;"ordinal",`Int ordinal;"channel",`String channel;
    "parent_tool_use_id",`String "parent";"message_id",`String "";"model",`String model;
    "text",`String body;"attribution",attribution] @ provenance)
let row seq observation=`Assoc ["seq",`Int seq;"recorded_at",`Float (float_of_int seq);"observation",observation]
let page ?(receiver=receiver) store through rows =
  envelope "masc.child_content.records.v1" ["scope",`Assoc ["keeper_name",`String keeper;"receiver",receiver_json receiver];
    "records",`List rows;"next_cursor",`Assoc ["store_id",`String store;"after_sequence",`Int through];
    "validation",`Assoc ["kind",`String "audited";"through_sequence",`Int through];"cleanup_failures",`List []]
let json value=Yojson.Safe.to_string value
let read mode previous entries serve =
  let reads=ref [] in
  let fetch path =
    let uri=Uri.of_string path in
    let endpoint=match mode with Consumer.Poll -> "/api/v1/keepers/alpha/child-content/hints"
      | Audit -> "/api/v1/keepers/alpha/child-content/receivers" in
    if Uri.path uri=endpoint then Ok (200,json (inventory mode entries))
    else if Uri.path uri="/api/v1/keepers/alpha/child-content/records" then begin
      reads:=uri::!reads;serve uri
    end else fail ("unexpected Child path: " ^ path) in
  match Consumer.read ~mode ~keeper_name:keeper ~fetch ~previous with
  | Ok state -> state,List.rev !reads | Error error -> fail (Consumer.error_text error)
let one state=match Consumer.stores state with [store] -> store | _ -> fail "one store required"
let after uri=Uri.get_query_param uri "after_sequence"
let records_count state=List.fold_left (fun count (store:Consumer.store) -> count+List.length store.records) 0 (Consumer.stores state)
let initial () =
  fst (read Consumer.Poll Consumer.empty [receiver,Ok ("store /&+%",1)]
    (fun uri -> check (option string) "new store begins without cursor" None (after uri);
      Ok (200,json (page "store /&+%" 1 [row 1 (observation "first")]))))

let test_snapshots_suffix_identity_and_idle () =
  let first=initial () in
  let store="store /&+%" in
  let second,requests=read Consumer.Poll first [receiver,Ok (store,3)] (fun uri ->
    check (option string) "exact suffix begins after committed1" (Some "1") (after uri);
    check (option string) "opaque generation survives URI" (Some receiver.receiver_generation) (Uri.get_query_param uri "receiver_generation");
    check (option string) "opaque session survives URI" (Some receiver.session_id) (Uri.get_query_param uri "session_id");
    check (option string) "opaque actual client survives URI" (Some receiver.client_uuid) (Uri.get_query_param uri "client_uuid");
    check (option string) "opaque store survives URI" (Some store) (Uri.get_query_param uri "store_id");
    Ok (200,json (page store 3 [row 2 (observation ~ordinal:2 ~channel:"thinking" ~body:"" "first");
      row 3 (observation ~known:true "later")])) ) in
  check int "one changed store suffix request" 1 (List.length requests);
  let rows=(one second).records in
  check int "all complete snapshots retained without Task fold" 3 (List.length rows);
  check (list string) "same provider UUID is a correlation, not dedup key"
    ["same-provider-envelope";"same-provider-envelope";"same-provider-envelope"]
    (List.map (fun (row:Read.record) -> row.observation.envelope_uuid) rows);
  check (list string) "host observation identity retained" ["first";"first";"later"]
    (List.map (fun (row:Read.record) -> row.observation.observation_id) rows);
  check (option string) "empty reported message ID distinct from absence" (Some "") (List.hd rows).observation.message_id;
  check string "empty supplied thinking retained" "" (List.nth rows 1).observation.text;
  let idle,requests=read Consumer.Poll second [receiver,Ok (store,3)] (fun _ -> fail "unchanged Poll performed full read") in
  check int "unchanged Poll only hints" 0 (List.length requests);
  check bool "idle keeps actual immutable state identity" true (idle==second);
  check bool "idle keeps exact rows list" true ((one idle).records==(one second).records);
  check bool "coverage is explicitly unavailable" true ((one idle).coverage=Read.Unavailable)

let test_newer_receipt_does_not_repeat_full_reads () =
  let first=initial () in
  let advanced,_=read Consumer.Poll first [receiver,Ok ("store /&+%",2)] (fun _ ->
    Ok (200,json (page "store /&+%" 3 [row 2 (observation "second");row 3 (observation "third")]))) in
  check (option int) "concurrent append actual audited receipt may exceed hint" (Some 3)
    (Option.map (fun (c:Read.cursor) -> c.after_sequence) (one advanced).cursor);
  let fresh,requests=read Consumer.Poll advanced [receiver,Ok ("store /&+%",3)] (fun _ -> fail "already audited tail repeated full read") in
  check int "new hint already covered by actual receipt" 0 (List.length requests);
  let _,requests=read Consumer.Poll fresh [receiver,Ok ("store /&+%",2)] (fun _ -> fail "same attempted stale hint repeated full read") in
  check int "same original trigger hint does not repeat scan" 0 (List.length requests)

let test_cross_page_duplicate_and_receiver_failure () =
  let first=initial () in
  let bad,requests=read Consumer.Poll first [receiver,Ok ("store /&+%",2)] (fun _ ->
    Ok (200,json (page "store /&+%" 2 [row 2 (observation "first")]))) in
  check int "duplicate candidate actually fetched" 1 (List.length requests);
  check int "cross-page composite replay does not create second sequence" 1 (records_count bad);
  check (option int) "failure does not advance audited cursor" (Some 1) (Option.map (fun (c:Read.cursor) -> c.after_sequence) (one bad).cursor);
  (match (one bad).error with Some (Consumer.Invalid_response Read.Duplicate_observation) -> () | _ -> fail "duplicate not typed");
  let other:Read.receiver={receiver with client_uuid="other /&+%"} in
  let mixed,requests=read Consumer.Poll bad [receiver,Ok ("store /&+%",2);other,Ok ("other",1)] (fun uri ->
    check (option string) "failed same hint not retried while other client advances" (Some other.client_uuid) (Uri.get_query_param uri "client_uuid");
    Ok (200,json (page ~receiver:other "other" 1 [row 1 (observation ~receiver:other "other-observation")]))) in
  check int "one healthy receiver read" 1 (List.length requests);
  check int "actual client UUID keeps separate snapshot history" 2 (records_count mixed);
  check bool "original failure remains visible" true (Consumer.errors mixed<>[])

let test_audited_failure_sticky_until_full_success () =
  let first=initial () in
  let failed,_=read Consumer.Audit first [receiver,Error "store_corrupt"] (fun _ -> fail "failed audited inventory must not read records") in
  check int "one audited receiver failure is published once" 1 (List.length (Consumer.errors failed));
  let distinct,_=read Consumer.Poll failed [receiver,Error "store_unavailable"]
      (fun _ -> fail "failed inventory must not read records") in
  check int "distinct scoped failure codes are retained" 2 (List.length (Consumer.errors distinct));
  let hinted,requests=read Consumer.Poll failed [receiver,Ok ("store /&+%",1)] (fun _ -> fail "same hint retried full history") in
  check int "same hint no repeated corrupt full scan" 0 (List.length requests);
  check bool "unchecked inventory cannot clear audited failure" true (Consumer.errors hinted<>[]);
  let repaired,requests=read Consumer.Audit hinted [receiver,Ok ("store /&+%",1)] (fun uri ->
    check (option string) "explicit Audit always reads full history" None (after uri);
    Ok (200,json (page "store /&+%" 1 [row 1 (observation "first")]))) in
  check int "Audit retries full records even unchanged tail" 1 (List.length requests);
  check int "actual full success clears current audited failure" 0 (List.length (Consumer.errors repaired));
  let failed_read,_=read Consumer.Poll repaired [receiver,Ok ("store /&+%",2)] (fun _ ->
    Ok (503,json (Read.to_json (Read.failure Read.Store_corrupt)))) in
  let no_retry,requests=read Consumer.Poll failed_read [receiver,Ok ("store /&+%",2)] (fun _ -> fail "same failed hint repeated") in
  check int "failed full read attempt is throttled by exact hint" 0 (List.length requests);
  check bool "same failed attempt remains visibly failed" true (Consumer.errors no_retry<>[])

let test_audit_redaction_disappearance_and_replacement () =
  let first=initial () in
  let fresh,_=read Consumer.Audit first [receiver,Ok ("store /&+%",1)] (fun uri ->
    check (option string) "full Audit refreshes cached human leaves" None (after uri);
    Ok (200,json (page "store /&+%" 1 [row 1 (observation ~body:"[redacted]" ~model:"[redacted-model]" "first")]))) in
  check string "current full response replaces cached text" "[redacted]" (List.hd (one fresh).records).observation.text;
  check string "current full response replaces cached model only" "[redacted-model]" (List.hd (one fresh).records).observation.model;
  let absent,_=read Consumer.Poll fresh [] (fun _ -> fail "absent inventory must not invent store") in
  check int "disappeared history retained" 1 (records_count absent);
  check bool "last-observed absent body not claimed currently redacted" true (Consumer.diagnostics absent<>Consumer.diagnostics fresh);
  let replacement,_=read Consumer.Poll absent [receiver,Ok ("replacement",1)] (fun uri ->
    check (option string) "new incarnation begins without old cursor" None (after uri);
    Ok (200,json (page "replacement" 1 [row 1 (observation "first")]))) in
  check int "new incarnation cannot collapse old observations" 2 (records_count replacement);
  check (list string) "retained store identity preserved" ["store /&+%";"replacement"]
    (List.map (fun (store:Consumer.store) -> store.store_id) (Consumer.stores replacement))

let test_audit_refuses_rollback_and_identity_rewrite () =
  let rows=List.init 4 (fun index -> row (index+1) (observation (string_of_int (index+1)))) in
  let initial,_=read Consumer.Poll Consumer.empty [receiver,Ok ("stable",4)] (fun _ -> Ok (200,json (page "stable" 4 rows))) in
  let rollback,_=read Consumer.Audit initial [receiver,Ok ("stable",2)] (fun _ ->
    Ok (200,json (page "stable" 2 [List.nth rows 0;List.nth rows 1]))) in
  check int "same-incarnation rollback retains all known rows" 4 (records_count rollback);
  (match (one rollback).error with Some (Consumer.History_rewritten _) -> () | _ -> fail "rollback lost typed refusal");
  let rewritten,_=read Consumer.Audit initial [receiver,Ok ("stable",4)] (fun _ ->
    Ok (200,json (page "stable" 4 (row 1 (observation ~provider:"rewritten-provider-envelope" "1")::List.tl rows)))) in
  check int "rewritten prior identity retains original history" 4 (records_count rewritten);
  check string "original provider correlation unchanged" "same-provider-envelope" (List.hd (one rewritten).records).observation.envelope_uuid;
  (match (one rewritten).error with Some (Consumer.History_rewritten _) -> () | _ -> fail "identity rewrite not refused")

let test_changed_hint_cannot_clear_known_rewrite_with_suffix () =
  let rows=List.init 4 (fun i -> row (i+1) (observation (string_of_int (i+1)))) in
  let first,_=read Consumer.Poll Consumer.empty [receiver,Ok ("stable",4)]
    (fun _ -> Ok (200,json (page "stable" 4 rows))) in
  let broken=row 1 (observation ~provider:"changed" "1")::List.tl rows in
  let refused,_=read Consumer.Audit first [receiver,Ok ("stable",4)]
    (fun _ -> Ok (200,json (page "stable" 4 broken))) in
  let failed,_=read Consumer.Poll refused [receiver,Ok ("stable",5)] (fun uri ->
    check (option string) "known rewrite requires full request" None (after uri);
    Error "temporary transport failure") in
  (match (one failed).error with Some (Consumer.History_rewritten _) -> ()
   | _ -> fail "temporary failure erased known prefix rewrite");
  let suffix,_=read Consumer.Poll failed [receiver,Ok ("stable",6)] (fun uri ->
    check (option string) "transient failure keeps full-recheck requirement" None (after uri);
    Ok (200,json (page "stable" 6 [row 5 (observation "5");row 6 (observation "6")]))) in
  check int "internally valid suffix cannot replace retained prefix" 4 (records_count suffix);
  (match (one suffix).error with Some (Consumer.History_rewritten _) -> ()
   | _ -> fail "suffix cleared known rewrite");
  let fresh=rows @ [row 5 (observation "5");row 6 (observation "6");row 7 (observation "7")] in
  let repaired,_=read Consumer.Poll suffix [receiver,Ok ("stable",7)] (fun uri ->
    check (option string) "changed hint retries complete prefix" None (after uri);
    Ok (200,json (page "stable" 7 fresh))) in
  check int "matching full prefix repairs and advances history" 7 (records_count repaired);
  check int "only full prefix success clears rewrite" 0 (List.length (Consumer.errors repaired))

let test_bad_pages_and_guarded_fetch_keep_cache () =
  let first=initial () in
  let variants=[200,"{";403,"{}";200,json (page "foreign-store" 2 [row 2 (observation "second")]);
    200,json (page "store /&+%" 3 [row 3 (observation "third")]);
    200,json (page "store /&+%" 2 [row 2 (observation ~receiver:{receiver with client_uuid="foreign"} "second")])] in
  List.iter (fun (status,body) ->
    let failed,_=read Consumer.Poll first [receiver,Ok ("store /&+%",2)] (fun _ -> Ok (status,body)) in
    check int "malformed/refused/foreign/gapped read retains old rows" 1 (records_count failed);
    check bool "failed read is visible" true (Consumer.errors failed<>[])) variants;
  let withdrawn,_=read Consumer.Poll first [receiver,Ok ("store /&+%",2)] (fun _ -> Error "workspace authority withdrawn") in
  check int "guarded fetch refuses before cache replacement" 1 (records_count withdrawn);
  check bool "guarded transport refusal visible" true (Consumer.errors withdrawn<>[]);
  (match Consumer.read ~mode:Consumer.Poll ~keeper_name:"beta" ~previous:first
    ~fetch:(fun _ -> fail "foreign Keeper request must refuse before fetch") with
   | Error (Consumer.Invalid_response Read.Scope_mismatch) -> () | _ -> fail "foreign Keeper cache reused")

let ()=run "Child immutable snapshot reader" ["read",[
  test_case "snapshots, opaque suffix and idle identity" `Quick test_snapshots_suffix_identity_and_idle;
  test_case "newer audited receipt and same trigger do not repeat scans" `Quick test_newer_receipt_does_not_repeat_full_reads;
  test_case "cross-page composite and independent actual clients" `Quick test_cross_page_duplicate_and_receiver_failure;
  test_case "audited failures sticky until full success" `Quick test_audited_failure_sticky_until_full_success;
  test_case "full Audit redaction and retained disappeared incarnations" `Quick test_audit_redaction_disappearance_and_replacement;
  test_case "Audit rollback and immutable identity rewrite refuse" `Quick test_audit_refuses_rollback_and_identity_rewrite;
  test_case "changed hints require full recovery of known prefix rewrite" `Quick test_changed_hint_cannot_clear_known_rewrite_with_suffix;
  test_case "bad public pages and guarded fetch keep previous cache" `Quick test_bad_pages_and_guarded_fetch_keep_cache]]
