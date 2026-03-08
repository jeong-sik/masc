(** Chain Category - Category Theory Abstractions for Chain Engine

    결합(Composition)과 분해(Decomposition)의 수학적 기반을 제공합니다.

    핵심 법칙:
    - 항등원: id >> f = f = f >> id
    - 결합법칙: (a >> b) >> c = a >> (b >> c)
    - 함자 법칙: map id = id, map (f . g) = map f . map g

    @author Chain Engine
    @since 2026-01
*)

(** {1 Core Signatures} *)

(** Functor - 분해: 컨테이너 내부 값 변환 *)
module type FUNCTOR = sig
  type 'a t

  (** [map f x] applies [f] to the value inside [x].
      Laws:
      - map id = id
      - map (f . g) = map f . map g *)
  val map : ('a -> 'b) -> 'a t -> 'b t
end

(** Applicative - 결합: 독립적 효과의 병렬 적용 *)
module type APPLICATIVE = sig
  include FUNCTOR

  (** [pure x] lifts [x] into the applicative context. *)
  val pure : 'a -> 'a t

  (** [ap f x] applies the function inside [f] to the value inside [x].
      This enables parallel composition of independent computations. *)
  val ap : ('a -> 'b) t -> 'a t -> 'b t

  (** [map2 f x y] combines two applicatives with a binary function. *)
  val map2 : ('a -> 'b -> 'c) -> 'a t -> 'b t -> 'c t

  (** [sequence xs] collects a list of applicatives into an applicative of list.
      Enables parallel execution of independent operations. *)
  val sequence : 'a t list -> 'a list t
end

(** Monad - 결합: 순차 의존성 체인 *)
module type MONAD = sig
  include APPLICATIVE

  (** [bind m f] sequences [m] with [f], where [f] depends on [m]'s result.
      Also known as flatMap or >>=.
      Laws:
      - bind (pure x) f = f x         (left identity)
      - bind m pure = m                (right identity)
      - bind (bind m f) g = bind m (fun x -> bind (f x) g)  (associativity) *)
  val bind : 'a t -> ('a -> 'b t) -> 'b t

  (** Infix bind operator. *)
  val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t

  (** [join mm] flattens a nested monad. *)
  val join : 'a t t -> 'a t

  (** Kleisli composition: [(f >=> g) x = f x >>= g].
      Composes two monadic functions. *)
  val ( >=> ) : ('a -> 'b t) -> ('b -> 'c t) -> ('a -> 'c t)
end

(** Monoid - 결합: 결과 합치기 *)
module type MONOID = sig
  type t

  (** The identity element. [concat empty x = x = concat x empty] *)
  val empty : t

  (** [concat a b] combines two values.
      Must be associative: concat (concat a b) c = concat a (concat b c) *)
  val concat : t -> t -> t

  (** [concat_all xs] combines a list of values left-to-right. *)
  val concat_all : t list -> t
end

(** Kleisli Arrow - 결합: 파이프라인 조립 *)
module type KLEISLI = sig
  type ('a, 'b) t

  (** [arr f] lifts a pure function into an arrow. *)
  val arr : ('a -> 'b) -> ('a, 'b) t

  (** [f >>> g] composes two arrows sequentially. *)
  val ( >>> ) : ('a, 'b) t -> ('b, 'c) t -> ('a, 'c) t

  (** [f &&& g] runs both arrows on the same input (fanout). *)
  val ( &&& ) : ('a, 'b) t -> ('a, 'c) t -> ('a, 'b * 'c) t

  (** [f *** g] runs arrows on respective inputs (parallel). *)
  val ( *** ) : ('a, 'b) t -> ('c, 'd) t -> ('a * 'c, 'b * 'd) t

  (** [first f] runs [f] on the first element of a pair. *)
  val first : ('a, 'b) t -> ('a * 'c, 'b * 'c) t

  (** [second f] runs [f] on the second element of a pair. *)
  val second : ('a, 'b) t -> ('c * 'a, 'c * 'b) t
end

(** Profunctor - 분해+결합: 입출력 양방향 변환 *)
module type PROFUNCTOR = sig
  type ('a, 'b) t

  (** [dimap f g p] transforms both input (contravariantly) and output (covariantly).
      [dimap f g p = lmap f (rmap g p) = rmap g (lmap f p)] *)
  val dimap : ('a -> 'b) -> ('c -> 'd) -> ('b, 'c) t -> ('a, 'd) t

  (** [lmap f p] transforms the input. *)
  val lmap : ('a -> 'b) -> ('b, 'c) t -> ('a, 'c) t

  (** [rmap f p] transforms the output. *)
  val rmap : ('b -> 'c) -> ('a, 'b) t -> ('a, 'c) t
end

(** {1 Result-based Implementations} *)

(** Result monad for error-handling chains *)
module Result_monad : sig
  include MONAD with type 'a t = ('a, string) result

  (** [run m] extracts the result or raises Failure. *)
  val run : 'a t -> 'a

  (** [catch f] catches exceptions and wraps them in Error. *)
  val catch : (unit -> 'a) -> 'a t

  (** [map_error f m] transforms the error case. *)
  val map_error : (string -> string) -> 'a t -> 'a t
end = struct
  type 'a t = ('a, string) result

  let pure x = Ok x

  let map f = function
    | Ok x -> Ok (f x)
    | Error e -> Error e

  let ap mf mx = match mf, mx with
    | Ok f, Ok x -> Ok (f x)
    | Error e, _ -> Error e
    | _, Error e -> Error e

  let map2 f mx my = match mx, my with
    | Ok x, Ok y -> Ok (f x y)
    | Error e, _ -> Error e
    | _, Error e -> Error e

  let rec sequence = function
    | [] -> Ok []
    | x :: xs ->
      match x, sequence xs with
      | Ok v, Ok vs -> Ok (v :: vs)
      | Error e, _ -> Error e
      | _, Error e -> Error e

  let bind m f = match m with
    | Ok x -> f x
    | Error e -> Error e

  let ( >>= ) = bind

  let join mm = bind mm (fun m -> m)

  let ( >=> ) f g x = f x >>= g

  let run = function
    | Ok x -> x
    | Error e -> failwith e

  let catch f =
    try Ok (f ())
    with e -> Error (Printexc.to_string e)

  let map_error f = function
    | Ok x -> Ok x
    | Error e -> Error (f e)
end

(** {1 Kleisli Arrow for Result} *)

(** Kleisli arrows over Result - composable error-handling pipelines *)
module Result_kleisli : sig
  include KLEISLI with type ('a, 'b) t = 'a -> ('b, string) result

  (** [run f x] executes the arrow on input [x]. *)
  val run : ('a, 'b) t -> 'a -> ('b, string) result

  (** [from_option ~error f] converts an option-returning function. *)
  val from_option : error:string -> ('a -> 'b option) -> ('a, 'b) t

  (** [guard ~error pred] fails if predicate is false. *)
  val guard : error:string -> ('a -> bool) -> ('a, 'a) t

  (** [retry ~times ~delay f] retries on failure. *)
  val retry : times:int -> delay:float -> ('a, 'b) t -> ('a, 'b) t
end = struct
  type ('a, 'b) t = 'a -> ('b, string) result

  let arr f x = Ok (f x)

  let ( >>> ) f g x =
    match f x with
    | Ok y -> g y
    | Error e -> Error e

  let ( &&& ) f g x =
    match f x, g x with
    | Ok a, Ok b -> Ok (a, b)
    | Error e, _ -> Error e
    | _, Error e -> Error e

  let ( *** ) f g (x, y) =
    match f x, g y with
    | Ok a, Ok b -> Ok (a, b)
    | Error e, _ -> Error e
    | _, Error e -> Error e

  let first f (x, y) =
    match f x with
    | Ok x' -> Ok (x', y)
    | Error e -> Error e

  let second f (x, y) =
    match f y with
    | Ok y' -> Ok (x, y')
    | Error e -> Error e

  let run f x = f x

  let from_option ~error f x =
    match f x with
    | Some y -> Ok y
    | None -> Error error

  let guard ~error pred x =
    if pred x then Ok x else Error error

  let retry ~times ~delay f x =
    let rec loop n =
      match f x with
      | Ok y -> Ok y
      | Error _ when n > 0 ->
        Unix.sleepf delay;
        loop (n - 1)
      | Error e -> Error e
    in
    loop times
