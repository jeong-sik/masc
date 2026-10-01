(* Test funding is a complete historical payout, not an orphan mint. *)
let funding_rows (at : Candle_time.t) (payment : Candle_payment.t) : Candle_event.t list =
  let identity = payment.identity in
  let keeper = match payment.allocations with
    | [allocation] -> allocation.Candle_payment.keeper
    | _ -> Alcotest.fail "funding fixture expects one Keeper" in
  let task_ids = List.map (fun (r : Candle_appraisal.task_relation) -> r.task_id) payment.relations in
  [ {Candle_event.at;body=Candle_event.Half_life_set Candle_decay.Off}
  ; {Candle_event.at;body=Candle_event.Snapshot
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;criterion_revision="funding-proof";
       passed_at=at;goal_created_at=(match Candle_time.of_rfc3339 "1970-01-01T00:00:00Z" with
         | Ok value -> value | Error detail -> Alcotest.fail detail);
       due_date=None;title="Completed funding fixture";metric=Some "completed";
       target_value=Some "1";linked_task_ids=task_ids}}
  ; {Candle_event.at;body=Candle_event.Payout_owed
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;passed_at=at;confirmed_at=at}}
  ; {Candle_event.at;body=Candle_event.Candidates
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;
       tasks=List.map (fun id -> id, Candle_event.Found
         {title="Completed contribution";assignee=Some keeper;
          status=Candle_event.Done {completed_at=at}}) task_ids;
       candidate_task_ids=task_ids;candidate_keepers=[keeper]}}
  ; {Candle_event.at;body=Candle_event.Paid payment}
  ]
;;

open Alcotest
open Masc

(* Test funding is a complete historical payout, not an orphan mint. *)
let funding_rows (at : Candle_time.t) (payment : Candle_payment.t) : Candle_event.t list =
  let identity = payment.identity in
  let keeper = match payment.allocations with
    | [allocation] -> allocation.Candle_payment.keeper
    | _ -> Alcotest.fail "funding fixture expects one Keeper" in
  let task_ids = List.map (fun (r : Candle_appraisal.task_relation) -> r.task_id) payment.relations in
  [ {Candle_event.at;body=Candle_event.Half_life_set Candle_decay.Off}
  ; {Candle_event.at;body=Candle_event.Snapshot
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;criterion_revision="funding-proof";
       passed_at=at;goal_created_at=(match Candle_time.of_rfc3339 "1970-01-01T00:00:00Z" with
         | Ok value -> value | Error detail -> Alcotest.fail detail);
       due_date=None;title="Completed funding fixture";metric=Some "completed";
       target_value=Some "1";linked_task_ids=task_ids}}
  ; {Candle_event.at;body=Candle_event.Payout_owed
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;passed_at=at;confirmed_at=at}}
  ; {Candle_event.at;body=Candle_event.Candidates
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;
       tasks=List.map (fun id -> id, Candle_event.Found
         {title="Completed contribution";assignee=Some keeper;
          status=Candle_event.Done {completed_at=at}}) task_ids;
       candidate_task_ids=task_ids;candidate_keepers=[keeper];
       candidate_task_keepers=List.map (fun id -> id, Some keeper) task_ids}}
  ; {Candle_event.at;body=Candle_event.Paid payment}
  ]
;;


module Http = Http_server_eio
module Api = Server_dashboard_http_keeper_portrait
module Items_api = Server_dashboard_http_keeper_items

let () = Mirage_crypto_rng_unix.use_default ()
let () = Server_startup_state.mark_state_ready () |> Result.get_ok

let keeper = "portrait-http-probe"
let png_signature = "\137PNG\r\n\026\n"

let require_ok error = function Ok value -> value | Error value -> fail (error value)

(* IHDR follows the signature: length(4) "IHDR"(4) width(4) height(4) depth colour ... *)
let ihdr png =
  check string "PNG signature" png_signature (String.sub png 0 8);
  check string "first chunk is IHDR" "IHDR" (String.sub png 12 4);
  let u32 at = Int32.to_int (String.get_int32_be png at) in
  u32 16, u32 20, Char.code png.[24], Char.code png.[25]

let present () = Ok true
let never_asked () = fail "keeper presence must not be read for a malformed request"
let holds_nothing _ = false
let a_build = Api.Executable "portrait-test-build-a"
let roomy_budget = 64 * 1024 * 1024

(* A fresh cache per call, so every answer below draws unless it says otherwise. *)
let answer ?(cache = Api.Cache.create ~byte_budget:roomy_budget) ?(build = a_build)
    ?(holds_tag = holds_nothing) ?equipment ?expected_equipment ~name ~size ~keeper_present () =
  let equipment = match equipment with
    | Some read -> read
    | None -> (fun () -> Ok (Keeper_portrait_look.equipment_of_name name)) in
  Api.answer ~cache ~build ~name ~size ~expected_equipment:(Option.map (fun value -> Ok value) expected_equipment) ~keeper_present ~equipment ~holds_tag

let describe = function
  | Api.Png _ -> "Png"
  | Api.Not_modified tag -> "Not_modified " ^ tag
  | Api.Invalid_name -> "Invalid_name"
  | Api.Invalid_size raw -> "Invalid_size " ^ raw
  | Api.Invalid_equipment detail -> "Invalid_equipment " ^ detail
  | Api.Equipment_changed -> "Equipment_changed"
  | Api.Unknown_keeper -> "Unknown_keeper"
  | Api.Lookup_failed message -> "Lookup_failed " ^ message
  | Api.Encode_failed message -> "Encode_failed " ^ message

let expect_tagged_png = function
  | Api.Png { etag; png } -> etag, png
  | other -> fail (describe other)

let expect_png answer = snd (expect_tagged_png answer)

