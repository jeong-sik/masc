(* Writes Native_ir as Kotlin types for kotlinx.serialization JSON.

   - Record: a @Serializable data class; each property carries its wire
     name in @SerialName. Optional fields are nullable with default null,
     so an absent key reads as null.
   - Closed enum: an enum class with @SerialName entries. An unknown name
     fails to decode.
   - Open enum: a sealed interface with one data object per name plus
     Unrecognized(wireName); <Name>Serializer reads and writes the name.
   - Tagged sum: a sealed interface with one wrapper per kind, read by
     <Name>Deserializer, which reads "type" first. When open, an unknown
     kind becomes Unrecognized(name, raw) instead of an error.

   Payloads are decoded with WireJson, which ignores unknown keys: every
   payload carries "type", and a newer server may add fields. *)

open Native_ir

let scalar = function
  | String -> "String"
  | Int -> "Long"
  | Float -> "Double"
  | Bool -> "Boolean"
  | Json -> "JsonElement"

let rec ty = function
  | Scalar s -> scalar s
  | Ref name -> Naming.upper_camel name
  | List item -> "List<" ^ ty item ^ ">"

(* A package is dot-separated lowercase names that are not Kotlin
   keywords. *)
let valid_package package =
  let segment name =
    name <> ""
    && (match name.[0] with
        | 'a' .. 'z' -> true
        | _ -> false)
    && String.for_all
         (function
           | 'a' .. 'z' | '0' .. '9' | '_' -> true
           | _ -> false)
         name
    && not (List.mem name kotlin_keywords)
  in
  List.for_all segment (String.split_on_char '.' package)

let kotlinx name = "kotlinx.serialization." ^ name

let imports defs =
  let rec ty_json = function
    | Scalar Json -> true
    | Scalar (String | Int | Float | Bool) | Ref _ -> false
    | List item -> ty_json item
  in
  let of_def = function
    | Record { fields = []; _ } -> [ "Serializable" ]
    | Record { fields; _ } ->
      [ "Serializable"; "SerialName" ]
      @ if List.exists (fun (field : field) -> ty_json field.ty) fields then [ "json.JsonElement" ] else []
    | Enum { openness = Closed; _ } -> [ "Serializable"; "SerialName" ]
    | Enum { openness = Open; _ } ->
      [ "Serializable"; "KSerializer"; "descriptors.PrimitiveKind"
      ; "descriptors.PrimitiveSerialDescriptor"; "descriptors.SerialDescriptor"
      ; "encoding.Decoder"; "encoding.Encoder" ]
    | Tagged { openness; _ } ->
      [ "DeserializationStrategy"; "SerializationException"; "descriptors.SerialDescriptor"
      ; "descriptors.buildClassSerialDescriptor"; "encoding.Decoder"; "json.Json"
      ; "json.JsonDecoder"; "json.JsonObject"; "json.JsonPrimitive" ]
      @ (match openness with
         | Open -> [ "json.JsonElement" ]
         | Closed -> [])
  in
  List.sort_uniq compare (List.map kotlinx (List.concat_map of_def defs))

let record buffer ~name ~fields =
  let p fmt = Printf.bprintf buffer fmt in
  match fields with
  | [] -> p "@Serializable\ndata object %s\n" (Naming.upper_camel name)
  | _ :: _ ->
    p "@Serializable\ndata class %s(\n" (Naming.upper_camel name);
    List.iter
      (fun field ->
        p "    @SerialName(%s) val %s: %s%s,\n" (Naming.quoted field.json_name)
          (Naming.lower_camel field.name) (ty field.ty)
          (if field.optional then "? = null" else ""))
      fields;
    p ")\n"

