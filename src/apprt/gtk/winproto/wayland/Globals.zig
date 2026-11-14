const Globals = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const org = wayland.client.org;
const vicinae = wayland.client.vicinae;
const xdg = wayland.client.xdg;

const log = std.log.scoped(.winproto_wayland_globals);

alloc: Allocator,
state: State,
map: std.EnumMap(Tag, Binding),

/// Used in the initial roundtrip to determine whether more
/// roundtrips are required to fetch the initial state.
needs_roundtrip: bool = false,

const Binding = struct {
    // All globals can be casted into a wl.Proxy object.
    proxy: *wl.Proxy,
    name: u32,
};

pub const Tag = enum {
    compositor,
    ext_background_effect,
    kde_decoration_manager,
    vicinae_hotkey_manager,
    xdg_activation,

    fn Type(comptime self: Tag) type {
        return switch (self) {
            .compositor => wl.Compositor,
            .ext_background_effect => ext.BackgroundEffectManagerV1,
            .kde_decoration_manager => org.KdeKwinServerDecorationManager,
            .vicinae_hotkey_manager => vicinae.HotkeyManagerV1,
            .xdg_activation => xdg.ActivationV1,
        };
    }
};

pub const State = struct {
    default_deco_mode: ?org.KdeKwinServerDecorationManager.Mode = null,

    bg_effect_capabilities: ext.BackgroundEffectManagerV1.Capability = .{},
};

pub fn init(alloc: Allocator, display: *wl.Display) !*Globals {
    // We need to allocate here since the listener
    // expects a stable memory address.
    const self = try alloc.create(Globals);
    self.* = .{
        .alloc = alloc,
        .state = .{},
        .map = .{},
    };

    const registry = try display.getRegistry();
    registry.setListener(*Globals, registryListener, self);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Do another roundtrip to process events emitted by globals we bound
    // during registry discovery. Listeners are
    // installed at bind time in registryListener.
    if (self.needs_roundtrip) {
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }
    return self;
}

pub fn deinit(self: *Globals) void {
    self.alloc.destroy(self);
}

pub fn get(self: *const Globals, comptime tag: Tag) ?*tag.Type() {
    const binding = self.map.get(tag) orelse return null;
    return @ptrCast(binding.proxy);
}

fn onGlobalAttached(self: *Globals, comptime tag: Tag) void {
    // Install listeners immediately at bind time. This
    // keeps listener setup and object lifetime in one
    // place and also supports globals that appear later.
    switch (tag) {
        .ext_background_effect => {
            const v = self.get(tag) orelse return;
            v.setListener(*Globals, bgEffectListener, self);
            self.needs_roundtrip = true;
        },
        .kde_decoration_manager => {
            const v = self.get(tag) orelse return;
            v.setListener(*Globals, decoManagerListener, self);
            self.needs_roundtrip = true;
        },
        else => {},
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    self: *Globals,
) void {
    switch (event) {
        .global => |v| {
            log.debug("found global {s}", .{v.interface});
            inline for (comptime std.meta.tags(Tag)) |tag| {
                const T = tag.Type();
                if (std.mem.orderZ(u8, v.interface, T.interface.name) == .eq) {
                    log.debug("matched {}", .{T});

                    const new_proxy = registry.bind(
                        v.name,
                        T,
                        T.generated_version,
                    ) catch |err| {
                        log.warn(
                            "error binding interface {s} error={}",
                            .{ v.interface, err },
                        );
                        return;
                    };

                    // If this global was already bound,
                    // then we also need to destroy the old binding.
                    if (self.map.get(tag)) |old| {
                        old.proxy.destroy();
                    }

                    self.map.put(tag, .{
                        .proxy = @ptrCast(new_proxy),
                        .name = v.name,
                    });
                    self.onGlobalAttached(tag);
                }
            }
        },

        // This should be a rare occurrence, but in case a global
        // is suddenly no longer available, we destroy and unset it
        // as the protocol mandates.
        .global_remove => |v| {
            var it = self.map.iterator();
            while (it.next()) |kv| {
                if (kv.value.name != v.name) continue;
                kv.value.proxy.destroy();
                self.map.remove(kv.key);
            }
        },
    }
}

fn bgEffectListener(
    _: *ext.BackgroundEffectManagerV1,
    event: ext.BackgroundEffectManagerV1.Event,
    self: *Globals,
) void {
    switch (event) {
        .capabilities => |cap| {
            self.state.bg_effect_capabilities = cap.flags;
        },
    }
}

fn decoManagerListener(
    _: *org.KdeKwinServerDecorationManager,
    event: org.KdeKwinServerDecorationManager.Event,
    self: *Globals,
) void {
    switch (event) {
        .default_mode => |mode| {
            self.state.default_deco_mode = @fromBackingInt(@intCast(mode.mode));
        },
    }
}
