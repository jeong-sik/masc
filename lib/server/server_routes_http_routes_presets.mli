(** HTTP routes for prompt presets (#32777): list, save, restore under
    [/api/v1/presets]. Writes require [Masc_domain.CanAdmin]. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

type save_request =
  { name : string
  ; description : string
  }

