open Alcotest
open Masc

let decode_with_python ~png ~rgb ~width ~height =
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
 if k==b'IHDR': assert struct.unpack('>IIBBBBB',b)==(d['width'],d['height'],8,2,0,0,0)
 if k==b'IDAT': compressed+=b
 i+=n+12
assert i==len(p) and chunks==[b'IHDR',b'IDAT',b'IEND']
raw=zlib.decompress(compressed); stride=d['width']*3
assert len(raw)==(stride+1)*d['height']
assert all(raw[y*(stride+1)]==0 for y in range(d['height']))
pixels=b''.join(raw[y*(stride+1)+1:(y+1)*(stride+1)] for y in range(d['height']))
assert pixels==base64.b64decode(d['rgb'])
print('decoded exact pixels')
|} in
  let channels = Unix.open_process_args_full "python3" [|"python3"; "-c"; script|] (Unix.environment ()) in
  let input, output, errors = channels in
  let request = `Assoc ["png", `String (Base64.encode_string png);
    "rgb", `String (Base64.encode_string rgb); "width", `Int width; "height", `Int height] in
  output_string output (Yojson.Safe.to_string request ^ "\n");
  flush output;
  let reply = In_channel.input_all input in
  let error = In_channel.input_all errors in
  let status = Unix.close_process_full channels in
  check bool ("PNG decoder: " ^ error) true (status = Unix.WEXITED 0);
  check string "independent pixels" "decoded exact pixels\n" reply

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

let test_keeper_capture () =
  let base = Filename.temp_dir "msx-vision-" "" in
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" base;
  Config_dir_resolver.reset ();
  Fun.protect ~finally:(fun () ->
    ignore (Msx_lane.eject ());
    Unix.putenv "MASC_BASE_PATH" (Option.value ~default:"" previous);
    Config_dir_resolver.reset ();
    Fs_compat.remove_tree base) (fun () ->
      let config = Workspace.default_config base in
      let meta = match Masc_test_deps.meta_of_json_fixture (`Assoc ["name", `String "vision-player"]) with
        | Ok meta -> meta | Error e -> fail e in
      let screen () = Keeper_tool_in_process_runtime.handle_masc_misc_with_outcome
        ~config ~meta ~name:"masc_msx_screen" ~args:(`Assoc []) in
      ignore (Msx_lane.eject ());
      check bool "no machine fails" true
        (match (screen ()).disposition with Tool_result.Failed _ -> true | _ -> false);
      (match Msx_lane.load ~ledger_dir:(Filename.concat base "ledger") ~roms_dir:""
         ~cart_path:None ~disk_path:None with Ok _ -> () | Error e -> fail (Msx_lane.error_to_string e));
      let before = match Msx_lane.capture () with Ok value -> value | Error _ -> fail "no capture" in
      let result = screen () in
      let json = match result.data with Some d -> d | None -> fail result.raw_output in
      let open Yojson.Safe.Util in
      let handle = json |> member "artifact" |> to_string in
      let dir = Keeper_vision_tool.vision_store_dir ~keeper_name:meta.name in
      let png = match Multimodal.Vision_artifact_store.load ~dir
        (Multimodal.Vision_artifact_store.of_string handle) with
        | Ok bytes -> bytes | Error e -> fail e in
      let obs, frame = before in
      check int "captured same frame" obs.frame (json |> member "frame" |> to_int);
      decode_with_python ~png ~rgb:frame.rgb ~width:frame.width ~height:frame.height;
      check int "screen did not advance" obs.frame
        (match Msx_lane.screen () with Ok o -> o.frame | Error _ -> fail "no machine");
      check int "no input ledger changes" 0 (List.length (Msx_lane.ledger ()));
      let again = screen () in
      check string "unchanged frame deduplicates artifact" handle
        (Option.get again.data |> member "artifact" |> to_string);
      let other_dir = Keeper_vision_tool.vision_store_dir ~keeper_name:"another-player" in
      check bool "not stored for another Keeper" false (Sys.file_exists (Filename.concat other_dir handle));
      Sys.remove (Filename.concat dir handle);
      Unix.rmdir dir;
      Out_channel.with_open_bin dir (fun oc -> output_string oc "not a directory");
      check bool "storage failure is explicit" true
        (match (screen ()).disposition with Tool_result.Failed _ -> true | _ -> false))

let () = run "MSX vision"
  ["pixels", [test_case "PNG roundtrip" `Quick test_rgb];
   "Keeper", [test_case "screen yields owned image without input" `Quick test_keeper_capture]]
