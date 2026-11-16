(* HIGH-RISK-UNREVIEWED: a nonce is the one part of a content security policy
   that changes with each answer, and a browser runs and applies what carries
   it. [draw] is the only maker of one, so no caller can put another text
   there. *)

(** The nonce of one HTTP answer: the value its content security policy names
    and its [<script>] and [<style>] elements carry. Every page the server
    writes with an inline script or sheet draws it here. *)
type t

(** 32 bytes from the CSPRNG of {!Random_id}, as lowercase hex: a value a
    browser cannot guess, of hex digits only. An answer draws its own. *)
val draw : unit -> t

(** ['nonce-<value>'], quotes included: the source of a [script-src] or
    [style-src] directive. *)
val source : t -> string

(** [nonce="<value>"]: the attribute of a [<script>] or [<style>] element. *)
val attribute : t -> string
