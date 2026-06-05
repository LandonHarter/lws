const std = @import("std");

const adjectives = [_][]const u8{
    "bold",   "calm",    "clever",  "eager",   "fancy",  "gentle",
    "happy",  "jolly",   "keen",    "lively",  "merry",  "nimble",
    "proud",  "quiet",   "rapid",   "shiny",   "swift",  "tidy",
    "vivid",  "witty",   "brave",   "cosmic",  "dapper", "fuzzy",
    "golden", "hidden",  "icy",     "lucky",   "mellow", "noble",
};

const nouns = [_][]const u8{
    "otter",  "falcon",  "panda",   "lynx",    "heron",  "badger",
    "marlin", "raven",   "tiger",   "walrus",  "ferret", "gecko",
    "kestrel","mantis",  "narwhal", "ocelot",  "puffin", "quokka",
    "shrew",  "tapir",   "urchin",  "viper",   "wombat", "yak",
    "zebra",  "bison",   "cobra",   "dingo",   "egret",  "finch",
};

pub fn generate(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var source = std.Random.IoSource{ .io = io };
    const rand = source.interface();

    const adj = adjectives[rand.uintLessThan(usize, adjectives.len)];
    const noun = nouns[rand.uintLessThan(usize, nouns.len)];
    const suffix = rand.uintLessThan(u16, 10000);
    return std.fmt.allocPrint(allocator, "{s}_{s}_{d}", .{ adj, noun, suffix });
}
