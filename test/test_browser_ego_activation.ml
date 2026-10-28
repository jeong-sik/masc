open Alcotest
module A = Masc.Browser_ego_activation
let obj fields = `Assoc fields
let str value = `String value
let field name json = Yojson.Safe.Util.member name json
let ok = function Ok value -> value | Error detail -> fail detail
let native ?(state_before="normal") ?(state_after="normal") ?(restored=false) () = obj [
  "spaceId",`Int 51;"label",str "p1";"targetId",str "T1";"urlBefore",str "https://example.org/";
  "url",str "https://example.org/";"title",str "Page";"active",`Bool true;
  "window",obj ["windowId",`Int 7;"stateBefore",str state_before;"stateAfter",str state_after;"restored",`Bool restored]]
let receipt = A.receipt ~space_id:51 ~tab_id:3 ~label:"p1" ~expected_url:"https://example.org/"
let replace name value = function `Assoc fields -> obj ((name,value)::List.remove_assoc name fields) | _ -> fail "object required"
let test_receipt_binding () =
  let result=ok (receipt (native ~state_before:"minimized" ~restored:true ())) in
  check bool "original tab and native observations retained" true
    (field "tabId" result=`Int 3 && field "action" result=str "activate_tab" && field "active" result=`Bool true);
  List.iter (fun value -> check bool "foreign/unconfirmed observation refused" true (Result.is_error (receipt value)))
    [replace "spaceId" (`Int 52) (native ());replace "label" (str "p2") (native ());
     replace "url" (str "https://example.org/moved") (native ());replace "active" (`Bool false) (native ());
     native ~state_after:"minimized" ();native ~state_before:"minimized" ();
     native ~restored:true ();native ~state_after:"future-state" ();
     replace "window" (obj ["windowId",`Int (-1);"stateBefore",str "normal";"stateAfter",str "normal";"restored",`Bool false]) (native ());
     (match native () with `Assoc fields -> obj (("active",`Bool true)::fields) | _ -> fail "object required")]

let execute config =
  let path=Filename.temp_file "masc-native-activation-" ".mjs" in
  let out=Filename.temp_file "masc-native-activation-" ".json" in
  Fun.protect ~finally:(fun () -> Sys.remove path;Sys.remove out) (fun () ->
    let shim={js|
const config=JSON.parse(process.argv[2]), calls=[];
let activated=false, state=config.state || 'normal', lookups=0;
const task={spaceId:51,
 tabs:async()=>{
  const changed=lookups>0 ? config.changeDuringLookup : undefined;
  return [{label:config.unmanaged ? null : changed==='label' ? 'p2' : 'p1',targetId:changed==='target' ? 'T2' : 'T1',
   openedBy:changed==='origin' ? (config.origin==='unknown' ? 'agent' : 'unknown')
    : activated && config.originAfter ? config.originAfter : config.origin || 'agent',
   url:(config.moved && activated) || changed==='url' ? 'https://example.org/moved' : 'https://example.org/',
   title:'Page',active:activated && !config.inactive}];
 },
 cdp:async(method,params)=>{
  calls.push({method,params});
  if(method==='Browser.getWindowForTarget'){
   if(params.targetId!=='T1')throw Error('foreign target');
   lookups++;
   const windowState=lookups>1 && config.changeDuringLookup==='invalidWindow' ? 'future-state' : state;
   return {windowId:(activated && config.foreignWindow) || (lookups>1 && config.changeDuringLookup==='window') ? 8 : 7,
    bounds:config.omitWindowState && windowState==='normal' ? {} : {windowState}};
  }
  if(method==='Browser.setWindowBounds'){
   if(params.windowId!==7 || params.bounds.windowState!=='normal')throw Error('foreign restore');
   state='normal';return {};
  }
  if(method==='Target.activateTarget'){
   if(params.targetId!=='T1')throw Error('foreign activation');
   activated=true;if(config.lost)throw Error('lost after activation');return {};
  }
  throw Error('unexpected protocol method');
 }};
|js} in
    let script=shim ^ "const activate=" ^ A.script ^ {js|;
let value,error;
try{value=await activate(task,{label:'p1',expectedUrl:config.expectedUrl || 'https://example.org/'});}
catch(caught){error=String(caught.message);}
console.log(JSON.stringify({value,error,calls}));
|js} in
    Out_channel.with_open_bin path (fun channel -> output_string channel script);
    let fd=Unix.openfile out [Unix.O_WRONLY;Unix.O_TRUNC] 0o600 in
    let pid=Fun.protect ~finally:(fun () -> Unix.close fd)
      (fun () -> Unix.create_process "node" [|"node";path;Yojson.Safe.to_string config|] Unix.stdin fd Unix.stderr) in
    (match Unix.waitpid [] pid with _,Unix.WEXITED 0 -> ()
     | _,(Unix.WEXITED _|Unix.WSIGNALED _|Unix.WSTOPPED _) -> fail "native activation script failed to run");
    In_channel.with_open_bin out In_channel.input_all |> Yojson.Safe.from_string)
let calls result=Yojson.Safe.Util.to_list (field "calls" result)
let methods result=List.map (fun call -> field "method" call) (calls result)
let test_native_activation () =
  List.iter (fun (origin,state) ->
    let result=execute (obj ["origin",str origin;"state",str state]) in
    ignore(ok (receipt (field "value" result)));
    check bool "only minimized windows are restored" (state="minimized")
      (List.mem (str "Browser.setWindowBounds") (methods result));
    check int "activation is not replayed" 1
      (List.length (List.filter ((=) (str "Target.activateTarget")) (methods result))))
    (List.concat_map (fun origin -> List.map (fun state -> origin,state)
      ["normal";"minimized";"maximized";"fullscreen"]) ["agent";"unknown"]);
  List.iter (fun state ->
    let result=execute (obj ["origin",str "agent";"state",str state;"omitWindowState",`Bool true]) in
    let window=field "window" (ok (receipt (field "value" result))) in
    check bool "a CDP window without the optional windowState is a normal window" true
      (field "stateBefore" window=str state && field "stateAfter" window=str "normal"))
    ["normal";"minimized"];
  List.iter (fun config ->
    let result=execute config in
    check bool "wrong Page/URL refuses before native commands" true
      (field "before" (field "value" result)=`Bool true && calls result=[]))
    [obj ["origin",str "user"];obj ["unmanaged",`Bool true];
     obj ["expectedUrl",str "https://example.org/elsewhere"]];
  List.iter (fun config ->
    let result=execute config in
    check bool "post-effect failure has no success receipt" true
      (field "error" result<>`Null && field "value" result=`Null);
    check int "failed activation is never replayed" 1
      (List.length (List.filter ((=) (str "Target.activateTarget")) (methods result))))
    [obj ["moved",`Bool true];obj ["foreignWindow",`Bool true];obj ["inactive",`Bool true];obj ["lost",`Bool true];
     obj ["origin",str "unknown";"originAfter",str "agent"]]
let test_native_activation_revalidates_before_effect () =
  List.iter (fun (origin,change) ->
    let result=execute (obj ["origin",str origin;"state",str "minimized";"changeDuringLookup",str change]) in
    check bool "neither window restoration nor target activation was attempted" false
      (List.exists (fun method_ -> method_=str "Browser.setWindowBounds" || method_=str "Target.activateTarget")
        (methods result));
    let refused = match field "value" result with
      | `Assoc fields -> List.assoc_opt "before" fields=Some (`Bool true)
      | _ -> false in
    check bool (change ^ " changed while the first window lookup awaited: before-effect refusal") true
      (refused && field "error" result=`Null))
    (List.concat_map (fun origin -> List.map (fun change -> origin,change)
      ["url";"label";"origin";"target";"window";"invalidWindow"]) ["agent";"unknown"])
let () = run "native Ego activation" ["boundary",[
  test_case "receipt stays with original Page and observed window" `Quick test_receipt_binding;
  test_case "native target activation and minimized window restoration" `Quick test_native_activation;
  test_case "activation revalidates Page and window before mutations" `Quick test_native_activation_revalidates_before_effect]]
