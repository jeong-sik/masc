open Alcotest
open Masc

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
    ?(holds_tag = holds_nothing) ?equipment ~name ~size ~keeper_present () =
  let equipment = match equipment with
    | Some read -> read
    | None -> (fun () -> Ok (Keeper_portrait_look.equipment_of_name name)) in
  Api.answer ~cache ~build ~name ~size ~keeper_present ~equipment ~holds_tag

let describe = function
  | Api.Png _ -> "Png"
  | Api.Not_modified tag -> "Not_modified " ^ tag
  | Api.Invalid_name -> "Invalid_name"
  | Api.Invalid_size raw -> "Invalid_size " ^ raw
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

let path ?size name =
  "/api/v1/keepers/" ^ name ^ "/portrait.png"
  ^ match size with None -> "" | Some size -> "?size=" ^ size

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
    check int "malformed name" 400 (get ~router (path "Not_A_Keeper!")).status)

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
    check bool "reader sees explicit Candle off" true
      (item_account (get ~router ~token:reader items) = Masc_tui_keeper_items.Off);
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
    (match item_account (get ~router ~token:reader items) with
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
    Fs_compat.save_file policy_path {|[payout]
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
crown = 200
beanie = 200
|};
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
      (Candle_ledger.update ~base_path (fun _ -> Ok ([{Candle_event.at;body=Candle_event.Paid payment}], ())));
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
    let before = get ~router (path ~size:"96" keeper) in
    check int "starting portrait" 200 before.status;
    let reader = token_for config ~agent_name:"portrait-item-reader" Masc_domain.Worker in
    let credited = get ~router ~token:reader (item_path keeper) in
    let credited_json = Yojson.Safe.from_string credited.body in
    check string "Item balance is an exact decimal string" "1000"
      Yojson.Safe.Util.(credited_json |> member "balance_milli" |> to_string);
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
     | Ok (Masc_tui_keeper_items.Ready account) ->
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
    let stable = ledger_bytes () in
    let same = accepted (call id) in
    check bool "same choice is a no-op" false Yojson.Safe.Util.(same |> member "changed" |> to_bool);
    check string "same choice does not append" stable (ledger_bytes ());
    Keeper_tool_surface.For_testing.reset_keeper_list_cache ();
    let roster = match !Keeper_dispatch_ref.dispatch ~config ~agent_name:"observer"
      ~publication_recovery_provider:Masc_test_deps.non_runtime_publication_recovery_provider
      ~name:"masc_keeper_list" ~args:(`Assoc ["detailed", `Bool true]) () with
      | Some result -> Yojson.Safe.from_string (Tool_result.message result)
      | None -> fail "public Keeper roster not registered" in
    let runtime_rows, errors, _, _ = require_ok Fun.id (Tui_decode.decode_keeper_runtime_list roster) in
    check int "public roster has no metadata error rows" 0 (List.length errors);
    let reading = match runtime_rows with
      | [row] -> row.Tui_decode.kr_portrait
      | _ -> fail "expected one healthy decoded Keeper runtime row" in
    check bool "public roster and real TUI decoder preserve equipped input" true
      (reading = Keeper_portrait_equipment.Ready expected);
    check bool "restart-style replay preserves current equipment" true
      (require_ok Fun.id (Candle_equipment.current ~base_path ~keeper) = expected);
    ignore (accepted (call "default"));
    check string "Default restores exact starting PNG" before.body (get ~router (path ~size:"96" keeper)).body;
    let account = require_ok Candle_shop.error_to_string (Candle_shop.account ~base_path ~keeper:owner) in
    check int "equipping spends no Candle" 800 account.balance_milli;
    check bool "reset preserves purchase ownership" true (List.mem item account.owned_items);
    Fs_compat.append_file (Candle_ledger.path ~base_path) "{partial";
    let corrupt = ledger_bytes () in
    check int "unreadable ledger refuses a cached portrait" 503 (get ~router (path ~size:"96" keeper)).status;
    check int "unreadable ledger refuses an Item account" 503
      (get ~router ~token:reader (item_path keeper)).status;
    (match dashboard_portrait () with
     | Keeper_portrait_equipment.Unavailable _ -> ()
     | Keeper_portrait_equipment.Ready _ -> fail "dashboard hid unreadable authority with cached gear");
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
      ; test_case "equipment wire changes actual PNG and cache identity" `Quick test_equipment_wire_and_cache ]
    ; "router",
      [ test_case "PNG with a strong tag and 304" `Quick test_router_serves_png_with_a_strong_tag
      ; test_case "400 and 404" `Quick test_router_refusals
      ; test_case "strict auth needs a read token" `Quick test_router_strict_auth_needs_a_read_token
      ; test_case "GET leaves keeper metadata untouched" `Quick test_router_leaves_keeper_metadata_untouched
      ; test_case "purchase equip reset and remote portrait share one ledger" `Quick test_purchase_equip_and_remote_portrait ] ]