let test_route_is_exact () =
  check (option string) "portrait path" (Some keeper)
    (Api.route ("/api/v1/keepers/" ^ keeper ^ "/portrait.png"));
  List.iter (fun path -> check (option string) path None (Api.route path))
    [ "/api/v1/keepers//portrait.png"
    ; "/api/v1/keepers/" ^ keeper ^ "/portrait.png/extra"
    ; "/api/v1/keepers/" ^ keeper ^ "/portrait.jpg"
    ; "/api/v1/keepers/" ^ keeper
    ; "/api/v1/other/" ^ keeper ^ "/portrait.png" ];
  check (option string) "Item account path" (Some keeper)
    (Items_api.route ("/api/v1/keepers/" ^ keeper ^ "/items"));
  List.iter (fun path -> check (option string) path None (Items_api.route path))
    [ "/api/v1/keepers//items"
    ; "/api/v1/keepers/" ^ keeper ^ "/items/extra"
    ; "/api/v1/keepers/" ^ keeper ^ "/item" ]

let test_size_and_default () =
  let width, height, depth, colour =
    ihdr (expect_png (answer ~name:keeper ~size:None ~keeper_present:present ())) in
  check int "default width" Api.default_size width;
  check int "default height" Api.default_size height;
  check int "8-bit samples" 8 depth;
  check int "RGBA colour type keeps the transparent corners" 6 colour;
  let width, _, _, _ =
    ihdr (expect_png (answer ~name:keeper ~size:(Some "64") ~keeper_present:present ())) in
  check int "requested size" 64 width

let test_bad_sizes_are_refused_not_clamped () =
  List.iter (fun raw ->
    match answer ~name:keeper ~size:(Some raw) ~keeper_present:never_asked () with
    | Api.Invalid_size echoed -> check string "refusal names the value" raw echoed
    | other -> fail ("accepted size " ^ raw ^ ": " ^ describe other))
    [ ""; "0"; "15"; "513"; "0x40"; "+64"; "6_4"; " 64"; "64px"; "1e2"; "99999999999999999999" ]

let test_order_of_checks () =
  let holds_everything _ = true in
  (match answer ~name:"../escape" ~size:(Some "nonsense") ~keeper_present:never_asked () with
   | Api.Invalid_name -> ()
   | other -> fail ("a malformed name is refused before anything else: " ^ describe other));
  (match answer ~holds_tag:holds_everything ~name:keeper ~size:None ~keeper_present:(fun () -> Ok false) () with
   | Api.Unknown_keeper -> ()
   | other -> fail ("an absent keeper is not drawn, and its tag is never asked: " ^ describe other));
  match answer ~name:keeper ~size:None ~keeper_present:(fun () -> Error "store down") () with
  | Api.Lookup_failed message -> check string "store error kept" "store down" message
  | other -> fail ("a store failure is not an absent keeper: " ^ describe other)

let test_same_name_same_bytes () =
  let draw name = expect_png (answer ~name ~size:(Some "96") ~keeper_present:present ()) in
  check string "deterministic" (draw keeper) (draw keeper);
  check bool "another name draws another picture" false
    (String.equal (draw keeper) (draw "portrait-http-other"))

let test_a_held_tag_is_answered_without_drawing () =
  let cache = Api.Cache.create ~byte_budget:roomy_budget in
  let offered = ref [] in
  let holds_tag tag = offered := tag :: !offered; true in
  (match answer ~cache ~holds_tag ~name:keeper ~size:(Some "64") ~keeper_present:present () with
   | Api.Not_modified tag -> check (list string) "the tag it was asked about" [ tag ] !offered
   | other -> fail ("a held tag is a 304: " ^ describe other));
  check int "nothing was drawn, so nothing was cached" 0 (Api.Cache.length cache);
  (* The same tag comes back with the bytes when the client does not hold it. *)
  let etag, _ = expect_tagged_png (answer ~cache ~name:keeper ~size:(Some "64") ~keeper_present:present ()) in
  check (list string) "one tag for name, size and build" [ etag ] !offered

let test_tags_follow_build_name_and_size () =
  let tag ?(build = a_build) ?(name = keeper) size =
    fst (expect_tagged_png (answer ~build ~name ~size:(Some size) ~keeper_present:present ())) in
  let base = tag "64" in
  check string "stable" base (tag "64");
  check bool "another build" false (String.equal base (tag ~build:(Api.Executable "portrait-test-build-b") "64"));
  check bool "another size" false (String.equal base (tag "65"));
  check bool "another name" false (String.equal base (tag ~name:"portrait-http-other" "64"))

let test_unscoped_tags_follow_the_bytes () =
  let etag, png =
    expect_tagged_png (answer ~build:Api.Unscoped ~name:keeper ~size:(Some "48") ~keeper_present:present ()) in
  check string "tag from the PNG bytes" (Http.Response.etag_of_body png) etag;
  match answer ~build:Api.Unscoped ~holds_tag:(String.equal etag) ~name:keeper ~size:(Some "48")
          ~keeper_present:present () with
  | Api.Not_modified held -> check string "304 on that tag" etag held
  | other -> fail ("an unscoped build still answers 304: " ^ describe other)

let test_cache_keeps_drawings_within_its_budget () =
  let one = expect_png (answer ~name:keeper ~size:(Some "64") ~keeper_present:present ()) in
  let budget = (String.length one * 5) / 2 in
  let cache = Api.Cache.create ~byte_budget:budget in
  let draw name = expect_png (answer ~cache ~name ~size:(Some "64") ~keeper_present:present ()) in
  let first = draw keeper in
  check int "kept" 1 (Api.Cache.length cache);
  check string "a kept picture is served as drawn" first (draw keeper);
  check int "not kept twice" 1 (Api.Cache.length cache);
  List.iter (fun suffix -> ignore (draw ("portrait-http-crowd-" ^ suffix)))
    [ "a"; "b"; "c"; "d"; "e"; "f" ];
  check bool "never above the budget" true (Api.Cache.bytes cache <= budget);
  check bool "the oldest went first" true (Api.Cache.length cache < 7);
  let tiny = Api.Cache.create ~byte_budget:1 in
  ignore (expect_png (answer ~cache:tiny ~name:keeper ~size:(Some "64") ~keeper_present:present ()));
  check int "a picture larger than the budget is served, not kept" 0 (Api.Cache.length tiny)

