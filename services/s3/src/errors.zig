const std = @import("std");
const xml = @import("wire/xml.zig");

pub const Code = enum {
    no_such_bucket,
    no_such_key,
    no_such_upload,
    bucket_already_exists,
    bucket_already_owned_by_you,
    bucket_not_empty,
    invalid_bucket_name,
    invalid_argument,
    invalid_part,
    invalid_part_order,
    method_not_allowed,
    not_implemented,
    missing_content_length,
    entity_too_large,
    malformed_xml,
    no_such_bucket_policy,
    no_such_cors_configuration,
    no_such_lifecycle_configuration,
    no_such_website_configuration,
    no_such_tag_set,
    no_such_public_access_block_configuration,
    ownership_controls_not_found,
    replication_configuration_not_found,
    object_lock_configuration_not_found,
    server_side_encryption_configuration_not_found,
    access_denied,
    invalid_range,
    precondition_failed,
    request_timeout,
    internal_error,
};

pub fn httpStatus(c: Code) u16 {
    return switch (c) {
        .no_such_bucket,
        .no_such_key,
        .no_such_upload,
        .no_such_bucket_policy,
        .no_such_cors_configuration,
        .no_such_lifecycle_configuration,
        .no_such_website_configuration,
        .no_such_tag_set,
        .no_such_public_access_block_configuration,
        .ownership_controls_not_found,
        .replication_configuration_not_found,
        .object_lock_configuration_not_found,
        .server_side_encryption_configuration_not_found,
        => 404,

        .bucket_already_exists,
        .bucket_already_owned_by_you,
        .bucket_not_empty,
        => 409,

        .method_not_allowed => 405,
        .not_implemented => 501,
        .missing_content_length => 411,
        .access_denied => 403,
        .invalid_range => 416,
        .precondition_failed => 412,
        .internal_error => 500,

        .invalid_bucket_name,
        .invalid_argument,
        .invalid_part,
        .invalid_part_order,
        .entity_too_large,
        .malformed_xml,
        .request_timeout,
        => 400,
    };
}

pub fn codeString(c: Code) []const u8 {
    return switch (c) {
        .no_such_bucket => "NoSuchBucket",
        .no_such_key => "NoSuchKey",
        .no_such_upload => "NoSuchUpload",
        .bucket_already_exists => "BucketAlreadyExists",
        .bucket_already_owned_by_you => "BucketAlreadyOwnedByYou",
        .bucket_not_empty => "BucketNotEmpty",
        .invalid_bucket_name => "InvalidBucketName",
        .invalid_argument => "InvalidArgument",
        .invalid_part => "InvalidPart",
        .invalid_part_order => "InvalidPartOrder",
        .method_not_allowed => "MethodNotAllowed",
        .not_implemented => "NotImplemented",
        .missing_content_length => "MissingContentLength",
        .entity_too_large => "EntityTooLarge",
        .malformed_xml => "MalformedXML",
        .no_such_bucket_policy => "NoSuchBucketPolicy",
        .no_such_cors_configuration => "NoSuchCORSConfiguration",
        .no_such_lifecycle_configuration => "NoSuchLifecycleConfiguration",
        .no_such_website_configuration => "NoSuchWebsiteConfiguration",
        .no_such_tag_set => "NoSuchTagSet",
        .no_such_public_access_block_configuration => "NoSuchPublicAccessBlockConfiguration",
        .ownership_controls_not_found => "OwnershipControlsNotFoundError",
        .replication_configuration_not_found => "ReplicationConfigurationNotFoundError",
        .object_lock_configuration_not_found => "ObjectLockConfigurationNotFoundError",
        .server_side_encryption_configuration_not_found => "ServerSideEncryptionConfigurationNotFoundError",
        .access_denied => "AccessDenied",
        .invalid_range => "InvalidRange",
        .precondition_failed => "PreconditionFailed",
        .request_timeout => "RequestTimeout",
        .internal_error => "InternalError",
    };
}

