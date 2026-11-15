(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Nonce = struct
  (* HIGH-RISK-UNREVIEWED: only [draw] makes a [t], so a [t] holds the hex
     digits of Random_id.hex and nothing that ends a source or an attribute. *)
  type t = string

  let random_bytes = 32
  let draw () = Random_id.hex ~bytes:random_bytes
  let source nonce = Printf.sprintf "'nonce-%s'" nonce
  let attribute nonce = Printf.sprintf "nonce=\"%s\"" nonce
end

let style_source ~nonce = "style-src " ^ Nonce.source nonce
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
    ; Printf.sprintf "<style %s>%s</style>" (Nonce.attribute nonce) Account_page_css.sheet
    ; "</head>"
    ; "<body>"
    ; "<header class=\"site-header\"><span class=\"brand\">MASC</span><span class=\"brand-sub\">계정</span></header>"
    ; body
    ; "</body>"
    ; "</html>"
    ; ""
    ]
;;
