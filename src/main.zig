const r4os = @import("r4os");
const r4std = @import("r4std");
const AppApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    net: r4os.r4net.Context,
    dev: r4os.r4dev.Context,

    fn init(r4_app: *r4os.App) ?AppApi {
        return .{
            .sys = r4_app.system(),
            .desk = r4_app.desktop() orelse return null,
            .draw = r4_app.drawing() orelse return null,
            .net = r4_app.networkLowLevel() orelse return null,
            .dev = r4_app.devicesLowLevel() orelse return null,
        };
    }
};

const app_bg = r4os.gui.default_palette.face;
const face_bg: u32 = 0xFFFFFF;
const text = r4os.gui.default_palette.text;
const shadow = r4os.gui.default_palette.face_shadow;
const hand = 0x000000;
const second_hand = 0xA00000;

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), "/SELFTEST")) return runSelfTest(&ctx.sys);
    var app = App{ .ctx = &ctx };
    return app.run();
}

const App = struct {
    ctx: *AppApi,
    w: i32 = 260,
    h: i32 = 230,
    should_exit: bool = false,
    config: r4std.time.Config = .{},
    last_second: u32 = r4std.time.seconds_per_day,
    last_clock_format: u32 = r4os.abi.clock_format_24h,
    last_config_check: u32 = 0,

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() >= 0) return self.runHosted();
        self.ctx.sys.println("CLOCK is a desktop GUI application.");
        self.ctx.sys.println("Please start from Desktop or through GUI launch.");
        return 0;
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Clock");
        _ = self.ctx.desk.guiSetMinSize(240, 220);
        self.loadConfig();
        self.updateMetrics();
        self.render();

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            var event: r4os.abi.GuiEvent = .{};
            while (self.ctx.desk.guiPollEvent(&event) > 0) {
                const kind: r4os.abi.GuiEventKind = @enumFromInt(event.kind);
                switch (kind) {
                    .close => return 0,
                    .resize => {
                        self.updateMetrics();
                        self.render();
                    },
                    .key_down => {
                        if (@as(u8, @intCast(event.key & 0xFF)) == r4os.gui.Key.escape) self.should_exit = true;
                    },
                    else => {},
                }
            }
            if (self.needsTickRender()) self.render();
            self.ctx.sys.sleepTicks(5);
        }
        return 0;
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = clampI32(canvas.w, 240, 640);
        self.h = clampI32(canvas.h, 220, 520);
    }

    fn needsTickRender(self: *App) bool {
        const state = self.ctx.sys.timeState();
        const raw = state.seconds_since_midnight;
        var service_status: r4os.abi.TimeServiceStatus = .{};
        if (self.ctx.sys.timeServiceStatus(&service_status) == r4os.abi.service_api_result_ok) {
            const zoned = service_status.local_seconds_since_midnight;
            const clock_format = @as(u32, service_status.clock_format);
            if (zoned == self.last_second and clock_format == self.last_clock_format) return false;
            self.last_second = zoned;
            self.last_clock_format = clock_format;
            return true;
        }
        if (raw % 3 == 0 and raw != self.last_config_check) {
            self.last_config_check = raw;
            self.loadConfig();
        }
        const zoned = r4std.time.secondsInZone(raw, self.config.offsetMinutesForState(state));
        if (zoned == self.last_second) return false;
        self.last_second = zoned;
        return true;
    }

    fn render(self: *App) void {
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [96]u8 = .{0} ** 96;
        const state = self.ctx.sys.timeState();
        var service_status: r4os.abi.TimeServiceStatus = .{};
        const service_ok = self.ctx.sys.timeServiceStatus(&service_status) == r4os.abi.service_api_result_ok;
        const seconds = if (service_ok)
            service_status.local_seconds_since_midnight
        else
            r4std.time.secondsInZone(state.seconds_since_midnight, self.config.offsetMinutesForState(state));
        const time = r4std.time.splitTime(seconds);
        self.last_second = seconds;
        const clock_format = if (service_ok) @as(u32, service_status.clock_format) else self.config.selectedClockFormat();
        self.last_clock_format = clock_format;
        var zone_label_buffer: [r4std.time.zone_label_max + 1]u8 = .{0} ** (r4std.time.zone_label_max + 1);
        const zone_label = if (service_ok)
            spanZ(service_status.zone_label[0..])
        else
            r4std.time.copyZoneLabelForState(zone_label_buffer[0..], self.config.selectedIndex(), state);

        _ = canvas.clear(app_bg);
        _ = canvas.groupBox(.{ .rect = .{ .x = 12, .y = 10, .w = self.w - 24, .h = self.h - 62 }, .title = "Clock" }, scratch[0..]);
        self.drawAnalog(canvas, time);

        var hms: [12]u8 = .{0} ** 12;
        _ = r4std.time.formatDisplay(hms[0..], time, clock_format);
        _ = canvas.label(.{ .rect = .{ .x = 16, .y = self.h - 44, .w = self.w - 32, .h = 16 }, .text = spanZ(hms[0..]), .alignment = .center, .fg = text, .bg = app_bg }, scratch[0..]);
        _ = canvas.textClipped(16, self.h - 24, self.w - 32, scratch[0..], zone_label, text, app_bg);
        _ = paint.present();
    }

    fn drawAnalog(self: *App, canvas: r4os.gui.Canvas, time: r4std.time.ClockTime) void {
        const cx = @divTrunc(self.w, 2);
        const available_h = @max(90, self.h - 92);
        const cy = 30 + @divTrunc(available_h, 2);
        const radius = clampI32(@divTrunc(@min(self.w - 72, available_h - 12), 2), 42, 92);

        _ = canvas.rect(.{ .x = cx - radius - 3, .y = cy - radius - 3, .w = radius * 2 + 6, .h = radius * 2 + 6 }, shadow);
        _ = canvas.rect(.{ .x = cx - radius - 2, .y = cy - radius - 2, .w = radius * 2 + 4, .h = radius * 2 + 4 }, face_bg);
        _ = canvas.rect(.{ .x = cx - radius - 2, .y = cy - radius - 2, .w = radius * 2 + 4, .h = 1 }, text);
        _ = canvas.rect(.{ .x = cx - radius - 2, .y = cy - radius - 2, .w = 1, .h = radius * 2 + 4 }, text);
        _ = canvas.rect(.{ .x = cx - radius - 2, .y = cy + radius + 1, .w = radius * 2 + 4, .h = 1 }, text);
        _ = canvas.rect(.{ .x = cx + radius + 1, .y = cy - radius - 2, .w = 1, .h = radius * 2 + 4 }, text);

        var i: usize = 0;
        while (i < 12) : (i += 1) {
            const p = pointForHour(i, radius - 8);
            const size: i32 = if ((i % 3) == 0) 4 else 2;
            _ = canvas.rect(.{ .x = cx + p.x - @divTrunc(size, 2), .y = cy + p.y - @divTrunc(size, 2), .w = size, .h = size }, text);
        }

        _ = canvas.text(cx - 4, cy - radius + 8, "12", text, face_bg);
        _ = canvas.text(cx + radius - 18, cy - 4, "3", text, face_bg);
        _ = canvas.text(cx - 4, cy + radius - 18, "6", text, face_bg);
        _ = canvas.text(cx - radius + 10, cy - 4, "9", text, face_bg);

        const minute_seg: usize = @intCast(time.minutes);
        const second_seg: usize = @intCast(time.seconds);
        const hour_seg: usize = @as(usize, @intCast(time.hours % 12)) * 5 + @as(usize, @intCast(time.minutes / 12));

        const hour_p = pointForMinute(hour_seg, radius - 30);
        const minute_p = pointForMinute(minute_seg, radius - 16);
        const second_p = pointForMinute(second_seg, radius - 12);
        drawLine(canvas, cx, cy, cx + hour_p.x, cy + hour_p.y, hand, 2);
        drawLine(canvas, cx, cy, cx + minute_p.x, cy + minute_p.y, hand, 1);
        drawLine(canvas, cx, cy, cx + second_p.x, cy + second_p.y, second_hand, 1);
        _ = canvas.rect(.{ .x = cx - 2, .y = cy - 2, .w = 5, .h = 5 }, text);
    }

    fn loadConfig(self: *App) void {
        var buffer: [768]u8 = undefined;
        const len = self.ctx.sys.fileRead(r4std.settings.paths.time, buffer[0..]);
        if (len > 0) _ = self.config.loadFromBytes(buffer[0..@intCast(len)]);
    }
};