end

(** {1 Practical Monoid Instances} *)

(** Verdict type from validator *)
type verdict =
  | Pass of string
  | Warn of string
  | Fail of string
  | Defer of string
[@@deriving yojson]

(** Verdict monoid - combines verdicts with fail-fast semantics *)
module Verdict_monoid : MONOID with type t = verdict = struct
  type t = verdict

  let empty = Pass "identity"

  let concat a b = match a, b with
    | Fail reason, _ -> Fail reason
    | _, Fail reason -> Fail reason
    | Warn w1, Warn w2 -> Warn (w1 ^ "; " ^ w2)
    | Warn w, _ | _, Warn w -> Warn w
    | Pass p1, Pass p2 -> Pass (p1 ^ " & " ^ p2)
    | Defer d, _ | _, Defer d -> Defer d

  let concat_all = function
    | [] -> empty
    | [x] -> x
    | x :: xs -> List.fold_left concat x xs
end

(** Confidence monoid - combines confidence scores *)
module Confidence_monoid : sig
  include MONOID with type t = float

  (** [geometric xs] computes geometric mean (for multiplicative confidence). *)
  val geometric : float list -> float

  (** [harmonic xs] computes harmonic mean (penalizes low scores). *)
  val harmonic : float list -> float

  (** [weighted ws xs] computes weighted average. *)
  val weighted : float list -> float list -> float
