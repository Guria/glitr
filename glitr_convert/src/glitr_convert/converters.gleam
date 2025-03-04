import gleam/dict
import gleam/dynamic
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glitr_convert.{type GlitrType, type GlitrValue}

/// A converter is an object with the data necessary to encode and decode a specific Gleam type.  
/// You can build converters using the provided constructors.
pub opaque type Converter(a) {
  Converter(
    encoder: fn(a) -> GlitrValue,
    decoder: fn(GlitrValue) -> Result(a, List(dynamic.DecodeError)),
    type_def: GlitrType,
  )
}

/// This is an intermediary type to build converters for a custom Gleam type.  
/// TODO: rename
pub opaque type ObjectDefinition(current, base) {
  ObjectDefinition(constructor: fn() -> base)
  ObjectParameterDefinition(constructor: fn(current) -> base)
}

/// This is an intermediary type to build converters for a custom Gleam type.  
/// TODO: rename
pub opaque type ObjectConverterBuilder(current, base) {
  ObjectConverterBuilder(
    encoder: fn(base, current) -> GlitrValue,
    decoder: fn(GlitrValue, current) -> Result(base, List(dynamic.DecodeError)),
    type_def: GlitrType,
  )
}

/// Build a converter for a custom Gleam type.
/// 
/// Example: 
/// ```
/// type Person {
///   Person(name: String, age: Int)
/// }
/// 
/// let converter = object({
///   use name <- parameter
///   use age <- parameter
///   use <- constructor
/// 
///   Person(name:, age:)
/// })
/// |> field("name", fn(v) { Ok(v.name) }, string())
/// |> field("age", fn(v) { Ok(v.age) }, int())
/// |> to_converter
/// ```
pub fn object(
  object_converter: ObjectDefinition(a, b),
) -> ObjectConverterBuilder(a, b) {
  ObjectConverterBuilder(
    fn(_, _) { glitr_convert.ObjectValue([]) },
    fn(_, curr) {
      case object_converter {
        ObjectDefinition(constructor) -> Ok(constructor())
        ObjectParameterDefinition(constructor) -> Ok(constructor(curr))
      }
    },
    glitr_convert.Object([]),
  )
}

/// Specify a new parameter to be used in an object converter.  
/// See `object()`
pub fn parameter(
  next: fn(a) -> ObjectDefinition(b, c),
) -> ObjectDefinition(#(a, b), c) {
  ObjectParameterDefinition(fn(v: #(a, b)) {
    case next(v.0) {
      ObjectDefinition(constructor) -> constructor()
      ObjectParameterDefinition(constructor) -> constructor(v.1)
    }
  })
}

/// Specify that the next instruction returns a constructed instance of the type to convert.  
/// See `object()`
pub fn constructor(c: fn() -> a) -> ObjectDefinition(Nil, a) {
  ObjectDefinition(c)
}

/// Provide information about the fields of an object converter. 
///  
/// `field_name` is the key that will be used in the encoded data.  
/// `field_getter` is a function returning a way to access the field from an instance.  
/// `field_type` is the converter to use for this field.  
/// 
/// See `object()` for an example.
pub fn field(
  converter: ObjectConverterBuilder(#(a, b), c),
  field_name: String,
  field_getter: fn(c) -> Result(a, Nil),
  field_type: Converter(a),
) -> ObjectConverterBuilder(b, c) {
  ObjectConverterBuilder(
    encoder: fn(base: c, curr: b) {
      let value = field_getter(base)

      case value {
        Error(Nil) -> glitr_convert.NullValue
        Ok(field_value) -> {
          case converter.encoder(base, #(field_value, curr)) {
            glitr_convert.ObjectValue(fields) ->
              glitr_convert.ObjectValue(
                list.append(fields, [
                  #(field_name, field_type.encoder(field_value)),
                ]),
              )
            _ -> glitr_convert.NullValue
          }
        }
      }
    },
    decoder: fn(v: GlitrValue, curr: b) {
      case v {
        glitr_convert.ObjectValue(values) -> {
          let field_value =
            values
            |> list.key_find(field_name)
            |> result.replace_error([
              dynamic.DecodeError("Value", "None", [field_name]),
            ])
            |> result.then(field_type.decoder)

          use a <- result.try(field_value)

          converter.decoder(v, #(a, curr))
        }
        _ -> Error([])
      }
    },
    type_def: case converter.type_def {
      glitr_convert.Object(fields) ->
        glitr_convert.Object(
          list.append(fields, [#(field_name, field_type.type_def)]),
        )
      _ -> glitr_convert.Object([#(field_name, field_type.type_def)])
    },
  )
}

/// Generate a converter from a builder type
pub fn to_converter(converter: ObjectConverterBuilder(Nil, a)) -> Converter(a) {
  Converter(
    encoder: converter.encoder(_, Nil),
    decoder: converter.decoder(_, Nil),
    type_def: converter.type_def,
  )
}

/// Basic converter for a String value
pub fn string() -> Converter(String) {
  Converter(
    fn(v: String) { glitr_convert.StringValue(v) },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.StringValue(val) -> Ok(val)
        other ->
          Error([dynamic.DecodeError("StringValue", get_type(other), [])])
      }
    },
    glitr_convert.String,
  )
}

/// Basic converter for a Bool value
pub fn bool() -> Converter(Bool) {
  Converter(
    fn(v: Bool) { glitr_convert.BoolValue(v) },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.BoolValue(val) -> Ok(val)
        other -> Error([dynamic.DecodeError("BoolValue", get_type(other), [])])
      }
    },
    glitr_convert.Bool,
  )
}

/// Basic converter for a Float value
pub fn float() -> Converter(Float) {
  Converter(
    fn(v: Float) { glitr_convert.FloatValue(v) },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.FloatValue(val) -> Ok(val)
        other -> Error([dynamic.DecodeError("FloatValue", get_type(other), [])])
      }
    },
    glitr_convert.Float,
  )
}

