const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Thread = std.Thread;

const Color = struct {
    const reset = "\x1b[0m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const cyan = "\x1b[36m";
    const white = "\x1b[37m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
};

const SearchResult = struct {
    path: []const u8,
    score: i32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SearchResult) void {
        self.allocator.free(self.path);
    }
};

const SearchContext = struct {
    pattern: []const u8,
    results: std.ArrayList(SearchResult),
    mutex: Thread.Mutex,
    allocator: std.mem.Allocator,
    max_depth: usize,
    case_sensitive: bool,
};

/// Calculate fuzzy match score between pattern and text
/// Higher score means better match
fn fuzzyMatchScore(pattern: []const u8, text: []const u8, case_sensitive: bool) i32 {
    if (pattern.len == 0) return 0;
    if (text.len == 0) return -1000;

    var score: i32 = 0;
    var pattern_idx: usize = 0;
    var consecutive: i32 = 0;
    var last_match_idx: usize = 0;

    for (text, 0..) |text_char, text_idx| {
        if (pattern_idx >= pattern.len) break;

        const t_char = if (case_sensitive) text_char else std.ascii.toLower(text_char);
        const p_char = if (case_sensitive) pattern[pattern_idx] else std.ascii.toLower(pattern[pattern_idx]);

        if (t_char == p_char) {
            score += 10;
            
            // Bonus for consecutive matches
            if (text_idx == last_match_idx + 1) {
                consecutive += 1;
                score += consecutive * 5;
            } else {
                consecutive = 0;
            }

            // Bonus for matching at start
            if (pattern_idx == 0 and text_idx == 0) {
                score += 20;
            }

            // Bonus for matching after separator
            if (text_idx > 0 and (text[text_idx - 1] == '/' or text[text_idx - 1] == '_' or text[text_idx - 1] == '-' or text[text_idx - 1] == '.')) {
                score += 15;
            }

            last_match_idx = text_idx;
            pattern_idx += 1;
        }
    }

    // All pattern characters must be matched
    if (pattern_idx < pattern.len) {
        return -1000;
    }

    // Penalize based on length difference
    const len_diff: i32 = @intCast(text.len - pattern.len);
    score -= len_diff;

    return score;
}