fn runSelfTest(ctx: *const r4os.r4sys.Context) i32 {
    ctx.println("CLOCK selftest");
    var status: r4os.abi.TimeServiceStatus = .{};
    if (ctx.timeServiceStatus(&status) != r4os.abi.service_api_result_ok) return fail(ctx, "timesvc");
    if (status.zone_count != @as(u32, @intCast(r4std.time.zoneCount()))) return fail(ctx, "zone-count");
    const time = r4std.time.splitTime(status.local_seconds_since_midnight);
    var hms: [12]u8 = .{0} ** 12;
    const text_value = r4std.time.formatDisplay(hms[0..], time, @as(u32, status.clock_format));
    if (text_value.len < 8) return fail(ctx, "format");
    if (status.local_year < 1980 or status.local_month == 0 or status.local_day == 0) return fail(ctx, "local-date");
    if (spanZ(status.zone_label[0..]).len == 0) return fail(ctx, "zone-label");
    if (samePoint(pointForMinute(0, 60), pointForMinute(1, 60))) return fail(ctx, "second-step");
    if (samePoint(pointForMinute(5, 60), pointForMinute(6, 60))) return fail(ctx, "minute-step");
    ctx.write("CLOCK display ");
    ctx.write(text_value);
    ctx.write(" ");
    ctx.println(spanZ(status.zone_label[0..]));
    ctx.println("CLOCK selftest: OK");
    return 0;
}

