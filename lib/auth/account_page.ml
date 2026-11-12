(* HIGH-RISK-UNREVIEWED: see the interface. *)

let style_source ~nonce = Printf.sprintf "style-src 'nonce-%s'" nonce
let formless_limits = "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
let base_sheet = Account_page_css.base

let document ~nonce ~title body =
  String.concat
    "\n"
    [ "<!doctype html>"
    ; "<html lang=\"ko\">"
    ; "<head>"
    ; "<meta charset=\"utf-8\">"
    ; "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    ; "<title>" ^ title ^ "</title>"
    ; Printf.sprintf "<style nonce=\"%s\">%s</style>" nonce Account_page_css.sheet
    ; "</head>"
    ; "<body>"
    ; "<header class=\"site-header\"><span class=\"brand\">MASC</span><span class=\"brand-sub\">계정</span></header>"
    ; body
    ; "</body>"
    ; "</html>"
    ; ""
    ]
;;
