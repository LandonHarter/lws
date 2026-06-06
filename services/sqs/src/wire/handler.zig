const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const errors = @import("../errors.zig");
const envelope = @import("envelope.zig");
const json_proto = @import("json_proto.zig");
const query_proto = @import("query_proto.zig");

const Request = envelope.Request;

pub const json_content_type = "application/x-amz-json-1.0";
pub const xml_content_type = "text/xml";

pub const Response = struct {
    status: u16 = 200,
    body: []const u8,
    content_type: []const u8,
};

pub const Handler = *const fn (rt: *Runtime, req: *const Request) anyerror!Response;

pub fn renderError(rt: *Runtime, req: *const Request, code: errors.Code, message: []const u8) Response {
    _ = rt;
    const arena = req.arena.allocator();
    const status = errors.httpStatus(code);
    switch (req.protocol) {
        .json => {
            const body = json_proto.writeError(arena, errors.jsonType(code), message) catch
                "{\"__type\":\"com.amazonaws.sqs#InternalError\",\"message\":\"\"}";
            return .{ .status = status, .body = body, .content_type = json_content_type };
        },
        .query => {
            const body = query_proto.writeError(arena, errors.queryCode(code), message, &req.request_id) catch
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ErrorResponse><Error><Code>InternalError</Code></Error></ErrorResponse>";
            return .{ .status = status, .body = body, .content_type = xml_content_type };
        },
    }
}

pub fn renderResult(rt: *Runtime, req: *const Request, result: anyerror!Response) Response {
    return result catch |err| switch (err) {
        error.InvalidJson, error.InvalidForm, error.MissingAction => renderError(rt, req, .invalid_parameter_value, "Could not parse the request body."),
        error.OutOfMemory => renderError(rt, req, .internal_error, errors.defaultMessage(.internal_error)),
        else => renderError(rt, req, .internal_error, errors.defaultMessage(.internal_error)),
    };
}