let enum buffer ~package ~name ~cases ~openness =
  let p fmt = Printf.bprintf buffer fmt in
  let kotlin_name = Naming.upper_camel name in
  match openness with
  | Closed ->
    p "@Serializable\nenum class %s {\n" kotlin_name;
    List.iter
      (fun case -> p "    @SerialName(%s) %s,\n" (Naming.quoted case.case_json) (Naming.upper_camel case.case_name))
      cases;
    p "}\n"
  | Open ->
    p "@Serializable(with = %sSerializer::class)\nsealed interface %s {\n" kotlin_name kotlin_name;
    p "    val wireName: String\n";
    List.iter
      (fun case ->
        p "\n    data object %s : %s {\n" (Naming.upper_camel case.case_name) kotlin_name;
        p "        override val wireName: String = %s\n" (Naming.quoted case.case_json);
        p "    }\n")
      cases;
    p "\n    /** A name this client does not know yet. Decoding never puts a known\n";
    p "        name here. */\n";
    p "    data class Unrecognized(override val wireName: String) : %s\n" kotlin_name;
    p "}\n\n";
    p "object %sSerializer : KSerializer<%s> {\n" kotlin_name kotlin_name;
    p "    override val descriptor: SerialDescriptor =\n";
    p "        PrimitiveSerialDescriptor(\"%s.%s\", PrimitiveKind.STRING)\n\n" package kotlin_name;
    p "    override fun deserialize(decoder: Decoder): %s =\n" kotlin_name;
    p "        when (val name = decoder.decodeString()) {\n";
    List.iter
      (fun case ->
        p "            %s -> %s.%s\n" (Naming.quoted case.case_json) kotlin_name
          (Naming.upper_camel case.case_name))
      cases;
    p "            else -> %s.Unrecognized(name)\n" kotlin_name;
    p "        }\n\n";
    p "    override fun serialize(encoder: Encoder, value: %s) {\n" kotlin_name;
    p "        encoder.encodeString(value.wireName)\n";
    p "    }\n";
    p "}\n"

let tagged buffer ~package ~name ~cases ~openness =
  let p fmt = Printf.bprintf buffer fmt in
  let kotlin_name = Naming.upper_camel name in
  p "sealed interface %s {\n" kotlin_name;
  List.iter
    (fun case ->
      p "    data class %s(val value: %s.%s) : %s\n" (Naming.upper_camel case.tag_name) package
        (Naming.upper_camel case.payload) kotlin_name)
    cases;
  (match openness with
   | Open ->
     p "\n    /** A kind this client does not know yet, with the whole frame. */\n";
     p "    data class Unrecognized(val name: String, val raw: JsonElement) : %s\n" kotlin_name
   | Closed -> ());
  p "}\n\n";
  p "/** Reads a %s from JSON: \"type\" first, then the record of that kind. */\n" kotlin_name;
  p "object %sDeserializer : DeserializationStrategy<%s> {\n" kotlin_name kotlin_name;
  p "    override val descriptor: SerialDescriptor = buildClassSerialDescriptor(\"%s.%s\")\n\n"
    package kotlin_name;
  p "    override fun deserialize(decoder: Decoder): %s {\n" kotlin_name;
  p "        val input = decoder as? JsonDecoder\n";
  p "            ?: throw SerializationException(\"%s decodes from JSON only\")\n" kotlin_name;
  p "        val element = input.decodeJsonElement()\n";
  p "        val tag = ((element as? JsonObject)?.get(\"type\") as? JsonPrimitive)\n";
  p "            ?.takeIf { it.isString }?.content\n";
  p "            ?: throw SerializationException(\"%s needs a string \\\"type\\\"\")\n" kotlin_name;
  p "        return when (tag) {\n";
  List.iter
    (fun case ->
      p "            %s -> %s.%s(WireJson.decodeFromJsonElement(%s.serializer(), element))\n"
        (Naming.quoted case.tag_json) kotlin_name (Naming.upper_camel case.tag_name)
        (Naming.upper_camel case.payload))
    cases;
  (match openness with
   | Open -> p "            else -> %s.Unrecognized(tag, element)\n" kotlin_name
   | Closed -> p "            else -> throw SerializationException(\"unknown type $tag\")\n");
  p "        }\n";
  p "    }\n";
  p "}\n"

let emit ~source ~package defs =
  let buffer = Buffer.create 16384 in
  let p fmt = Printf.bprintf buffer fmt in
  p "// Generated by tools/atd-native-gen from %s. Do not edit.\n" source;
  p "// To regenerate: dune build @check, then dune promote.\n\n";
  p "package %s\n\n" package;
  List.iter (fun import -> p "import %s\n" import) (imports defs);
  if List.exists (function Tagged _ -> true | Record _ | Enum _ -> false) defs
  then (
    p "\n/** The Json the wire types decode with. Unknown keys are ignored: every\n";
    p "    payload carries \"type\", and a newer server may add fields. */\n";
    p "val WireJson: Json = Json { ignoreUnknownKeys = true }\n");
  List.iter
    (fun def ->
      Buffer.add_char buffer '\n';
      match def with
      | Record { name; fields } -> record buffer ~name ~fields
      | Enum { name; cases; openness } -> enum buffer ~package ~name ~cases ~openness
      | Tagged { name; cases; openness } -> tagged buffer ~package ~name ~cases ~openness)
    defs;
  Buffer.contents buffer
