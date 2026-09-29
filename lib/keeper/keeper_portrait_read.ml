let size_arg args =
  match args with
  | `Assoc fields ->
      (match List.assoc_opt "size" fields with
       | None -> Ok 160
       | Some (`Int size) -> Ok size
       | Some _ -> Error "size must be an integer")
  | _ -> Error "arguments must be an object"

let equipment_to_json (equipment : Keeper_portrait_look.equipment) =
  let face =
    match equipment.face with
    | Bare_face -> "bare_face" | Glasses -> "glasses" | Shades -> "shades"
    | Eye_patch -> "eye_patch" | Plaster -> "plaster" | Freckles -> "freckles" | Beard -> "beard"
  in
  let neck =
    match equipment.neck with
    | Bare_neck -> "bare_neck" | Scarf -> "scarf" | Bow_tie -> "bow_tie" | Medal -> "medal"
  in
  let head =
    match equipment.head with
    | Bare_head -> "bare_head" | Bow -> "bow" | Crown -> "crown" | Beanie -> "beanie"
  in
  let hand =
    match equipment.hand with
    | Empty_hand -> "empty_hand" | Book -> "book" | Mug -> "mug" | Quill -> "quill"
  in
  let base =
    match equipment.base with
    | No_dish -> "no_dish" | Dish Oak -> "dish_oak" | Dish Silver -> "dish_silver" | Dish Gilt -> "dish_gilt"
  in
  `Assoc [ "face", `String face; "neck", `String neck; "head", `String head
         ; "hand", `String hand; "base", `String base ]

let handle ~keeper_name ~tool_name ~start_time ~args =
  match size_arg args with
  | Error message -> Tool_result.make_err ~tool_name ~class_:Tool_result.Policy_rejection ~start_time message
  | Ok size ->
      (match Keeper_portrait_draw.size_of_int size with
       | None -> Tool_result.make_err ~tool_name ~class_:Tool_result.Policy_rejection ~start_time
           (Printf.sprintf "size must be between %d and %d" Keeper_portrait_draw.min_size Keeper_portrait_draw.max_size)
       | Some size ->
           let body = Keeper_portrait_look.body_of_name keeper_name in
           let equipment = Keeper_portrait_look.equipment_of_name keeper_name in
           let width = Keeper_portrait_draw.int_of_size size in
           (* Distance-field sampling, pixel composition and PNG compression
              are CPU work. Let other Keeper fibers run while rendering. *)
           let encoded = Eio_guard.run_in_systhread ~label:"keeper-portrait-png" (fun () ->
             let image = Keeper_portrait_draw.render body equipment size in
             let rgb = Bytes.create (width * width * 3) in
             for y = 0 to width - 1 do
               for x = 0 to width - 1 do
                 let colour, alpha = Keeper_portrait_draw.pixel image ~x ~y in
                 let offset = (y * width + x) * 3 in
                 let blend channel =
                   let background = 22 in
                   (channel * alpha + background * (255 - alpha)) / 255
                 in
                 Bytes.set rgb offset (Char.chr (blend colour.red));
                 Bytes.set rgb (offset + 1) (Char.chr (blend colour.green));
                 Bytes.set rgb (offset + 2) (Char.chr (blend colour.blue))
               done
             done;
             Rgb_png.encode ~width ~height:width ~rgb:(Bytes.unsafe_to_string rgb)) in
           match encoded with
           | Error message -> Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time message
           | Ok bytes ->
               (match Keeper_vision_tool.store_frame ~keeper_name bytes with
                | Error message -> Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time message
                | Ok artifact ->
                    Tool_result.make_ok ~tool_name ~start_time
                      ~data:(`Assoc [ "name", `String keeper_name
                                   ; "equipment", equipment_to_json equipment
                                   ; "artifact", `String (Multimodal.Vision_artifact_store.to_string artifact)
                                   ; "media_type", `String "image/png"
                                   ; "width", `Int width; "height", `Int width
                                   ; "bytes", `Int (String.length bytes) ]) ()))
