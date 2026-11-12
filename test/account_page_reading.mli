(** What a page of the account server lets a person do about a login.

    The page is read as a browser parses it: it goes through the HTML parser
    of the product ({!Markup_document}), and a fact is read from the elements
    that come out. So a fact does not depend on how the page spells or orders
    its attributes ([disabled], [disabled=""] and [DISABLED] are one fact), and
    nothing here reads the words of a page.

    A test of the routes has no browser, so what is read is the document a
    browser starts from. What a script of the page or a style sheet changes
    afterwards is measured in a browser (docs/evidence). *)

type login =
  | Open
  (** One form of the page posts to the start route, that form has one submit
      button, and a person can press it. *)
  | Closed
  (** The same form and button, and the button is disabled. The page says why
      where a person reads it: the button names its description, every element
      it names is in the page and not hidden, and they hold text. *)

(** Why a page has no login a person can use or understand. *)
type flaw =
  | No_form (** No form posts to the start route. *)
  | Several_forms of int
  | No_submit_button
  (** The form holds no [button] that submits it to its own route: an element
      of another kind, a [button] of type [button] or [reset], or one that
      names another form, route or method. *)
  | Several_submit_buttons of int
  | Not_rendered (** The form or its button is under a [hidden] attribute. *)
  | No_description (** The button is disabled and names no description. *)
  | Description_missing of string (** It names an id no element has. *)
  | Description_hidden of string
  | Description_blank

val login : start:string -> string -> (login, flaw) result
(** [login ~start page] reads the login of the HTML [page] whose start route
    is [start]. *)

val outcome : (login, flaw) result Alcotest.testable