/// Check if text contains pattern (simple substring match)
fn containsMatch(pattern: []const u8, text: []const u8, case_sensitive: bool) bool {
    if (pattern.len == 0) return true;
    if (text.len < pattern.len) return false;

    if (case_sensitive) {
        return mem.indexOf(u8, text, pattern) != null;
    } else {
        var i: usize = 0;
        while (i <= text.len - pattern.len) : (i += 1) {
            var match = true;
            for (pattern, 0..) |p_char, j| {
                if (std.ascii.toLower(text[i + j]) != std.ascii.toLower(p_char)) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }
}

/// Recursively scan directory and add matching files to results
fn scanDirectory(ctx: *SearchContext, dir_path: []const u8, depth: usize) void {
    if (depth > ctx.max_depth) return;

    var dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        // Skip hidden files unless pattern starts with '.'
        if (entry.name[0] == '.' and ctx.pattern[0] != '.') continue;

        const full_path = std.fmt.allocPrint(
            ctx.allocator,
            "{s}/{s}",
            .{ dir_path, entry.name },
        ) catch continue;
        defer ctx.allocator.free(full_path);

        switch (entry.kind) {
            .directory => {
                // Check if directory name matches
                const score = fuzzyMatchScore(ctx.pattern, entry.name, ctx.case_sensitive);
                if (score > 0 or containsMatch(ctx.pattern, entry.name, ctx.case_sensitive)) {
                    const path_copy = ctx.allocator.dupe(u8, full_path) catch continue;
                    
                    ctx.mutex.lock();
                    defer ctx.mutex.unlock();
                    
                    ctx.results.append(.{
                        .path = path_copy,
                        .score = score,
                        .allocator = ctx.allocator,
                    }) catch {
                        ctx.allocator.free(path_copy);
                    };
                }
                
                // Recurse into subdirectory
                scanDirectory(ctx, full_path, depth + 1);
            },
            .file => {
                // Check if file name matches
                const score = fuzzyMatchScore(ctx.pattern, entry.name, ctx.case_sensitive);
                if (score > 0 or containsMatch(ctx.pattern, entry.name, ctx.case_sensitive)) {
                    const path_copy = ctx.allocator.dupe(u8, full_path) catch continue;
                    
                    ctx.mutex.lock();
                    defer ctx.mutex.unlock();
                    
                    ctx.results.append(.{
                        .path = path_copy,
                        .score = score,
                        .allocator = ctx.allocator,
                    }) catch {
                        ctx.allocator.free(path_copy);
                    };
                }
            },
            else => {},
        }
    }
}

/// Get color for file based on its type
fn getFileColor(path: []const u8) []const u8 {
    if (fs.openFileAbsolute(path, .{})) |file| {
        defer file.close();
        const stat = file.stat() catch return Color.white;
        
        // Check if executable
        if (stat.mode & 0o111 != 0) {
            return Color.green;
        }
    } else |_| {}

    // Check if directory
    {
        var dir = fs.openDirAbsolute(path, .{}) catch return Color.white;
        dir.close();
        return Color.blue;
    }

    // Color by extension
    if (mem.lastIndexOfScalar(u8, path, '.')) |dot_idx| {
        const ext = path[dot_idx + 1 ..];
        if (mem.eql(u8, ext, "zip") or mem.eql(u8, ext, "tar") or mem.eql(u8, ext, "gz") or mem.eql(u8, ext, "bz2")) {
            return Color.red;
        }
        if (mem.eql(u8, ext, "jpg") or mem.eql(u8, ext, "png") or mem.eql(u8, ext, "gif") or mem.eql(u8, ext, "jpeg")) {
            return Color.magenta;
        }
        if (mem.eql(u8, ext, "mp3") or mem.eql(u8, ext, "wav") or mem.eql(u8, ext, "flac")) {
            return Color.cyan;
        }
    }

    return Color.white;
}

fn printUsage() void {
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll(
        \\zs - Supercharged file search tool
        \\
        \\Usage: zs [options] <pattern>
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\  -p, --path <path>    Start search from path (default: /)
        \\  -d, --depth <n>      Maximum depth to search (default: 10)
        \\  -c, --case           Case-sensitive search
        \\  -l, --limit <n>      Limit number of results (default: 100)
        \\  -n, --no-color       Disable colored output
        \\
        \\Examples:
        \\  zs main.zig          Find all files matching "main.zig"
        \\  zs -p /home main     Search only in /home
        \\  zs -d 5 config       Search with max depth of 5
        \\
    ) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    var pattern: ?[]const u8 = null;
    var start_path: []const u8 = "/";
    var max_depth: usize = 10;
    var case_sensitive = false;
    var max_results: usize = 100;
    var use_color = true;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--path")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --path requires an argument\n", .{});
                return;
            }
            start_path = args[i];
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --depth requires an argument\n", .{});
                return;
            }
            max_depth = try std.fmt.parseInt(usize, args[i], 10);
        } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--case")) {
            case_sensitive = true;
        } else if (mem.eql(u8, arg, "-l") or mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --limit requires an argument\n", .{});
                return;
            }
            max_results = try std.fmt.parseInt(usize, args[i], 10);
        } else if (mem.eql(u8, arg, "-n") or mem.eql(u8, arg, "--no-color")) {
            use_color = false;
        } else if (arg[0] != '-') {
            pattern = arg;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return;
        }
    }

    if (pattern == null) {
        std.debug.print("Error: No search pattern provided\n\n", .{});
        printUsage();
        return;
    }

    const stdout = std.io.getStdOut().writer();
    
    if (use_color) {
        try stdout.print("{s}{s}Searching for:{s} {s}\n", .{ Color.bold, Color.cyan, Color.reset, pattern.? });
        try stdout.print("{s}Starting from:{s} {s}\n", .{ Color.dim, Color.reset, start_path });
        try stdout.print("{s}Max depth:{s} {d}\n\n", .{ Color.dim, Color.reset, max_depth });
    } else {
        try stdout.print("Searching for: {s}\n", .{pattern.?});
        try stdout.print("Starting from: {s}\n", .{start_path});
        try stdout.print("Max depth: {d}\n\n", .{max_depth});
    }

    var ctx = SearchContext{
        .pattern = pattern.?,
        .results = std.ArrayList(SearchResult).init(allocator),
        .mutex = Thread.Mutex{},
        .allocator = allocator,
        .max_depth = max_depth,
        .case_sensitive = case_sensitive,
    };
    defer {
        for (ctx.results.items) |*result| {
            result.deinit();
        }
        ctx.results.deinit();
    }

    // Start scanning
    scanDirectory(&ctx, start_path, 0);

    // Sort results by score (descending)
    std.mem.sort(SearchResult, ctx.results.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score > b.score;
        }
    }.lessThan);

    // Display results
    const num_results = @min(ctx.results.items.len, max_results);
    
    if (num_results == 0) {
        try stdout.print("{s}No matches found.{s}\n", .{ Color.dim, Color.reset });
        return;
    }

    if (use_color) {
        try stdout.print("{s}{s}Found {d} matches:{s}\n\n", .{ Color.bold, Color.green, num_results, Color.reset });
    } else {
        try stdout.print("Found {d} matches:\n\n", .{num_results});
    }

    for (ctx.results.items[0..num_results]) |result| {
        if (use_color) {
            const color = getFileColor(result.path);
            try stdout.print("{s}{s}{s} {s}(score: {d}){s}\n", .{
                color,
                result.path,
                Color.reset,
                Color.dim,
                result.score,
                Color.reset,
            });
        } else {
            try stdout.print("{s} (score: {d})\n", .{ result.path, result.score });
        }
    }

    if (ctx.results.items.len > max_results) {
        const remaining = ctx.results.items.len - max_results;
        try stdout.print("\n{s}... and {d} more results. Use -l to see more.{s}\n", .{
            Color.dim,
            remaining,
            Color.reset,
        });
    }
}
