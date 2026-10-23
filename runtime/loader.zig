// SPDX-License-Identifier: MIT
//
//! Generic process-wide loader for a translated C API.
//! It publishes only fully resolved and validated tables; failed candidates close, while successful handles remain loaded.
//! There is no unload or reset; routed calls require a successful load.

const std = @import("std");
const builtin = @import("builtin");

/// Select an absolute file path or a platform library name; requests never fall back between forms.
pub const LoadSource = union(enum) {
    /// Absolute path; relative paths return `InvalidSource`.
    path: []const u8,
    /// Basename or SONAME without separators or NUL; searched by the platform loader.
    system: []const u8,
};

/// Every way `load` can decline.
pub const LoadError = error{
    /// The request's path or name is empty.
    EmptySource,
    /// The request exceeds `max_source_len`; it is refused, never truncated.
    SourceTooLong,
    /// The path is not absolute, the name has a path component, or the request contains NUL.
    InvalidSource,
    /// This target has no dynamic library loader.
    UnsupportedTarget,
    /// The platform loader could not open the library or resolve its dependencies.
    OpenFailed,
    /// An opened library does not export a required symbol.
    MissingSymbol,
    /// The library-specific validation refused the resolved candidate.
    ValidationFailed,
    /// A different request is loading or has already succeeded.
    ProviderMismatch,
    /// The calling thread is already running this loader's attempt.
    ReentrantLoad,
};

/// The longest request the loader will remember, in bytes.
pub const max_source_len = 32768;

/// Fixed-size copy of the current request; no allocation or caller-buffer lifetime dependency.
const SourceRecord = struct {
    tag: enum(u8) { none = 0, path, system } = .none,
    len: u32 = 0,
    bytes: [max_source_len]u8 = undefined,

    /// Called under the loader lock after checking the request length.
    fn set(self: *SourceRecord, request: LoadSource) void {
        const text = switch (request) {
            .path => |p| p,
            .system => |s| s,
        };
        @memcpy(self.bytes[0..text.len], text);
        self.len = @intCast(text.len);
        self.tag = switch (request) {
            .path => .path,
            .system => .system,
        };
    }

    /// Return the remembered request, borrowing bytes from this process-lifetime record.
    pub fn source(self: *const SourceRecord) ?LoadSource {
        const text = self.bytes[0..self.len];
        return switch (self.tag) {
            .none => null,
            .path => .{ .path = text },
            .system => .{ .system = text },
        };
    }
};

/// Compare request kind and bytes without normalizing paths.
pub fn eqlSource(a: LoadSource, b: LoadSource) bool {
    return switch (a) {
        .path => |pa| switch (b) {
            .path => |pb| std.mem.eql(u8, pa, pb),
            .system => false,
        },
        .system => |sa| switch (b) {
            .system => |sb| std.mem.eql(u8, sa, sb),
            .path => false,
        },
    };
}

fn validateSource(source: LoadSource) LoadError!void {
    const text = switch (source) {
        .path => |p| p,
        .system => |s| s,
    };
    if (text.len == 0) return error.EmptySource;
    if (text.len > max_source_len) return error.SourceTooLong;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidSource;
    switch (source) {
        .path => {
            const absolute = if (builtin.os.tag == .windows)
                switch (std.fs.path.getWin32PathType(u8, text)) {
                    .drive_absolute, .unc_absolute, .local_device, .root_local_device => true,
                    .relative, .rooted, .drive_relative => false,
                }
            else
                std.fs.path.isAbsolutePosix(text);
            if (!absolute) return error.InvalidSource;
        },
        .system => {
            for (text) |byte| {
                if (std.fs.path.isSep(byte)) return error.InvalidSource;
                if (builtin.os.tag == .windows and byte == ':') return error.InvalidSource;
            }
        },
    }
}

/// The three states of a configured module's table.
pub const Phase = enum(u8) {
    /// No successful provider; failed loads can be retried.
    not_loaded = 0,
    /// One thread is filling the table. No reader can see it.
    loading = 1,
    /// The table is published and every routed call is usable.
    ready = 2,
};

/// Acquire/release readiness flag for publishing the dispatch table.
/// Readers that see `ready` also observe every table write.
pub const Ready = struct {
    phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.not_loaded)),

    /// True after successful publication.
    pub fn isReady(self: *const Ready) bool {
        return self.phase.load(.acquire) == @intFromEnum(Phase.ready);
    }

    /// The current state, for the loader's own decisions under its lock.
    pub fn state(self: *const Ready) Phase {
        return @enumFromInt(self.phase.load(.acquire));
    }

    /// Publish or withdraw the table, with release ordering.
    pub fn set(self: *Ready, value: Phase) void {
        self.phase.store(@intFromEnum(value), .release);
    }
};