pub fn defaultMessage(c: Code) []const u8 {
    return switch (c) {
        .no_such_bucket => "The specified bucket does not exist",
        .no_such_key => "The specified key does not exist.",
        .no_such_upload => "The specified upload does not exist. The upload ID may be invalid, or the upload may have been aborted or completed.",
        .bucket_already_exists => "The requested bucket name is not available. The bucket namespace is shared by all users of the system. Please select a different name and try again.",
        .bucket_already_owned_by_you => "Your previous request to create the named bucket succeeded and you already own it.",
        .bucket_not_empty => "The bucket you tried to delete is not empty",
        .invalid_bucket_name => "The specified bucket is not valid.",
        .invalid_argument => "Invalid Argument",
        .invalid_part => "One or more of the specified parts could not be found. The part may not have been uploaded, or the specified entity tag may not match the part's entity tag.",
        .invalid_part_order => "The list of parts was not in ascending order. Parts must be ordered by part number.",
        .method_not_allowed => "The specified method is not allowed against this resource.",
        .not_implemented => "A header you provided implies functionality that is not implemented.",
        .missing_content_length => "You must provide the Content-Length HTTP header.",
        .entity_too_large => "Your proposed upload exceeds the maximum allowed size",
        .malformed_xml => "The XML you provided was not well-formed or did not validate against our published schema",
        .no_such_bucket_policy => "The bucket policy does not exist",
        .no_such_cors_configuration => "The CORS configuration does not exist",
        .no_such_lifecycle_configuration => "The lifecycle configuration does not exist.",
        .no_such_website_configuration => "The specified bucket does not have a website configuration",
        .no_such_tag_set => "The TagSet does not exist",
        .no_such_public_access_block_configuration => "The public access block configuration was not found",
        .ownership_controls_not_found => "The bucket ownership controls were not found",
        .replication_configuration_not_found => "The replication configuration was not found",
        .object_lock_configuration_not_found => "Object Lock configuration does not exist for this bucket",
        .server_side_encryption_configuration_not_found => "The server side encryption configuration was not found",
        .access_denied => "Access Denied",
        .invalid_range => "The requested range is not satisfiable",
        .precondition_failed => "At least one of the preconditions you specified did not hold.",
        .request_timeout => "Your socket connection to the server was not read from or written to within the timeout period.",
        .internal_error => "We encountered an internal error. Please try again.",
    };
}

// REST XML error envelope. `bucket` and `resource` are optional; when null
// their elements are omitted.
pub fn render(
    arena: std.mem.Allocator,
    code: Code,
    bucket: ?[]const u8,
    resource: ?[]const u8,
    request_id: []const u8,
) ![]const u8 {
    var x = xml.Writer.init(arena);
    try x.declaration();
    try x.open("Error");
    try x.element("Code", codeString(code));
    try x.element("Message", defaultMessage(code));
    if (bucket) |b| try x.element("BucketName", b);
    if (resource) |r| try x.element("Resource", r);
    try x.element("RequestId", request_id);
    try x.element("HostId", "lws");
    try x.close("Error");
    return x.finish();
}

const testing = std.testing;

test "status and code strings" {
    try testing.expectEqual(@as(u16, 404), httpStatus(.no_such_bucket));
    try testing.expectEqual(@as(u16, 409), httpStatus(.bucket_not_empty));
    try testing.expectEqual(@as(u16, 501), httpStatus(.not_implemented));
    try testing.expectEqual(@as(u16, 416), httpStatus(.invalid_range));
    try testing.expectEqualStrings("NoSuchBucket", codeString(.no_such_bucket));
    try testing.expectEqualStrings("NoSuchCORSConfiguration", codeString(.no_such_cors_configuration));
}

test "render error envelope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try render(arena.allocator(), .no_such_bucket, "foo", "/foo/k", "rid-1");
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ++
            "<Error><Code>NoSuchBucket</Code>" ++
            "<Message>The specified bucket does not exist</Message>" ++
            "<BucketName>foo</BucketName><Resource>/foo/k</Resource>" ++
            "<RequestId>rid-1</RequestId><HostId>lws</HostId></Error>",
        s,
    );
}

test "render omits optional elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try render(arena.allocator(), .not_implemented, null, null, "rid-2");
    try testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" ++
            "<Error><Code>NotImplemented</Code>" ++
            "<Message>A header you provided implies functionality that is not implemented.</Message>" ++
            "<RequestId>rid-2</RequestId><HostId>lws</HostId></Error>",
        s,
    );
}
