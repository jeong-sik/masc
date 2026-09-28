(* Writes a sheet of keeper portraits as a PNG so a person can look at them.

   dune exec test/keeper_portrait_preview.exe -- --out portraits.png NAME...
   dune exec test/keeper_portrait_preview.exe -- --keepers-dir <base>/.masc/config/keepers
   dune exec test/keeper_portrait_preview.exe -- --at-ms 1900 NAME...     (an animation frame)

   Portraits are drawn on the dark page most terminals use; five to a row. *)

let usage =
  "keeper_portrait_preview [--out FILE] [--size PX] [--at-ms MS] [--keepers-dir DIR] [NAME...]\n\
   Draws each keeper's portrait into one PNG sheet (default: keeper-portraits.png)."

(* The dark page the sheet is laid on. *)
let page = (22, 20, 28)
let per_row = 5
let default_edge = 160

let keeper_names_in dir =
  Sys.readdir dir |> Array.to_list
  |> List.filter_map (fun f -> if Filename.check_suffix f ".toml" then Some (Filename.chop_suffix f ".toml") else None)
  |> List.sort String.compare

let () =
  let out = ref "keeper-portraits.png" and edge = ref default_edge and dir = ref None and names = ref [] in
  let at = ref None in
  Arg.parse
    [
      ("--out", Arg.Set_string out, "FILE  where to write the PNG");
      ("--size", Arg.Set_int edge, "PX  portrait edge in pixels");
      ("--keepers-dir", Arg.String (fun d -> dir := Some d), "DIR  draw every KEEPER.toml found here");
      ("--at-ms", Arg.Int (fun ms -> at := Some ms), "MS  draw the animation pose this many milliseconds in");
    ]
    (fun n -> names := n :: !names)
    usage;
  let names = List.rev !names @ match !dir with Some d -> keeper_names_in d | None -> [] in
  match (names, Keeper_portrait_draw.size_of_int !edge) with
  | [], _ ->
      prerr_endline usage;
      exit 2
  | _, None ->
      Printf.eprintf "--size must be between %d and %d\n" Keeper_portrait_draw.min_size Keeper_portrait_draw.max_size;
      exit 2
  | _ :: _, Some size ->
      let e = Keeper_portrait_draw.int_of_size size in
      let rows = (List.length names + per_row - 1) / per_row in
      let width = e * per_row and height = e * rows in
      let pr, pg, pb = page in
      let rgb = Bytes.create (width * height * 3) in
      for i = 0 to (width * height) - 1 do
        Bytes.set rgb (i * 3) (Char.chr pr);
        Bytes.set rgb ((i * 3) + 1) (Char.chr pg);
        Bytes.set rgb ((i * 3) + 2) (Char.chr pb)
      done;
      List.iteri
        (fun n name ->
          let pose =
            match !at with
            | Some milliseconds -> Keeper_portrait_draw.pose_at ~milliseconds
            | None -> Keeper_portrait_draw.still
          in
          let img =
            Keeper_portrait_draw.render_posed (Keeper_portrait_look.body_of_name name)
              (Keeper_portrait_look.equipment_of_name name) pose size
          in
          let ox = n mod per_row * e and oy = n / per_row * e in
          for y = 0 to e - 1 do
            for x = 0 to e - 1 do
              let c, a = Keeper_portrait_draw.pixel img ~x ~y in
              let k = ((((oy + y) * width) + ox + x) * 3) in
              let over v bg = ((v * a) + (bg * (255 - a)) + 127) / 255 in
              Bytes.set rgb k (Char.chr (over c.Keeper_portrait_draw.red pr));
              Bytes.set rgb (k + 1) (Char.chr (over c.green pg));
              Bytes.set rgb (k + 2) (Char.chr (over c.blue pb))
            done
          done)
        names;
      (match Rgb_png.encode ~width ~height ~rgb:(Bytes.unsafe_to_string rgb) with
      | Ok png ->
          Out_channel.with_open_bin !out (fun oc -> Out_channel.output_string oc png);
          Printf.printf "%s: %d portraits\n" !out (List.length names)
      | Error reason ->
          Printf.eprintf "PNG encoding failed: %s\n" reason;
          exit 1)