let test_equipment_wire_and_cache () =
  let module Equipment = Keeper_portrait_equipment in
  let module Item = Keeper_portrait_item in
  let original = Keeper_portrait_look.bare in
  let crown = match Item.of_id "crown" with Some value -> value | None -> fail "catalog crown missing" in
  let equipped = Item.preview crown original in
  let received = require_ok Fun.id (Equipment.of_json (Equipment.to_json equipped)) in
  check bool "wire preserves complete rendered equipment" true (received = equipped);
  let fields = match Equipment.to_json equipped with `Assoc fields -> fields | _ -> fail "equipment object" in
  let rejects label json = match Equipment.of_json json with
    | Error _ -> () | Ok _ -> fail label in
  rejects "missing slot" (`Assoc (List.remove_assoc "head" fields));
  rejects "duplicate slot" (`Assoc (("head", `String "crown") :: fields));
  rejects "wrong slot" (`Assoc (("face", `String "crown") :: List.remove_assoc "face" fields));
  rejects "unknown item" (`Assoc (("head", `String "unknown") :: List.remove_assoc "head" fields));
  let cache = Api.Cache.create ~byte_budget:roomy_budget in
  let get ?(holds_tag = holds_nothing) equipment =
    answer ~cache ~holds_tag ~equipment:(fun () -> Ok equipment)
      ~name:keeper ~size:(Some "96") ~keeper_present:present () in
  let before_tag, before_png = expect_tagged_png (get original) in
  let after_tag, after_png = expect_tagged_png (get ~holds_tag:(String.equal before_tag) received) in
  check bool "new equipment invalidates old tag" false (before_tag = after_tag);
  check bool "new equipment changes actual PNG" false (before_png = after_png);
  check int "distinct equipment has distinct cache entries" 2 (Api.Cache.length cache);
  let restored_tag, restored_png = expect_tagged_png (get original) in
  check string "restore returns original bytes" before_png restored_png;
  check string "restore returns original tag" before_tag restored_tag;
  match answer ~cache ~holds_tag:(fun _ -> true) ~equipment:(fun () -> Error "ledger unavailable")
    ~name:keeper ~size:(Some "96") ~keeper_present:present () with
  | Api.Lookup_failed message -> check string "authority error kept" "ledger unavailable" message
  | other -> fail ("authority failure must not serve stale cached portrait: " ^ describe other)

let test_expected_equipment_precedes_tags_and_cache () =
  let original = Keeper_portrait_look.bare in
  let crown = match Keeper_portrait_item.of_id "crown" with Some item -> item | None -> fail "crown missing" in
  let changed = Keeper_portrait_item.preview crown original in
  let cache = Api.Cache.create ~byte_budget:roomy_budget in
  let reads = ref 0 in
  let equipment () = incr reads; Ok changed in
  (match answer ~cache ~expected_equipment:original ~equipment ~holds_tag:(fun _ -> fail "mismatch asked for a tag")
      ~name:keeper ~size:None ~keeper_present:present () with
   | Api.Equipment_changed -> ()
   | other -> fail ("expected snapshot mismatch: " ^ describe other));
  check int "one authoritative equipment read" 1 !reads;
  check int "mismatch cached no PNG" 0 (Api.Cache.length cache);
  (match Api.answer ~cache ~build:a_build ~expected_equipment:(Some (Error "bad codec"))
      ~name:keeper ~size:None ~keeper_present:never_asked ~equipment ~holds_tag:holds_nothing with
   | Api.Invalid_equipment _ -> ()
   | other -> fail ("invalid expected equipment: " ^ describe other));
  check int "malformed expectation read no equipment" 1 !reads

let test_account_revision_binds_facts_not_decay_clock () =
  let at0 = require_ok Fun.id (Candle_time.of_rfc3339 "2026-09-29T00:00:00Z") in
  let at1 = require_ok Fun.id (Candle_time.of_rfc3339 "2026-09-29T00:00:01Z") in
  let payment name owner = require_ok Fun.id (Candle_payment.make
    ~identity:{goal_id=name;request_id=name ^ "-request";verification_run_id=name ^ "-run"}
    ~grade:Candle_grade.Trivial ~total_milli:1000
    ~grade_trace:{run_id="grade";slot_id="appraiser"}
    ~relations:[{task_id="task";relation=Candle_appraisal.Related;trace={run_id="relation";slot_id="appraiser"}}]
    ~weights_trace:{run_id="weights";slot_id="appraiser"}
    ~weight_max:1 ~deduction_rate:0 ~deduction_floor:1000 ~overdue_hours:0 ~weights:[owner,1]) in
  let policy = match Candle_config.of_toml_string {|half_life = 1
[payout]
weight_max = 1
deduction_rate = 0
deduction_floor = 1000
[payout.grades_milli]
trivial = 1000
small = 1000
medium = 1000
large = 1000
epic = 1000
[shop.prices_milli]
crown = 0
|} with
    | Candle_config.Enabled policy -> policy
    | config -> fail (Candle_config.to_string config) in
  let events = funding_rows at0 (payment "own-credit" keeper) |> List.map (fun (event : Candle_event.t) ->
    match event.body with Candle_event.Half_life_set _ -> {event with body=Half_life_set (Candle_decay.Hours 1)}
    | _ -> event) in
  let project at events = require_ok Candle_balance.error_to_string (Candle_balance.of_events ~at events) in
  let revision ?(policy=policy) at events =
    Candle_observe.ready_account_revision ~events ~policy ~balance:(project at events) ~keeper in
  check int "funded at initial instant" 1000 (Candle_balance.balance (project at0 events) ~keeper);
  check int "natural one-second decay remains observable" 999 (Candle_balance.balance (project at1 events) ~keeper);
  let initial = revision at0 events in
  check string "pure decay does not invalidate durable account revision" initial (revision at1 events);
  let other = funding_rows at1 (payment "other-credit" "other-keeper") |> List.filter (fun (event : Candle_event.t) ->
    match event.body with Candle_event.Half_life_set _ -> false | _ -> true) in
  check string "unrelated preparation and payment do not invalidate this account" initial (revision at1 (events @ other));
  let own = funding_rows at1 (payment "next-own-credit" keeper) |> List.filter (fun (event : Candle_event.t) ->
    match event.body with Candle_event.Half_life_set _ -> false | _ -> true) in
  check bool "relevant new credit invalidates the old revision" false (initial = revision at1 (events @ own));
  let crown = match Keeper_portrait_item.of_id "crown" with Some item -> item | None -> fail "crown missing" in
  let bought = events @ [{Candle_event.at=at1;body=Purchased {keeper;item=crown;amount_milli=0}}] in
  check bool "free purchase invalidates despite no debit" false (initial = revision at1 bought);
  let equipped = bought @ [{Candle_event.at=at1;body=Equipped {keeper;slot=Keeper_portrait_item.Head;choice=Item crown}}] in
  check bool "equipment fact invalidates unchanged money/ownership" false (revision at1 bought = revision at1 equipped);
  let other_equipped = events @ other @ [{Candle_event.at=at1;body=Purchased {keeper="other-keeper";item=crown;amount_milli=0}};
    {Candle_event.at=at1;body=Equipped {keeper="other-keeper";slot=Keeper_portrait_item.Head;choice=Item crown}}] in
  check string "unrelated purchase/equipment do not invalidate this account" initial (revision at1 other_equipped);
  let boundary = events @ [{Candle_event.at=at1;body=Half_life_set (Candle_decay.Hours 2)}] in
  check bool "durable policy boundary invalidates" false (initial = revision at1 boundary)

