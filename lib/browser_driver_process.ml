let argv ~driver ~port ~profile_root =
  [ driver
  ; "--host"
  ; Masc_network_defaults.masc_http_default_host
  ; "--port"
  ; string_of_int port
  ; "--websocket-port"
  ; "0"
  ; "--profile-root"
  ; profile_root
  ]
