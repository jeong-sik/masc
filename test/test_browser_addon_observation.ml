open Alcotest
module Observation = Masc.Browser_addon_observation
module Types = Masc.Lane_addon_types
let ok = function Ok value -> value | Error message -> fail message
let roundtrip () =
  let snapshot=`Assoc ["state",`String "serving";
    "clients",`List [`Assoc ["interactions",`List [`Assoc ["phase",`String "running"]]]]] in
  let output=ok (Observation.of_snapshot ~observed_at:42. snapshot) in
  let retained=ok (Types.output_of_json (Types.output_to_json output)) in
  check bool "live and retained observation carry the same snapshot" true
    (match output.rows,retained.rows with [live],[retained] ->
      `Assoc live.fields=snapshot && live=retained | _ -> false)
let duplicate () = check bool "duplicate snapshot fields rejected before publication" true
  (Result.is_error (Observation.of_snapshot ~observed_at:0.
    (`Assoc ["state",`String "serving";"state",`String "retired"])))
let invalid_time () = check bool "invalid time rejected before publication" true
  (Result.is_error (Observation.of_snapshot ~observed_at:Float.nan (`Assoc [])))
let invalid_snapshot () = check bool "non-object snapshot rejected before publication" true
  (Result.is_error (Observation.of_snapshot ~observed_at:0. (`List [])))
let client id browser = `Assoc ["clientId",`String id;"browser",`String browser;
  "version",`String "158.0.1";"engineVersion",`String "158.0.1";"transport",`String "webdriver_bidi";"space",`Null;
  "interactions",`List [];"lastActivities",`List [];"spaceObservation",`Null;"spacePresence",`Null]
let serving clients = `Assoc ["state",`String "serving";"clients",`List clients]
(* The server reads the browser rows of the Lanes list from this cached
   observation, so what the worker published must read back whole. *)
let published_reads_back () =
  let output=ok (Observation.of_snapshot ~observed_at:1.
    (serving [client "01a16363-ef67-7000-ad62-05bcd0320d99" "firefox";
              client "01a16363-ef68-7000-aee1-37e1be230202" "firefox"])) in
  let published=ok (Observation.read output) in
  check int "both connected clients read back" 2 (List.length published.clients)
(* The runtime keeps an observation with its row renamed under the
   installation (Lane_addon_runtime.namespace); the reader must find it. *)
let namespaced_row_reads_back () =
  let output=ok (Observation.of_snapshot ~observed_at:1.
    (serving [client "01a16363-ef67-7000-ad62-05bcd0320d99" "firefox"])) in
  let cached={output with rows=List.map (fun (row:Types.row) ->
    {row with id="browser-work/7/" ^ row.id;lane_id="browser-work/" ^ row.lane_id}) output.rows} in
  let published=ok (Observation.read cached) in
  check int "the renamed row still reads back its client" 1 (List.length published.clients)
let retired_is_not_connected () =
  let output=ok (Observation.of_snapshot ~observed_at:1.
    (`Assoc ["state",`String "retired";"clients",`List []])) in
  check bool "a retired worker's observation does not read as a connected browser" true
    (Result.is_error (Observation.read output))
let duplicate_client () =
  let id="01a16363-ef67-7000-ad62-05bcd0320d99" in
  check bool "the same client twice is refused" true
    (Result.is_error (Observation.decode_snapshot (serving [client id "firefox"; client id "firefox"])))
let sdk_observation id ownership = `Assoc ["spaceId",`Int id;"spaceName",`String "Renamed native Space";
  "ownership",`String ownership;"observedAt",`Float 42.]
let native_space_presence () =
  let module O=Masc.Browser_ego_space_observation in
  let row id=`Assoc ["spaceId",`Int id;"name",`String "native";"ownership",`String "future-owner"] in
  let inspect value=O.inventory ~expected_id:32 ~observed_at:42. value in
  let present,metadata=inspect (`List [row 32]) in
  check bool "exact native ID establishes presence without interpreting ownership" true
    (present.state=O.Present && Option.is_some metadata);
  let missing,metadata=inspect (`List [row 33]) in
  check bool "a successful inventory without the original ID establishes missing" true
    (missing.state=O.Missing && metadata=None);
  let ambiguous,_=inspect (`List [row 32;row 32]) in
  check bool "duplicate original IDs are unknown, never missing" true
    (ambiguous.state=O.Unknown O.Ambiguous_inventory);
  List.iter (fun value -> let unknown,_=inspect value in
    check bool "unreadable inventory cannot establish absence" true
      (match unknown.state with O.Unknown (O.Invalid_inventory _) -> true | Present|Missing|Unknown _ -> false))
    [`Null;`List [`Null];`List [`Assoc ["spaceId",`String "33"]]];
  let user_row=`Assoc ["spaceId",`Int 0;"name",`String "";"ownership",`String "user"] in
  check bool "unrelated unnamed user Spaces do not invalidate the bound observation" true
    ((fst (inspect (`List [user_row;row 32]))).state=O.Present);
  let transport={missing with state=O.Unknown (O.Transport_unavailable "offline")} in
  List.iter (fun presence ->
    let encoded=O.presence_to_json presence in
    check bool "dated typed presence roundtrips" true (O.presence_of_json ~expected_id:32 encoded=Ok presence);
    check bool "a different bound ID cannot borrow presence" true
      (Result.is_error (O.presence_of_json ~expected_id:33 encoded)))
    [present;missing;ambiguous;transport]
let ego_client observation = match client "01a16363-ef67-7000-ad62-05bcd0320d99" "ego_lite" with
  | `Assoc fields -> `Assoc (("transport",`String "ego_task_space")::
      ("space",`Assoc ["id",`Int 32;"name",`String "Attachment name"])::
      ("spaceObservation",observation)::List.filter (fun (key,_) -> not (List.mem key ["transport";"space";"spaceObservation"])) fields)
  | _ -> fail "fixture client is not an object"
let published_space_observation () =
  let native=sdk_observation 32 "agentDelegatedToUser" in
  let output=ok (Observation.of_snapshot ~observed_at:99. (serving [ego_client native])) in
  let retained=ok (Types.output_of_json (Types.output_to_json output)) in
  let published=ok (Observation.read retained) in
  check bool "dated native observation survives publication and host readback" true
    (List.map (Yojson.Safe.Util.member "spaceObservation") published.client_rows=[native]);
  check bool "cached observation never replaces attachment identity" true
    ((List.hd published.clients).space=Some {Browser_lane.id=32;name="Attachment name"});
  ignore (ok (Observation.decode_snapshot (serving [ego_client (sdk_observation 32 "future-native-owner")])));
  ignore (ok (Observation.decode_snapshot (serving [ego_client `Null])));
  let codec=ok (Masc.Browser_ego_space_observation.of_json ~expected_id:32 native) in
  check bool "published observation codec preserves exact native value" true
    (Masc.Browser_ego_space_observation.to_json codec=native);
  List.iter (fun malformed -> check bool "invalid/foreign metadata is refused at host boundary" true
    (Result.is_error (Observation.decode_snapshot (serving [ego_client malformed]))))
    [sdk_observation 33 "agent";sdk_observation 32 " ";
     `Assoc ["spaceId",`Int 32;"spaceName",`String "name";"ownership",`String "agent";"observedAt",`Float nan];
     `Assoc ["spaceId",`Int 32;"spaceName",`String "name";"ownership",`String "agent";"observedAt",`Int 1;"observedAt",`Int 2]];
  let forged=match client "01a16363-ef67-7000-ad62-05bcd0320d99" "firefox" with
    | `Assoc fields -> `Assoc (("spaceObservation",native)::List.remove_assoc "spaceObservation" fields)
    | _ -> fail "fixture client is not an object" in
  check bool "non-Ego client cannot carry native Space metadata" true
    (Result.is_error (Observation.decode_snapshot (serving [forged])))
let publisher_binds_original_client_space () = Eio_main.run (fun _ ->
  let native=ok (Masc.Browser_ego_space_observation.of_json ~expected_id:32 (sdk_observation 32 "agentDelegatedToUser")) in
  let base=ok (Masc.Browser_addon_wire.client_of_json (`Assoc [
    "clientId",`String "01a16363-ef67-7000-ad62-05bcd0320d99";"browser",`String "ego_lite";
    "version",`String "0.6.1.11";"engineVersion",`String "chromium";"transport",`String "ego_task_space";
    "space",`Assoc ["id",`Int 32;"name",`String "Attachment name"]])) in
  let published client observation = Observation.publish_client client ~space_observation:observation ~space_presence:None
    |> Yojson.Safe.Util.member "spaceObservation" in
  check bool "same-Space cache is published" true (published base (Some native)=sdk_observation 32 "agentDelegatedToUser");
  check bool "invalidated cache is explicitly unknown" true (published base None=`Null);
  check bool "foreign numeric ID cannot leak to this client" true
    (published {base with space=Some {id=33;name="Another"}} (Some native)=`Null);
  check bool "non-Ego client cannot borrow the cache" true
    (published {base with browser=Firefox;transport=Webdriver_bidi;space=None} (Some native)=`Null))
let published_space_presence () =
  let module O=Masc.Browser_ego_space_observation in
  let set key value = function `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | _ -> fail "fixture client must be an object" in
  List.iter (fun state ->
    let presence:O.presence={space_id=32;observed_at=42.;state} in
    let encoded=O.presence_to_json presence in
    let row=ego_client `Null |> set "spacePresence" encoded in
    let published=ok (Observation.decode_snapshot (serving [row])) in
    check bool "typed absence/unknown survives worker-to-host publication" true
      (List.map snd published.space_presence=[presence]);
    check bool "the connected identity remains present" true (List.length published.clients=1);
    let foreign=O.presence_to_json {presence with space_id=33} in
    check bool "foreign Space presence cannot enter the host snapshot" true
      (Result.is_error (Observation.decode_snapshot (serving [set "spacePresence" foreign row])));
    check bool "a non-Ego connection cannot borrow Space presence" true
      (Result.is_error (Observation.decode_snapshot
        (serving [client "01a16363-ef67-7000-ad62-05bcd0320d99" "firefox" |> set "spacePresence" encoded]))))
    [O.Missing;O.Unknown (O.Transport_unavailable "offline")]
let unavailable_reads_back () =
  let unavailable = Observation.Ego_user_owned_name {space="masc";ids=[36];observed_at=42.} in
  let snapshot = match serving [] with
    | `Assoc fields -> `Assoc (("unavailable",`List [Observation.unavailable_to_json unavailable]) :: fields)
    | _ -> assert false in
  let published = ok (Observation.read (ok (Observation.of_snapshot ~observed_at:1. snapshot))) in
  check bool "the unavailable backend and exact reason survive publication" true (published.unavailable=[unavailable]);
  let malformed = match snapshot with
    | `Assoc fields -> `Assoc (("unavailable",`List [`Assoc ["backend",`String "ego"]]) :: List.remove_assoc "unavailable" fields)
    | _ -> assert false in
  check bool "an incomplete unavailable reason is not accepted" true (Result.is_error (Observation.decode_snapshot malformed));
  List.iter (fun ids ->
    let broken = match Observation.unavailable_to_json unavailable with
      | `Assoc fields -> `Assoc (("ids",`List ids)::List.remove_assoc "ids" fields)
      | value -> value in
    let snapshot = match serving [] with
      | `Assoc fields -> `Assoc (("unavailable",`List [broken]) :: fields)
      | _ -> assert false in
    check bool "an unreadable id list is not an unavailable backend" true
      (Result.is_error (Observation.decode_snapshot snapshot)))
    (* An empty id list stays readable: the worker observed the name without
       deciding an id, and the owner refuses to claim on it. *)
    [[`Int 0];[`Int (-1)];[`Int 36;`Int 36];[`String "36"]]
(* A connection that ended because ego no longer lists its Space names that
   Space; a record that mixes both kinds' fields is neither. *)
let missing_space_reads_back () =
  let missing = Observation.Ego_space_missing {space="masc";space_id=12;observed_at=42.} in
  let published record = match serving [] with
    | `Assoc fields -> Observation.decode_snapshot (`Assoc (("unavailable",`List [record]) :: fields))
    | _ -> assert false in
  let encoded = Observation.unavailable_to_json missing in
  check bool "the missing Space survives publication" true
    (match published encoded with Ok value -> value.unavailable=[missing] | Error _ -> false);
  let with_field key value = match encoded with
    | `Assoc fields -> `Assoc ((key,value)::List.remove_assoc key fields)
    | other -> other in
  List.iter (fun (name,record) ->
    check bool name true (Result.is_error (published record)))
    ["a Space number that is not positive", with_field "spaceId" (`Int 0);
     "a Space number that is text", with_field "spaceId" (`String "12");
     "a missing Space with refused ids", with_field "ids" (`List [`Int 12]);
     "a missing Space without its name", with_field "space" (`String "");
     "an unknown reason", with_field "reason" (`String "space_gone")]
(* Distinct live workers retain their source observations. *)
let merge_keeps_the_live_workers_unavailability () =
  let unavailable = Observation.Ego_user_owned_name {space="masc";ids=[36];observed_at=42.} in
  let published unavailable =
    { (ok (Observation.read (ok (Observation.of_snapshot ~observed_at:1. (serving []))))) with unavailable } in
  let ego = published [unavailable] and firefox = published [] in
  let module B = Browser_lane.Backend in
  let merged = Observation.merge [B.Ego, Some ego; B.Owned_firefox, Some firefox] in
  check bool "the live Ego worker's unavailability survives the merge" true (merged.unavailable=[unavailable]);
  let doubled = Observation.merge [B.Ego, Some ego; B.Ego, None] in
  check bool "another live worker does not suppress known unavailability" true (doubled.unavailable=[unavailable])
let ()=run "browser addon observation" ["publication",[
  test_case "native inventory distinguishes missing and observation unknown" `Quick native_space_presence;
  test_case "typed Space presence reaches cached host observations" `Quick published_space_presence;
  test_case "native Space metadata reaches cached host observations" `Quick published_space_observation;
  test_case "publisher binds cache to original Space" `Quick publisher_binds_original_client_space;
  test_case "published snapshot reads back" `Quick published_reads_back;
  test_case "namespaced row reads back" `Quick namespaced_row_reads_back;
  test_case "retired worker is not connected" `Quick retired_is_not_connected;
  test_case "duplicate client refused" `Quick duplicate_client;
  test_case "unavailable backend reads back" `Quick unavailable_reads_back;
  test_case "a missing Space reads back" `Quick missing_space_reads_back;
  test_case "merge keeps the live worker's unavailability" `Quick merge_keeps_the_live_workers_unavailability;
  test_case "live and retained observations agree" `Quick roundtrip;
  test_case "duplicate snapshot fields" `Quick duplicate;
  test_case "invalid time" `Quick invalid_time;
  test_case "invalid snapshot" `Quick invalid_snapshot]]