(* ---- the real router, over an in-memory HTTP/1.1 connection ---- *)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_router f =
  let base_path = Filename.temp_dir "keeper-portrait-http" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Fs_compat.clear_fs ();
      remove_tree base_path)
    (fun () -> Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      ignore (Workspace.init config ~agent_name:None);
      Server_auth.For_testing.restore_server_state (Some state);
      let meta = require_ok Fun.id
        (Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper ])) in
      require_ok Fun.id (Keeper_meta_store.replace_snapshot config meta);
      let router = Server_routes_http_routes_dashboard.add_routes ~sw
        ~clock:(Eio.Stdenv.clock env) (Http.Router.create ()) in
      f ~config router)

type reply = { status : int; headers : (string * string) list; body : string }

let get ~router ?if_none_match ?token path =
  let output = Buffer.create 4096 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let optional name = Option.fold ~none:"" ~some:(fun value -> name ^ ": " ^ value ^ "\r\n") in
  let raw_request =
    Printf.sprintf "GET %s HTTP/1.1\r\nHost: x\r\n%s%sContent-Length: 0\r\n\r\n" path
      (optional "If-None-Match" if_none_match)
      (optional "Authorization" (Option.map (fun token -> "Bearer " ^ token) token)) in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes); drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let raw = Buffer.contents output in
  let rec head_end index =
    if index + 4 > String.length raw then fail ("no end of headers: " ^ raw)
    else if String.sub raw index 4 = "\r\n\r\n" then index
    else head_end (index + 1) in
  let stop = head_end 0 in
  let lines = String.split_on_char '\n' (String.sub raw 0 stop) in
  let status = int_of_string (List.nth (String.split_on_char ' ' (List.hd lines)) 1) in
  let headers = List.filter_map (fun line ->
    match String.index_opt line ':' with
    | None -> None
    | Some at ->
      Some (String.lowercase_ascii (String.sub line 0 at),
            String.trim (String.sub line (at + 1) (String.length line - at - 1))))
    (List.tl lines) in
  { status; headers; body = String.sub raw (stop + 4) (String.length raw - stop - 4) }

let header reply name =
  match List.assoc_opt name reply.headers with
  | Some value -> value
  | None -> fail ("missing header " ^ name)

let path ?size ?expected_equipment name =
  let query = (match size with None -> [] | Some value -> ["size", [value]])
    @ (match expected_equipment with None -> [] | Some value -> ["expected_equipment", [value]]) in
  Uri.to_string (Uri.make ~path:("/api/v1/keepers/" ^ name ^ "/portrait.png") ~query ())

let bound_path ?size equipment name =
  path ?size ~expected_equipment:(Yojson.Safe.to_string (Keeper_portrait_equipment.to_json equipment)) name

let item_path name = "/api/v1/keepers/" ^ name ^ "/items"

let item_account reply =
  check int "Item account HTTP response" 200 reply.status;
  require_ok Fun.id
    (Masc_tui_keeper_items.decode ~keeper_name:keeper
       (Yojson.Safe.from_string reply.body))
  |> snd

let item_path name = "/api/v1/keepers/" ^ name ^ "/items"

let item_account reply =
  check int "Item account HTTP response" 200 reply.status;
  require_ok Fun.id
    (Masc_tui_keeper_items.decode ~keeper_name:keeper
       (Yojson.Safe.from_string reply.body))

let test_router_serves_png_with_a_strong_tag () =
  with_router (fun ~config:_ router ->
    let first = get ~router (path ~size:"72" keeper) in
    check int "200 without a token" 200 first.status;
    check string "content type" "image/png" (header first "content-type");
    check string "revalidate" "no-cache" (header first "cache-control");
    let tag = header first "etag" in
    check bool "strong tag" false (String.starts_with ~prefix:"W/" tag);
    let width, height, _, _ = ihdr first.body in
    check int "width" 72 width;
    check int "height" 72 height;
    let again = get ~router (path ~size:"72" keeper) in
    check string "same bytes" first.body again.body;
    check string "same tag" tag (header again "etag");
    let cached = get ~router ~if_none_match:tag (path ~size:"72" keeper) in
    check int "304 on the tag" 304 cached.status;
    check string "no body on 304" "" cached.body;
    check string "304 repeats the tag" tag (header cached "etag");
    let listed = get ~router ~if_none_match:("\"stale\", " ^ tag) (path ~size:"72" keeper) in
    check int "304 when the tag is in a list" 304 listed.status;
    let weak = get ~router ~if_none_match:("W/" ^ tag) (path ~size:"72" keeper) in
    check int "304 on the weak form of the tag" 304 weak.status;
    check int "304 on any tag" 304 (get ~router ~if_none_match:"*" (path ~size:"72" keeper)).status;
    let other_size = get ~router ~if_none_match:tag (path ~size:"96" keeper) in
    check int "a different size is a different image" 200 other_size.status)

