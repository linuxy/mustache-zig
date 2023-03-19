const std = @import("std");
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const mustache = @import("mustache");

// Mustache template
const template_text =
    \\{{! This is a spec-compliant mustache template }}
    \\Hello {{name}} from Zig
    \\This template was generated with
    \\{{#env}}
    \\Zig: {{zig_version}}
    \\Mustache: {{mustache_version}}
    \\{{/env}}
    \\Supported features:
    \\{{#features}}
    \\  - {{name}} {{condition}}
    \\{{/features}}
;

const Feature = struct {
    name: []const u8,
    condition: []const u8,
};

// Context, can be any Zig struct, supporting optionals, slices, tuples, recursive types, pointers, etc.
var ctx = .{
    .name = "friends",
    .env = .{
        .zig_version = "master",
        .mustache_version = "alpha",
    },
    .features = &[_]Feature{
        .{ .name = "interpolation", .condition = "✅ done" },
        .{ .name = "sections", .condition = "✅ done" },
        .{ .name = "comments", .condition = "✅ done" },
        .{ .name = "delimiters", .condition = "✅ done" },
        .{ .name = "partials", .condition = "✅ done" },
        .{ .name = "lambdas", .condition = "✅ done" },
        .{ .name = "inheritance", .condition = "⏳ comming soon" },
    },
};

pub fn main() anyerror!void {
    try renderFromString();
    try renderFromJson();
    //try renderComptimeTemplate();
    try renderFromCachedTemplate();
    try renderFromFile();
    //try renderComptimePartialTemplate();
}

/// Render a template from a string
pub fn renderFromString() anyerror!void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.detectLeaks()) @panic("renderFromString leaked");
        _ = gpa.deinit();
    }

    const allocator = gpa.allocator();
    var out = std.io.getStdOut();

    // Direct render to save memory
    try mustache.renderText(allocator, template_text, ctx, out.writer());
}

/// Render a template from a Json object
pub fn renderFromJson() anyerror!void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.detectLeaks()) @panic("renderFromJson leaked");
        _ = gpa.deinit();
    }

    const allocator = gpa.allocator();
    var out = std.io.getStdOut();

    // Serializing the context as a json string
    const json_text = try std.json.stringifyAlloc(allocator, ctx, .{});
    defer allocator.free(json_text);

    // Parsing into a Json object
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var tree = try parser.parse(json_text);
    defer tree.deinit();

    // Rendering from a Json object
    try mustache.renderText(allocator, template_text, tree, out.writer());
}

/// Parses a template at comptime to render many times at runtime, no allocations needed
pub fn renderComptimeTemplate() anyerror!void {
    var out = std.io.getStdOut();

    // Comptime-parsed template
    const comptime_template = comptime mustache.parseComptime(template_text, .{}, .{});

    var repeat: u32 = 0;
    while (repeat < 10) : (repeat += 1) {
        try mustache.render(comptime_template, ctx, out.writer());
    }
}

/// Caches a template to render many times
pub fn renderFromCachedTemplate() anyerror!void {
    var gpa = GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.detectLeaks()) @panic("renderFromCachedTemplate leaked");
        _ = gpa.deinit();
    }

    const allocator = gpa.allocator();

    // Store this template and render many times from it
    const cached_template = switch (try mustache.parseText(allocator, template_text, .{}, .{ .copy_strings = false })) {
        .success => |ret| ret,
        .parse_error => |detail| {
            std.log.err("Parse error {s} at lin {}, col {}", .{ @errorName(detail.parse_error), detail.lin, detail.col });
            return;
        },
    };
    defer cached_template.deinit(allocator);

    var repeat: u32 = 0;
    while (repeat < 10) : (repeat += 1) {
        var result = try mustache.allocRender(allocator, cached_template, ctx);
        defer allocator.free(result);

        var out = std.io.getStdOut();
        try out.writeAll(result);
    }
}

/// Render a template from a file path
pub fn renderFromFile() anyerror!void {

    // 16KB should be enough memory for this job
    var plenty_of_memory = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){
        .requested_memory_limit = 16 * 1024,
    };
    defer _ = plenty_of_memory.deinit();

    const allocator = plenty_of_memory.allocator();

    const path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(path);

    // Creating a temp file
    const path_to_template = try std.fs.path.join(allocator, &.{ path, "template.mustache" });
    defer allocator.free(path_to_template);
    defer std.fs.deleteFileAbsolute(path_to_template) catch {};

    {
        var file = try std.fs.createFileAbsolute(path_to_template, .{ .truncate = true });
        defer file.close();
        var repeat: u32 = 0;

        // Writing the same template 10K times on a file
        while (repeat < 10_000) : (repeat += 1) {
            try file.writeAll(template_text);
        }
    }

    var out = std.io.getStdOut();

    // Rendering this large template with only 16KB of RAM
    try mustache.renderFile(allocator, path_to_template, ctx, out.writer());
}

/// Parses a template at comptime to render many times at runtime, no allocations needed
pub fn renderComptimePartialTemplate() anyerror!void {
    var out = std.io.getStdOut();

    // Comptime-parsed template
    const comptime_template = comptime mustache.parseComptime(
        \\{{=[ ]=}}
        \\📜 hello [>partial], your lucky number is [sub_value.value]
        \\--------------------------------------
        \\
    , .{}, .{});

    // Comptime tuple with a comptime partial template
    const comptime_partials = .{ "partial", comptime mustache.parseComptime("from {{name}}", .{}, .{}) };

    const Data = struct {
        name: []const u8,
        sub_value: struct {
            value: u32,
        },
    };

    // Runtime value
    var data: Data = .{ .name = "mustache", .sub_value = .{ .value = 42 } };

    var repeat: u32 = 0;
    while (repeat < 10) : (repeat += 1) {
        try mustache.renderPartials(comptime_template, comptime_partials, data, out.writer());
    }
}