/// Classify an exported symbol as a function or data object.
pub const SymbolKind = enum {
    /// Function address stored with the translated function-pointer type.
    function,
    /// Object address stored directly; the object is not copied.
    data,
};

/// One required export: the name to look up and what kind of thing it is.
pub const Symbol = struct {
    /// The exported name, exactly as the C header spells it.
    name: [:0]const u8,
    /// What the table field holds for this symbol.
    kind: SymbolKind,
};

/// Panic on a pre-load call, naming the library and symbol.
/// The panic remains enabled in ReleaseFast and ReleaseSmall.
pub fn panicNotReady(library: []const u8, comptime symbol: []const u8) noreturn {
    std.debug.panic(
        "{s}: {s} was called before this module was loaded; call " ++
            "load({{ .path = \"...\" }}) or load({{ .system = \"...\" }}) first",
        .{ library, symbol },
    );
}

/// Whether this target has a dynamic loader; false for WASI, Emscripten, and freestanding.
pub const supported_target: bool = switch (builtin.os.tag) {
    .wasi, .emscripten, .freestanding => false,
    else => true,
};

/// Process-global loader for one configured table; success retains its handle and request, while failures close candidates and allow explicit retry.
/// Config supplies symbol resolution, synchronization, and optional validation; concurrent calls for the same request share an attempt.
pub fn Loader(comptime Config: type) type {
    return struct {
        const LoaderType = @This();

        /// The table type this loader fills, for the configuration's own use.
        pub const table_type = Config.table;

        /// Current attempt, retained until its waiters drain.
        attempt: ?Attempt = null,

        /// Fixed copy of the request; immutable after publication.
        request: SourceRecord = .{},

        /// Resolve and publish a provider; errors leave no partial table.
        /// Concurrent same-request calls share an attempt; conflicts and reentrancy fail.
        pub fn load(self: *LoaderType, source: LoadSource) LoadError!void {
            try validateSource(source);
            if (Config.ready().isReady()) return self.accept(source);

            Config.sync.lock();
            while (true) {
                switch (Config.ready().state()) {
                    .ready => {
                        Config.sync.unlock();
                        return self.accept(source);
                    },
                    .loading => {
                        const attempt = &self.attempt.?;
                        if (attempt.owner == Config.sync.threadSelf()) {
                            Config.sync.unlock();
                            return error.ReentrantLoad;
                        }
                        if (!eqlSource(self.request.source().?, source)) {
                            Config.sync.unlock();
                            return error.ProviderMismatch;
                        }
                        // Join the in-flight attempt so every waiter receives its result.
                        attempt.waiters += 1;
                        while (Config.ready().state() == .loading) Config.sync.wait();
                        const result = attempt.result;
                        attempt.waiters -= 1;
                        Config.sync.broadcast();
                        // Keep the result until all waiters have read it.
                        Config.sync.unlock();
                        return result;
                    },
                    .not_loaded => {
                        // Wait for the prior attempt's waiters before allowing a retry.
                        if (self.attempt != null) {
                            Config.sync.wait();
                            continue;
                        }
                        break;
                    },
                }
            }

            self.request.set(source);
            self.attempt = .{ .owner = Config.sync.threadSelf() };
            Config.ready().set(.loading);
            Config.sync.unlock();

            // Open outside the lock so other callers can join this attempt.
            const outcome = runAttempt(self.request.source().?);
            const succeeded = if (outcome) |_| true else |_| false;

            Config.sync.lock();
            self.attempt.?.result = outcome;
            Config.ready().set(if (succeeded) .ready else .not_loaded);
            // Wake every waiter; all must receive this attempt's result.
            Config.sync.broadcast();
            // Retain the attempt record until the waiters drain.
            while (self.attempt.?.waiters > 0) Config.sync.wait();
            self.attempt = null;
            // Wake callers waiting to start a retry.
            Config.sync.broadcast();
            Config.sync.unlock();

            return outcome;
        }

        /// Return the successful request, borrowing process-lifetime bytes, or null before success.
        pub fn loadedSource(self: *const LoaderType) ?LoadSource {
            if (!Config.ready().isReady()) return null;
            return self.request.source();
        }

        /// The request already in use, checked against a new one.
        fn accept(self: *const LoaderType, source: LoadSource) LoadError!void {
            // Called only after an acquire read observes readiness.
            const published = self.request.source() orelse unreachable;
            if (eqlSource(published, source)) return;
            return error.ProviderMismatch;
        }

        /// Open, resolve, and validate without the lock; close every failed candidate.
        fn runAttempt(source: LoadSource) LoadError!void {
            const handle = platform.open(source) catch |err| return err;

            var retain = false;
            defer if (!retain) platform.close(handle);

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |_, index| {
                    Config.assignMissing(index, Config.tablePtr());
                }
            }

            inline for (Config.symbols, 0..) |symbol, index| {
                const address = platform.lookup(handle, symbol.name) orelse
                    return error.MissingSymbol;
                Config.assign(index, Config.tablePtr(), address);
            }

            if (@hasDecl(Config, "optional_symbols")) {
                inline for (Config.optional_symbols, 0..) |symbol, index| {
                    if (platform.lookup(handle, symbol.name)) |address| {
                        Config.assignOptional(index, Config.tablePtr(), address);
                    }
                }
            }

            if (@hasDecl(Config, "validate")) {
                if (Config.validate(Config.tablePtr())) |refusal| {
                    // Include the library-specific refusal in the diagnostic.
                    std.debug.print("{s}: refusing this provider: {s}\n", .{
                        Config.library_name,
                        refusal,
                    });
                    return error.ValidationFailed;
                }
            }

            // Keep the handle alive because the table stores its symbol addresses.
            retain = true;
        }
    };
}

