(* Keeper portraits: the look comes from the name, every variant and item
   shows, and the drawing keeps its promises (outline, flame light, face on
   the wax, transparent outside the backdrop, nothing at the border). *)

open Keeper_portrait_look
module D = Keeper_portrait_draw

let size n = Option.get (D.size_of_int n)
let draw ?(equipment = bare) body n = (D.render body equipment (size n)).D.rgba

(* A body built through the checked constructor; a fixture outside the
   ranges is a mistake in this file. *)
let make ?(wax = Ivory) ?(half_width = 0.30) ?(half_height = 0.40) ?(corner = 0.09) ?(drips = []) ?(flame = Ember)
    ?(flame_size = 1.0) ?(flame_lean = 0.0) ?(twin_flame = false) ?(horns = Long) ?(horn_colour = Crimson)
    ?(horn_length = 1.0) ?(eyes = Bean) ?(mouth = W) ?(blush = true) ?(backdrop_hue = 0.6) () =
  match
    body ~wax ~half_width ~half_height ~corner ~drips ~flame ~flame_size ~flame_lean ~twin_flame ~horns ~horn_colour
      ~horn_length ~eyes ~mouth ~blush ~backdrop_hue
  with
  | Ok b -> b
  | Error _ -> Alcotest.fail "a fixture body is outside the ranges"

(* A fixed, readable body to vary one field at a time. *)
let base_body = make ()

(* The same body with other eyes or mouth. *)
let remake ?eyes ?mouth (b : body) =
  make ~wax:b.wax ~half_width:b.half_width ~half_height:b.half_height ~corner:b.corner ~drips:b.drips ~flame:b.flame
    ~flame_size:b.flame_size ~flame_lean:b.flame_lean ~twin_flame:b.twin_flame ~horns:b.horns
    ~horn_colour:b.horn_colour ~horn_length:b.horn_length
    ~eyes:(Option.value eyes ~default:b.eyes)
    ~mouth:(Option.value mouth ~default:b.mouth)
    ~blush:b.blush ~backdrop_hue:b.backdrop_hue ()

let pose ~flicker ~blink ~bob =
  match D.pose ~flicker ~blink ~bob with Some p -> p | None -> Alcotest.fail "a fixture pose is outside [-1, 1]"

let distinct images =
  let seen = Hashtbl.create 16 in
  List.iter (fun img -> Hashtbl.replace seen img ()) images;
  Hashtbl.length seen

(* ---- look ------------------------------------------------------------------ *)

