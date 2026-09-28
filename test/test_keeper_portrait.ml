(* Keeper portraits: the look comes from the name, every variant and item
   shows, and the drawing keeps its promises (outline, flame light, face on
   the wax, transparent outside the backdrop). *)

open Keeper_portrait_look
module D = Keeper_portrait_draw

let size n = Option.get (D.size_of_int n)
let draw ?(equipment = bare) body n = (D.render body equipment (size n)).D.rgba

(* A fixed, readable body to vary one field at a time. *)
let base_body =
  {
    wax = Ivory;
    half_width = 0.30;
    half_height = 0.40;
    corner = 0.09;
    drips = [];
    flame = Ember;
    flame_size = 1.0;
    flame_lean = 0.0;
    twin_flame = false;
    horns = Long;
    horn_colour = Crimson;
    horn_length = 1.0;
    eyes = Bean;
    mouth = W;
    blush = true;
    backdrop_hue = 0.6;
  }

let distinct images =
  let seen = Hashtbl.create 16 in
  List.iter (fun img -> Hashtbl.replace seen img ()) images;
  Hashtbl.length seen

(* Exhaustive indexes: adding a constructor fails to compile here until the
   tests (and the all_* lists they check) know about it. *)
let wax_index = function
  | Ivory -> 0 | Peach -> 1 | Mint -> 2 | Lavender -> 3 | Sky -> 4 | Butter -> 5 | Rose -> 6 | Charcoal -> 7
let flame_index = function Ember -> 0 | Azure -> 1 | Jade -> 2 | Violet -> 3 | Pink -> 4 | Gold -> 5
let horn_index = function Nub -> 0 | Long -> 1 | One -> 2 | Ram -> 3
let horn_colour_index = function Crimson -> 0 | Soot -> 1 | Brass -> 2 | Bone -> 3 | Blossom -> 4
let eyes_index = function Bean -> 0 | Dot -> 1 | Happy -> 2 | Sleepy -> 3 | Sparkle -> 4 | Wink -> 5
let mouth_index = function W -> 0 | Smile -> 1 | O -> 2 | Flat -> 3 | Fang -> 4
let face_index = function
  | Bare_face -> 0 | Glasses -> 1 | Shades -> 2 | Eye_patch -> 3 | Plaster -> 4 | Freckles -> 5 | Beard -> 6
let neck_index = function Bare_neck -> 0 | Scarf -> 1
let head_index = function Bare_head -> 0 | Bow -> 1
let hand_index = function Empty_hand -> 0
let base_index = function No_dish -> 0 | Dish Gilt -> 1 | Dish Silver -> 2 | Dish Oak -> 3

let covers name index count all =
  Alcotest.(check (list int)) (name ^ " lists every constructor once") (List.init count Fun.id)
    (List.sort compare (List.map index all))

let test_lists_cover_every_constructor () =
  covers "wax" wax_index 8 all_wax;
  covers "flames" flame_index 6 all_flames;
  covers "horn styles" horn_index 4 all_horn_styles;
  covers "horn colours" horn_colour_index 5 all_horn_colours;
  covers "eyes" eyes_index 6 all_eyes;
  covers "mouths" mouth_index 5 all_mouths;
  covers "face items" face_index 7 all_face_items;
  covers "neck items" neck_index 2 all_neck_items;
  covers "head items" head_index 2 all_head_items;
  covers "hand items" hand_index 1 all_hand_items;
  covers "base items" base_index 4 all_base_items

let test_same_name_same_bytes () =
  let name = "e-masc-the-leader" in
  Alcotest.(check bool) "body" true (body_of_name name = body_of_name name);
  Alcotest.(check bool) "equipment" true (equipment_of_name name = equipment_of_name name);
  let once = draw ~equipment:(equipment_of_name name) (body_of_name name) 96 in
  let again = draw ~equipment:(equipment_of_name name) (body_of_name name) 96 in
  Alcotest.(check bool) "pixels" true (String.equal once again)