/// Basic converter for a Int value
pub fn int() -> Converter(Int) {
  Converter(
    fn(v: Int) { glitr_convert.IntValue(v) },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.IntValue(val) -> Ok(val)
        other -> Error([dynamic.DecodeError("IntValue", get_type(other), [])])
      }
    },
    glitr_convert.Int,
  )
}

/// Basic converter for a Nil value
pub fn null() -> Converter(Nil) {
  Converter(
    fn(_: Nil) { glitr_convert.NullValue },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.NullValue -> Ok(Nil)
        other -> Error([dynamic.DecodeError("NullValue", get_type(other), [])])
      }
    },
    glitr_convert.Null,
  )
}

/// Basic converter for a List value.   
/// 
/// `of` is a converter for the type of the elements.
pub fn list(of: Converter(a)) -> Converter(List(a)) {
  Converter(
    fn(v: List(a)) { glitr_convert.ListValue(v |> list.map(of.encoder)) },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.ListValue(vals) ->
          vals
          |> list.fold(Ok([]), fn(result, val) {
            case result, of.decoder(val) {
              Ok(res), Ok(new_res) -> Ok(list.append(res, [new_res]))
              Error(errs), Error(new_errs) -> Error(list.append(errs, new_errs))
              _, Error(errs) | Error(errs), _ -> Error(errs)
            }
          })
        other -> Error([dynamic.DecodeError("ListValue", get_type(other), [])])
      }
    },
    glitr_convert.List(of.type_def),
  )
}

/// Basic converter for a Option value.
/// 
/// `of` is a converter for the optional value.
pub fn optional(of: Converter(a)) -> Converter(option.Option(a)) {
  Converter(
    fn(v: option.Option(a)) {
      glitr_convert.OptionalValue(v |> option.map(of.encoder))
    },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.OptionalValue(option.None) -> Ok(option.None)
        glitr_convert.OptionalValue(option.Some(val)) ->
          val |> of.decoder |> result.map(option.Some)
        other ->
          Error([dynamic.DecodeError("OptionalValue", get_type(other), [])])
      }
    },
    glitr_convert.Optional(of.type_def),
  )
}

/// Basic converter for a Result value.
/// 
/// `res` is a converter for the Ok value.
/// `error` is a converter for the Error value.
pub fn result(
  res: Converter(ok),
  error: Converter(err),
) -> Converter(Result(ok, err)) {
  Converter(
    fn(v: Result(ok, err)) {
      glitr_convert.ResultValue(
        v |> result.map(res.encoder) |> result.map_error(error.encoder),
      )
    },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.ResultValue(Ok(val)) ->
          val |> res.decoder |> result.map(Ok)
        glitr_convert.ResultValue(Error(val)) ->
          val |> error.decoder |> result.map(Error)
        other ->
          Error([dynamic.DecodeError("ResultValue", get_type(other), [])])
      }
    },
    glitr_convert.Result(res.type_def, error.type_def),
  )
}

