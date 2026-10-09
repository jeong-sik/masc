open Alcotest

let decode_png_with_python ~colour_type ~png ~pixels:rgb ~width ~height =
  (* An independent standard-library decoder verifies both PNG framing and
     decoded pixels, including channel order and every row's filter byte. *)
  let script = {|
import sys,json,base64,struct,zlib
d=json.loads(sys.stdin.readline()); p=base64.b64decode(d['png'])
assert p[:8]==b'\x89PNG\r\n\x1a\n'
i=8; chunks=[]; compressed=b''
while i<len(p):
 n=struct.unpack('>I',p[i:i+4])[0]; k=p[i+4:i+8]; b=p[i+8:i+8+n]
 assert len(b)==n and zlib.crc32(k+b)==struct.unpack('>I',p[i+8+n:i+12+n])[0]
 chunks.append(k)
 if k==b'IHDR': assert struct.unpack('>IIBBBBB',b)==(d['width'],d['height'],8,d['colour'],0,0,0)
 if k==b'IDAT': compressed+=b
 i+=n+12
assert i==len(p) and chunks==[b'IHDR',b'IDAT',b'IEND']
raw=zlib.decompress(compressed); stride=d['width']*{2:3,6:4}[d['colour']]
assert len(raw)==(stride+1)*d['height']
assert all(raw[y*(stride+1)]==0 for y in range(d['height']))
pixels=b''.join(raw[y*(stride+1)+1:(y+1)*(stride+1)] for y in range(d['height']))
assert pixels==base64.b64decode(d['rgb'])
print('decoded exact pixels')
|} in
  let channels = Unix.open_process_args_full "python3" [|"python3"; "-c"; script|] (Unix.environment ()) in
  let input, output, errors = channels in
  let request = `Assoc ["png", `String (Base64.encode_string png);
    "rgb", `String (Base64.encode_string rgb); "width", `Int width; "height", `Int height;
    "colour", `Int colour_type] in
  output_string output (Yojson.Safe.to_string request ^ "\n");
  flush output;
  let reply = In_channel.input_all input in
  let error = In_channel.input_all errors in
  let status = Unix.close_process_full channels in
  check bool ("PNG decoder: " ^ error) true (status = Unix.WEXITED 0);
  check string "independent pixels" "decoded exact pixels\n" reply

let decode_with_python ~png ~rgb ~width ~height =
  decode_png_with_python ~colour_type:2 ~png ~pixels:rgb ~width ~height

let test_rgb () =
  List.iter (fun (width, height) ->
    let rgb = String.init (width * height * 3) (fun i -> Char.chr ((i * 71 + i / 17) mod 256)) in
    match Rgb_png.encode ~width ~height ~rgb with
    | Error e -> fail e
    | Ok png -> decode_with_python ~png ~rgb ~width ~height)
    [1,1; 3,2; 256,192; 512,212];
  check bool "short RGB rejected" true
    (Result.is_error (Rgb_png.encode ~width:2 ~height:1 ~rgb:"abc"));
  check bool "overflow rejected" true
    (Result.is_error (Rgb_png.encode ~width:max_int ~height:max_int ~rgb:""))

