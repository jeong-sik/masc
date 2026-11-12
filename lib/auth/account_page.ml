(* HIGH-RISK-UNREVIEWED: see the interface. *)

let style_source ~nonce = Printf.sprintf "style-src 'nonce-%s'" nonce

let document ~nonce ~title body =
  String.concat
    "\n"
    [ "<!doctype html>"
    ; "<html lang=\"en\">"
    ; "<head>"
    ; "<meta charset=\"utf-8\">"
    ; "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    ; "<title>" ^ title ^ "</title>"
    ; Printf.sprintf "<style nonce=\"%s\">%s</style>" nonce Account_page_css.sheet
    ; "</head>"
    ; "<body>"
    ; body
    ; "</body>"
    ; "</html>"
    ; ""
    ]
;;
