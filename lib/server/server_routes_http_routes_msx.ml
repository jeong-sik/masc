(** HTTP routes for the workspace MSX machine (RFC-0439 §3.7, RFC #38695).

    Spectating the machine goes through
    [GET /api/v1/lane-addons/live?source_kind=msx_capture] (RFC #38695);
    the legacy per-machine frame route has been removed.

    [POST /api/v1/msx/press] lets the human at the TUI press keys on the same
    machine a keeper is playing (RFC-0439 §3.3): [{keys:[..], hold_frames?,
    frames?, sequence?}] goes to [Msx_lane.press] under the identity
    [with_tool_actor_auth] resolved for the request, so its edges land in the
    shared ledger next to the keeper's under the name the credential carries.
    It is a write, gated like the mutating MSX tools. A field of the wrong
    type is a 400 naming the field, never a silent default. *)

open Server_auth
module Http = Http_server_eio

let json_field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

(* The body of a refused MSX write: [{ok:false, message}], with [code] first
   when the caller names one. The caller names it, not the HTTP status: 409 is
   also the activity gate's answer, under its own codes. *)
let write_error_json ?code message : Yojson.Safe.t =
  let fields = ["ok", `Bool false; "message", `String message] in
  `Assoc (match code with
    | Some code -> ("code", `String code) :: fields
    | None -> fields)
;;

(* Request-owned workspace admission precedes every MSX effect. The shared
   validator strips the binding so strict operation decoders retain their
   existing field contracts. The handler uses this same captured config. A
   refusal is the finished answer; only the failed precondition carries the
   [code] the terminal reads to tell a changed workspace from the activity
   refusals. *)
let decode_write_body ~config ~body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message ->
      Error (`Bad_request, write_error_json ("invalid JSON: " ^ message))
  | args -> match Workspace.validate_expected_workspace ~config args with
      | Ok args -> Ok args
      | Error Workspace.Invalid_workspace_precondition ->
          Error (`Bad_request, write_error_json "invalid expected_workspace precondition")
      | Error Workspace.Workspace_precondition_failed ->
          Error (`Conflict,
                 write_error_json ~code:"workspace_precondition_failed"
                   "workspace precondition failed")
;;

(* Frames a press holds its keys down, and the frames the call advances in
   all, when the body names neither (RFC-0439 §3.3): a tap. *)
let press_default_hold_frames = 5
let press_default_step_frames = 15

(* An absent field is the default; a present one must be a positive integer.
   The wrong type is the caller's mistake and is named back to them, not
   replaced by the default. *)
let positive_int_field name ~default json : (int, string) result =
  match json_field name json with
  | None -> Ok default
  | Some (`Int n) when n > 0 -> Ok n
  | Some (`Int _ | `Intlit _ | `Float _ | `String _ | `Bool _ | `Null | `List _ | `Assoc _) ->
    Error (name ^ " must be a positive integer")

let bool_field name ~default json : (bool, string) result =
  match json_field name json with
  | None -> Ok default
  | Some (`Bool b) -> Ok b
  | Some (`Int _ | `Intlit _ | `Float _ | `String _ | `Null | `List _ | `Assoc _) ->
    Error (name ^ " must be a boolean")

(* An absent array is empty (the press then fails for naming no key); a present
   one must hold only strings, so a stray number cannot vanish from a chord. *)
let string_list_field name json : (string list, string) result =
  let not_strings = Error (name ^ " must be an array of strings") in
  match json_field name json with
  | None -> Ok []
  | Some (`List items) ->
    List.fold_left
      (fun acc item ->
        match acc, item with
        | (Error _ as e), _ -> e
        | Ok ss, `String s -> Ok (ss @ [ s ])
        | Ok _, (`Int _ | `Intlit _ | `Float _ | `Bool _ | `Null | `List _ | `Assoc _) ->
          not_strings)
      (Ok []) items
  | Some (`Int _ | `Intlit _ | `Float _ | `String _ | `Bool _ | `Null | `Assoc _) -> not_strings

let press_result_json ~ok ?message (obs : Msx_lane.observation option) : Yojson.Safe.t =
  let base = [ ("ok", `Bool ok) ] in
  let base = match message with Some m -> base @ [ ("message", `String m) ] | None -> base in
  match obs with
  | None -> `Assoc base
  | Some o ->
    `Assoc
      (base
      @ [ ("frame", `Int o.Msx_lane.frame)
        ; ("mode", `String o.Msx_lane.mode)
        ; ( "cartridge"
          , match o.Msx_lane.cartridge with Some c -> `String c | None -> `Null )
        ; ("disk", match o.Msx_lane.disk with Some d -> `String d | None -> `Null )
        ])
;;

(* The activity gate rejects a request because the machine's activity is off,
   not because the request is malformed: the same request succeeds once the
   operator turns activity on, so the client should retry rather than fix its
   body. Every route that can hit the gate answers it the same way — 409 with
   the code the client keys on — so a client built against one route reads the
   other's rejection the same way. *)
let activity_rejection_json code =
  `Assoc [ ("ok", `Bool false); ("code", `String code) ]
;;

(* A human change to the machine wakes the Lane instances bound to it with the
   typed activity a Keeper's finished MSX tool produces through the event
   bridge (RFC machine-spectating-goes-through-lanes §2.2). These routes call
   [Msx_lane] or the tool handlers directly and publish no ToolCompleted, so the
   bridge never notifies for the same operation. An [Error] answer took no
   effect (msx_lane.mli error contract), so it does not notify. An exception is
   not an [Error]: a press or a restore/disk worker that raised may already have
   run frames or swapped the machine, so it notifies before the failure is
   reported, as the Keeper tool path notifies for a failed ToolCompleted. A
   cancelled press is re-raised without notifying: cancellation belongs to the
   caller and the notification would wait on the root domain. Save does not
   move the machine. Tick advances it every poll and stays silent until the RFC's §4
   realtime question has an answer. *)
let machine_changed ~config =
  Eio.Cancel.protect (fun () ->
    Lane_addon_runtime.notify_activity ~config ~activity:(Lane_addon_sources.Machine_changed Machine_lane.Msx))

(* The keys the caller named, parsed to the lane's vocabulary; the first bad one
   fails the whole press so nothing is half-applied. *)
let parse_keys names =
  List.fold_left
    (fun acc name ->
      match acc with
      | Error _ as e -> e
      | Ok ks -> (
        match Msx_lane.key_of_string name with
        | Ok k -> Ok (ks @ [ k ])
        | Error message -> Error message))
    (Ok []) names

(* The press body decoded and applied under [who], the identity the route's
   actor auth resolved. The route test drives it with its own workspace. *)
let press_response ~config ~who ~body =
  let error status message = status, write_error_json message in
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok json -> (
    let ( let* ) = Result.bind in
    let decoded =
      let* names = string_list_field "keys" json in
      let* keys = parse_keys names in
      let* hold_frames = positive_int_field "hold_frames" ~default:press_default_hold_frames json in
      let* step_frames = positive_int_field "frames" ~default:press_default_step_frames json in
      let* sequence = bool_field "sequence" ~default:false json in
      Ok (keys, hold_frames, step_frames, sequence)
    in
    match decoded with
    | Error message -> error `Bad_request message
    | Ok ([], _, _, _) -> error `Bad_request "keys must name at least one key"
    | Ok (keys, hold_frames, step_frames, sequence) -> (
      match Msx_lane.press ~who ~keys ~hold_frames ~step_frames ~sequence with
      | exception (Eio.Cancel.Cancelled _ as cancelled) -> raise cancelled
      | exception failure ->
        let bt = Printexc.get_raw_backtrace () in
        machine_changed ~config;
        Printexc.raise_with_backtrace failure bt
      | Ok obs ->
        machine_changed ~config;
        `OK, press_result_json ~ok:true (Some obs)
      | Error Msx_lane.Activity_disabled ->
        `Conflict, activity_rejection_json "activity_disabled"
      | Error Msx_lane.Activity_unobserved ->
        `Conflict, activity_rejection_json "activity_unobserved"
      | Error ((Msx_lane.No_machine | Msx_lane.Invalid_request _) as e) ->
        error `Bad_request (Msx_lane.error_to_string e)
      | Error (Msx_lane.Unreadable _ as e) ->
        error `Internal_server_error (Msx_lane.error_to_string e)))
;;

let handle_press ~state ~who request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let config = Mcp_server.workspace_config state in
      let status, json = press_response ~config ~who ~body in
      respond_json_value_with_cors ~status request reqd json)
