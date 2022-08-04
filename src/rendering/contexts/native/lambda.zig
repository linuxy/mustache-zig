const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = meta.trait;

const assert = std.debug.assert;
const testing = std.testing;

const mustache = @import("../../../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const Delimiters = mustache.Delimiters;

const context = @import("../../context.zig");
const Escape = context.Escape;
const LambdaContext = context.LambdaContext;

const rendering = @import("../../rendering.zig");

pub fn LambdaContextImpl(comptime Writer: type, comptime PartialsMap: type, comptime options: RenderOptions) type {
    const RenderEngine = rendering.RenderEngine(.native, Writer, PartialsMap, options);
    const DataRender = RenderEngine.DataRender;

    return struct {
        const Self = @This();

        data_render: *DataRender,
        escape: Escape,
        delimiters: Delimiters,

        const vtable = LambdaContext.VTable{
            .renderAlloc = renderAlloc,
            .render = render,
            .write = write,
        };

        pub fn context(self: *Self, inner_text: []const u8) LambdaContext {
            return .{
                .ptr = self,
                .vtable = &vtable,
                .inner_text = inner_text,
            };
        }

        fn renderAlloc(ctx: *const anyopaque, allocator: Allocator, template_text: []const u8) anyerror![]u8 {
            var self = getSelf(ctx);

            var template = switch (try mustache.parseText(allocator, template_text, self.delimiters, .{ .copy_strings = false })) {
                .success => |value| value,
                .parse_error => |detail| return detail.parse_error,
            };
            defer template.deinit(allocator);

            var out_writer = self.data_render.out_writer;
            var list = std.ArrayList(u8).init(allocator);
            self.data_render.out_writer = .{ .buffer = list.writer() };

            defer {
                self.data_render.out_writer = out_writer;
                list.deinit();
            }

            try self.data_render.render(template.elements);
            return list.toOwnedSlice();
        }

        fn render(ctx: *const anyopaque, allocator: Allocator, template_text: []const u8) anyerror!void {
            var self = getSelf(ctx);

            var template = switch (try mustache.parseText(allocator, template_text, self.delimiters, .{ .copy_strings = false })) {
                .success => |value| value,
                .parse_error => return,
            };
            defer template.deinit(allocator);

            try self.data_render.render(template.elements);
        }

        fn write(ctx: *const anyopaque, rendered_text: []const u8) anyerror!usize {
            var self = getSelf(ctx);
            return try self.data_render.countWrite(rendered_text, self.escape);
        }

        inline fn getSelf(ctx: *const anyopaque) *const Self {
            return @ptrCast(*const Self, @alignCast(@alignOf(Self), ctx));
        }
    };
}

/// Returns true if TValue is a type generated by LambdaInvoker(...)
pub fn isLambdaInvoker(comptime TValue: type) bool {
    if (comptime trait.isSingleItemPtr(TValue)) {
        return isLambdaInvoker(meta.Child(TValue));
    } else {
        return @typeInfo(TValue) == .Struct and
            @hasField(TValue, "data") and
            @hasField(TValue, "bound_fn") and
            blk: {
            const TFn = meta.fieldInfo(TValue, .bound_fn).field_type;
            const TData = meta.fieldInfo(TValue, .data).field_type;

            break :blk comptime isValidLambdaFunction(TData, TFn) and
                TValue == LambdaInvoker(TData, TFn);
        };
    }
}

test "isLambdaInvoker" {
    const foo = struct {
        pub fn _foo(ctx: LambdaContext) void {
            _ = ctx;
        }
    }._foo;

    const TFn = @TypeOf(foo);
    const Impl = LambdaInvoker(void, TFn);
    const IsntImpl = struct { field: usize };

    try testing.expect(isLambdaInvoker(Impl));
    try testing.expect(isLambdaInvoker(IsntImpl) == false);
    try testing.expect(isLambdaInvoker(TFn) == false);
    try testing.expect(isLambdaInvoker(u32) == false);
}

/// Returns true if TFn is a function of one of the signatures:
/// fn (LambdaContext) anyerror!void
/// fn (TData, LambdaContext) anyerror!void
/// fn (*const TData, LambdaContext) anyerror!void
/// fn (*TData, LambdaContext) anyerror!void
pub fn isValidLambdaFunction(comptime TData: type, comptime TFn: type) bool {
    const fn_info = switch (@typeInfo(TFn)) {
        .Fn => |info| info,
        else => return false,
    };

    //TODO: deprecated
    const Type = std.builtin.TypeInfo;

    const argIs = struct {
        fn action(comptime arg: Type.FnArg, comptime types: []const type) bool {
            inline for (types) |compare_to| {
                if (arg.arg_type) |arg_type| {
                    if (arg_type == compare_to) return true;
                }
            } else {
                return false;
            }
        }
    }.action;

    const TValue = if (comptime meta.trait.isSingleItemPtr(TData)) meta.Child(TData) else TData;

    const valid_args = comptime switch (fn_info.args.len) {
        1 => argIs(fn_info.args[0], &.{LambdaContext}),
        2 => argIs(fn_info.args[0], &.{ TValue, *const TValue, *TValue }) and argIs(fn_info.args[1], &.{LambdaContext}),
        else => false,
    };

    const valid_return = comptime if (fn_info.return_type) |return_type| switch (@typeInfo(return_type)) {
        .ErrorUnion => |err_info| err_info.payload == void,
        .Void => true,
        else => false,
    } else false;

    return valid_args and valid_return;
}

test "isValidLambdaFunction" {
    const signatures = struct {
        const Self = struct {};

        const WrongSelf = struct {};

        const static_valid_1 = fn (LambdaContext) anyerror!void;
        const static_valid_2 = fn (LambdaContext) void;

        const self_valid_1 = fn (Self, LambdaContext) anyerror!void;
        const self_valid_2 = fn (*const Self, LambdaContext) anyerror!void;
        const self_valid_3 = fn (*Self, LambdaContext) anyerror!void;
        const self_valid_4 = fn (Self, LambdaContext) void;
        const self_valid_5 = fn (*const Self, LambdaContext) void;
        const self_valid_6 = fn (*Self, LambdaContext) void;

        const invalid_return_1 = fn (LambdaContext) anyerror!u32;
        const invalid_return_2 = fn (Self, LambdaContext) anyerror![]const u8;
        const invalid_return_3 = fn (*const Self, LambdaContext) anyerror!?usize;
        const invalid_return_4 = fn (*Self, LambdaContext) []u8;

        const invalid_args_1 = fn () anyerror!void;
        const invalid_args_2 = fn (Self) anyerror!void;
        const invalid_args_3 = fn (*const Self) anyerror!void;
        const invalid_args_4 = fn (*Self) anyerror!void;
        const invalid_args_5 = fn (u32) anyerror!void;
        const invalid_args_6 = fn (LambdaContext, Self) anyerror!void;
        const invalid_args_7 = fn (LambdaContext, u32) anyerror!void;
        const invalid_args_8 = fn (Self, LambdaContext, u32) anyerror!void;
    };

    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.static_valid_1));
    try testing.expect(isValidLambdaFunction(void, signatures.static_valid_1));
    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.static_valid_1));
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.static_valid_2));
    try testing.expect(isValidLambdaFunction(void, signatures.static_valid_2));
    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.static_valid_2));

    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.self_valid_1));
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.self_valid_2));
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.self_valid_3));
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.self_valid_4));
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.self_valid_5));
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.self_valid_6));

    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.self_valid_1) == false);
    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.self_valid_2) == false);
    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.self_valid_3) == false);
    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.self_valid_4) == false);
    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.self_valid_5) == false);
    try testing.expect(isValidLambdaFunction(signatures.WrongSelf, signatures.self_valid_6) == false);

    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_return_1) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_return_2) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_return_3) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_return_4) == false);

    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_1) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_2) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_3) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_4) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_5) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_6) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_7) == false);
    try testing.expect(isValidLambdaFunction(signatures.Self, signatures.invalid_args_8) == false);
}

