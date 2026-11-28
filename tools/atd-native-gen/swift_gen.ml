(* Writes Native_ir as Swift 6 types that decode the server's JSON.

   - Record: a struct whose CodingKeys map each property to its wire name.
     Optional fields are Swift optionals; the synthesized decoder reads an
     absent key as nil.
   - Closed enum: a String raw-value enum. An unknown name fails to decode.
   - Open enum: cases plus unrecognized(String).
   - Tagged sum: an enum with one associated record per kind, decoded by
     reading "type" first. When open, an unknown kind becomes
     unrecognized(name:raw:) instead of an error.

   The types are Decodable only: the clients read these frames and never
   write them. *)

open Native_ir

let scalar = function
  | String -> "String"
  | Int -> "Int"
  | Float -> "Double"
  | Bool -> "Bool"
  | Json -> "JSONValue"

let rec ty = function
  | Scalar s -> scalar s
  | Ref name -> Naming.upper_camel name
  | List item -> "[" ^ ty item ^ "]"

let conformances = "Decodable, Equatable, Sendable"

let json_value =
  {|/// Any JSON value. Numbers are Double, so an integer above 2^53 loses
/// precision.
public enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}
|}

let record buffer ~name ~fields =
  let p fmt = Printf.bprintf buffer fmt in
  p "public struct %s: %s {\n" (Naming.upper_camel name) conformances;
  List.iter
    (fun field ->
      p "    public let %s: %s%s\n" (Naming.lower_camel field.name) (ty field.ty)
        (if field.optional then "?" else ""))
    fields;
  (match fields with
   | [] -> ()
   | _ :: _ ->
     p "\n    private enum CodingKeys: String, CodingKey {\n";
     List.iter
       (fun field ->
         p "        case %s = %s\n" (Naming.lower_camel field.name) (Naming.quoted field.json_name))
       fields;
     p "    }\n");
  p "}\n"

let enum buffer ~name ~cases ~openness =
  let p fmt = Printf.bprintf buffer fmt in
  let swift_name = Naming.upper_camel name in
  match openness with
  | Closed ->
    p "public enum %s: String, %s {\n" swift_name conformances;
    List.iter
      (fun case -> p "    case %s = %s\n" (Naming.lower_camel case.case_name) (Naming.quoted case.case_json))
      cases;
    p "}\n"
  | Open ->
    p "public enum %s: %s {\n" swift_name conformances;
    List.iter (fun case -> p "    case %s\n" (Naming.lower_camel case.case_name)) cases;
    p "    /// A name this client does not know yet. Show it as it is; it never\n";
    p "    /// stands for a known name.\n";
    p "    case unrecognized(String)\n\n";
    p "    public init(from decoder: any Decoder) throws {\n";
    p "        let name = try decoder.singleValueContainer().decode(String.self)\n";
    p "        switch name {\n";
    List.iter
      (fun case ->
        p "        case %s: self = .%s\n" (Naming.quoted case.case_json) (Naming.lower_camel case.case_name))
      cases;
    p "        default: self = .unrecognized(name)\n";
    p "        }\n";
    p "    }\n";
    p "}\n"

let tagged buffer ~name ~cases ~openness =
  let p fmt = Printf.bprintf buffer fmt in
  p "public enum %s: %s {\n" (Naming.upper_camel name) conformances;
  List.iter
    (fun case ->
      p "    case %s(%s)\n" (Naming.lower_camel case.tag_name) (Naming.upper_camel case.payload))
    cases;
  (match openness with
   | Open ->
     p "    /// A kind this client does not know yet, with the whole frame.\n";
     p "    case unrecognized(name: String, raw: JSONValue)\n"
   | Closed -> ());
  p "\n    private enum TagKey: String, CodingKey {\n";
  p "        case tag = \"type\"\n";
  p "    }\n\n";
  p "    public init(from decoder: any Decoder) throws {\n";
  p "        let container = try decoder.container(keyedBy: TagKey.self)\n";
  p "        let tag = try container.decode(String.self, forKey: .tag)\n";
  p "        switch tag {\n";
  List.iter
    (fun case ->
      p "        case %s: self = .%s(try %s(from: decoder))\n" (Naming.quoted case.tag_json)
        (Naming.lower_camel case.tag_name) (Naming.upper_camel case.payload))
    cases;
  (match openness with
   | Open -> p "        default: self = .unrecognized(name: tag, raw: try JSONValue(from: decoder))\n"
   | Closed ->
     p "        default:\n";
     p "            throw DecodingError.dataCorruptedError(\n";
     p "                forKey: .tag, in: container, debugDescription: \"unknown type \\(tag)\")\n");
  p "        }\n";
  p "    }\n";
  p "}\n"

let emit ~source defs =
  let buffer = Buffer.create 16384 in
  Printf.bprintf buffer
    "// Generated by tools/atd-native-gen from %s. Do not edit.\n\
     // To regenerate: dune build @check, then dune promote.\n\n\
     import Foundation\n"
    source;
  if uses_json defs then Printf.bprintf buffer "\n%s" json_value;
  List.iter
    (fun def ->
      Buffer.add_char buffer '\n';
      match def with
      | Record { name; fields } -> record buffer ~name ~fields
      | Enum { name; cases; openness } -> enum buffer ~name ~cases ~openness
      | Tagged { name; cases; openness } -> tagged buffer ~name ~cases ~openness)
    defs;
  Buffer.contents buffer
