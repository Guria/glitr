import gleam/bool
import gleam/list
import gleam/result
import gleam/string_builder
import glitr
import glitr/body
import glitr/path
import glitr/query
import glitr/route
import glitr_wisp/errors
import wisp

/// A Router is basically a request handler for glitr Routes  
/// It store the incoming request and will compare it to the different Routes that are provided to it.
/// The resulting response is generated based on the matching Route and the handler associated to it.
pub opaque type Router {
  Router(req: wisp.Request)
}

/// Create a new Router for the incoming request
pub fn for(req: wisp.Request) -> Result(Router, wisp.Response) {
  Ok(Router(req))
}

/// Compare the stored request with the provided Route  
/// If the first parameter has a response, this will be ignored.
/// Otherwise, if the request match the Route, generate a response based on the provided handler,
/// else return the Router so that these functions can be chained.
pub fn try(
  router_res: Result(Router, wisp.Response),
  route: route.Route(p, q, b, res),
  handler: fn(glitr.RouteOptions(p, q, b)) -> Result(res, errors.AppError),
) -> Result(Router, wisp.Response) {
  use router <- result.try(router_res)

  let result = receive(router.req, route, handler)

  case result {
    Ok(response) -> Error(response)
    Error(Nil) -> Ok(router)
  }
}

/// Do the same as the try function but also map the generated response
pub fn try_map(
  router_res: Result(Router, wisp.Response),
  route: route.Route(p, q, b, res),
  handler: fn(glitr.RouteOptions(p, q, b)) -> Result(res, errors.AppError),
  map_fn: fn(wisp.Response) -> wisp.Response,
) -> Result(Router, wisp.Response) {
  use router <- result.try(router_res)

  let result = receive(router.req, route, handler)

  case result {
    Ok(response) -> Error(response |> map_fn)
    Error(Nil) -> Ok(router)
  }
}

/// Unwrap the response generated by a Route or return a not_found if no route matched
pub fn unwrap(router_res: Result(Router, wisp.Response)) -> wisp.Response {
  case router_res {
    Ok(_) -> wisp.not_found()
    Error(response) -> response
  }
}

/// Test if the request match the Route, if so extract the path, query and body data and execute the handler function
/// to generate a response
fn receive(
  req: wisp.Request,
  route: route.Route(p, q, b, res),
  handler: fn(glitr.RouteOptions(p, q, b)) -> Result(res, errors.AppError),
) -> Result(wisp.Response, Nil) {
  use <- bool.guard(req.method != route.method, Error(Nil))
  use path <- handle_path(req, route)
  use query <- handle_query(req, route)
  use body <- handle_body(req, route)

  use <- handle_result(route)

  handler(glitr.RouteOptions(path, query, body))
}

/// Try extracting the path data from a request given a Route  
/// If successful, call callback with it.
/// Otherwise, return an error
fn handle_path(
  req: wisp.Request,
  route: route.Route(p, _, _, _),
  callback: fn(p) -> Result(wisp.Response, Nil),
) -> Result(wisp.Response, Nil) {
  let path_result = req |> wisp.path_segments |> path.decode(route.path, _)

  case path_result {
    Ok(path) -> callback(path)
    Error(_) -> Error(Nil)
  }
}

/// Try extracting the query data from a request given a Route  
/// If successful, call callback with it.
/// Otherwise, return an error
fn handle_query(
  req: wisp.Request,
  route: route.Route(_, q, _, _),
  callback: fn(q) -> Result(wisp.Response, Nil),
) -> Result(wisp.Response, Nil) {
  let path_result = req |> wisp.get_query |> query.decode(route.query, _)

  case path_result {
    Ok(path) -> callback(path)
    Error(_) -> Error(Nil)
  }
}

/// Try extracting the body data from a request given a Route  
/// If successful, call callback with it.
/// Otherwise, return an error
fn handle_body(
  req: wisp.Request,
  route: route.Route(_, _, b, _),
  callback: fn(b) -> wisp.Response,
) -> Result(wisp.Response, Nil) {
  let call_callback = fn(res) {
    case res {
      Ok(value) -> callback(value)
      Error(_) ->
        wisp.bad_request()
        |> wisp.string_body("Error while decoding body as JSON")
    }
  }

  let body = case route.req_body |> body.get_type {
    body.EmptyBody -> route.req_body |> body.decode("") |> call_callback
    body.JsonBody -> {
      use value <- wisp.require_string_body(req)
      use <- bool.guard(
        req.headers |> list.key_find("content-type") != Ok("application/json"),
        wisp.unsupported_media_type(["application/json"]),
      )
      route.req_body
      |> body.decode(value)
      |> call_callback
    }
    body.StringBody -> {
      use value <- wisp.require_string_body(req)
      route.req_body
      |> body.decode(value)
      |> call_callback
    }
  }
  Ok(body)
}

/// Generate a response with the correct data if handler is successful,
/// or an error response otherwise
fn handle_result(
  route: route.Route(_, _, _, res),
  handler: fn() -> Result(res, errors.AppError),
) -> wisp.Response {
  let result = handler()

  case result {
    Error(errors.DecoderError(msg)) ->
      wisp.bad_request()
      |> wisp.set_body(wisp.Text(string_builder.from_string(msg)))
    Error(errors.DBError(msg)) ->
      wisp.internal_server_error()
      |> wisp.set_body(wisp.Text(string_builder.from_string(msg)))
    Error(errors.InternalError(msg)) ->
      wisp.internal_server_error()
      |> wisp.set_body(wisp.Text(string_builder.from_string(msg)))
    Ok(res) ->
      case route.res_body |> body.get_type {
        body.JsonBody ->
          route.res_body
          |> body.encode(res)
          |> wisp.json_response(200)
        body.StringBody ->
          wisp.ok()
          |> wisp.set_body(wisp.Text(
            route.res_body
            |> body.encode(res),
          ))
        body.EmptyBody -> wisp.ok()
      }
  }
}