let test_router_refusals () =
  with_router (fun ~config:_ router ->
    check int "unknown keeper" 404 (get ~router (path "portrait-http-nobody")).status;
    check int "size out of range" 400 (get ~router (path ~size:"4096" keeper)).status;
    check int "size not a number" 400 (get ~router (path ~size:"big" keeper)).status;
    check int "malformed name" 400 (get ~router (path "Not_A_Keeper!")).status;
    List.iter (fun raw ->
      check int "malformed expected equipment is not an unbound read" 400
        (get ~router (path ~expected_equipment:raw keeper)).status)
      ["{partial"; "null"; {|{"head":"crown"}|};
       {|{"face":"bare_face","neck":"bare_neck","head":"crown","hand":"empty_hand","base":"no_dish","extra":true}|}])

let token_for config ~agent_name role =
  match Auth.create_token config.Workspace.base_path ~agent_name ~role with
  | Ok (token, _) -> token
  | Error error -> fail (Masc_domain.masc_error_to_string error)

(* Once HTTP auth is strict the portrait is a read like any other: no token is
   a 401, a token that may read state is a 200, a token that may only play a
   shared machine is refused. *)
let test_router_strict_auth_needs_a_read_token () =
  with_router (fun ~config router ->
    Auth.save_auth_config config.Workspace.base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let reader = token_for config ~agent_name:"portrait-http-reader" Masc_domain.Worker in
    let player = token_for config ~agent_name:"portrait-http-player" Masc_domain.Player in
    Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" (Some "1") @@ fun () ->
    let url = path ~size:"64" keeper in
    let anonymous = get ~router url in
    check int "no token" 401 anonymous.status;
    check bool "no picture without a token" false (String.starts_with ~prefix:png_signature anonymous.body);
    let read = get ~router ~token:reader url in
    check int "a reader's token" 200 read.status;
    check string "a PNG" "image/png" (header read "content-type");
    check int "a player's token" 403 (get ~router ~token:player url).status;
    let items = item_path keeper in
    check int "Item account rejects anonymous" 401 (get ~router items).status;
    let off = get ~router ~token:reader items in
    let expected_workspace = Server_base_path_diagnostics.detect
      ~effective_base_path:config.Workspace.base_path ~effective_masc_root:(Workspace.masc_dir config) () in
    let bound suffix = items ^ "?expected_workspace=" ^ Uri.pct_encode ~component:`Query_value suffix in
    check int "matching health workspace binding admits the current account" 200
      (get ~router ~token:reader (bound expected_workspace.effective_base_path)).status;
    check int "a different served workspace is refused before its account is read" 409
      (get ~router ~token:reader (bound (expected_workspace.effective_base_path ^ "/another-workspace"))).status;
    check int "blank workspace binding is malformed" 400
      (get ~router ~token:reader (bound " ")).status;
    check bool "reader sees explicit Candle off" true (item_account off = Masc_tui_keeper_items.Off);
    check bool "Off has explicit null revision" true
      (Yojson.Safe.Util.member "account_revision" (Yojson.Safe.from_string off.body) = `Null);
    check int "Item account rejects player" 403
      (get ~router ~token:player items).status;
    check int "Item account refuses an unknown Keeper" 404
      (get ~router ~token:reader (item_path "portrait-http-nobody")).status;
    check int "Item account refuses a malformed Keeper" 400
      (get ~router ~token:reader (item_path "Not_A_Keeper!")).status;
    let candle_path =
      Config_dir_resolver.candle_toml_path_for_base_path
        ~base_path:config.Workspace.base_path in
    Fs_compat.mkdir_p (Filename.dirname candle_path);
    Fs_compat.save_file candle_path "[shop]\nprices_milli = \"bad\"\n";
    let disabled = get ~router ~token:reader items in
    let observed_revision = Candle_observe.account_revision
      (Candle_observe.read ~now:Time_compat.now ~base_path:config.Workspace.base_path) ~keeper in
    check (option string) "stable Disabled revision agrees with the actual roster helper"
      observed_revision (Some Yojson.Safe.Util.(Yojson.Safe.from_string disabled.body |> member "account_revision" |> to_string));
    (match item_account disabled with
     | Masc_tui_keeper_items.Disabled reason ->
       check bool "disabled names a reason" true (String.length reason > 0)
     | Masc_tui_keeper_items.Off | Masc_tui_keeper_items.Ready _ ->
       fail "invalid Candle policy was not visible in Item account"))

let file_state file =
  let stats = Unix.stat file in
  In_channel.with_open_bin file In_channel.input_all, stats.Unix.st_mtime, stats.Unix.st_ino

(* The presence check looks at the file system entry only. A GET leaves the
   metadata file as it was, and a file that does not even decode still counts
   as a Keeper rather than being repaired or quarantined. *)
let test_router_leaves_keeper_metadata_untouched () =
  with_router (fun ~config router ->
    let meta = Keeper_types_profile.keeper_meta_path config keeper in
    let before = file_state meta in
    check int "drawn" 200 (get ~router (path ~size:"64" keeper)).status;
    check int "drawn again" 200 (get ~router (path ~size:"80" keeper)).status;
    check bool "metadata bytes, time and inode unchanged" true (before = file_state meta);
    let unreadable = "portrait-http-garbled" in
    let garbled = Keeper_types_profile.keeper_meta_path config unreadable in
    Out_channel.with_open_bin garbled (fun channel -> Out_channel.output_string channel "{ not json");
    let garbled_before = file_state garbled in
    check int "a file that does not decode is still present" 200
      (get ~router (path ~size:"64" unreadable)).status;
    check bool "and is not rewritten" true (garbled_before = file_state garbled))