let live_keepers =
  [
    "code-reviewer"; "context-reviewer"; "e-masc-the-leader"; "geek-scout"; "glossary-maniac"; "goo-yang-bong";
    "hole-finder"; "indie-geek-blue"; "jazz-developer"; "lane-smith"; "masc-pro-builder"; "msx-retro-mania";
    "ocaml-agent-ic"; "polisher"; "pr-updater"; "rondo"; "rust-hwp-guy"; "sangsu"; "simplifyer"; "tui-developer";
    "wkbl-data"; "wkbl-front"; "wkbl-growth"; "wkbl-web-leader"; "won-chik";
  ]

let test_live_keepers_differ () =
  let images = List.map (fun n -> draw ~equipment:(equipment_of_name n) (body_of_name n) 64) live_keepers in
  Alcotest.(check int) "every keeper looks different" (List.length live_keepers) (distinct images)

let each_differs label variants make =
  let images = List.map (fun v -> draw (make v) 96) variants in
  Alcotest.(check int) (label ^ ": every variant draws differently") (List.length variants) (distinct images)

let test_every_body_variant_shows () =
  each_differs "wax" all_wax (fun wax -> { base_body with wax });
  each_differs "flame" all_flames (fun flame -> { base_body with flame });
  each_differs "horns" all_horn_styles (fun horns -> { base_body with horns });
  each_differs "horn colour" all_horn_colours (fun horn_colour -> { base_body with horn_colour });
  each_differs "eyes" all_eyes (fun eyes -> { base_body with eyes });
  each_differs "mouth" all_mouths (fun mouth -> { base_body with mouth });
  each_differs "blush" [ true; false ] (fun blush -> { base_body with blush });
  each_differs "twin flame" [ true; false ] (fun twin_flame -> { base_body with twin_flame });
  each_differs "drips"
    [ []; [ { drip_x = -0.1; drip_length = 0.2; drip_width = 0.05 } ] ]
    (fun drips -> { base_body with drips })

let test_every_item_shows () =
  let bare_image = draw base_body 96 in
  let worn label equipment =
    Alcotest.(check bool) (label ^ " changes the portrait") false (String.equal bare_image (draw ~equipment base_body 96))
  in
  List.iter
    (fun face -> match face with Bare_face -> () | Glasses | Shades | Eye_patch | Plaster | Freckles | Beard -> worn "face item" { bare with face })
    all_face_items;
  List.iter (fun neck -> match neck with Bare_neck -> () | Scarf -> worn "scarf" { bare with neck }) all_neck_items;
  List.iter (fun head -> match head with Bare_head -> () | Bow -> worn "bow" { bare with head }) all_head_items;
  List.iter
    (fun base -> match base with No_dish -> () | Dish _ -> worn "dish" { bare with base })
    all_base_items;
  let dishes = List.map (fun base -> draw ~equipment:{ bare with base } base_body 96) all_base_items in
  Alcotest.(check int) "each dish is its own" (List.length all_base_items) (distinct dishes)

let test_size_and_alpha () =
  Alcotest.(check bool) "too small" true (D.size_of_int (D.min_size - 1) = None);
  Alcotest.(check bool) "too large" true (D.size_of_int (D.max_size + 1) = None);
  let n = 80 in
  let img = D.render base_body bare (size n) in
  Alcotest.(check int) "edge" n img.D.edge;
  Alcotest.(check int) "bytes" (n * n * 4) (String.length img.D.rgba);
  let _, corner_alpha = D.pixel img ~x:0 ~y:0 in
  Alcotest.(check int) "outside the backdrop is transparent" 0 corner_alpha;
  let _, centre_alpha = D.pixel img ~x:(n / 2) ~y:(n / 2) in
  Alcotest.(check int) "the middle is opaque" 255 centre_alpha

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
      let body = { (body_of_name name) with eyes = Bean } in
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

(* ---- motion ---------------------------------------------------------------- *)

