type error =
  | Too_large
  | Pane_too_narrow of { required_cells : int; available_cells : int }

let quiet_zone_modules = 4

let render ~available_cells link =
  match Qrc.encode link with
  | None -> Error Too_large
  | Some matrix ->
      let required_cells = Qrc.Matrix.w matrix + (2 * quiet_zone_modules) in
      if required_cells > available_cells then
        Error (Pane_too_narrow { required_cells; available_cells })
      else
        Ok
          (Format.asprintf "%a"
             (Qrc_fmt.pp_utf_8_half ~invert:false ~quiet_zone:true)
             matrix)