/// Basic converter for a Dict value.
/// 
/// `key` is a converter for the keys.
/// `value` is a converter for the values.
/// 
/// Example:
/// ```
/// let converter: Converter(Dict(String, Int)) = dict(string(), int())
/// ```
pub fn dict(
  key: Converter(k),
  value: Converter(v),
) -> Converter(dict.Dict(k, v)) {
  Converter(
    fn(v: dict.Dict(k, v)) {
      glitr_convert.DictValue(
        v
        |> dict.to_list
        |> list.map(fn(kv) { #(kv.0 |> key.encoder, kv.1 |> value.encoder) })
        |> dict.from_list,
      )
    },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.DictValue(d) ->
          d
          |> dict.to_list
          |> list.fold(Ok([]), fn(result, kv) {
            case result, key.decoder(kv.0), value.decoder(kv.1) {
              Ok(values), Ok(new_k), Ok(new_v) ->
                Ok(list.append(values, [#(new_k, new_v)]))
              Error(errs), Ok(_), Ok(_)
              | Ok(_), Ok(_), Error(errs)
              | Ok(_), Error(errs), Ok(_)
              -> Error(errs)
              Ok(_), Error(errs_1), Error(errs_2)
              | Error(errs_1), Error(errs_2), Ok(_)
              | Error(errs_1), Ok(_), Error(errs_2)
              -> Error(list.append(errs_1, errs_2))
              Error(errs), Error(errs_k), Error(errs_v) ->
                Error(list.concat([errs, errs_k, errs_v]))
            }
          })
          |> result.map(dict.from_list)
        other -> Error([dynamic.DecodeError("DictValue", get_type(other), [])])
      }
    },
    glitr_convert.Dict(key.type_def, value.type_def),
  )
}

/// Create a converter for an enum type
/// 
/// `tags` is a function that associate a tag to each variant of the enum
/// `converters` is a list of converters, each associated with a tag
/// 
/// Example:
/// ```
/// type Action {
///   Open(id: String)
///   Close(id: String)
/// }
/// 
/// let open_converter = object({
///   use id <- parameter
///   use <- constructor
///   Open(id:)
/// })
/// |> field("id", fn(v) {
///   case v {
///     Open(id) -> Ok(id)
///     _ -> Error(Nil)
///   }
/// })
/// |> to_converter
/// 
/// let close_converter = object({
///   use id <- parameter
///   use <- constructor
///   Close(id:)
/// })
/// |> field("id", fn(v) {
///   case v {
///     Close(id) -> Ok(id)
///     _ -> Error(Nil)
///   }
/// })
/// |> to_converter
/// 
/// let action_converter = enum(
///   fn(v) {
///     case v {
///       Open(_) -> "Open"
///       Close(_) -> "Close"
///     }
///   },
///   [
///     #("Open", open_converter),
///     #("Close", close_converter),
///   ]
/// )
/// ```
pub fn enum(
  tags: fn(a) -> String,
  converters: List(#(String, Converter(a))),
) -> Converter(a) {
  Converter(
    fn(v: a) {
      let tag = tags(v)

      case converters |> list.key_find(tag) {
        Ok(variant) -> glitr_convert.EnumValue(tag, variant.encoder(v))
        Error(_) -> glitr_convert.NullValue
      }
    },
    fn(v: GlitrValue) {
      case v {
        glitr_convert.EnumValue(variant_name, value) -> {
          use variant <- result.try(
            converters
            |> list.key_find(variant_name)
            |> result.replace_error([
              dynamic.DecodeError(
                "One of: "
                  <> converters |> list.map(fn(v) { v.0 }) |> string.join("/"),
                variant_name,
                ["0"],
              ),
            ]),
          )
          variant.decoder(value)
        }
        other -> Error([dynamic.DecodeError("EnumValue", get_type(other), [])])
      }
    },
    glitr_convert.Enum(
      converters |> list.map(fn(var) { #(var.0, { var.1 }.type_def) }),
    ),
  )
}

fn get_type(val: GlitrValue) -> String {
  case val {
    glitr_convert.BoolValue(_) -> "BoolValue"
    glitr_convert.DictValue(_) -> "DictValue"
    glitr_convert.EnumValue(_, _) -> "EnumValue"
    glitr_convert.FloatValue(_) -> "FloatValue"
    glitr_convert.IntValue(_) -> "IntValue"
    glitr_convert.ListValue(_) -> "ListValue"
    glitr_convert.NullValue -> "NullValue"
    glitr_convert.ObjectValue(_) -> "ObjectValue"
    glitr_convert.OptionalValue(_) -> "OptionalValue"
    glitr_convert.ResultValue(_) -> "ResultValue"
    glitr_convert.StringValue(_) -> "StringValue"
  }
}

/// Encode a value into the corresponding GlitrValue using the converter.  
/// If the converter isn't valid, a NullValue is returned.
pub fn encode(converter: Converter(a)) -> fn(a) -> GlitrValue {
  converter.encoder
}

/// Decode a GlitrValue using the provided converter.
pub fn decode(
  converter: Converter(a),
) -> fn(GlitrValue) -> Result(a, List(dynamic.DecodeError)) {
  converter.decoder
}

pub fn type_def(converter: Converter(a)) -> GlitrType {
  converter.type_def
}