let test_purchase_equip_and_remote_portrait () =
  with_router (fun ~config router ->
    let base_path = config.Workspace.base_path in
    let runtime_path = Filename.concat base_path "portrait-test-runtime.toml" in
    Fs_compat.save_file runtime_path {|[runtime]
default = "test_provider.test_model"
[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"
[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true
[test_provider.test_model]
is-default = true
max-concurrent = 1
|};
    require_ok Fun.id (Runtime.init_default ~config_path:runtime_path);
    let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
    if not (String.starts_with ~prefix:(base_path ^ Filename.dir_sep) keepers_dir) then fail "Keeper fixture escaped workspace";
    Fs_compat.mkdir_p keepers_dir;
    Fs_compat.save_file (Filename.concat keepers_dir (keeper ^ ".toml"))
      "[keeper]\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\ninstructions = \"portrait integration fixture\"\n";
    Candle_status.install_appraiser_check (fun () -> Ok ());
    let policy_path = Config_dir_resolver.candle_toml_path_for_base_path ~base_path in
    if not (String.starts_with ~prefix:base_path policy_path) then fail "policy escaped fixture";
    Fs_compat.mkdir_p (Filename.dirname policy_path);
    let policy_text price = Printf.sprintf {|half_life = "off"
[payout]
weight_max = 1
deduction_rate = 0
deduction_floor = 1000
[payout.grades_milli]
trivial = 1000
small = 1000
medium = 1000
large = 1000
epic = 1000
[shop.prices_milli]
crown = %d
beanie = %d
|} price price in
    Fs_compat.save_file policy_path (policy_text 200);
    let owner = require_ok Fun.id (Keeper_id.Keeper_name.of_string keeper) in
    let at = require_ok Fun.id (Candle_time.of_rfc3339 "2026-09-29T00:00:00Z") in
    let payment = require_ok Fun.id (Candle_payment.make
      ~identity:{goal_id="portrait-goal";request_id="proof-request";verification_run_id="proof-run"}
      ~grade:Candle_grade.Trivial ~total_milli:1000
      ~grade_trace:{run_id="grade";slot_id="appraiser"}
      ~relations:[{task_id="task";relation=Candle_appraisal.Related;trace={run_id="relation";slot_id="appraiser"}}]
      ~weights_trace:{run_id="weights";slot_id="appraiser"}
      ~weight_max:1 ~deduction_rate:0 ~deduction_floor:1000 ~overdue_hours:0 ~weights:[keeper,1]) in
    require_ok (Candle_ledger.update_error_to_string Fun.id)
      (Candle_ledger.update ~base_path (fun _ -> Ok (funding_rows at payment, ())));
    let starting = Keeper_portrait_look.equipment_of_name keeper in
    let id = match starting.head with Keeper_portrait_look.Crown -> "beanie"
      | Keeper_portrait_look.Bare_head | Keeper_portrait_look.Bow | Keeper_portrait_look.Beanie -> "crown" in
    let item = match Keeper_portrait_item.of_id id with Some item -> item | None -> fail "catalog item missing" in
    let expected = Keeper_portrait_item.preview item starting in
    let call ?(slot="head") item = Keeper_candle_tools.handle ~operation:Keeper_candle_tools.Equip
      ~base_path ~keeper_name:keeper ~tool_name:"keeper_candle_equip" ~start_time:(Tool_timing.start ())
      ~args:(`Assoc ["slot", `String slot;"item",`String item]) in
    let accepted = function Tool_result.Completed _ as result -> Tool_result.data result
      | other -> fail (Tool_result.message other) in
    let ledger_bytes () = Fs_compat.load_file (Candle_ledger.path ~base_path) in
    let initial = ledger_bytes () in
    (match call id with Tool_result.Completed _ -> fail "equipped without purchase" | _ -> ());
    check string "refusal did not mutate ledger" initial (ledger_bytes ());
    check int "expected equipment does not authorize an unowned outfit" 409
      (get ~router (bound_path ~size:"96" expected keeper)).status;
    check string "bound refusal does not equip or append" initial (ledger_bytes ());
    let before = get ~router (path ~size:"96" keeper) in
    check int "starting portrait" 200 before.status;
    let reader = token_for config ~agent_name:"portrait-item-reader" Masc_domain.Worker in
    let credited = get ~router ~token:reader (item_path keeper) in
    let credited_json = Yojson.Safe.from_string credited.body in
    check (option string) "ready HTTP account is bound to the actual roster revision"
      (Candle_observe.account_revision (Candle_observe.read ~now:Time_compat.now ~base_path) ~keeper)
      (Some Yojson.Safe.Util.(credited_json |> member "account_revision" |> to_string));
    let fields = match credited_json with `Assoc fields -> fields | _ -> fail "Item object" in
    List.iter (fun json ->
      match Masc_tui_keeper_items.decode ~keeper_name:keeper json with
      | Error _ -> () | Ok _ -> fail "TUI accepted missing or malformed account revision")
      [`Assoc (List.remove_assoc "account_revision" fields);
       `Assoc (("account_revision", `Null) :: List.remove_assoc "account_revision" fields);
       `Assoc (("account_revision", `String (String.make 64 'A')) :: List.remove_assoc "account_revision" fields)];
    check string "Item balance is an exact decimal string" "1000"
      Yojson.Safe.Util.(credited_json |> member "balance_milli" |> to_string);
    let original_revision = Yojson.Safe.Util.(credited_json |> member "account_revision" |> to_string) in
    Fs_compat.save_file policy_path (policy_text 400);
    let changed_json = Yojson.Safe.from_string (get ~router ~token:reader (item_path keeper)).body in
    let changed_revision = Yojson.Safe.Util.(changed_json |> member "account_revision" |> to_string) in
    check bool "price B changes actual response revision" false (original_revision = changed_revision);
    let changed_reading = require_ok Fun.id (Masc_tui_keeper_items.decode ~keeper_name:keeper changed_json) in
    check bool "TUI refuses price B beside the retained price A roster" true
      (Result.is_error (Masc_tui_keeper_items.match_revision
        ~expected_revision:(Ok (Some original_revision)) changed_reading));
    check bool "TUI accepts price B only with its matching observed roster revision" true
      (Result.is_ok (Masc_tui_keeper_items.match_revision
        ~expected_revision:(Ok (Some changed_revision)) changed_reading));
    check bool "an unobserved roster cannot authorize an otherwise valid Item body" true
      (Result.is_error (Masc_tui_keeper_items.match_revision
        ~expected_revision:(Error "roster unavailable") changed_reading));
    check (option string) "price B response uses the same current roster view identity"
      (Candle_observe.account_revision (Candle_observe.read ~now:Time_compat.now ~base_path) ~keeper)
      (Some changed_revision);
    let changed_catalog = Yojson.Safe.Util.(changed_json |> member "catalog" |> to_list) in
    let changed_price = List.find (fun entry -> Yojson.Safe.Util.(entry |> member "id" |> to_string) = id) changed_catalog in
    check string "price B body is not mislabeled A" "400"
      Yojson.Safe.Util.(changed_price |> member "price_milli" |> to_string);
    Fs_compat.save_file policy_path (policy_text 200);
    let restored_json = Yojson.Safe.from_string (get ~router ~token:reader (item_path keeper)).body in
    check string "price A after B restores only A revision" original_revision
      Yojson.Safe.Util.(restored_json |> member "account_revision" |> to_string);
    let catalog_json = Yojson.Safe.Util.(credited_json |> member "catalog" |> to_list) in
    let priced = List.find (fun entry ->
      Yojson.Safe.Util.(entry |> member "id" |> to_string) = id) catalog_json in
    check string "Item price is an exact decimal string" "200"
      Yojson.Safe.Util.(priced |> member "price_milli" |> to_string);
    let with_balance value = match credited_json with
      | `Assoc fields -> `Assoc (List.map (fun (key, field) ->
          key, if String.equal key "balance_milli" then value else field) fields)
      | _ -> fail "Item account response is not an object" in
    (match Masc_tui_keeper_items.decode ~keeper_name:keeper
        (with_balance (`String (string_of_int max_int))) with
     | Ok (_, Masc_tui_keeper_items.Ready account) ->
       check int "Item decoder keeps the full OCaml wallet range" max_int account.balance_milli
     | Ok _ | Error _ -> fail "Item decoder lost a valid large wallet");
    List.iter (fun amount ->
      match Masc_tui_keeper_items.decode ~keeper_name:keeper (with_balance amount) with
      | Error _ -> ()
      | Ok _ -> fail "Item decoder accepted a noncanonical wallet")
      [`Int 1000; `String "01000"; `String "999999999999999999999999999999"];
    (match item_account credited with
     | Masc_tui_keeper_items.Ready account ->
       check int "Item view reads credited balance" 1000 account.balance_milli;
       check int "Item view reads full catalog" 18 (List.length account.catalog);
       check int "Item view starts without purchases" 0 (List.length account.owned_items)
     | Masc_tui_keeper_items.Off | Masc_tui_keeper_items.Disabled _ ->
       fail "credited Item account unavailable");
    let snapshot_computations = ref 0 in
    let dashboard_portrait () =
      let snapshot = Dashboard_projection_cache.get_or_compute_snapshot_json
        ~config ~actor:(Some "portrait-fixture") (fun _ ->
          incr snapshot_computations;
          `Assoc ["keepers", `Assoc ["items", `List [`Assoc ["name", `String keeper]]]]) in
      let rows = Yojson.Safe.Util.(snapshot |> member "keepers" |> member "items" |> to_list) in
      match rows with
      | [row] -> require_ok Fun.id (Keeper_portrait_equipment.reading_of_json
          Yojson.Safe.Util.(member "portrait" row))
      | _ -> fail "dashboard snapshot lost the Keeper row" in
    check bool "operator snapshot supplies starting portrait" true
      (dashboard_portrait () = Keeper_portrait_equipment.Ready starting);
    ignore (require_ok Candle_shop.error_to_string
      (Candle_shop.purchase ~now:(fun () -> 1790640000.) ~base_path ~keeper:owner ~item));
    (match item_account (get ~router ~token:reader (item_path keeper)) with
     | Masc_tui_keeper_items.Ready account ->
       check int "Item view reads debit" 800 account.balance_milli;
       check bool "Item view reads purchase" true (List.mem item account.owned_items)
     | Masc_tui_keeper_items.Off | Masc_tui_keeper_items.Disabled _ ->
       fail "purchased Item account unavailable");
    check string "purchase alone does not equip" before.body (get ~router (path ~size:"96" keeper)).body;
    let purchased = ledger_bytes () in
    (match call ~slot:"face" id with Tool_result.Completed _ -> fail "head item equipped into face slot" | _ -> ());
    check string "wrong-slot refusal does not append" purchased (ledger_bytes ());
    let equipped = accepted (call id) in
    check bool "first choice changed" true Yojson.Safe.Util.(equipped |> member "changed" |> to_bool);
    check bool "cached operator metadata exposes fresh equipped portrait" true
      (dashboard_portrait () = Keeper_portrait_equipment.Ready expected);
    check int "equipment refresh did not recompute metadata" 1 !snapshot_computations;
    let after = get ~router ~if_none_match:(header before "etag") (path ~size:"96" keeper) in
    check int "old tag does not conceal equipped item" 200 after.status;
    check bool "actual HTTP PNG changed" false (before.body = after.body);
    let refused = get ~router ~if_none_match:"*" (bound_path ~size:"96" starting keeper) in
    check int "pending A read refuses current B even with a held tag" 409 refused.status;
    check bool "mismatch publishes no PNG" false (String.starts_with ~prefix:png_signature refused.body);
    let bound = get ~router (bound_path ~size:"96" expected keeper) in
    check int "matching equipment publishes current B" 200 bound.status;
    check string "bound and unbound B share actual PNG" after.body bound.body;
    check int "matching equipment preserves 304" 304
      (get ~router ~if_none_match:(header bound "etag") (bound_path ~size:"96" expected keeper)).status;
    let stable = ledger_bytes () in
    let same = accepted (call id) in
    check bool "same choice is a no-op" false Yojson.Safe.Util.(same |> member "changed" |> to_bool);
    check string "same choice does not append" stable (ledger_bytes ());
    Keeper_tool_surface.For_testing.reset_keeper_list_cache ();
    let public_roster () = match !Keeper_dispatch_ref.dispatch ~config ~agent_name:"observer"
      ~publication_recovery_provider:Masc_test_deps.non_runtime_publication_recovery_provider
      ~name:"masc_keeper_list" ~args:(`Assoc ["detailed", `Bool true]) () with
      | Some result -> Yojson.Safe.from_string (Tool_result.message result)
      | None -> fail "public Keeper roster not registered" in
    let runtime_rows, errors, _, _, candle = require_ok Fun.id (Tui_decode.decode_keeper_runtime_list (public_roster ())) in
    check int "public roster has no metadata error rows" 0 (List.length errors);
    (match require_ok Fun.id candle with
     | Candle_observation.Ready supply ->
       check string "actual paid amount is issued" "1000" supply.issued_milli;
       check string "purchase burns only its price" "200" supply.burned_milli;
       check string "equipping leaves circulating amount unchanged" "800" supply.circulating_milli
     | Candle_observation.Off | Candle_observation.Disabled _ -> fail "paid ledger observation unavailable");
    let reading = match runtime_rows with
      | [row] ->
        check (option string) "remote wallet comes from the same ledger reading" (Some "800") row.Tui_decode.kr_candle_balance_milli;
        row.Tui_decode.kr_portrait
      | _ -> fail "expected one healthy decoded Keeper runtime row" in
    check bool "public roster and real TUI decoder preserve equipped input" true
      (reading = Keeper_portrait_equipment.Ready expected);
    check bool "restart-style replay preserves current equipment" true
      (require_ok Fun.id (Candle_equipment.current ~now:Time_compat.now ~base_path ~keeper) = expected);
    ignore (accepted (call "default"));
    check string "Default restores exact starting PNG" before.body (get ~router (path ~size:"96" keeper)).body;
    let restored = get ~router (bound_path ~size:"96" starting keeper) in
    check int "A after B after A accepts only matching A" 200 restored.status;
    check string "restored bound A is never the B PNG" before.body restored.body;
    let account = require_ok Candle_shop.error_to_string (Candle_shop.account ~now:Time_compat.now ~base_path ~keeper:owner) in
    check int "equipping spends no Candle" 800 account.balance_milli;
    check bool "reset preserves purchase ownership" true (List.mem item account.owned_items);
    Fs_compat.append_file (Candle_ledger.path ~base_path) "{partial";
    let corrupt = ledger_bytes () in
    check int "unreadable ledger refuses a cached portrait" 503 (get ~router (path ~size:"96" keeper)).status;
    check int "unreadable authority refuses a bound cached portrait" 503
      (get ~router (bound_path ~size:"96" starting keeper)).status;
    check int "unreadable ledger refuses an Item account" 503
      (get ~router ~token:reader (item_path keeper)).status;
    (match dashboard_portrait () with
     | Keeper_portrait_equipment.Unavailable _ -> ()
     | Keeper_portrait_equipment.Ready _ -> fail "dashboard hid unreadable authority with cached gear");
    let damaged_rows, errors, _, _, damaged_candle = require_ok Fun.id
      (Tui_decode.decode_keeper_runtime_list (public_roster ())) in
    check int "currency failure does not invent a Keeper metadata error" 0 (List.length errors);
    (match require_ok Fun.id damaged_candle with
     | Candle_observation.Disabled {reason} -> check bool "ledger error is observable" true (String.length reason > 0)
     | Candle_observation.Off | Candle_observation.Ready _ -> fail "damaged ledger concealed its failure");
    (match runtime_rows, damaged_rows with
     | [before], [row] ->
       check (option string) "damaged ledger withdraws prior balance" None row.Tui_decode.kr_candle_balance_milli;
       check bool "Keeper lifecycle reading survives currency failure" true
         (before.kr_phase = row.kr_phase && before.kr_health = row.kr_health && before.kr_keepalive_running = row.kr_keepalive_running)
     | _ -> fail "currency failure hid the healthy Keeper");
    check string "portrait read does not truncate damaged ledger" corrupt (ledger_bytes ());
    (match Sys.getenv_opt "RUNNER_TEMP" with
     | None -> ()
     | Some root ->
       (* Only CI artifact export may write under the runner home. The
          workspace and all product mutations retain the isolation guard. *)
       Masc_test_deps.with_process_env "MASC_TEST_ALLOW_HOME_BASE_PATH" (Some "1")
       @@ fun () ->
       let evidence = Filename.concat root "candle-equipped-portrait" in
       Fs_compat.mkdir_p evidence;
       Fs_compat.save_file (Filename.concat evidence "before.png") before.body;
       Fs_compat.save_file (Filename.concat evidence "equipped.png") after.body;
       Fs_compat.save_file (Filename.concat evidence "manifest.json")
         (Yojson.Safe.pretty_to_string (`Assoc ["keeper",`String keeper;
           "before",Keeper_portrait_equipment.to_json starting;
           "equipped",Keeper_portrait_equipment.to_json expected;
           "before_etag",`String (header before "etag");"equipped_etag",`String (header after "etag");
           "build",Build_identity.to_yojson (Build_identity.current ());
           "scope",`String "real HTTP router fixture after purchase and equip; not live deployment"]))) )

let () =
  run "Keeper portrait HTTP"
    [ "answer",
      [ test_case "route is exact" `Quick test_route_is_exact
      ; test_case "default and requested size" `Quick test_size_and_default
      ; test_case "bad sizes are refused, not clamped" `Quick test_bad_sizes_are_refused_not_clamped
      ; test_case "name, size, presence, in that order" `Quick test_order_of_checks
      ; test_case "same name, same bytes" `Quick test_same_name_same_bytes
      ; test_case "a held tag is answered without drawing" `Quick test_a_held_tag_is_answered_without_drawing
      ; test_case "tags follow build, name and size" `Quick test_tags_follow_build_name_and_size
      ; test_case "unscoped tags follow the bytes" `Quick test_unscoped_tags_follow_the_bytes
      ; test_case "cache stays within its byte budget" `Quick test_cache_keeps_drawings_within_its_budget
      ; test_case "equipment wire changes actual PNG and cache identity" `Quick test_equipment_wire_and_cache
      ; test_case "expected equipment is checked once before tags/cache" `Quick test_expected_equipment_precedes_tags_and_cache
      ; test_case "account identity binds facts, not natural decay" `Quick test_account_revision_binds_facts_not_decay_clock ]
    ; "router",
      [ test_case "PNG with a strong tag and 304" `Quick test_router_serves_png_with_a_strong_tag
      ; test_case "400 and 404" `Quick test_router_refusals
      ; test_case "strict auth needs a read token" `Quick test_router_strict_auth_needs_a_read_token
      ; test_case "GET leaves keeper metadata untouched" `Quick test_router_leaves_keeper_metadata_untouched
      ; test_case "purchase equip reset and remote portrait share one ledger" `Quick test_purchase_equip_and_remote_portrait ] ]