const Point = struct {
    x: i32,
    y: i32,
};

fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn pointForHour(index: usize, radius: i32) Point {
    const xs = [_]i32{ 0, 50, 87, 100, 87, 50, 0, -50, -87, -100, -87, -50 };
    const ys = [_]i32{ -100, -87, -50, 0, 50, 87, 100, 87, 50, 0, -50, -87 };
    const i = index % 12;
    return .{
        .x = @divTrunc(xs[i] * radius, 100),
        .y = @divTrunc(ys[i] * radius, 100),
    };
}

fn pointForMinute(index: usize, radius: i32) Point {
    const xs = [_]i32{
        0,    10,  21,  31,  41,  50,  59,  67,  74,  81,  87,  91,  95,  98,  99,
        100,  99,  98,  95,  91,  87,  81,  74,  67,  59,  50,  41,  31,  21,  10,
        0,    -10, -21, -31, -41, -50, -59, -67, -74, -81, -87, -91, -95, -98, -99,
        -100, -99, -98, -95, -91, -87, -81, -74, -67, -59, -50, -41, -31, -21, -10,
    };
    const ys = [_]i32{
        -100, -99, -98, -95, -91, -87, -81, -74, -67, -59, -50, -41, -31, -21, -10,
        0,    10,  21,  31,  41,  50,  59,  67,  74,  81,  87,  91,  95,  98,  99,
        100,  99,  98,  95,  91,  87,  81,  74,  67,  59,  50,  41,  31,  21,  10,
        0,    -10, -21, -31, -41, -50, -59, -67, -74, -81, -87, -91, -95, -98, -99,
    };
    const i = index % 60;
    return .{
        .x = @divTrunc(xs[i] * radius, 100),
        .y = @divTrunc(ys[i] * radius, 100),
    };
}

fn drawLine(canvas: r4os.gui.Canvas, x0: i32, y0: i32, x1: i32, y1: i32, color: u32, thickness: i32) void {
    var x = x0;
    var y = y0;
    const dx = absI32(x1 - x0);
    const sx: i32 = if (x0 < x1) 1 else -1;
    const dy = -absI32(y1 - y0);
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    var step: u32 = 0;
    while (true) {
        if ((step & 1) == 0 or (x == x1 and y == y1)) {
            _ = canvas.rect(.{ .x = x - @divTrunc(thickness, 2), .y = y - @divTrunc(thickness, 2), .w = thickness, .h = thickness }, color);
        }
        if (x == x1 and y == y1) break;
        step += 1;
        const e2 = err * 2;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

fn absI32(value: i32) i32 {
    return if (value < 0) -value else value;
}

fn clampI32(value: i32, min: i32, max: i32) i32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}

fn fail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("CLOCK selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}
