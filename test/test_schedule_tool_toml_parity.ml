(** Byte-identity pins for the schedule tool toml parity declarations moving to
    [config/tools/*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2).

    The expected values were read off [Tool_schemas_schedule.schemas] before any file moved, so this
    suite passing *before* the TOML replaces a literal is what proves the file
    says the same thing. Written against the published list rather than a loader
    module, so it holds across the whole migration: what a Keeper receives must
    not move whether a declaration lives in OCaml or TOML.

    [masc_schedule_create] has since moved on purpose: the payload envelope was
    replaced by the fields it wrapped, and the two the runtime cannot proceed
    without are now declared mandatory. Its entry is the shape after that
    change, not the pre-migration one. The other three are still the original
    pins.

    The enum arrays are literals in TOML -- nothing there can read an OCaml
    variant. [test_enum_mirror_sync] already compares each of the six against
    Schedule_contract_values, so the owners stay the owners and a drifted
    literal fails there rather than shipping a schema that never offers the
    value.

    [masc_schedule_update] was added after the migration. It deliberately
    shares the create field set and makes [schedule_id] mandatory; a separate
    structural assertion below pins that relationship instead of pretending
    it has pre-migration bytes.

    Compared as parsed JSON with keys sorted, per RFC §4 -- object key order is
    not part of a JSON object's meaning, and TOML cannot place a sub-table
    before its parent's scalar keys. *)

open Alcotest

let rec sorted (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, sorted value)
       |> List.sort (fun (a, _) (b, _) -> String.compare a b))
  | `List items -> `List (List.map sorted items)
  | other -> other
;;

(* name, description, input_schema (keys sorted) *)
let expected =
    [ {|masc_schedule_create|}, {|Wake a Keeper at a later time; the way to wait instead of polling the clock.
Create a durable Keeper wake request. For 'every day at 09:00 KST', use recurrence_kind=daily, recurrence_hour=9, recurrence_minute=0, recurrence_timezone=Asia/Seoul. For compact calendar rules, use recurrence_kind=cron with a 5-field recurrence_cron such as '0 9 * * 1-5'. The due request wakes its Keeper; it does not authorize later effects. When the creating turn has a routable continuation, the runtime records that exact route as the result destination; otherwise it records an explicit no-delivery policy.|}, {|{"additionalProperties":false,"properties":{"allow_unregistered_keeper":{"description":"Allow a masc.keeper_wake schedule whose target keeper has no durable metadata yet. Default false: creation is rejected because such a wake can never be settled until the keeper exists.","type":"boolean"},"due_at_iso":{"description":"RFC 3339 timestamp with Z or an explicit numeric offset, for example 2026-08-02T09:00:00+09:00. It is normalized to whole-second UTC; fractional seconds are accepted and truncated. Provide this, due_at_unix, or a calendar recurrence (daily/cron) that can derive the first due time.","type":"string"},"due_at_unix":{"description":"Unix timestamp in seconds. Provide this, due_at_iso, or a calendar recurrence (daily/cron) that can derive the first due time.","type":"number"},"expires_at_unix":{"description":"Optional expiry timestamp.","type":"number"},"keeper_name":{"description":"The Keeper to wake.","type":"string"},"message":{"description":"What the Keeper is being woken to do. It reads this and nothing else about why the wake exists, so write the work, not a reminder that work exists.","type":"string"},"recurrence_cron":{"description":"Required when recurrence_kind is cron. Standard 5-field cron expression: minute hour day-of-month month day-of-week. Supports wildcards, comma lists, numeric ranges, and steps such as */15 or 1-5/2.","type":"string"},"recurrence_hour":{"description":"Required when recurrence_kind is daily; local hour in 0..23.","type":"integer"},"recurrence_interval_sec":{"description":"Required when recurrence_kind is interval; seconds between runs.","type":"integer"},"recurrence_kind":{"description":"Recurrence kind. Defaults to one_shot.","enum":["one_shot","interval","daily","cron"],"type":"string"},"recurrence_minute":{"description":"Required when recurrence_kind is daily; local minute in 0..59.","type":"integer"},"recurrence_second":{"description":"Optional when recurrence_kind is daily; local second in 0..59.","type":"integer"},"recurrence_timezone":{"description":"Required when recurrence_kind is daily or cron. Fixed-offset only: UTC, Asia/Seoul/KST as +09:00 aliases, or offsets like +09:00/UTC+09:00. DST-aware IANA zones are not supported.","type":"string"},"requested_at_unix":{"description":"Optional request timestamp for replay/tests.","type":"number"},"requested_by_display_name":{"description":"Requester display name.","type":"string"},"requested_by_id":{"description":"Requester actor id. Defaults to operator.","type":"string"},"requested_by_kind":{"enum":["human_operator","automated_actor","system"],"type":"string"},"schedule_id":{"description":"Optional stable schedule id.","type":"string"},"scheduled_by_display_name":{"description":"Scheduler display name.","type":"string"},"scheduled_by_id":{"description":"Scheduler actor id. Defaults to caller agent name.","type":"string"},"scheduled_by_kind":{"enum":["human_operator","automated_actor","system"],"type":"string"},"source":{"enum":["operator_request","automated_request","system_request"],"type":"string"},"title":{"description":"Short label for this wake in listings. Falls back to message.","type":"string"},"urgency":{"description":"Where the wake sits in the Keeper's queue when it lands. Defaults to normal.","enum":["immediate","normal","low"],"type":"string"}},"required":["keeper_name","message"],"type":"object"}|}
    ; {|masc_schedule_list|}, {|List durable scheduled internal automation requests.|}, {|{"additionalProperties":false,"properties":{"limit":{"description":"Maximum rows to return. Defaults to 50, capped at 200.","type":"integer"},"status":{"enum":["scheduled","due","running","succeeded","failed","cancelled","expired"],"type":"string"}},"type":"object"}|}
    ; {|masc_schedule_get|}, {|Read the current durable scheduled request by schedule_id. A recurring request may already point at its next occurrence.|}, {|{"additionalProperties":false,"properties":{"schedule_id":{"description":"Durable schedule id.","type":"string"}},"required":["schedule_id"],"type":"object"}|}
    ; {|masc_schedule_cancel|}, {|Cancel a scheduled or due request before execution.|}, {|{"additionalProperties":false,"properties":{"cancelled_by_id":{"description":"Human or system actor id cancelling the schedule.","type":"string"},"cancelled_by_kind":{"enum":["human_operator","automated_actor","system"],"type":"string"},"reason":{"description":"Reason for operator-visible cancellation.","type":"string"},"schedule_id":{"description":"Schedule id to cancel.","type":"string"}},"required":["schedule_id","cancelled_by_id","reason"],"type":"object"}|}
    ]
;;

let published = Tool_schemas_schedule.schemas

let find name =
  match
    List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) published
  with
  | Some schema -> schema
  | None -> failwith (name ^ " is absent from Tool_schemas_schedule.schemas")