let posed ?(body = base_body) pose n = (D.render_posed body bare pose (size n)).D.rgba

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
      let changed = changed_pixels n (posed ~body D.still n) (posed ~body { D.still with flicker = 1.0 } n) in
      Alcotest.(check bool) (label ^ ": the flame moved") true (changed <> []);
      Alcotest.(check (list (pair int int))) (label ^ ": nothing outside the flame moved") []
        (List.filter (fun px -> not (inside_boxes n [ D.For_testing.flame_box body ] px)) changed))
    [ ("one wick", base_body); ("twin wicks", { base_body with twin_flame = true }) ]

let test_blink_closes_only_the_eyes () =
  let n = 160 in
  let changed = changed_pixels n (posed D.still n) (posed { D.still with blink = true } n) in
  Alcotest.(check bool) "the eyes closed" true (changed <> []);
  Alcotest.(check (list (pair int int))) "nothing outside the eyes changed" []
    (List.filter (fun px -> not (inside_boxes n (D.For_testing.eye_boxes base_body) px)) changed)

let test_bob_moves_the_candle_not_the_backdrop () =
  let n = 160 in
  let still = D.render_posed base_body bare D.still (size n) in
  let risen = D.render_posed base_body bare { D.still with bob = 1.0 } (size n) in
  Alcotest.(check bool) "the candle moved" false (String.equal still.D.rgba risen.D.rgba);
  (* a backdrop pixel well clear of the candle, and the backdrop's edge *)
  List.iter
    (fun (x, y) -> Alcotest.(check bool) "backdrop unchanged" true (D.pixel still ~x ~y = D.pixel risen ~x ~y))
    [ (12, n / 2); (n - 13, n / 2); (n / 2, 3); (n / 2, n - 4) ]

let test_pose_at_is_a_pure_loop () =
  let times = List.init 400 (fun i -> float_of_int i *. 0.05) in
  List.iter
    (fun t ->
      let p = D.pose_at ~seconds:t in
      Alcotest.(check bool) "same moment, same pose" true (p = D.pose_at ~seconds:t);
      Alcotest.(check bool) "flicker in range" true (p.D.flicker >= -1.0 && p.D.flicker <= 1.0);
      Alcotest.(check bool) "bob in range" true (p.D.bob >= -1.0 && p.D.bob <= 1.0))
    times;
  Alcotest.(check bool) "a loop opens on open eyes" false (D.pose_at ~seconds:0.0).D.blink;
  let blinks = List.length (List.filter (fun t -> (D.pose_at ~seconds:t).D.blink) times) in
  Alcotest.(check bool) "blinks now and then, not most of the time" true (blinks > 0 && blinks * 10 < List.length times)

let () =
  Alcotest.run "keeper portrait"
    [
      ( "look",
        [
          Alcotest.test_case "lists cover every constructor" `Quick test_lists_cover_every_constructor;
          Alcotest.test_case "same name, same bytes" `Quick test_same_name_same_bytes;
          Alcotest.test_case "live keepers all differ" `Quick test_live_keepers_differ;
        ] );
      ( "draw",
        [
          Alcotest.test_case "every body variant shows" `Quick test_every_body_variant_shows;
          Alcotest.test_case "every item shows" `Quick test_every_item_shows;
          Alcotest.test_case "size and alpha" `Quick test_size_and_alpha;
          Alcotest.test_case "outline rings the silhouette" `Quick test_outline_rings_the_silhouette;
          Alcotest.test_case "flame gives light" `Quick test_flame_gives_light;
          Alcotest.test_case "face sits on the wax" `Quick test_face_sits_on_the_wax;
        ] );
      ( "motion",
        [
          Alcotest.test_case "still pose is the portrait" `Quick test_still_pose_is_the_portrait;
          Alcotest.test_case "flicker moves only the flame" `Quick test_flicker_moves_only_the_flame;
          Alcotest.test_case "blink closes only the eyes" `Quick test_blink_closes_only_the_eyes;
          Alcotest.test_case "bob moves the candle, not the backdrop" `Quick test_bob_moves_the_candle_not_the_backdrop;
          Alcotest.test_case "pose_at is a pure loop" `Quick test_pose_at_is_a_pure_loop;
        ] );
    ]