(* Made-up names, none of them a Keeper's. *)
let fixture_names = List.init 2000 (Printf.sprintf "portrait-fixture-%d")

let reaches label all seen =
  List.iter
    (fun c -> Alcotest.(check bool) (label ^ ": some name gets every constructor") true (List.mem c seen))
    all

(* The lists come from the type declarations; this checks generation uses
   them, so a constructor that no name can get (a zero weight, an item left
   out of the starting sets) fails here. *)
let test_names_reach_every_constructor () =
  let bodies = List.map body_of_name fixture_names in
  let kit = List.map equipment_of_name fixture_names in
  reaches "wax" all_wax (List.map (fun (b : body) -> b.wax) bodies);
  reaches "flame" all_flames (List.map (fun (b : body) -> b.flame) bodies);
  reaches "horn style" all_horn_styles (List.map (fun (b : body) -> b.horns) bodies);
  reaches "horn colour" all_horn_colours (List.map (fun (b : body) -> b.horn_colour) bodies);
  reaches "eyes" all_eyes (List.map (fun (b : body) -> b.eyes) bodies);
  reaches "mouth" all_mouths (List.map (fun (b : body) -> b.mouth) bodies);
  reaches "twin flame" [ true; false ] (List.map (fun (b : body) -> b.twin_flame) bodies);
  reaches "blush" [ true; false ] (List.map (fun (b : body) -> b.blush) bodies);
  reaches "drip count" (List.init (max_drips + 1) Fun.id) (List.map (fun (b : body) -> List.length b.drips) bodies);
  reaches "face item" all_face_items (List.map (fun e -> e.face) kit);
  reaches "neck item" all_neck_items (List.map (fun e -> e.neck) kit);
  reaches "head item" all_head_items (List.map (fun e -> e.head) kit);
  reaches "hand item" all_hand_items (List.map (fun e -> e.hand) kit);
  reaches "base item" all_base_items (List.map (fun e -> e.base) kit)

let test_names_give_bodies_in_range () =
  List.iter
    (fun name ->
      let b = body_of_name name in
      let rebuilt =
        body ~wax:b.wax ~half_width:b.half_width ~half_height:b.half_height ~corner:b.corner ~drips:b.drips
          ~flame:b.flame ~flame_size:b.flame_size ~flame_lean:b.flame_lean ~twin_flame:b.twin_flame ~horns:b.horns
          ~horn_colour:b.horn_colour ~horn_length:b.horn_length ~eyes:b.eyes ~mouth:b.mouth ~blush:b.blush
          ~backdrop_hue:b.backdrop_hue
      in
      Alcotest.(check bool) (name ^ ": the checked constructor accepts it") true (rebuilt = Ok b))
    fixture_names

let test_body_rejects_out_of_range () =
  let rejects label expected got =
    Alcotest.(check bool) label true (match got with Error e -> e = expected | Ok _ -> false)
  in
  let with_ ?(half_width = 0.30) ?(flame_size = 1.0) ?(backdrop_hue = 0.6) ?(drips = []) () =
    body ~wax:Ivory ~half_width ~half_height:0.40 ~corner:0.09 ~drips ~flame:Ember ~flame_size ~flame_lean:0.0
      ~twin_flame:false ~horns:Long ~horn_colour:Crimson ~horn_length:1.0 ~eyes:Bean ~mouth:W ~blush:true
      ~backdrop_hue
  in
  rejects "zero flame" Flame_size_out_of_range (with_ ~flame_size:0.0 ());
  rejects "NaN flame" Flame_size_out_of_range (with_ ~flame_size:Float.nan ());
  rejects "infinite width" Half_width_out_of_range (with_ ~half_width:Float.infinity ());
  rejects "hue 1 wraps to 0" Backdrop_hue_out_of_range (with_ ~backdrop_hue:1.0 ());
  let drip = { drip_x = 0.0; drip_length = 0.1; drip_width = 0.04 } in
  rejects "four drips" Too_many_drips (with_ ~drips:[ drip; drip; drip; drip ] ());
  rejects "a drip past the side" Drip_out_of_range (with_ ~drips:[ { drip with drip_x = 0.29 } ] ())

(* Every item a slot can hold, once, and nothing but bare sets besides. *)
let test_starting_equipment_lists_every_item () =
  let worn_alone slot_items empty wear = List.filter_map (fun i -> if i = empty then None else Some (wear i)) slot_items in
  let expected =
    worn_alone all_face_items bare.face (fun face -> { bare with face })
    @ worn_alone all_neck_items bare.neck (fun neck -> { bare with neck })
    @ worn_alone all_head_items bare.head (fun head -> { bare with head })
    @ worn_alone all_hand_items bare.hand (fun hand -> { bare with hand })
  in
  let worn = List.filter (fun e -> e <> bare) starting_equipment in
  Alcotest.(check bool) "one set per item" true (List.sort compare worn = List.sort compare expected);
  Alcotest.(check bool) "some bare sets" true (List.exists (fun e -> e = bare) starting_equipment)

let test_every_flame_has_a_weight () =
  List.iter (fun f -> Alcotest.(check bool) "weight above zero" true (flame_weight f > 0)) all_flames

let test_same_name_same_bytes () =
  let name = "e-masc-the-leader" in
  Alcotest.(check bool) "body" true (body_of_name name = body_of_name name);
  Alcotest.(check bool) "equipment" true (equipment_of_name name = equipment_of_name name);
  let once = draw ~equipment:(equipment_of_name name) (body_of_name name) 96 in
  let again = draw ~equipment:(equipment_of_name name) (body_of_name name) 96 in
  Alcotest.(check bool) "pixels" true (String.equal once again)

(* One made-up name, pinned: a change to the generator, the key or the
   drawing shows up here as a changed body or digest. Update the pin only
   when that change is meant. *)
let test_pinned_name () =
  let name = "portrait-fixture-pin" in
  let expected =
    make ~wax:Butter ~half_width:0.33968977063049399 ~half_height:0.39673138590329809 ~corner:0.11661930404785943
      ~drips:
        [
          { drip_x = -0.023817603797805592; drip_length = 0.086865732343732252; drip_width = 0.035810239091863441 };
          { drip_x = -0.10115379241507411; drip_length = 0.25756779149562137; drip_width = 0.051432430909412741 };
        ]
      ~flame:Ember ~flame_size:1.098178053279792 ~flame_lean:0.058704902450052054 ~twin_flame:false ~horns:One
      ~horn_colour:Bone ~horn_length:1.1202657627529355 ~eyes:Happy ~mouth:Flat ~blush:true
      ~backdrop_hue:0.47156321624094832 ()
  in
  Alcotest.(check bool) "body" true (body_of_name name = expected);
  Alcotest.(check bool) "equipment" true (equipment_of_name name = { bare with hand = Mug; base = Dish Gilt });
  Alcotest.(check string) "pixels at 64" "78ce1b73ed85ffb2b2675afd3bad4234"
    (Digest.to_hex (Digest.string (draw ~equipment:(equipment_of_name name) (body_of_name name) 64)))

(* A roster the size of the live one. Two names are stand-ins: the live
   Keepers they replace are listed in test/fixtures/concrete-keeper-identities.txt,
   which OCaml source may not name (test_keeper_toml). *)
let live_keepers =
  [
    "code-reviewer"; "context-reviewer"; "e-masc-the-leader"; "geek-scout"; "glossary-maniac"; "goo-yang-bong";
    "hole-finder"; "indie-geek-blue"; "jazz-developer"; "lane-smith"; "masc-pro-builder"; "msx-retro-mania";
    "ocaml-agent-ic"; "polisher"; "pr-updater"; "quill-tender"; "rust-hwp-guy"; "lamp-mender"; "simplifyer";
    "tui-developer"; "wkbl-data"; "wkbl-front"; "wkbl-growth"; "wkbl-web-leader"; "won-chik";
  ]

let test_live_keepers_differ () =
  let images = List.map (fun n -> draw ~equipment:(equipment_of_name n) (body_of_name n) 64) live_keepers in
  Alcotest.(check int) "every keeper looks different" (List.length live_keepers) (distinct images)

(* ---- draw ------------------------------------------------------------------ *)

let each_differs label variants make_body =
  let images = List.map (fun v -> draw (make_body v) 96) variants in
  Alcotest.(check int) (label ^ ": every variant draws differently") (List.length variants) (distinct images)

let test_every_body_variant_shows () =
  each_differs "wax" all_wax (fun wax -> make ~wax ());
  each_differs "flame" all_flames (fun flame -> make ~flame ());
  each_differs "horns" all_horn_styles (fun horns -> make ~horns ());
  each_differs "horn colour" all_horn_colours (fun horn_colour -> make ~horn_colour ());
  each_differs "eyes" all_eyes (fun eyes -> make ~eyes ());
  each_differs "mouth" all_mouths (fun mouth -> make ~mouth ());
  each_differs "blush" [ true; false ] (fun blush -> make ~blush ());
  each_differs "twin flame" [ true; false ] (fun twin_flame -> make ~twin_flame ());
  each_differs "drips"
    [ []; [ { drip_x = -0.1; drip_length = 0.2; drip_width = 0.05 } ] ]
    (fun drips -> make ~drips ())

let test_every_item_shows () =
  let bare_image = draw base_body 96 in
  let worn label equipment =
    Alcotest.(check bool) (label ^ " changes the portrait") false (String.equal bare_image (draw ~equipment base_body 96))
  in
  List.iter
    (fun face -> match face with Bare_face -> () | Glasses | Shades | Eye_patch | Plaster | Freckles | Beard -> worn "face item" { bare with face })
    all_face_items;
  List.iter
    (fun neck -> match neck with Bare_neck -> () | Scarf | Bow_tie | Medal -> worn "neck item" { bare with neck })
    all_neck_items;
  List.iter
    (fun head -> match head with Bare_head -> () | Bow | Crown | Beanie -> worn "head item" { bare with head })
    all_head_items;
  List.iter
    (fun hand -> match hand with Empty_hand -> () | Book | Mug | Quill -> worn "hand item" { bare with hand })
    all_hand_items;
  List.iter
    (fun base -> match base with No_dish -> () | Dish _ -> worn "dish" { bare with base })
    all_base_items;
  let dishes = List.map (fun base -> draw ~equipment:{ bare with base } base_body 96) all_base_items in
  Alcotest.(check int) "each dish is its own" (List.length all_base_items) (distinct dishes)

let test_size_and_alpha () =
  Alcotest.(check bool) "too small" true (D.size_of_int (D.min_size - 1) = None);
  Alcotest.(check bool) "too large" true (D.size_of_int (D.max_size + 1) = None);
  List.iter
    (fun n -> Alcotest.(check (option int)) "the ends are sizes" (Some n) (Option.map D.int_of_size (D.size_of_int n)))
    [ D.min_size; D.max_size ];
  List.iter
    (fun n ->
      let img = D.render base_body bare (size n) in
      Alcotest.(check int) "edge" n img.D.edge;
      Alcotest.(check int) "bytes" (n * n * 4) (String.length img.D.rgba);
      let _, corner_alpha = D.pixel img ~x:0 ~y:0 in
      Alcotest.(check int) "outside the backdrop is transparent" 0 corner_alpha;
      let _, centre_alpha = D.pixel img ~x:(n / 2) ~y:(n / 2) in
      Alcotest.(check int) "the middle is opaque" 255 centre_alpha)
    [ D.min_size; 80 ]

let distance a b =
  let d x y = float_of_int (x - y) in
  Float.sqrt ((d a.D.red b.D.red ** 2.0) +. (d a.D.green b.D.green ** 2.0) +. (d a.D.blue b.D.blue ** 2.0))

let test_outline_rings_the_silhouette () =
  let n = 128 in
  let img = D.render base_body bare (size n) in
  let left, top, _, bottom = D.For_testing.wax_bounds base_body in
  let y = (top +. bottom) /. 2.0 in
  let x0, py = D.For_testing.pixel_of_point (size n) (left -. 0.12, y) in
  (* stop short of the eyes, which have ink of their own *)
  let x1, _ = D.For_testing.pixel_of_point (size n) (left +. 0.05, y) in
  let ink = D.For_testing.ink base_body in
  let backdrop = D.For_testing.backdrop_rgb base_body in
  let wax = D.For_testing.wax_rgb base_body in
  let darkest =
    List.fold_left
      (fun best x ->
        let c, _ = D.pixel img ~x ~y:py in
        match best with Some b when distance b ink <= distance c ink -> best | Some _ | None -> Some c)
      None
      (List.init (x1 - x0 + 1) (fun i -> x0 + i))
  in
  match darkest with
  | None -> Alcotest.fail "no pixels scanned"
  | Some c ->
      Alcotest.(check bool) "a line nearer the ink than the backdrop" true (distance c ink < distance c backdrop);
      Alcotest.(check bool) "a line nearer the ink than the wax" true (distance c ink < distance c wax)

let test_ink_line_is_one_width () =
  let reach n = D.For_testing.line_reach_pixels (size n) in
  List.iter
    (fun n -> Alcotest.(check (float 1e-9)) "same line at every size" (reach D.min_size) (reach n))
    [ 64; 127; 128; 256; D.max_size ]

let test_flame_gives_light () =
  let n = 256 in
  let img = D.render base_body bare (size n) in
  let px, py = D.For_testing.pixel_of_point (size n) (D.For_testing.flame_probe base_body) in
  let c, a = D.pixel img ~x:px ~y:py in
  Alcotest.(check int) "opaque" 255 a;
  let f = D.For_testing.flame_rgb base_body in
  Alcotest.(check (list int)) "the flame's lower right keeps its own colour" [ f.D.red; f.D.green; f.D.blue ]
    [ c.D.red; c.D.green; c.D.blue ]

let test_face_sits_on_the_wax () =
  let n = 160 in
  List.iter
    (fun name ->
      let body = remake ~eyes:Bean (body_of_name name) in
      let left, top, right, bottom = D.For_testing.wax_bounds body in
      let img = D.render body bare (size n) in
      List.iter
        (fun (ex, ey) ->
          Alcotest.(check bool) (name ^ ": eye inside the wax") true (ex > left && ex < right && ey > top && ey < bottom);
          let px, py = D.For_testing.pixel_of_point (size n) (ex, ey) in
          let c, _ = D.pixel img ~x:px ~y:py in
          let e = D.For_testing.eye_rgb body in
          Alcotest.(check (list int)) (name ^ ": eye drawn where it sits") [ e.D.red; e.D.green; e.D.blue ]
            [ c.D.red; c.D.green; c.D.blue ])
        (D.For_testing.eye_centres body))
    live_keepers

(* The narrowest and widest, tallest and shortest candles the ranges allow. *)
let corner_bodies ?eyes ?mouth () =
  let lo (a, _) = a and hi (_, b) = b in
  List.concat_map
    (fun half_width ->
      List.map
        (fun half_height -> make ?eyes ?mouth ~half_width ~half_height ())
        [ lo half_height_range; hi half_height_range ])
    [ lo half_width_range; hi half_width_range ]

let test_every_freckle_shows_on_the_wax () =
  List.iter
    (fun body ->
      let left, top, right, bottom = D.For_testing.wax_bounds body in
      let freckles = D.For_testing.freckle_centres body in
      Alcotest.(check int) "six freckles" 6 (List.length freckles);
      List.iter
        (fun n ->
          let plain = D.render body bare (size n) in
          let freckled = D.render body { bare with face = Freckles } (size n) in
          List.iter
            (fun (fx, fy) ->
              Alcotest.(check bool) "freckle inside the wax" true (fx > left && fx < right && fy > top && fy < bottom);
              let x, y = D.For_testing.pixel_of_point (size n) (fx, fy) in
              Alcotest.(check bool)
                (Printf.sprintf "the freckle at (%.3f, %.3f) changes its pixel at %d px" fx fy n)
                false
                (D.pixel plain ~x ~y = D.pixel freckled ~x ~y))
            freckles)
        [ 64; 128 ])
    (corner_bodies ~eyes:Sparkle ())

(* A neck item hangs under the mouth: every pixel that is mouth or tooth
   without one is the same with one. *)
let test_neck_item_leaves_the_mouth () =
  let n = 256 in
  List.iter
    (fun neck ->
      match neck with
      | Bare_neck -> ()
      | Scarf | Bow_tie | Medal ->
        List.iter
          (fun mouth ->
            List.iter
              (fun body ->
                let equipment = { bare with neck } in
                let plain = D.For_testing.render_in_frame_of body bare ~frame_of:equipment D.still (size n) in
                let worn = D.render body equipment (size n) in
                let marked = [ D.For_testing.mouth_rgb body; D.For_testing.tooth_rgb body ] in
                let kept = ref 0 in
                for y = 0 to n - 1 do
                  for x = 0 to n - 1 do
                    let c, a = D.pixel plain ~x ~y in
                    if a = 255 && List.mem c marked then begin
                      incr kept;
                      Alcotest.(check bool) "mouth pixel kept under a neck item" true (D.pixel worn ~x ~y = (c, a))
                    end
                  done
                done;
                Alcotest.(check bool) "the mouth was drawn" true (!kept > 0))
              (corner_bodies ~mouth ()))
          all_mouths)
    all_neck_items

(* A beard hangs below the mouth and its fang: every pixel that is mouth or
   tooth without one is the same with one. The old beard was a filled oval
   whose top edge sat on the mouth line, so it covered the mouth and read as a
   mask at small sizes. *)
let test_beard_leaves_the_mouth () =
  let n = 256 in
  List.iter
    (fun mouth ->
      List.iter
        (fun body ->
          let plain = D.render body bare (size n) in
          let bearded = D.render body { bare with face = Beard } (size n) in
          let marked = [ D.For_testing.mouth_rgb body; D.For_testing.tooth_rgb body ] in
          let kept = ref 0 in
          for y = 0 to n - 1 do
            for x = 0 to n - 1 do
              let c, a = D.pixel plain ~x ~y in
              if a = 255 && List.mem c marked then begin
                incr kept;
                Alcotest.(check bool) "mouth pixel kept under a beard" true (D.pixel bearded ~x ~y = (c, a))
              end
            done
          done;
          Alcotest.(check bool) "the mouth was drawn" true (!kept > 0))
        (corner_bodies ~mouth ()))
    all_mouths

(* The beard is hair, not a pale fill: its colour is its own, so it cannot
   read as a white mask over the face. *)
let test_beard_is_not_the_wax () =
  let n = 96 in
  List.iter
    (fun wax ->
      let body = make ~wax () in
      let bearded = D.render body { bare with face = Beard } (size n) in
      let beard_rgb = D.For_testing.beard_rgb body in
      let wax_rgb = D.For_testing.wax_rgb body in
      Alcotest.(check bool) "the beard has its own colour" false (beard_rgb = wax_rgb);
      let painted = ref 0 in
      for y = 0 to n - 1 do
        for x = 0 to n - 1 do
          let c, a = D.pixel bearded ~x ~y in
          if a = 255 && c = beard_rgb then incr painted
        done
      done;
      Alcotest.(check bool) "the beard is drawn" true (!painted > 0))
    all_wax

(* Bodies at the ranges' ends wearing an item in every slot. Cross every
   neck item with every body: coupling their indices tested the medal only
   on a tall candle and missed its disc leaving the frame on a short one. *)
let extreme_cases () =
  let lo (a, _) = a and hi (_, b) = b in
  let widths = [ lo half_width_range; hi half_width_range ] and heights = [ lo half_height_range; hi half_height_range ] in
  let dishes = List.filter_map (function Dish d -> Some d | No_dish -> None) all_base_items in
  List.mapi
    (fun k face ->
      let half_width = List.nth widths (k mod 2) and half_height = List.nth heights (k / 2 mod 2) in
      let edge_drip x = { drip_x = x; drip_length = hi drip_length_range; drip_width = hi drip_width_range } in
      let reach = half_width -. drip_edge_margin in
      let body =
        make ~half_width ~half_height ~corner:(hi corner_range)
          ~drips:[ edge_drip (-.reach); edge_drip 0.0; edge_drip reach ]
          ~flame_size:(hi flame_size_range)
          ~flame_lean:(if k mod 2 = 0 then lo flame_lean_range else hi flame_lean_range)
          ~twin_flame:(k mod 3 = 1)
          ~horns:(List.nth all_horn_styles (k mod List.length all_horn_styles))
          ~horn_length:(hi horn_length_range)
          ~eyes:(List.nth all_eyes (k mod List.length all_eyes))
          ~mouth:(List.nth all_mouths (k mod List.length all_mouths))
          ()
      in
      List.map
        (fun neck ->
          let equipment =
            { face; neck; head = Bow; hand = List.nth all_hand_items (k mod List.length all_hand_items); base = Dish (List.nth dishes (k mod List.length dishes)) }
          in
          (body, equipment))
        all_neck_items)
    all_face_items
  |> List.concat
  |> fun cases -> cases
  @ [ (make ~half_width:(hi half_width_range) ~half_height:(lo half_height_range) (), bare) ]

let stretched_poses = [ pose ~flicker:1.0 ~blink:false ~bob:1.0; pose ~flicker:(-1.0) ~blink:true ~bob:(-1.0) ]

let test_culling_changes_nothing () =
  List.iter
    (fun (body, equipment) ->
      List.iter
        (fun p ->
          List.iter
            (fun n ->
              let culled = D.render_posed body equipment p (size n) in
              let full = D.For_testing.render_unculled body equipment p (size n) in
              Alcotest.(check bool) (Printf.sprintf "same bytes at %d px" n) true (String.equal culled.D.rgba full.D.rgba))
            [ 16; 64; 128 ])
        (D.still :: stretched_poses))
    (extreme_cases ())

let check_empty_border img =
  let n = img.D.edge in
  for i = 0 to n - 1 do
    List.iter
      (fun (x, y) ->
        let _, a = D.pixel img ~x ~y in
        Alcotest.(check int) (Printf.sprintf "border pixel (%d, %d) is empty" x y) 0 a)
      [ (i, 0); (i, n - 1); (0, i); (n - 1, i) ]
  done

let test_nothing_reaches_the_border () =
  List.iter
    (fun (body, equipment) ->
      List.iter
        (fun p ->
          List.iter
            (fun n -> D.render_posed body equipment p (size n) |> check_empty_border)
            [ D.min_size; 128 ])
        (D.still :: stretched_poses))
    (extreme_cases ())

(* This valid name receives a medal and a short, wide body. Its disc used to
   end at y=1.0832 while the image ended at y=0.97, cutting it across the
   middle on the dashboard, TUI and portrait-read tool alike. *)
let test_name_derived_medal_is_whole () =
  let name = "audit-keeper-79" in
  let body = body_of_name name and equipment = equipment_of_name name in
  Alcotest.(check bool) "the name wears a medal" true (equipment.neck = Medal);
  List.iter
    (fun n ->
      List.iter
        (fun p ->
          let shown = D.render_posed body equipment p (size n) in
          check_empty_border shown;
          let without_medal =
            D.For_testing.render_in_frame_of body { equipment with neck = Bare_neck }
              ~frame_of:equipment p (size n)
          in
          Alcotest.(check bool) "the medal is drawn in the frame" false
            (String.equal shown.D.rgba without_medal.D.rgba))
        (D.still :: stretched_poses))
    [ D.min_size; 48; 160; D.max_size ]

(* ---- motion ---------------------------------------------------------------- *)

let posed ?(body = base_body) p n = (D.render_posed body bare p (size n)).D.rgba

(* Pixels (x, y) where two renders of the same size differ. *)
let changed_pixels n a b =
  let out = ref [] in
  for y = 0 to n - 1 do
    for x = 0 to n - 1 do
      let k = ((y * n) + x) * 4 in
      if String.sub a k 4 <> String.sub b k 4 then out := (x, y) :: !out
    done
  done;
  !out

let inside_boxes n boxes (x, y) =
  List.exists
    (fun (l, t, r, b) ->
      let x0, y0 = D.For_testing.pixel_of_point (size n) (l, t) in
      let x1, y1 = D.For_testing.pixel_of_point (size n) (r, b) in
      x >= x0 && x <= x1 && y >= y0 && y <= y1)
    boxes

let test_still_pose_is_the_portrait () =
  Alcotest.(check bool) "render = render_posed still" true
    (String.equal (draw base_body 96) (posed D.still 96))

let test_flicker_moves_only_the_flame () =
  let n = 160 in
  List.iter
    (fun (label, body) ->
      let changed = changed_pixels n (posed ~body D.still n) (posed ~body (pose ~flicker:1.0 ~blink:false ~bob:0.0) n) in
      Alcotest.(check bool) (label ^ ": the flame moved") true (changed <> []);
      Alcotest.(check (list (pair int int))) (label ^ ": nothing outside the flame moved") []
        (List.filter (fun px -> not (inside_boxes n [ D.For_testing.flame_box body ] px)) changed))
    [ ("one wick", base_body); ("twin wicks", make ~twin_flame:true ()) ]

let test_blink_closes_only_the_eyes () =
  let n = 160 in
  let changed = changed_pixels n (posed D.still n) (posed (pose ~flicker:0.0 ~blink:true ~bob:0.0) n) in
  Alcotest.(check bool) "the eyes closed" true (changed <> []);
  Alcotest.(check (list (pair int int))) "nothing outside the eyes changed" []
    (List.filter (fun px -> not (inside_boxes n (D.For_testing.eye_boxes base_body) px)) changed)

let test_bob_moves_the_candle_not_the_backdrop () =
  let n = 160 in
  let still = D.render_posed base_body bare D.still (size n) in
  let risen = D.render_posed base_body bare (pose ~flicker:0.0 ~blink:false ~bob:1.0) (size n) in
  let settled = D.render_posed base_body bare (pose ~flicker:0.0 ~blink:false ~bob:(-1.0)) (size n) in
  Alcotest.(check bool) "the candle moved" false (String.equal still.D.rgba risen.D.rgba);
  let backdrop = D.For_testing.backdrop_rgb base_body in
  (* on the backdrop disc, well clear of every part at every pose *)
  List.iter
    (fun point ->
      let x, y = D.For_testing.pixel_of_point (size n) point in
      Alcotest.(check bool) "a backdrop pixel" true (D.pixel still ~x ~y = (backdrop, 255));
      Alcotest.(check bool) "unchanged when risen" true (D.pixel risen ~x ~y = (backdrop, 255));
      Alcotest.(check bool) "unchanged when settled" true (D.pixel settled ~x ~y = (backdrop, 255)))
    [ (-0.75, 0.02); (0.75, 0.02); (-0.6, -0.6); (0.6, 0.6) ]

let test_pose_rejects_out_of_range () =
  let rejected ~flicker ~bob = D.pose ~flicker ~blink:false ~bob = None in
  List.iter
    (fun v ->
      Alcotest.(check bool) "flicker rejected" true (rejected ~flicker:v ~bob:0.0);
      Alcotest.(check bool) "bob rejected" true (rejected ~flicker:0.0 ~bob:v))
    [ Float.nan; Float.infinity; Float.neg_infinity; 1.5; -1.5 ];
  List.iter
    (fun v -> Alcotest.(check bool) "the ends accepted" false (rejected ~flicker:v ~bob:v))
    [ -1.0; 0.0; 1.0 ]

let test_pose_at_is_a_pure_loop () =
  let times = List.init 400 (fun i -> i * 50) in
  List.iter
    (fun milliseconds ->
      let p = D.pose_at ~milliseconds in
      Alcotest.(check bool) "same moment, same pose" true (p = D.pose_at ~milliseconds);
      Alcotest.(check bool) "flicker in range" true (p.D.flicker >= -1.0 && p.D.flicker <= 1.0);
      Alcotest.(check bool) "bob in range" true (p.D.bob >= -1.0 && p.D.bob <= 1.0))
    (times @ [ -1; -123_456; min_int; max_int ]);
  Alcotest.(check bool) "a loop opens on open eyes" false (D.pose_at ~milliseconds:0).D.blink;
  let blinks = List.length (List.filter (fun milliseconds -> (D.pose_at ~milliseconds).D.blink) times) in
  Alcotest.(check bool) "blinks now and then, not most of the time" true (blinks > 0 && blinks * 10 < List.length times)

(* The mascot is drawn by the same code as any keeper, puts its drips on the
   wax, and is not any live keeper's portrait. *)
let test_mascot_is_a_drawable_candle () =
  let body, equipment = mascot in
  Alcotest.(check bool) "inside the ranges" true (remake body = body);
  List.iter
    (fun d ->
      Alcotest.(check bool) "drip on the wax" true (Float.abs d.drip_x < body.half_width))
    body.drips;
  let img = D.render body equipment (size 96) in
  let lit = ref 0 in
  for i = 0 to (String.length img.D.rgba / 4) - 1 do
    if Char.code img.D.rgba.[(i * 4) + 3] = 255 then incr lit
  done;
  Alcotest.(check bool) "draws a picture" true (!lit > 96 * 96 / 4);
  let mascot_px = img.D.rgba in
  List.iter
    (fun n ->
      Alcotest.(check bool) ("differs from " ^ n) false
        (String.equal mascot_px (draw ~equipment:(equipment_of_name n) (body_of_name n) 96)))
    live_keepers


(* ---- the dotted 3D mascot --------------------------------------------------- *)

module S = Keeper_portrait_solid

let solid ?(milliseconds = 0) n = S.mascot ~milliseconds (size n)

let alpha_at (image : D.image) ~x ~y = snd (D.pixel image ~x ~y)

(* The same table paints both renderers, so a keeper looks the same body in
   either. *)
let test_palette_is_the_paint_table () =
  let body = fst mascot in
  let p = D.palette body in
  Alcotest.(check bool) "wax" true (p.D.wax_rgb = D.For_testing.wax_rgb body);
  Alcotest.(check bool) "flame" true (p.D.flame_rgb = D.For_testing.flame_rgb body);
  Alcotest.(check bool) "eyes" true (p.D.eye_rgb = D.For_testing.eye_rgb body);
  Alcotest.(check bool) "mouth" true (p.D.mouth_rgb = D.For_testing.mouth_rgb body);
  Alcotest.(check bool) "ink" true (p.D.ink_rgb = D.For_testing.ink body);
  Alcotest.(check bool) "backdrop" true (p.D.backdrop_rgb = D.For_testing.backdrop_rgb body)

let test_image_init_places_each_pixel () =
  let image =
    D.image_init (size 16) (fun ~x ~y -> ({ D.red = x; green = y; blue = 300 }, if x = y then 255 else 0))
  in
  Alcotest.(check int) "edge" 16 image.D.edge;
  Alcotest.(check int) "four bytes a pixel" (16 * 16 * 4) (String.length image.D.rgba);
  let colour, alpha = D.pixel image ~x:3 ~y:5 in
  Alcotest.(check (list int)) "the pixel's own colour, clamped" [ 3; 5; 255 ]
    [ colour.D.red; colour.D.green; colour.D.blue ];
  Alcotest.(check int) "and alpha" 0 alpha;
  Alcotest.(check int) "on the diagonal, opaque" 255 (alpha_at image ~x:7 ~y:7)

let test_dotted_mascot_is_its_size_and_stands_on_its_backdrop () =
  List.iter
    (fun n ->
      let image = solid n in
      Alcotest.(check int) "edge" n image.D.edge;
      Alcotest.(check int) "a corner is transparent" 0 (alpha_at image ~x:0 ~y:0);
      Alcotest.(check int) "the centre is drawn" 255 (alpha_at image ~x:(n / 2) ~y:(n / 2)))
    [ D.min_size; 24; 40; 96; 160; 240 ]

(* Every dot is a square of whole pixels: inside the margin, each pixel is
   the one at the top-left of its dot. *)
let test_every_dot_is_a_square () =
  List.iter
    (fun n ->
      let image = solid n in
      let k = Int.max 1 ((n + (S.grid / 2)) / S.grid) in
      let dots = n / k in
      let margin = (n - (dots * k)) / 2 in
      for y = margin to margin + (dots * k) - 1 do
        for x = margin to margin + (dots * k) - 1 do
          let corner = D.pixel image ~x:(margin + ((x - margin) / k * k)) ~y:(margin + ((y - margin) / k * k)) in
          if D.pixel image ~x ~y <> corner then
            Alcotest.failf "edge %d: pixel %d,%d is not its dot's colour" n x y
        done
      done)
    [ 80; 160; 240 ]

let test_dotted_mascot_sways_and_comes_back () =
  let at milliseconds = (solid ~milliseconds 96).D.rgba in
  Alcotest.(check bool) "the same moment is the same picture" true (String.equal (at 900) (at 900));
  Alcotest.(check bool) "a quarter sway later it has turned" false
    (String.equal (at 0) (at (S.sway_period_ms / 4)));
  Alcotest.(check bool) "a whole sway later it is back" true
    (String.equal (at 700) (at (700 + S.sway_period_ms)));
  Alcotest.(check bool) "a moment before the start is on the loop too" true
    (String.equal (at (-S.sway_period_ms)) (at 0))

let () =
  Alcotest.run "keeper portrait"
    [
      ( "look",
        [
          Alcotest.test_case "names reach every constructor" `Quick test_names_reach_every_constructor;
          Alcotest.test_case "names give bodies in range" `Quick test_names_give_bodies_in_range;
          Alcotest.test_case "body rejects out of range" `Quick test_body_rejects_out_of_range;
          Alcotest.test_case "starting equipment lists every item" `Quick test_starting_equipment_lists_every_item;
          Alcotest.test_case "every flame has a weight" `Quick test_every_flame_has_a_weight;
          Alcotest.test_case "same name, same bytes" `Quick test_same_name_same_bytes;
          Alcotest.test_case "pinned name" `Quick test_pinned_name;
          Alcotest.test_case "live keepers all differ" `Quick test_live_keepers_differ;
          Alcotest.test_case "mascot is a drawable candle" `Quick test_mascot_is_a_drawable_candle;
        ] );
      ( "draw",
        [
          Alcotest.test_case "every body variant shows" `Quick test_every_body_variant_shows;
          Alcotest.test_case "every item shows" `Quick test_every_item_shows;
          Alcotest.test_case "size and alpha" `Quick test_size_and_alpha;
          Alcotest.test_case "outline rings the silhouette" `Quick test_outline_rings_the_silhouette;
          Alcotest.test_case "ink line is one width" `Quick test_ink_line_is_one_width;
          Alcotest.test_case "flame gives light" `Quick test_flame_gives_light;
          Alcotest.test_case "face sits on the wax" `Quick test_face_sits_on_the_wax;
          Alcotest.test_case "every freckle shows on the wax" `Quick test_every_freckle_shows_on_the_wax;
          Alcotest.test_case "neck item leaves the mouth" `Quick test_neck_item_leaves_the_mouth;
          Alcotest.test_case "beard leaves the mouth" `Quick test_beard_leaves_the_mouth;
          Alcotest.test_case "beard is not the wax" `Quick test_beard_is_not_the_wax;
          Alcotest.test_case "culling changes nothing" `Quick test_culling_changes_nothing;
          Alcotest.test_case "nothing reaches the border" `Quick test_nothing_reaches_the_border;
          Alcotest.test_case "name-derived medal is whole" `Quick test_name_derived_medal_is_whole;
        ] );
      ( "dotted",
        [
          Alcotest.test_case "palette is the paint table" `Quick test_palette_is_the_paint_table;
          Alcotest.test_case "image_init places each pixel" `Quick test_image_init_places_each_pixel;
          Alcotest.test_case "dotted mascot is its size and stands on its backdrop" `Quick
            test_dotted_mascot_is_its_size_and_stands_on_its_backdrop;
          Alcotest.test_case "every dot is a square" `Quick test_every_dot_is_a_square;
          Alcotest.test_case "dotted mascot sways and comes back" `Quick
            test_dotted_mascot_sways_and_comes_back;
        ] );
      ( "motion",
        [
          Alcotest.test_case "still pose is the portrait" `Quick test_still_pose_is_the_portrait;
          Alcotest.test_case "flicker moves only the flame" `Quick test_flicker_moves_only_the_flame;
          Alcotest.test_case "blink closes only the eyes" `Quick test_blink_closes_only_the_eyes;
          Alcotest.test_case "bob moves the candle, not the backdrop" `Quick test_bob_moves_the_candle_not_the_backdrop;
          Alcotest.test_case "pose rejects out of range" `Quick test_pose_rejects_out_of_range;
          Alcotest.test_case "pose_at is a pure loop" `Quick test_pose_at_is_a_pure_loop;
        ] );
    ]