pub fn LambdaInvoker(comptime TData: type, comptime TFn: type) type {
    return struct {
        const Self = @This();

        bound_fn: TFn,
        data: TData,

        pub fn invoke(self: *const Self, lambda_context: LambdaContext) anyerror!void {
            comptime {
                if (!isValidLambdaFunction(TData, TFn)) {
                    @compileLog("isValidLambdaFunction", TData, TFn);
                }
            }

            const fn_type = @typeInfo(TFn).Fn;

            if (TData == void) {
                try self.call(.{lambda_context});
            } else {

                // Determining the correct type to call the first argument
                // depending on how is was declared on the lambda signature
                //
                // fn(self TValue ...)
                // fn(self *const TValue ...)
                // fn(self *TValue ...)
                const fnArg = fn_type.args[0].arg_type orelse @compileError("Generic argument could not be evaluated");

                switch (@typeInfo(TData)) {
                    .Pointer => |info| {
                        switch (info.size) {
                            .One => {
                                if (info.child == fnArg) {

                                    // Context is a pointer, but the parameter is a value
                                    // fn (self TValue ...) called from a *TValue or *const TValue
                                    try self.call(.{ self.data.*, lambda_context });
                                } else {
                                    switch (@typeInfo(fnArg)) {
                                        .Pointer => |arg_info| {
                                            if (info.child == arg_info.child) {
                                                if (arg_info.is_const == true or info.is_const == false) {

                                                    // Both context and parameter are pointers
                                                    // fn (self *TValue ...) called from a *TValue
                                                    // or
                                                    // fn (self const* TValue ...) called from a *const TValue or *TValue
                                                    try self.call(.{ self.data, lambda_context });
                                                }
                                            }
                                        },
                                        else => {},
                                    }
                                }
                            },
                            else => {},
                        }
                    },
                    else => {
                        switch (@typeInfo(fnArg)) {
                            .Pointer => |arg_info| {
                                if (TData == arg_info.child and arg_info.is_const == true) {

                                    // fn (self const* TValue ...)
                                    try self.call(.{ &self.data, lambda_context });
                                }
                            },
                            else => {
                                if (TData == fnArg) {

                                    // Both context and parameter are the same type:''
                                    // fn (self TValue ...) called from a TValue
                                    // or
                                    // fn (self *TValue ...) called from a *TValue
                                    // or
                                    // fn (self const* TValue ...) called from a *const TValue
                                    try self.call(.{ self.data, lambda_context });
                                }
                            },
                        }
                    },
                }

                // Cannot call the function if the lambda expects a mutable reference
                // and the context is a value or a const pointer

                return;
            }
        }

        inline fn call(self: Self, args: anytype) anyerror!void {
            const fn_type = @typeInfo(TFn).Fn;
            const return_type = fn_type.return_type orelse @compileError("Generic function could not be evaluated");
            const has_error = @typeInfo(return_type) == .ErrorUnion;

            if (has_error)
                try @call(.{}, self.bound_fn, args)
            else
                @call(.{}, self.bound_fn, args);
        }
    };
}