;;

let test_descriptions_are_byte_identical () =
  List.iter
    (fun (name, description, _) ->
       check string (name ^ " description") description (find name).description)
    expected
;;

let test_input_schemas_match_with_keys_sorted () =
  List.iter
    (fun (name, _, schema) ->
       check
         string
         (name ^ " input_schema")
         schema
         (Yojson.Safe.to_string (sorted (find name).input_schema)))
    expected
;;

(* The order is what a model reads the tool list in, so a reordering is a
   change to the surface even when every schema still matches. *)
let test_the_published_order_is_unchanged () =
  check
    (list string)
    "Tool_schemas_schedule.schemas in order"
    [ "masc_schedule_create"
    ; "masc_schedule_update"
    ; "masc_schedule_list"
    ; "masc_schedule_get"
    ; "masc_schedule_cancel"
    ]
    (List.map (fun (s : Masc_domain.tool_schema) -> s.name) published)
;;

let object_fields key schema =
  match Yojson.Safe.Util.member key schema with
  | `Assoc fields -> List.map fst fields |> List.sort_uniq String.compare
  | _ -> []
;;

let required_fields schema =
  match Yojson.Safe.Util.member "required" schema with
  | `List values ->
    List.filter_map (function `String value -> Some value | _ -> None) values
  | _ -> []
;;

let test_update_reuses_create_fields_and_requires_identity () =
  let create = (find "masc_schedule_create").input_schema in
  let update = (find "masc_schedule_update").input_schema in
  check (list string) "same editable fields"
    (object_fields "properties" create)
    (object_fields "properties" update);
  check (list string) "update additionally requires the stable id"
    [ "schedule_id"; "keeper_name"; "message" ]
    (required_fields update)
;;

(* [masc_schedule_create] is deferred: until the model asks for its schema,
   the listing carries only the first line of its description, cut at the
   listing's 80-byte cap ([Keeper_identity_tool_search.summary_of]). That
   line is the only
   thing a Keeper deciding how to wait for a later time ever reads, so it is
   pinned here next to the prose it summarises. *)
let test_the_deferred_listing_names_the_wait () =
  check
    string
    "masc_schedule_create summary"
    "Wake a Keeper at a later time; the way to wait instead of polling the clock."
    (Masc.Keeper_identity_tool_search.summary_of (find "masc_schedule_create").description)
;;

let () =
  run
    "schedule_tool_toml_parity"
    [ ( "byte_identity"
      , [ test_case "descriptions" `Quick test_descriptions_are_byte_identical
        ; test_case
            "input schemas, keys sorted"
            `Quick
            test_input_schemas_match_with_keys_sorted
        ; test_case "published order" `Quick test_the_published_order_is_unchanged
        ; test_case "update shares fields and requires identity" `Quick
            test_update_reuses_create_fields_and_requires_identity
        ; test_case "deferred listing names the wait" `Quick
            test_the_deferred_listing_names_the_wait
        ] )
    ]
;;