end = struct
  type t = float

  let empty = 1.0

  (* Arithmetic mean for combining *)
  let concat a b = (a +. b) /. 2.0

  let concat_all = function
    | [] -> empty
    | xs ->
      let sum = List.fold_left ( +. ) 0.0 xs in
      sum /. float_of_int (List.length xs)

  let geometric = function
    | [] -> 1.0
    | xs ->
      let product = List.fold_left ( *. ) 1.0 xs in
      Float.pow product (1.0 /. float_of_int (List.length xs))

  let harmonic = function
    | [] -> 1.0
    | xs ->
      let n = float_of_int (List.length xs) in
      let sum_inv = List.fold_left (fun acc x ->
          if x > 0.0 then acc +. (1.0 /. x) else acc
        ) 0.0 xs
      in
      if sum_inv > 0.0 then n /. sum_inv else 0.0

  let weighted weights values =
    let pairs = List.combine weights values in
    let weighted_sum = List.fold_left (fun acc (w, v) -> acc +. w *. v) 0.0 pairs in
    let weight_sum = List.fold_left ( +. ) 0.0 weights in
    if weight_sum > 0.0 then weighted_sum /. weight_sum else 0.0
end

(** Trace monoid - accumulates execution traces *)
module Trace_monoid : MONOID with type t = (string * float) list = struct
  type t = (string * float) list

  let empty = []

  let concat a b = a @ b

  let concat_all xs = List.concat xs
end

(** Token usage type *)
type token_usage = {
  prompt_tokens: int;
  completion_tokens: int;
  total_tokens: int;
  estimated_cost_usd: float;
} [@@deriving yojson]

(** Token usage monoid - sums token counts *)
module Token_monoid : MONOID with type t = token_usage = struct
  type t = token_usage

  let empty = {
    prompt_tokens = 0;
    completion_tokens = 0;
    total_tokens = 0;
    estimated_cost_usd = 0.0;
  }

  let concat a b = {
    prompt_tokens = a.prompt_tokens + b.prompt_tokens;
    completion_tokens = a.completion_tokens + b.completion_tokens;
    total_tokens = a.total_tokens + b.total_tokens;
    estimated_cost_usd = a.estimated_cost_usd +. b.estimated_cost_usd;
  }

  let concat_all = function
    | [] -> empty
    | x :: xs -> List.fold_left concat x xs
end

(** {1 Profunctor for Adapters} *)

(** Function profunctor - input/output adapters *)
module Function_profunctor : PROFUNCTOR with type ('a, 'b) t = 'a -> 'b = struct
  type ('a, 'b) t = 'a -> 'b

  let dimap f g p = fun x -> g (p (f x))

  let lmap f p = fun x -> p (f x)

  let rmap g p = fun x -> g (p x)
end

(** {1 Utility Functions} *)

(** [identity] is the identity function. *)
let identity x = x

(** [compose f g] is function composition: (f . g) x = f (g x). *)
let compose f g x = f (g x)

(** Infix function composition. *)
let ( << ) = compose

(** Reverse function composition: (f >> g) x = g (f x). *)
let ( >> ) f g x = g (f x)

(** [flip f] swaps the arguments of a binary function. *)
let flip f x y = f y x

(** [const x] returns a function that always returns [x]. *)
let const x _ = x

(** [curry f] converts a function on pairs to a curried function. *)
let curry f x y = f (x, y)

(** [uncurry f] converts a curried function to a function on pairs. *)
let uncurry f (x, y) = f x y

(** {1 Laws Verification (for testing)} *)

module Laws = struct
  (** Functor laws *)
  module Functor (F : FUNCTOR) = struct
    let identity_law (x : 'a F.t) (equal : 'a F.t -> 'a F.t -> bool) =
      equal (F.map identity x) x

    let composition_law f g (x : 'a F.t) (equal : 'c F.t -> 'c F.t -> bool) =
      equal (F.map (compose f g) x) (F.map f (F.map g x))
  end

  (** Monad laws *)
  module Monad (M : MONAD) = struct
    let left_identity_law x f (equal : 'b M.t -> 'b M.t -> bool) =
      equal (M.bind (M.pure x) f) (f x)

    let right_identity_law (m : 'a M.t) (equal : 'a M.t -> 'a M.t -> bool) =
      equal (M.bind m M.pure) m

    let associativity_law m f g (equal : 'c M.t -> 'c M.t -> bool) =
      equal
        (M.bind (M.bind m f) g)
        (M.bind m (fun x -> M.bind (f x) g))
  end

  (** Monoid laws *)
  module Monoid (Mon : MONOID) = struct
    let left_identity_law x =
      Mon.concat Mon.empty x = x

    let right_identity_law x =
      Mon.concat x Mon.empty = x

    let associativity_law a b c =
      Mon.concat (Mon.concat a b) c = Mon.concat a (Mon.concat b c)
  end
end