test "LambdaInvoker" {

    // LambdaInvoker is comptime validated
    // Only valid sinatures can be used
    // Invalid signatures are tested on "isValidLambdaFunction"

    const Foo = struct {
        var static_counter: u32 = 0;
        counter: u32 = 0,

        pub fn staticFn(ctx: LambdaContext) void {
            _ = ctx;
            static_counter += 1;
        }

        pub fn selfFnValue(self: @This(), ctx: LambdaContext) void {
            _ = self;
            _ = ctx;
            static_counter += 1;
        }

        pub fn selfFnConstPtr(self: *const @This(), ctx: LambdaContext) void {
            _ = self;
            _ = ctx;
            static_counter += 1;
        }

        pub fn selfFnPtr(self: *@This(), ctx: LambdaContext) void {
            _ = ctx;
            static_counter += 1;
            self.counter += 1;
        }
    };

    {
        const Impl = LambdaInvoker(void, @TypeOf(Foo.staticFn));
        var impl = Impl{ .bound_fn = Foo.staticFn, .data = {} };

        const last_counter = Foo.static_counter;
        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 1);

        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 2);
    }

    {
        const Impl = LambdaInvoker(Foo, @TypeOf(Foo.selfFnValue));
        var foo = Foo{};
        var impl = Impl{
            .bound_fn = Foo.selfFnValue,
            .data = foo,
        };

        const last_counter = Foo.static_counter;
        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 1);
        try testing.expect(foo.counter == 0);

        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 2);
        try testing.expect(foo.counter == 0);
    }

    {
        const Impl = LambdaInvoker(*Foo, @TypeOf(Foo.selfFnConstPtr));
        var foo = Foo{};
        var impl = Impl{
            .bound_fn = Foo.selfFnConstPtr,
            .data = &foo,
        };

        const last_counter = Foo.static_counter;
        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 1);
        try testing.expect(foo.counter == 0);

        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 2);
        try testing.expect(foo.counter == 0);
    }

    {
        const Impl = LambdaInvoker(*Foo, @TypeOf(Foo.selfFnPtr));
        var foo = Foo{};
        var impl = Impl{
            .bound_fn = Foo.selfFnPtr,
            .data = &foo,
        };

        const last_counter = Foo.static_counter;
        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 1);
        try testing.expect(foo.counter == 1);

        try impl.invoke(undefined);
        try testing.expect(Foo.static_counter == last_counter + 2);
        try testing.expect(foo.counter == 2);
    }
}

