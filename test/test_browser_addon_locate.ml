(** Real worker owner/model queue/Gecko consumer with a scripted WebDriver
    transport. No browser, provider or user profile is started. *)
open Alcotest
open Masc
module B=Browser_lane
module W=Browser_addon_wire
module Models=Browser_addon_models
module Owner=Browser_addon_owner
module Driver=Browser_webdriver
let ok=function Ok value -> value | Error _ -> fail "locate scenario failed"
let node ~text ~x=`Assoc ["nodeId",`String "menu";"kind",`String "control";"tag",`String "button";
  "text",`String text;"clickable",`Bool true;"editable",`Bool false;"disabled",`Bool false;
  "rects",`List [`Assoc ["x",`Float x;"y",`Float 10.;"width",`Float 60.;"height",`Float 20.]];
  "color",`String "black";"fontSize",`Float 16.;"fontWeight",`String "400";
  "whiteSpace",`String "normal";"sourceContext",`Null]
let scene ~document ~text ~x=`Assoc ["schema",`String "masc.browser.scene.v1";"documentId",`String document;
  "url",`String "https://example.test/";"title",`String "Fixture";"view",`String "content";"scope",`Null;
  "viewport",`Assoc ["width",`Float 800.;"height",`Float 600.;"scrollX",`Float 0.;"scrollY",`Float 0.];
  "nodes",`List [node ~text ~x];"truncated",`Bool false]
let scenario manifest =
  let root=Filename.temp_dir "browser-locate-" "" |> Unix.realpath in
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree root) (fun () ->
  Eio_main.run (fun env -> Eio.Switch.run (fun sw ->
    let clock=Eio.Stdenv.clock env in
    Time_compat.set_clock clock;Fs_compat.set_fs (Eio.Stdenv.fs env);
    Eio.Time.with_timeout_exn clock 15. (fun () ->
    Eio_context.with_test_env ~sw ~clock ~net:(Eio.Stdenv.net env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
      let package=Lane_addon_manifest.load ~path:manifest |> ok in
      check bool "bundled package declares its locate model consumer" true
        (List.exists (fun (output:Lane_addon_types.exact_output) -> output.name="locate") package.exact_outputs);
      let incarnation="0b000000-0000-4000-8000-000000000009" in
      let owner=Owner.create ~incarnation |> ok in
      check bool "no selected output exposes no model consumer" true (Browser_addon_locate.for_owner owner=Ok None);
      let models=Models.create ~incarnation ~configuration:{Models.store_root=Filename.concat root "model-results";
        outputs=package.exact_outputs} |> ok in
      Owner.attach_models owner models |> ok;
      let locate=Browser_addon_locate.for_owner owner |> ok in
      check bool "manifest schema matches the implemented consumer" true (Option.is_some locate);
      let document=ref "d1" and text=ref "Menu" and x=ref 5. and inputs=ref 0 in
      let request ~method_ ~path ~body = match method_,path with
        | `POST,"/session" -> Ok (`Assoc ["sessionId",`String "owned";
            "capabilities",`Assoc ["webSocketUrl",`String "ws://localhost/session/owned"]])
        | `GET,"/session/owned/window/handles" -> Ok (`List [`String "tab"])
        | `GET,"/session/owned/window" -> Ok (`String "tab")
        | `POST,"/session/owned/window" | `POST,"/session/owned/frame" | `DELETE,"/session/owned" -> Ok `Null
        | `POST,"/session/owned/execute/sync" ->
            (match Option.map Yojson.Safe.Util.(member "args") body with
             | Some (`List [_]) -> Ok (scene ~document:!document ~text:!text ~x:!x)
             | Some (`List []) -> Ok (`Assoc ["url",`String "https://example.test/";"title",`String "Fixture"])
             | None|Some _ -> fail "unexpected script arguments")
        | `POST,"/session/owned/actions" -> incr inputs;fail "locate must never dispatch browser input"
        | _ -> fail ("unexpected locate WebDriver request " ^ path) in
      let start_downloads ~session_id:_ ~websocket_url:_=Ok Browser_downloads.{
        read=(fun ~context:_ -> Ok (`Assoc ["downloads",`List []]));
        console=(fun ~context:_ -> Ok (`Assoc ["entries",`List [];"dropped",`Int 0]));check=(fun () -> Ok ());close=(fun () -> ())} in
      let driver=Driver.create ?locate ~start_downloads ~request () in
      ignore (Driver.execute driver (B.Session_open {headless=Some true}));
      ignore (Driver.execute driver B.Tabs_list);
      Owner.attach_automation owner ~locate:true ~execute:(Driver.execute driver)
        ~session:(fun () -> Driver.session_observation driver)
        ~document:(fun ~tab_id -> Driver.observe_document_if_idle driver ~tab_id)
        ~cleanup:(fun () -> Driver.close driver |> Result.map_error Driver.error_message) |> ok;
      check bool "inventory observes selected consumer, independently of provider readiness" true
        ((Browser_selection.snapshot ()).automation.locate);
      let invoke ()=Browser_addon_tool.invoke ~owner ~principal:(Lane_addon_call_context.Host_actor "reader")
        (`Assoc ["lane",`String "automation";"command",B.verb_json (B.Page_locate {tab_id=1;instruction=Some "Find Menu"})]) in
      let start ()=
        let before=Models.wait models ~after:None |> ok in
        Eio.Switch.check sw;
        let pending=Eio.Fiber.fork_promise ~sw invoke in
        let ready=Models.wait models ~after:(Some before.revision) |> ok in
        let id=match ready.request_ids with [id] -> id | _ -> fail "one original command must own one model request" in
        let listing=Models.listing models |> ok |> Lane_addon_host_request.listing_of_json |> ok in
        (match listing with [Lane_addon_host_request.Exact_output request] ->
          check string "request uses declared output" "locate" request.output;
          check int "request contains one scoped observation" 1 (List.length request.messages)
         | _ -> fail "missing exact locate request");
        pending,id in
      let deliver id node_id=Models.deliver models ~arguments:(Lane_addon_host_request.result_arguments ~request_id:id
        ~result:(`Assoc ["status",`String "answered";"slot",`String "fixture";"output",`Assoc ["matches",`List [
          `Assoc ["nodeId",`String node_id;"description",`String "The menu control"]]]])) |> ok in
      let failed pending=let (result:Mcp_protocol.Mcp_types.tool_result)=Eio.Promise.await_exn pending in
        check bool "stale or unobserved model selection is refused" true (result.is_error=Some true);
        check bool "locate refusal retains its original effect uncertainty" true
          (snd (Lane_addon_tool_result.failure result)=Tool_result.Effect_outcome_unknown) in
      let pending,id=start () in
      (* The locate command is now waiting on its model. That wait must not hold
         the session lock or the active count: an idle document observation
         still answers instead of reporting the owned browser as busy. *)
      (match Driver.observe_document_if_idle driver ~tab_id:1 with
       | B.Answered _ -> ()
       | B.Refused reason -> fail ("idle observation was refused during the locate model wait: " ^ reason)
       | B.Rejected_before_effect reason -> fail ("idle observation was rejected during the locate model wait: " ^ reason)
       | B.Lane_absent | B.Timed_out -> fail "idle observation did not reach the owned session");
      x:=42.;check bool "original waiter accepts result" true (deliver id "menu");
      let result=Eio.Promise.await_exn pending in
      check bool "actual consumer returns success" true (result.is_error=Some false);
      let data=Option.get result.structured_content |> Yojson.Safe.Util.member "answer"
        |> Yojson.Safe.Util.member "payload" |> Yojson.Safe.Util.member "data" in
      check string "returned target belongs to the observed document" "d1"
        Yojson.Safe.Util.(data |> member "matches" |> index 0 |> member "target" |> member "documentId" |> to_string);
      check (float 0.) "geometry is freshly observed, not the model's" 42.
        Yojson.Safe.Util.(data |> member "matches" |> index 0 |> member "observation" |> member "rects" |> index 0 |> member "x" |> to_float);
      let pending,id=start () in text:="Different action";ignore (deliver id "menu");failed pending;text:="Menu";
      let pending,id=start () in document:="d2";ignore (deliver id "menu");failed pending;document:="d1";
      let pending,id=start () in ignore (deliver id "invented");failed pending;
      let before=Models.wait models ~after:None |> ok in
      ignore (Eio.Fiber.first (fun () -> ignore (invoke ());false)
        (fun () -> ignore (Models.wait models ~after:(Some before.revision));true));
      check (list string) "original command cancellation withdraws its model request" []
        (Models.wait models ~after:None |> ok).request_ids;
      let pending,_=start () in
      check bool "private retirement joins the waiting model and driver cleanup" true
        (Owner.dispatch owner {W.incarnation;command=W.Retire}=W.Receipt);
      check bool "retirement cannot report a successful browser result" true
        ((Eio.Promise.await_exn pending).is_error=Some true);
      check bool "retirement withdraws locate availability" false (Browser_selection.snapshot ()).automation.locate;
      check int "all locate scenarios issued zero browser input" 0 !inputs)))))
let ()=Mirage_crypto_rng_unix.use_default ();
  (* The dune stanza passes the manifest it depends on, but the targeted-suite
     runner executes the exe with no arguments. Resolve the bundled manifest in
     that case instead of failing, so the suite can be run both ways. *)
  let bundled_manifest () =
    let candidates=["addons/browser/lane.toml";"../addons/browser/lane.toml";
      "../../addons/browser/lane.toml"] in
    match List.find_opt Sys.file_exists candidates with
    | Some path -> path
    | None ->
      fail ("expected bundled browser manifest path; looked for "
        ^ String.concat ", " candidates) in
  let manifest=if Array.length Sys.argv=2 then Sys.argv.(1) else bundled_manifest () in
  run ~argv:[|Sys.argv.(0)|] "browser Add-on locate consumer" ["read-only",[
    test_case "selected model, current targets, withdrawal and retire" `Quick (fun () -> scenario manifest)]]