/// One in-flight or undrained load attempt.
const Attempt = struct {
    /// Identity of the thread running the attempt, for the reentrancy check.
    owner: u64,
    /// Written under lock and read by waiters after loading ends.
    result: LoadError!void = error.OpenFailed,
    /// Number of callers still waiting to read this attempt's result.
    waiters: usize = 0,
};

/// UTF-16 buffer bound based on Windows' 32,767-code-unit path limit.
const windows_path_units = 32768;

const platform = if (builtin.os.tag == .windows)
    Windows
else if (supported_target)
    Unix
else
    NoLoader;

/// A target with no dynamic loader. Every request is refused by name.
const NoLoader = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        _ = source;
        return error.UnsupportedTarget;
    }
    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        _ = handle;
        _ = name;
        return null;
    }
    fn close(handle: *anyopaque) void {
        _ = handle;
    }
};

/// The Unix dynamic loader.
const Unix = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget };

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        var buffer: [max_source_len + 1]u8 = undefined;
        @memcpy(buffer[0..text.len], text);
        buffer[text.len] = 0;
        // Resolve dependencies immediately and keep symbols local to this handle.
        // This avoids delayed open failures and cross-provider lookup.
        return std.c.dlopen(
            // `dlopen` requires a sentinel-terminated name.
            buffer[0..text.len :0].ptr,
            .{ .NOW = true, .GLOBAL = false },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return std.c.dlsym(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = std.c.dlclose(handle);
    }
};

const kernel32 = struct {
    extern "kernel32" fn LoadLibraryExW(
        file_name: [*:0]const u16,
        file: ?*anyopaque,
        flags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) i32;
};

/// The Windows dynamic loader.
const Windows = struct {
    const OpenError = error{ OpenFailed, UnsupportedTarget, SourceTooLong };

    /// Search standard DLL locations; `.path` also searches its directory, `.system` excludes the current directory.
    const load_library_search_default_dirs: u32 = 0x0000_1000;
    const load_library_search_dll_load_dir: u32 = 0x0000_0100;

    fn open(source: LoadSource) OpenError!*anyopaque {
        const text = switch (source) {
            .path => |p| p,
            .system => |s| s,
        };
        if (text.len > windows_path_units) return error.SourceTooLong;
        var buffer: [windows_path_units + 1]u16 = undefined;
        const units = std.unicode.utf8ToUtf16Le(buffer[0..text.len], text) catch
            return error.OpenFailed;
        buffer[units] = 0;
        return kernel32.LoadLibraryExW(
            buffer[0..units :0],
            null,
            load_library_search_default_dirs | switch (source) {
                .path => load_library_search_dll_load_dir,
                .system => @as(u32, 0),
            },
        ) orelse error.OpenFailed;
    }

    fn lookup(handle: *anyopaque, name: [:0]const u8) ?*const anyopaque {
        return kernel32.GetProcAddress(handle, name.ptr);
    }

    fn close(handle: *anyopaque) void {
        _ = kernel32.FreeLibrary(handle);
    }
};
