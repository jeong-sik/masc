include Masc_server_lifecycle

let await_start starts server ~host ~port ~health_ok ~attempts ~sleep =
  Masc_server_lifecycle.await_start starts server ~host ~port ~health_ok
    ~attempts ~sleep
    ~on_settled:(fun () -> Masc_tui_wake.(ring loop Server_start_settled))