test "Zero-sized LambdaInvoker" {

    // Zero-sized structs have no address, but they can appear in expressions like *T or &value
    // This test asserts that structs of @sizeOf(T) == 0 can have any lambda function signature that a regular sized struct does.

    const ZeroSize = struct {
        var static_counter: u32 = 0;

        pub fn staticFn(ctx: LambdaContext) void {
            _ = ctx;
            static_counter += 1;
        }

        pub fn selfFnValue(self: @This(), ctx: LambdaContext) void {
            _ = self;
            _ = ctx;
            static_counter += 1;
        }

        pub fn selfFnConstPtr(self: *const @This(), ctx: LambdaContext) void {
            _ = self;
            _ = ctx;
            static_counter += 1;
        }

        pub fn selfFnPtr(self: *@This(), ctx: LambdaContext) void {
            _ = self;
            _ = ctx;
            static_counter += 1;
        }
    };

    comptime assert(@sizeOf(ZeroSize) == 0);

    {
        const Impl = LambdaInvoker(void, @TypeOf(ZeroSize.staticFn));
        var impl = Impl{ .bound_fn = ZeroSize.staticFn, .data = {} };

        const last_counter = ZeroSize.static_counter;
        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 1);

        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 2);
    }

    {
        const Impl = LambdaInvoker(ZeroSize, @TypeOf(ZeroSize.selfFnValue));
        var dummy = ZeroSize{};
        var impl = Impl{
            .bound_fn = ZeroSize.selfFnValue,
            .data = dummy,
        };

        const last_counter = ZeroSize.static_counter;
        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 1);

        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 2);
    }

    {
        const Impl = LambdaInvoker(*ZeroSize, @TypeOf(ZeroSize.selfFnConstPtr));
        var dummy = ZeroSize{};
        var impl = Impl{
            .bound_fn = ZeroSize.selfFnConstPtr,
            .data = &dummy,
        };

        const last_counter = ZeroSize.static_counter;
        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 1);

        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 2);
    }

    {
        const Impl = LambdaInvoker(*ZeroSize, @TypeOf(ZeroSize.selfFnPtr));
        var dummy = ZeroSize{};
        var impl = Impl{
            .bound_fn = ZeroSize.selfFnPtr,
            .data = &dummy,
        };

        const last_counter = ZeroSize.static_counter;
        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 1);

        try impl.invoke(undefined);
        try testing.expect(ZeroSize.static_counter == last_counter + 2);
    }
}
