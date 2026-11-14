(* HIGH-RISK-UNREVIEWED: the policy of a page decides what a browser may run
   and apply on the origin where a person signs in. *)

(** The frame of a page the account server writes itself: the document around
    a body, the line that names the place, its one style sheet, and the
    directive that lets a browser apply that sheet.

    The document is in Korean. A part in another language says so with a
    [lang] attribute of its own.

    The sheet is in the document, under a nonce. A page that uses this frame
    writes no [style] attribute: a nonce covers a [<style>] element and never
    an attribute, so the policy would drop it. *)

(* HIGH-RISK-UNREVIEWED: a nonce is the one part of a policy that changes
   with each answer, and a browser runs and applies what carries it. [draw]
   is the only maker of one, so no caller can put another text there. *)

(** The nonce of one answer. *)
module Nonce : sig
  type t

  (** 32 bytes from the CSPRNG of {!Random_id}, as lowercase hex: a value a
      browser cannot guess, of hex digits only. An answer draws its own. *)
  val draw : unit -> t

  (** ['nonce-<value>'], quotes included: the source of a [script-src] or
      [style-src] directive. *)
  val source : t -> string

  (** [nonce="<value>"]: the attribute of a [<script>] or [<style>]
      element. *)
  val attribute : t -> string
end

(** [style-src 'nonce-<value>']: the directive a policy needs so that a
    browser applies the sheet {!document} wrote with the same [nonce]. With
    [default-src 'none'] and without this directive the browser applies no
    style at all. *)
val style_source : nonce:Nonce.t -> string

(** [base-uri 'none'; form-action 'none'; frame-ancestors 'none']: the three
    limits [default-src] does not set, for a page that submits no form. Under
    them a browser takes no other base for the addresses of the page, sends
    no form from it, and shows it in no frame. *)
val formless_limits : string

(** The part of the sheet that is not the layout of the pages of this frame:
    the colours, the type, the line that names the place, cards, fields and
    buttons. A page that is built elsewhere and brings its own layout links
    it, so it looks like the pages {!document} writes. It is the first part of
    the sheet of {!document}, byte for byte. *)
val base_sheet : string

(** [document ~nonce ~title body]: an HTML document whose head holds [title]
    and the sheet, and whose body is the line that names the place and then
    [body]. [title] and [body] are written as
    they are given, so they hold no request data. [nonce] is the nonce of
    the answer, on the [<style>] element. *)
val document : nonce:Nonce.t -> title:string -> string -> string