let test_rgba () =
  (* Straight alpha: a pixel's colour bytes survive at every alpha, including 0. *)
  List.iter (fun (width, height) ->
    let rgba = String.init (width * height * 4) (fun i -> Char.chr ((i * 53 + i / 13) mod 256)) in
    match Rgb_png.encode_rgba ~width ~height ~rgba with
    | Error e -> fail e
    | Ok png -> decode_png_with_python ~colour_type:6 ~png ~pixels:rgba ~width ~height)
    [1,1; 3,2; 160,160];
  check bool "RGB-length bytes rejected as RGBA" true
    (Result.is_error (Rgb_png.encode_rgba ~width:2 ~height:1 ~rgba:"abcdef"));
  check bool "overflow rejected" true
    (Result.is_error (Rgb_png.encode_rgba ~width:max_int ~height:max_int ~rgba:""))

let test_worker_capture () =
  let module Client = Mcp_protocol_eio.Client in
  let module S = Mcp_protocol.Mcp_types in
  let unwrap = function Ok value -> value | Error message -> fail message in
  let base_path = Filename.temp_dir "msx-worker-vision-" "" in
  Msx_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect ~finally:(fun () ->
    ignore (Msx_lane.eject ());
    Msx_lane.install_activity_observer None;
    Fs_compat.remove_tree base_path) (fun () ->
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
        Eio.Switch.run (fun sw ->
          let request_source,request_sink = Eio_unix.pipe sw in
          let response_source,response_sink = Eio_unix.pipe sw in
          Eio.Fiber.first
            (fun () -> Mcp_protocol_eio.Server.run (Msx_addon_worker.create ~base_path ())
              ~stdin:request_source ~stdout:response_sink ~clock:(Eio.Stdenv.clock env) ())
            (fun () ->
              let client = Client.create ~stdin:response_source ~stdout:request_sink
                ~clock:(Eio.Stdenv.clock env) () in
              ignore (unwrap (Client.initialize client ~client_name:"vision-fixture" ~client_version:"1"));
              let call name arguments = unwrap (Client.call_tool client
                ~name:Lane_addon_call_context.tool_name
                ~arguments:(Lane_addon_call_context.to_json ~tool:name ~arguments
                  ~principal:(Lane_addon_call_context.Keeper "vision-player")) ()) in
              let screen () = call "masc_msx_screen" (`Assoc []) in
              check bool "unloaded worker screen fails explicitly" true ((screen ()).is_error = Some true);
              check bool "synthetic worker load succeeds" false
                ((call "masc_msx_load" (`Assoc ["roms_dir",`String ""])).is_error = Some true);
              let before,frame = match Msx_lane.capture () with
                | Ok value -> value | Error error -> fail (Msx_lane.error_to_string error) in
              let result = screen () in
              let png (result : S.tool_result) = match List.find_map (function
                | S.ImageContent {mime_type="image/png";data;_} -> Some (Base64.decode_exn data)
                | _ -> None) result.S.content with
                | Some png -> png | None -> fail "worker screen omitted its PNG" in
              let metadata = match result.structured_content with Some value -> value | None -> fail "no observation" in
              check int "PNG and observation describe the captured frame" before.frame
                Yojson.Safe.Util.(metadata |> member "frame" |> to_int);
              Eio_unix.run_in_systhread (fun () ->
                decode_with_python ~png:(png result) ~rgb:frame.rgb ~width:frame.width ~height:frame.height);
              check string "repeated capture preserves exact image bytes" (png result) (png (screen ()));
              check int "screen reads do not advance the machine" before.frame
                (match Msx_lane.screen () with Ok observation -> observation.frame | Error _ -> fail "machine lost");
              check int "screen reads do not inject input" 0 (List.length (Msx_lane.ledger ()));
              ignore (call "masc_msx_eject" (`Assoc []));
              check bool "eject cannot return the retained old image" true ((screen ()).is_error = Some true);
              ignore (call "masc_msx_load" (`Assoc ["roms_dir",`String ""]));
              let _,fresh = match Msx_lane.capture () with
                | Ok value -> value | Error error -> fail (Msx_lane.error_to_string error) in
              let fresh_png = png (screen ()) in
              Eio_unix.run_in_systhread (fun () ->
                decode_with_python ~png:fresh_png ~rgb:fresh.rgb ~width:fresh.width ~height:fresh.height))))))

let () = run "MSX vision"
  ["pixels", [test_case "PNG roundtrip" `Quick test_rgb;
               test_case "RGBA PNG roundtrip" `Quick test_rgba];
   "worker", [test_case "stdio screen yields exact pixels without input" `Quick test_worker_capture]]
