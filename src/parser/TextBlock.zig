const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const scanner = @import("scanner.zig");
const tokens = scanner.tokens;
const Event = scanner.Event;
const BlockType = scanner.BlockType;
const Mark = scanner.Mark;
const MarkType = scanner.MarkType;
const DelimiterType = scanner.DelimiterType;
const Delimiters = scanner.Delimiters;
const Trimming = scanner.Trimming;

const Self = @This();

event: Event,
tail: ?[]const u8,
row: u32,
col: u32,
right_trimming: Trimming = .PreserveWhitespaces,
left_trimming: Trimming = .PreserveWhitespaces,

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

pub fn trimRight(self: *Self) void {
    switch (self.right_trimming) {
        .PreserveWhitespaces, .Trimmed => {},
        .AllowTrimming => |right_trimming| {
            if (self.tail) |tail| {
                if (right_trimming.index == 0) {
                    self.tail = null;
                } else if (right_trimming.index < tail.len) {
                    self.tail = tail[0..right_trimming.index];
                }
            }

            self.right_trimming = .Trimmed;
        },
    }
}

pub fn trimLeft(self: *Self) void {
    switch (self.left_trimming) {
        .PreserveWhitespaces, .Trimmed => {},
        .AllowTrimming => |left_trimming| {
            if (self.tail) |tail| {
                switch (self.right_trimming) {
                    .AllowTrimming => |right_trimming| {

                        // Update the right index after trimming left
                        // BEFORE:
                        //                 2      7
                        //                 ↓      ↓
                        //const value = "  \nABC\n  "
                        //
                        // AFTER:
                        //                    4
                        //                    ↓
                        //const value = "ABC\n  "
                        self.right_trimming = .{
                            .AllowTrimming = .{
                                .index = right_trimming.index - left_trimming.index - 1,
                                .stand_alone = right_trimming.stand_alone,
                            },
                        };
                    },

                    else => {},
                }

                if (left_trimming.index >= tail.len - 1) {
                    self.tail = null;
                } else {
                    self.tail = tail[left_trimming.index + 1 ..];
                }
            }

            self.left_trimming = .Trimmed;
        },
    }
}
