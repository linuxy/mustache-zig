const std = @import("std");
const assert = std.debug.assert;

const scanner = @import("scanner.zig");
const tokens = scanner.tokens;
const Event = scanner.Event;
const BlockType = scanner.BlockType;
const Mark = scanner.Mark;
const MarkType = scanner.MarkType;
const DelimiterType = scanner.DelimiterType;
const Delimiters = scanner.Delimiters;

const Self = @This();

event: Event,
tail: ?[]const u8,
row: usize,
col: usize,

pub fn readBlockType(self: *Self) ?BlockType {
    if (self.tail) |tail| {
        const match: ?BlockType = switch (tail[0]) {
            tokens.Comments => .Comment,
            tokens.Section => .Section,
            tokens.InvertedSection => .InvertedSection,
            tokens.Partial => .Partial,
            tokens.Parent => .Parent,
            tokens.Block => .Block,
            tokens.Delimiters => .Delimiters,
            tokens.NoEscape => .NoScapeInterpolation,
            tokens.CloseSection => .CloseSection,
            else => null,
        };

        if (match) |block_type| {
            self.tail = tail[1..];
            return block_type;
        }
    }

    return null;
}

pub fn trimStandAlone(self: *Self, trim: enum { Left, Right }) bool {
    if (self.tail) |tail| {
        if (tail.len > 0) {
            switch (trim) {
                .Left => {
                    var index: usize = 0;
                    while (index < tail.len) : (index += 1) {
                        switch (tail[index]) {
                            ' ', '\t', '\r' => {},
                            '\n' => {
                                self.tail = if (index == tail.len - 1) null else tail[index + 1 ..];
                                return true;
                            },
                            else => return false,
                        }
                    }
                },

                .Right => {
                    var index: usize = 0;
                    while (index < tail.len) : (index += 1) {
                        var end = tail.len - index - 1;
                        switch (tail[end]) {
                            ' ', '\t', '\r' => {},
                            '\n' => {
                                self.tail = if (end == tail.len) null else tail[0 .. end + 1];
                                return true;
                            },
                            else => return false,
                        }
                    }
                },
            }
        }

        // Empty or white space is represented as "null"
        self.tail = null;
    }

    return true;
}