;;

(* The cartridge inventory the TUI load menu shows (RFC-0439 §3.7): the file
   names under <.masc>/msx/carts an operator filled, plus which one is plugged
   in now so the menu can mark it. Read-only; loading a game is the write
   below. [carts_available] is the same listing masc_msx_load returns when it
   is called with no cart, so the menu and a keeper see one inventory. *)
let carts_json ~base_path : Yojson.Safe.t =
  let carts = Tool_misc_msx_lane.carts_available ~base_path in
  let loaded, cartridge, disk =
    match Msx_lane.frame () with
    | None -> (false, `Null, `Null)
    | Some f ->
      ( true
      , (match f.Msx_lane.cartridge with Some c -> `String c | None -> `Null)
      , (match f.Msx_lane.disk with Some d -> `String d | None -> `Null) )
  in
  `Assoc
    [ ("carts", `List (List.map (fun c -> `String c) carts))
    ; ("loaded", `Bool loaded)
    ; ("cartridge", cartridge)
    ; ("disk", disk)
    ]
;;

let load_result_json ~ok ~message : Yojson.Safe.t =
  `Assoc [ ("ok", `Bool ok); ("message", `String message) ]
;;

(* The human at the TUI plugs a cartridge into the shared machine. The whole
   resolution — a name to its carts/ path, the BIOS inventory, a bad name's
   error message — is [Tool_misc_msx_lane.handle_load]'s, the same code a
   keeper's masc_msx_load runs, so there is one loader and one inventory. The
   route only turns its tool result into an HTTP answer; the TUI re-fetches the
   frame to start spectating. Body: {cart:"name"}. *)
let load_response ~(config : Workspace.config) ~agent_name ~body =
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok args ->
    let result =
      (* Tool_timing.start is the one tool-start stamp Tool_misc.dispatch
         also uses; it reads Time_compat.now, the clock accessor the
         determinism gate accepts. *)
      Tool_misc_msx_lane.handle_load ~tool_name:"masc_msx_load"
        ~start_time:(Tool_timing.start ()) ~base_path:config.base_path
        ~agent_name ~after_load:(fun () -> machine_changed ~config) args
    in
    let ok = Tool_result.is_success result in
    let status = if ok then `OK else `Bad_request in
    status, load_result_json ~ok ~message:(Tool_result.message result)
;;

let handle_load ~state ~agent_name request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let config = Mcp_server.workspace_config state in
      let status, json = load_response ~config ~agent_name ~body in
      respond_json_value_with_cors ~status request reqd json)
;;

(* "who is at the machine": each keeper's most-recent key within a window of the
   current frame, newest first, projected from the shared ledger. The lane is one
   machine anyone may press, so this reports presence -- it does not reserve the
   slot. A turn in a turn-based game can run long, so the window is a full
   minute of machine time at the machine's frame rate. *)
let players_window_sec = 60
let players_window_frames = players_window_sec * Msx_lane.frames_per_second

let recent_players_of ~now entries =
  let last : (string, int) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun (e : Msx_lane.entry) ->
      Hashtbl.replace last e.Msx_lane.who e.Msx_lane.at_frame)
    entries;
  Hashtbl.fold
    (fun who f acc ->
      if now - f <= players_window_frames then (who, f) :: acc else acc)
    last []
  |> List.sort (fun (_, a) (_, b) -> compare b a)
;;

(* The lane owns immutable RGB snapshots and reuses their identity until a
   machine mutation. Cache only pixel encoding: clock and player metadata must
   remain live. One entry bounds retained memory across load/restore/eject.
   Stdlib mutex: this pure serializer also runs outside Eio in route tests;
   neither the protected lookup nor Base64 encoding performs I/O or yields. *)
let encoded_pixels_mutex = Mutex.create ()
let encoded_pixels : (string * string) option ref = ref None

let frame_rgb_base64 rgb =
  Mutex.lock encoded_pixels_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock encoded_pixels_mutex) (fun () ->
    match !encoded_pixels with
    | Some (previous, encoded) when previous == rgb -> encoded
    | None | Some _ ->
        let encoded = Base64.encode_string rgb in
        encoded_pixels := Some (rgb, encoded);
        encoded)
;;

(* Frames per poll-cadence tick (RFC-0439 §3.2). At the TUI's ~3 Hz spectator
   poll this advances ~54 frames a second, close enough to the machine's 60 Hz
   that a game reads as live without a server-side ticker. *)
let msx_tick_default_frames = 18

let clamp_tick_frames requested = max 1 (min Msx_lane.max_frames_per_call requested)

type pixel_reference = { revision : string; width : int; height : int }
type pixel_response = Full_frame | Retained_pixels of pixel_reference option

let decode_pixel_reference = function
  | `Assoc fields when List.length fields = 3 ->
      (match List.assoc_opt "revision" fields, List.assoc_opt "width" fields,
             List.assoc_opt "height" fields with
       | Some (`String revision), Some (`Int width), Some (`Int height)
         when String.length revision = 64 && width > 0 && height > 0
              && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) revision ->
           Ok { revision; width; height }
       | _ -> Error "known_pixels requires a SHA256 revision and positive width/height")
  | _ -> Error "known_pixels requires exactly revision, width and height"

let decode_tick json =
  match json with
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let names = List.map fst fields in
      let* () =
        if List.length names <> List.length (List.sort_uniq String.compare names)
           || List.exists (fun name -> not (List.mem name ["frames"; "pixel_response"; "known_pixels"])) names
        then Error "tick has duplicate or unknown fields" else Ok () in
      let* frames = match List.assoc_opt "frames" fields with
        | None -> Ok msx_tick_default_frames
        | Some (`Int n) -> Ok (clamp_tick_frames n)
        | Some _ -> Error "frames must be an integer" in
      let* pixels = match List.assoc_opt "pixel_response" fields, List.assoc_opt "known_pixels" fields with
        | None, None -> Ok Full_frame
        | Some (`String "retained"), None -> Ok (Retained_pixels None)
        | Some (`String "retained"), Some value ->
            Result.map (fun reference -> Retained_pixels (Some reference)) (decode_pixel_reference value)
        | _ -> Error "known_pixels requires pixel_response=retained" in
      Ok (frames, pixels)
  | _ -> Error "tick body must be an object"
;;

type prepared_pixels = { rgb : string; encoded : string; reference : pixel_reference }
let tick_pixels_mutex = Mutex.create ()
let tick_pixels : prepared_pixels option ref = ref None

let prepare_tick_pixels (frame : Msx_lane.frame) =
  let previous = Mutex.protect tick_pixels_mutex (fun () -> !tick_pixels) in
  match previous with
  | Some pixels when pixels.reference.width = frame.width
                     && pixels.reference.height = frame.height
                     && String.equal pixels.rgb frame.rgb -> pixels
  | Some _ | None ->
      (* Advance invalidates the lane's RGB object even for identical pixels.
         Compare bytes before hashing/encoding; CPU work never holds this lock. *)
      let pixels =
        { rgb = frame.rgb; encoded = Base64.encode_string frame.rgb;
          reference = { width = frame.width; height = frame.height;
            revision = Digestif.SHA256.(to_hex (digest_string frame.rgb)) } } in
      Mutex.protect tick_pixels_mutex (fun () -> tick_pixels := Some pixels);
      pixels

let tick_frame_json pixel_response (frame : Msx_lane.frame) entries
    (mark : Msx_lane.change_mark) =
  let pixel_fields = match pixel_response with
    | Full_frame -> ["rgb_base64", `String (frame_rgb_base64 frame.rgb)]
    | Retained_pixels known ->
        let pixels = prepare_tick_pixels frame in
        let retained = known = Some pixels.reference in
        let fields =
          ["kind", `String (if retained then "retained" else "inline");
           "revision", `String pixels.reference.revision;
           "width", `Int frame.width; "height", `Int frame.height] in
        ["pixels", `Assoc (if retained then fields
           else fields @ ["rgb_base64", `String pixels.encoded])] in
  `Assoc
    (["loaded", `Bool true; "number", `Int frame.number;
      "change_count", `Int mark.count; "incarnation", `String mark.incarnation;
      "width", `Int frame.width; "height", `Int frame.height;
      "mode", `String frame.mode;
      "cartridge", (match frame.cartridge with Some s -> `String s | None -> `Null);
      "disk", (match frame.disk with Some s -> `String s | None -> `Null);
      "players", `List (List.map (fun (who, last) ->
        `Assoc ["who", `String who; "last_frame", `Int last;
                "frames_ago", `Int (frame.number - last)])
          (recent_players_of ~now:frame.number entries))] @ pixel_fields)

let tick_response ~config ~body =
  let error status message =
    status, write_error_json message
  in
  let decoded = Result.bind (decode_write_body ~config ~body) (fun args ->
    Result.map_error (error `Bad_request) (decode_tick args)) in
  match decoded with
  | Error refusal -> refusal
  | Ok (frames, pixel_response) ->
    (* This is a mutation: the best-effort executor adapter can replay failed
       work inline. Strict submission never retries or falls back to the HTTP
       domain. The worker owns both emulation and the frame's serialization. *)
    match Executor_pool_ref.submit_strict (fun () ->
      match Msx_lane.step_frame ~frames with
      | Ok (frame, entries, mark) ->
        `OK, tick_frame_json pixel_response frame entries mark
      | Error Msx_lane.No_machine -> `OK, `Assoc ["loaded", `Bool false]
      | Error Msx_lane.Activity_disabled ->
        `Conflict, activity_rejection_json "activity_disabled"
      | Error Msx_lane.Activity_unobserved ->
        `Conflict, activity_rejection_json "activity_unobserved"
      | Error (Msx_lane.Invalid_request _ as e) ->
        error `Bad_request (Msx_lane.error_to_string e)
      | Error (Msx_lane.Unreadable _ as e) ->
        error `Internal_server_error (Msx_lane.error_to_string e))
    with
    | Ok response -> response
    | Error (Executor_pool_ref.Pool_unavailable | Executor_pool_ref.Caller_not_in_eio) ->
      error `Service_unavailable "MSX tick worker is unavailable"
    | Error ((Executor_pool_ref.Work_failed _ | Executor_pool_ref.Submission_failed _) as failure) ->
      Log.Http.error "MSX tick: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
      error `Internal_server_error "MSX tick failed; read the current frame before retrying"
;;

(* The realtime driver (RFC-0439 §3.2, poll-cadence tick). The spectating TUI
   posts this a few times a second to advance the shared machine, so a game
   flows even when no keeper is pressing a key. Body: {frames:N}, clamped to
   1..max_frames_per_call; the answer is the advanced frame, so one call both
   steps and reads. A write, gated like press. *)
let handle_tick ~state request reqd =
  Http.Request.read_body_async reqd (fun body ->
      let config = Mcp_server.workspace_config state in
      let status, json = tick_response ~config ~body in
      Http.Response.json_value_on_cpu ~status ~request
        ~extra_headers:(Server_auth.cors_headers (Server_auth.get_origin request)) json reqd)
;;

let activity_json () = `Assoc ["schema",`String "masc.msx-activity/v1";
  "activity",`String (Machine_configuration.activity_to_wire (Msx_lane.activity ()))]

let checkpoint_legacy_response ~(config : Workspace.config) ~restore ~body =
  let base_path = config.base_path in
  let error status message = status, write_error_json message in
  match decode_write_body ~config ~body with
  | Error refusal -> refusal
  | Ok args ->
    (match Tool_misc_msx_lane.checkpoint_slot args with
     | Error message -> error `Bad_request message
     | Ok slot ->
       let pre_effect message =
         `Assoc ["ok", `Bool false; "message", `String message;
           "checkpoint", `String (if restore then "restore" else "save");
           "slot", `String slot;
           "effect_disposition", `String
             (Tool_result.failure_effect_disposition_to_string Tool_result.Proven_pre_effect)] in
       match Executor_pool_ref.submit_strict (fun () ->
         let tool_name = if restore then "masc_msx_restore" else "masc_msx_save" in
         let result = Tool_misc_msx_lane.handle_checkpoint ~restore ~tool_name
             ~start_time:(Tool_timing.start ()) ~base_path args in
         let ok = Tool_result.is_success result in
         let status = match Tool_result.failure_class result with
           | None -> `OK
           | Some Tool_result.Workflow_rejection -> `Bad_request
           | Some _ -> `Internal_server_error in
         let response = match result with
           | Tool_result.Failed {effect_disposition=Tool_result.Proven_pre_effect;message;_} ->
               pre_effect message
           | _ -> load_result_json ~ok ~message:(Tool_result.message result) in
         ok, (status, response)) with
       | Ok (ok, response) ->
         if ok && restore then machine_changed ~config;
         response
       | Error (Executor_pool_ref.Pool_unavailable | Executor_pool_ref.Caller_not_in_eio) ->
         `Service_unavailable, pre_effect "MSX checkpoint worker is unavailable"
       | Error (Executor_pool_ref.Work_failed _ as failure) ->
         (* The worker ran and raised; a restore may have replaced the machine. *)
         if restore then machine_changed ~config;
         Log.Http.error "MSX checkpoint: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
         error `Internal_server_error "MSX checkpoint failed; inspect the current state before retrying"
       | Error (Executor_pool_ref.Submission_failed _ as failure) ->
         Log.Http.error "MSX checkpoint: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
         error `Internal_server_error "MSX checkpoint failed; inspect the current state before retrying")
;;

module Checkpoint_receipt = Server_msx_checkpoint_receipt
let checkpoint_epoch = Random_id.uuid_v7 ()
let checkpoint_receipt_path (config : Workspace.config) =
  Filename.concat (Tool_misc_msx_lane.msx_dir ~base_path:config.base_path) "checkpoint-operations.sqlite3"

let checkpoint_binding ~restore args =
  match args with
  | `Assoc fields ->
      (match List.filter (fun (key,_) -> key="operation_id") fields with
       | [_, `String raw] ->
           (match Keeper_operation_id.of_string raw,
                  Tool_misc_msx_lane.checkpoint_slot (`Assoc (List.remove_assoc "operation_id" fields)) with
            | Ok operation_id, Ok slot -> Ok {Checkpoint_receipt.operation_id;
                action=(if restore then Restore else Save);slot}
            | Error message, _ | _, Error message -> Error message)
       | _ -> Error "checkpoint operation_id must be one canonical string")
  | _ -> Error "checkpoint request must be an object"

let receipt_json ~(config : Workspace.config) (receipt : Checkpoint_receipt.receipt) =
  let binding = receipt.binding in
  let status, extra = match receipt.state with
    | Pending when receipt.epoch=checkpoint_epoch -> "pending", []
    | Pending -> "unknown", ["message",`String "checkpoint belongs to an earlier server instance"]
    | Unknown detail -> "unknown", ["message",`String detail]
    | Refused detail -> "refused", ["message",`String detail;
        "effect_disposition",`String "proven_pre_effect"]
    | Committed completed -> "committed", ["effect",`Assoc [
        "change_count",`Int completed.mark.count; "incarnation",`String completed.mark.incarnation;
        "checkpoint_sha256",`String completed.checkpoint_sha256]] in
  ["ok",`Bool (status="committed");
   "workspace",`Assoc ["base_path",`String (Unix.realpath config.base_path);
                         "masc_root",`String (Unix.realpath (Workspace.masc_root_dir config))];
   "operation_id",`String (Keeper_operation_id.to_string binding.operation_id);
   "checkpoint",`String (match binding.action with Save -> "save" | Restore -> "restore");
   "slot",`String binding.slot;"epoch",`String receipt.epoch;"status",`String status] @ extra

let checkpoint_request_with_workspace ~config ~body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error message -> Error (`Bad_request,write_error_json message)
  | `Assoc fields when List.mem_assoc "expected_workspace" fields -> decode_write_body ~config ~body
  | _ -> Error (`Bad_request,write_error_json "checkpoint operation requires expected_workspace")

let settle_checkpoint_effect ~restore ~persist ~notify settled =
  let persisted = persist settled in
  let notify_needed = match settled with
    | Checkpoint_receipt.Committed _ | Unknown _ -> restore
    | Pending | Refused _ -> false in
  if not notify_needed then persisted else
  match notify () with
  | () -> persisted
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
      let message = "MSX restore observer notification failed: " ^ Printexc.to_string exn in
      Error (match persisted with Ok () -> message | Error cause -> cause ^ "; " ^ message)

let checkpoint_operation_response ~(config : Workspace.config) ~restore ~body =
  let refused binding message =
    `Service_unavailable, `Assoc (receipt_json ~config
      {Checkpoint_receipt.binding;epoch=checkpoint_epoch;state=Refused message}) in
  match checkpoint_request_with_workspace ~config ~body with
  | Error response -> response
  | Ok args -> match checkpoint_binding ~restore args with
    | Error message -> `Bad_request,write_error_json message
    | Ok binding ->
        let path = checkpoint_receipt_path config in
        (* Admission is durably committed before the effect job is submitted.
           A cancelled HTTP waiter cannot turn a pending record into permission
           to dispatch the same operation again. *)
        match Executor_pool_ref.submit_strict (fun () ->
          Workspace.mkdir_p (Filename.dirname path);
          Checkpoint_receipt.admit ~path ~epoch:checkpoint_epoch binding) with
        | Error failure ->
            `Service_unavailable, `Assoc (receipt_json ~config
              {Checkpoint_receipt.binding;epoch=checkpoint_epoch;
               state=Unknown (Executor_pool_ref.strict_submit_error_to_string failure)})
        | Ok (Error Checkpoint_receipt.Binding_conflict) ->
            `Conflict,write_error_json "checkpoint operation identity is bound to another action or slot"
        | Ok (Error error) ->
            (* A failed lookup may hide an already-running duplicate. Failure
               to acquire admission is not proof this operation had no effect. *)
            `Service_unavailable, `Assoc (receipt_json ~config
              {Checkpoint_receipt.binding;epoch=checkpoint_epoch;
               state=Unknown (Checkpoint_receipt.error_to_string error)})
        | Ok (Ok (Existing receipt)) -> `OK, `Assoc (receipt_json ~config receipt)
        | Ok (Ok Accepted) ->
            let run () =
              let settled =
                try match Tool_misc_msx_lane.run_checkpoint ~restore ~base_path:config.base_path ~slot:binding.slot with
                | Ok completed -> Checkpoint_receipt.Committed {
                    mark=completed.mark;checkpoint_sha256=completed.checkpoint_sha256}
                | Error error -> Refused (Msx_lane.error_to_string error)
                with
                | Eio.Cancel.Cancelled _ as exn -> raise exn
                | exn -> Checkpoint_receipt.Unknown (Printexc.to_string exn) in
              (* Publish from the worker, even when its HTTP caller stopped
                 waiting. A failed store write must never manufacture success. *)
              match settle_checkpoint_effect ~restore
                ~persist:(fun state ->
                  Checkpoint_receipt.settle ~path ~epoch:checkpoint_epoch binding state
                  |> Result.map_error Checkpoint_receipt.error_to_string)
                ~notify:(fun () -> machine_changed ~config) settled with
              | Error message -> Error message
              | Ok () -> Ok {Checkpoint_receipt.binding;epoch=checkpoint_epoch;state=settled} in
            (match Executor_pool_ref.submit_strict run with
             | Ok (Ok receipt) ->
                 `OK, `Assoc (receipt_json ~config receipt)
             | Ok (Error message) -> `Internal_server_error,write_error_json message
             | Error (Executor_pool_ref.Pool_unavailable | Caller_not_in_eio) ->
                 (* The admitted job never started. A receipt-store failure here
                    leaves pending evidence; the direct answer still proves this
                    request did not dispatch its effect. *)
                 refused binding "MSX checkpoint worker is unavailable"
             | Error failure ->
                 `Internal_server_error,write_error_json (Executor_pool_ref.strict_submit_error_to_string failure))

let checkpoint_status_response ~(config : Workspace.config) ~body =
  match checkpoint_request_with_workspace ~config ~body with
  | Error response -> response
  | Ok (`Assoc fields) ->
      (match List.filter (fun (key,_) -> key="checkpoint") fields with
       | [_, `String ("save" | "restore" as action)] ->
           (match checkpoint_binding ~restore:(action="restore") (`Assoc (List.remove_assoc "checkpoint" fields)) with
            | Error message -> `Bad_request,write_error_json message
            | Ok binding ->
                (match Executor_pool_ref.submit_strict (fun () ->
                  match Checkpoint_receipt.inspect ~path:(checkpoint_receipt_path config) binding with
                  | Error error -> Error (Checkpoint_receipt.error_to_string error)
                  | Ok receipt ->
                      let receipt = Option.value receipt ~default:{Checkpoint_receipt.binding;
                        epoch=checkpoint_epoch;state=Unknown "checkpoint operation has not been observed"} in
                      let fields = receipt_json ~config receipt in
                      let fields = match receipt.state with
                        | Committed _ when binding.action=Restore ->
                            (* Completion is read first; pixels are copied under
                               the lane lock afterwards in this same workspace
                               request. They may include subsequent mutations. *)
                            let live = Server_routes_http_routes_lane_addons.msx_live
                              Machine_lane.Msx ~since:None () in
                            ("live",live)::("live_relation",`String "observed_after_completion")::fields
                        | Committed _ | Pending | Refused _ | Unknown _ -> fields in
                      Ok (`Assoc fields)) with
                 | Ok (Ok json) -> `OK,json
                 | Ok (Error message) -> `Internal_server_error,write_error_json message
                 | Error failure -> `Service_unavailable,write_error_json (Executor_pool_ref.strict_submit_error_to_string failure)))
       | _ -> `Bad_request,write_error_json "checkpoint must name save or restore")
  | Ok _ -> `Bad_request,write_error_json "checkpoint status request must be an object"

let checkpoint_response ~config ~restore ~body =
  match Yojson.Safe.from_string body with
  | `Assoc fields when List.mem_assoc "operation_id" fields -> checkpoint_operation_response ~config ~restore ~body
  | _ | exception Yojson.Json_error _ -> checkpoint_legacy_response ~config ~restore ~body
;;

let change_disk_response ~(config : Workspace.config) ~body =
    let error status message = status, write_error_json message in
    match decode_write_body ~config ~body with
      | Error refusal -> refusal
      | Ok args -> (
        match Executor_pool_ref.submit_strict (fun () ->
          let result = Tool_misc_msx_lane.handle_change_disk ~tool_name:"masc_msx_change_disk"
              ~start_time:(Tool_timing.start ()) ~base_path:config.base_path args in
          let ok = Tool_result.is_success result in
          let status = match Tool_result.failure_class result with
            | None -> `OK | Some Tool_result.Workflow_rejection -> `Bad_request
            | Some _ -> `Internal_server_error in
          ok, (status, load_result_json ~ok ~message:(Tool_result.message result))) with
        | Ok (ok, response) ->
          if ok then machine_changed ~config;
          response
        | Error (Executor_pool_ref.Pool_unavailable | Executor_pool_ref.Caller_not_in_eio) ->
          error `Service_unavailable "MSX disk worker is unavailable"
        | Error (Executor_pool_ref.Work_failed _ as failure) ->
          (* The worker ran and raised; the disk may already be swapped. *)
          machine_changed ~config;
          Log.Http.error "MSX disk change: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
          error `Internal_server_error "MSX disk change failed; inspect the current state before retrying"
        | Error (Executor_pool_ref.Submission_failed _ as failure) ->
          Log.Http.error "MSX disk change: %s" (Executor_pool_ref.strict_submit_error_to_string failure);
          error `Internal_server_error "MSX disk change failed; inspect the current state before retrying")
;;

let handle_change_disk ~state request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let config = Mcp_server.workspace_config state in
    let status, json = change_disk_response ~config ~body in
    respond_json_value_with_cors ~status request reqd json)
;;

let handle_checkpoint ~state ~restore request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let config = Mcp_server.workspace_config state in
    let status, json = checkpoint_response ~config ~restore ~body in
    respond_json_value_with_cors ~status request reqd json)
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/msx/activity" (fun request reqd ->
       with_public_read
         (fun _state req reqd -> Http.Response.json_value ~compress:true ~request:req (activity_json ()) reqd)
         request reqd)
  |> Http.Router.get "/api/v1/msx/carts" (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           Http.Response.json_value ~compress:true ~request:req
             (carts_json ~base_path) reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/checkpoint-operation" (fun request reqd ->
       with_read_auth (fun state request reqd ->
         Http.Request.read_body_async reqd (fun body ->
           let config = Mcp_server.workspace_config state in
           let status,json = checkpoint_status_response ~config ~body in
           respond_json_value_with_cors ~status request reqd json)) request reqd)
  |> Http.Router.post "/api/v1/msx/press" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_msx_press"
         (fun state who _req reqd ->
           handle_press ~state ~who request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/load" (fun request reqd ->
       with_tool_actor_auth ~tool_name:"masc_msx_load"
         (fun state agent_name _req reqd ->
           handle_load ~state ~agent_name request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/save" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_save"
         (fun state _req reqd ->
           handle_checkpoint ~state ~restore:false
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/restore" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_restore"
         (fun state _req reqd ->
           handle_checkpoint ~state ~restore:true
             request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/disk" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_change_disk"
         (fun state _req reqd ->
           handle_change_disk ~state request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/msx/tick" (fun request reqd ->
       with_tool_auth ~tool_name:"masc_msx_step"
         (fun state _req reqd -> handle_tick ~state request reqd)
         request reqd)
;;
