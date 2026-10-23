let argv ~driver ~port ~marionette_port =
  [ driver
  ; "--host"
  ; Masc_network_defaults.masc_http_default_host
  ; "--port"
  ; string_of_int port
  ; "--websocket-port"
  ; "0"
  ; "--marionette-port"
  ; string_of_int marionette_port
  ]
