(* config/tools/keeper_portrait_read.toml states these three numbers as
   literals; test_keeper_portrait_read compares them with these. The renderer
   accepts a wider range ({!Keeper_portrait_draw.min_size} up), which the TUI
   uses for small terminal cells; this tool keeps to the range it declares. *)
let minimum_size = 48
let maximum_size = 512
let default_size = 160

module Item = Keeper_portrait_item

type mode = Current | Preview of Item.t

let request_arg args =
  let ( let* ) = Result.bind in
  match args with
  | `Assoc fields ->
      let* size =
        match List.assoc_opt "size" fields with
        | None -> Ok default_size
        | Some (`Int size) -> Ok size
        | Some _ -> Error "size must be an integer"
      in
      let* mode =
        match List.assoc_opt "preview_item" fields with
        | None -> Ok Current
        | Some (`String id) ->
            (match Item.of_id id with
             | Some item -> Ok (Preview item)
             | None -> Error (Printf.sprintf "unknown portrait item: %S; use an id from catalog" id))
        | Some _ -> Error "preview_item must be an item id string"
      in
      Ok (size, mode)
  | _ -> Error "arguments must be an object"

let equipment_to_json = Keeper_portrait_equipment.to_json

let catalog =
  `List
    (List.map
       (fun item ->
          `Assoc [ "id", `String (Item.id item)
                 ; "slot", `String (Item.slot_id (Item.slot item)) ])
       Item.all)

let handle ~base_path ~keeper_name ~tool_name ~start_time ~args =
  match request_arg args with
  | Error message -> Tool_result.make_err ~tool_name ~class_:Tool_result.Policy_rejection ~start_time message
  | Ok (size, mode) ->
      let refuse () =
        Tool_result.make_err ~tool_name ~class_:Tool_result.Policy_rejection ~start_time
          (Printf.sprintf "size must be between %d and %d" minimum_size maximum_size)
      in
      if size < minimum_size || size > maximum_size then refuse ()
      else
      (match Keeper_portrait_draw.size_of_int size with
       | None -> refuse ()
       | Some size ->
           let body = Keeper_portrait_look.body_of_name keeper_name in
           let starting_equipment = Keeper_portrait_look.equipment_of_name keeper_name in
           match Candle_equipment.current ~base_path ~keeper:keeper_name with
           | Error message -> Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time message
           | Ok current_equipment ->
           let equipment =
             match mode with
             | Current -> current_equipment
             | Preview item -> Item.preview item current_equipment
           in
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
               (* The tool promises a durable artifact. Screen frames share a
                  rotating cache; the kept store preserves the returned handle. *)
               (match Keeper_vision_tool.store_kept ~keeper_name bytes with
                | Error message -> Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time message
                | Ok artifact ->
                    Tool_result.make_ok ~tool_name ~start_time
                      ~data:(`Assoc [ "name", `String keeper_name
                                   ; "mode", `String (match mode with Current -> "current" | Preview _ -> "preview")
                                   ; "preview_item", (match mode with Current -> `Null | Preview item -> `String (Item.id item))
                                   ; "starting_equipment", equipment_to_json starting_equipment
                                   ; "current_equipment", equipment_to_json current_equipment
                                   ; "equipment", equipment_to_json equipment
                                   ; "catalog", catalog
                                   ; "artifact", `String (Multimodal.Vision_artifact_store.to_string artifact)
                                   ; "media_type", `String "image/png"
                                   ; "width", `Int width; "height", `Int width
                                   ; "bytes", `Int (String.length bytes) ]) ()))
