const std = @import("std");
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
const clock_timer_id = r4os.TimerId.init(1);
const benchmark_gui_timer_id = r4os.TimerId.init(2);
const time_service_name = "TIMESVC";
const benchmark_output_path = "D:\\CLOCKPERF.TXT";
const benchmark_error_path = "D:\\CLOCKERR.TXT";
const clock_second_ns: u64 = 1_000_000_000;
const benchmark_gui_interval_ns: u64 = 100_000_000;
const time_service_timeout_ns: u64 = 1_000_000_000;
const benchmark_seconds: u64 = 10;
const timer_lateness_capacity: usize = 32;

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    if (!r4std.init(r4_app.startContext())) return r4os.abi.err_no_group;
    var ctx = AppApi.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), "/SELFTEST")) {
        const selftest_result = runSelfTest(&ctx.sys);
        if (selftest_result != 0) return selftest_result;
        return runRecoveryTest(&ctx);
    }
    const args = ctx.sys.argsRaw();
    const benchmark = hasArg(args, "/BENCHMARK");
    var app = App{
        .ctx = &ctx,
        .benchmark = benchmark,
        .benchmark_phase = if (!benchmark)
            .quiet
        else if (hasArg(args, "/GUI"))
            .gui
        else if (hasArg(args, "/RECOVERY"))
            .recovery
        else
            .quiet,
    };
    return app.run();
}

const BenchmarkPhase = enum(u8) {
    quiet = 0,
    gui = 1,
    recovery = 2,
};

const SampleKind = enum {
    initial,
    timer,
    wait_fallback,
};

const DisplaySnapshot = struct {
    status: r4os.abi.TimeServiceStatus = .{},
    valid: bool = false,
    from_service: bool = false,
};

const ClockMetrics = struct {
    started_tick: u64 = 0,
    wait_calls: u64 = 0,
    timer_wakes: u64 = 0,
    load_timer_wakes: u64 = 0,
    gui_wakes: u64 = 0,
    wait_failures: u64 = 0,
    missed_timer_periods: u64 = 0,
    max_timer_late_ticks: u64 = 0,
    initial_samples: u64 = 0,
    timer_samples: u64 = 0,
    fallback_wait_samples: u64 = 0,
    service_calls: u64 = 0,
    service_successes: u64 = 0,
    service_failures: u64 = 0,
    open_attempts: u64 = 0,
    open_successes: u64 = 0,
    reconnect_successes: u64 = 0,
    close_attempts: u64 = 0,
    close_successes: u64 = 0,
    fallback_samples: u64 = 0,
    render_attempts: u64 = 0,
    presented_frames: u64 = 0,
    second_changes: u64 = 0,
    format_changes: u64 = 0,
    zone_changes: u64 = 0,
    remote_status_first: u64 = 0,
    remote_status_last: u64 = 0,
    remote_status_samples: u64 = 0,
    remote_status_delta_sum: u64 = 0,
    remote_status_resets: u64 = 0,
    phase_actions: u64 = 0,
    phase_action_failures: u64 = 0,
    recovery_stop_result: i32 = 0,
    recovery_start_result: i32 = 0,
};

const App = struct {
    ctx: *AppApi,
    w: i32 = 260,
    h: i32 = 230,
    should_exit: bool = false,
    benchmark: bool = false,
    benchmark_phase: BenchmarkPhase = .quiet,
    config: r4std.time.Config = .{},
    snapshot: DisplaySnapshot = .{},
    time_connection: ?r4os.ServiceConnection = null,
    connected_once: bool = false,
    last_config_check: u32 = std.math.maxInt(u32),
    benchmark_deadline_tick: u64 = 0,
    timer_interval_ticks: u64 = 1,
    next_timer_tick: u64 = 0,
    timer_lateness: [timer_lateness_capacity]u64 = .{0} ** timer_lateness_capacity,
    timer_lateness_count: usize = 0,
    metrics: ClockMetrics = .{},

    fn run(self: *App) i32 {
        if (self.ctx.desk.programWindowId() >= 0) return self.runHosted();
        self.ctx.sys.println("CLOCK is a desktop GUI application.");
        self.ctx.sys.println("Please start from Desktop or through GUI launch.");
        return 0;
    }

    fn runHosted(self: *App) i32 {
        _ = self.ctx.desk.guiSetTitle("Clock");
        _ = self.ctx.desk.guiSetMinSize(240, 220);
        self.metrics.started_tick = self.ctx.sys.ticks();
        self.timer_interval_ticks = @max(@as(u64, 1), self.ctx.sys.ticksFromMilliseconds(1000));
        if (self.benchmark) {
            const duration_ticks = @max(@as(u64, 1), self.ctx.sys.ticksFromMilliseconds(benchmark_seconds * 1000));
            self.benchmark_deadline_tick = self.metrics.started_tick +| duration_ticks;
        }
        defer if (self.benchmark) self.reportMetrics();
        defer if (self.benchmark and self.benchmark_phase == .recovery) ensureTimeServiceRunning(&self.ctx.sys);
        defer self.closeTimeConnection();

        self.loadConfig();
        self.updateMetrics();
        _ = self.refreshSnapshot(.initial);
        self.render();

        var timers: [2]r4os.Timer = .{ .{}, .{} };
        const timer_ready = timers[0].start(
            &self.ctx.sys,
            clock_timer_id,
            .{ .nanoseconds = clock_second_ns },
            true,
        );
        if (self.benchmark and self.benchmark_phase == .gui) {
            _ = timers[1].start(
                &self.ctx.sys,
                benchmark_gui_timer_id,
                .{ .nanoseconds = benchmark_gui_interval_ns },
                true,
            );
        }
        self.next_timer_tick = self.ctx.sys.ticks() +| self.timer_interval_ticks;
        var events = r4os.EventLoop.init(self.ctx.sys, self.ctx.desk, timers[0..]);

        while (!self.ctx.sys.programShouldClose() and !self.should_exit) {
            self.metrics.wait_calls +%= 1;
            const timeout: r4os.abi.R4Timeout = if (timer_ready)
                .{ .kind = r4os.abi.timeout_kind_forever }
            else
                .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = clock_second_ns };
            switch (events.wait(timeout)) {
                .message => |message| self.handleMessage(message),
                .timed_out => self.handleTimerWake(self.ctx.sys.ticks(), .wait_fallback),
                .failure => {
                    self.metrics.wait_failures +%= 1;
                    self.ctx.sys.sleepTicks(self.timer_interval_ticks);
                    self.handleTimerWake(self.ctx.sys.ticks(), .wait_fallback);
                },
            }
            if (self.benchmarkExpired()) self.should_exit = true;
        }
        return 0;
    }

    fn handleMessage(self: *App, message: r4os.Message) void {
        switch (message) {
            .close => {
                self.metrics.gui_wakes +%= 1;
                self.should_exit = true;
            },
            .resize => {
                self.metrics.gui_wakes +%= 1;
                self.updateMetrics();
                self.render();
            },
            .key => |key| {
                self.metrics.gui_wakes +%= 1;
                if (key.key == r4os.gui.Key.escape) self.should_exit = true;
            },
            .timer => |timer| {
                if (timer.id.value == clock_timer_id.value) {
                    self.handleTimerWake(timer.tick, .timer);
                } else if (timer.id.value == benchmark_gui_timer_id.value) {
                    self.handleBenchmarkGuiWake();
                }
            },
            else => self.metrics.gui_wakes +%= 1,
        }
    }

    fn handleTimerWake(self: *App, tick: u64, sample_kind: SampleKind) void {
        self.metrics.timer_wakes +%= 1;
        const late = if (tick > self.next_timer_tick) tick - self.next_timer_tick else 0;
        if (self.timer_lateness_count < self.timer_lateness.len) {
            self.timer_lateness[self.timer_lateness_count] = late;
            self.timer_lateness_count += 1;
        }
        if (tick > self.next_timer_tick) {
            self.metrics.max_timer_late_ticks = @max(self.metrics.max_timer_late_ticks, late);
            self.metrics.missed_timer_periods +%= late / self.timer_interval_ticks;
        }
        const elapsed = if (tick >= self.next_timer_tick) tick - self.next_timer_tick else 0;
        const periods = elapsed / self.timer_interval_ticks +| 1;
        self.next_timer_tick +|= periods *| self.timer_interval_ticks;
        if (sample_kind == .timer and self.benchmark and self.benchmark_phase == .recovery and
            self.metrics.timer_wakes == 4 and self.metrics.phase_actions == 0)
        {
            self.runBenchmarkRecoveryAction();
        }
        if (self.refreshSnapshot(sample_kind)) self.render();
    }

    fn handleBenchmarkGuiWake(self: *App) void {
        if (!self.benchmark or self.benchmark_phase != .gui) return;
        self.metrics.load_timer_wakes +%= 1;
        self.metrics.phase_actions +%= 1;
        const step: i32 = @intCast(@min(self.metrics.phase_actions, 96));
        if (self.ctx.desk.guiSetMinSize(440 + step * 2, 250 + step * 2) < 0) {
            self.metrics.phase_action_failures +%= 1;
        }
    }

    fn runBenchmarkRecoveryAction(self: *App) void {
        self.metrics.phase_actions +%= 1;
        var info: r4os.abi.ServiceInfo = .{};
        self.metrics.recovery_stop_result = self.ctx.sys.serviceStop(
            time_service_name,
            &info,
            self.ctx.sys.ticksFromMilliseconds(2000),
        );
        if (self.metrics.recovery_stop_result != r4os.abi.service_api_result_ok) {
            self.metrics.phase_action_failures +%= 1;
            return;
        }
        self.metrics.recovery_start_result = self.ctx.sys.serviceStart(time_service_name, &info);
        if (self.metrics.recovery_start_result != r4os.abi.service_api_result_ok and
            self.metrics.recovery_start_result != r4os.abi.service_api_result_running)
        {
            self.metrics.phase_action_failures +%= 1;
        }
    }

    fn benchmarkExpired(self: *const App) bool {
        return self.benchmark and self.ctx.sys.ticks() >= self.benchmark_deadline_tick;
    }

    fn updateMetrics(self: *App) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        _ = self.ctx.desk.guiWindowInfo(&info);
        const canvas = r4os.gui.Canvas.init(&self.ctx.draw, info);
        self.w = clampI32(canvas.w, 240, 640);
        self.h = clampI32(canvas.h, 220, 520);
    }

    fn refreshSnapshot(self: *App, sample_kind: SampleKind) bool {
        switch (sample_kind) {
            .initial => self.metrics.initial_samples +%= 1,
            .timer => self.metrics.timer_samples +%= 1,
            .wait_fallback => self.metrics.fallback_wait_samples +%= 1,
        }

        const state = self.ctx.sys.timeState();
        const raw = state.seconds_since_midnight;
        var next: DisplaySnapshot = .{};
        if (self.readTimeServiceStatus(&next.status)) {
            next.valid = true;
            next.from_service = true;
        } else {
            self.metrics.fallback_samples +%= 1;
            if (raw != self.last_config_check) {
                self.last_config_check = raw;
                self.loadConfig();
            }
            next.status.local_seconds_since_midnight = r4std.time.secondsInZone(raw, self.config.offsetMinutesForState(state));
            next.status.clock_format = @intCast(self.config.selectedClockFormat());
            @memset(next.status.zone_label[0..], 0);
            _ = r4std.time.copyZoneLabelForState(next.status.zone_label[0..], self.config.selectedIndex(), state);
            next.valid = true;
        }

        const changed = !self.snapshot.valid or displaySnapshotChanged(self.snapshot, next);
        if (self.snapshot.valid) {
            if (self.snapshot.status.local_seconds_since_midnight != next.status.local_seconds_since_midnight) self.metrics.second_changes +%= 1;
            if (self.snapshot.status.clock_format != next.status.clock_format) self.metrics.format_changes +%= 1;
            if (!std.mem.eql(u8, self.snapshot.status.zone_label[0..], next.status.zone_label[0..])) self.metrics.zone_changes +%= 1;
        }
        self.snapshot = next;
        return changed;
    }

    fn readTimeServiceStatus(self: *App, out: *r4os.abi.TimeServiceStatus) bool {
        if (!self.ensureTimeConnection()) return false;
        var connection = self.time_connection orelse return false;
        out.* = .{};
        self.metrics.service_calls +%= 1;
        const called = connection.call(
            r4os.abi.time_service_op_status,
            "",
            std.mem.asBytes(out),
            .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = time_service_timeout_ns },
        );
        self.time_connection = if (connection.valid()) connection else null;
        switch (called) {
            .response => |response| {
                if (response.bytes < @sizeOf(r4os.abi.TimeServiceStatus) or
                    out.magic != r4os.abi.time_service_status_magic or
                    out.version != r4os.abi.time_service_status_version)
                {
                    self.metrics.service_failures +%= 1;
                    self.closeTimeConnection();
                    return false;
                }
                self.metrics.service_successes +%= 1;
                if (self.metrics.remote_status_samples == 0) {
                    self.metrics.remote_status_first = out.status_requests;
                } else if (out.status_requests >= self.metrics.remote_status_last) {
                    self.metrics.remote_status_delta_sum +%= out.status_requests - self.metrics.remote_status_last;
                } else {
                    self.metrics.remote_status_resets +%= 1;
                    self.metrics.remote_status_delta_sum +%= out.status_requests;
                }
                self.metrics.remote_status_last = out.status_requests;
                self.metrics.remote_status_samples +%= 1;
                return true;
            },
            .timed_out, .remote_failure, .failure => {
                self.metrics.service_failures +%= 1;
                return false;
            },
        }
    }

    fn ensureTimeConnection(self: *App) bool {
        if (self.time_connection) |connection| {
            if (connection.valid()) return true;
            self.time_connection = null;
        }
        self.metrics.open_attempts +%= 1;
        var services = r4os.Services{ .sys = self.ctx.sys };
        switch (services.open(time_service_name)) {
            .connection => |connection| {
                self.time_connection = connection;
                self.metrics.open_successes +%= 1;
                if (self.connected_once) self.metrics.reconnect_successes +%= 1;
                self.connected_once = true;
                return true;
            },
            .failure => {
                self.metrics.service_failures +%= 1;
                return false;
            },
        }
    }

    fn closeTimeConnection(self: *App) void {
        var connection = self.time_connection orelse return;
        self.time_connection = null;
        if (!connection.valid()) return;
        self.metrics.close_attempts +%= 1;
        if (connection.close() == r4os.abi.service_api_result_ok) self.metrics.close_successes +%= 1;
    }

    fn render(self: *App) void {
        self.metrics.render_attempts +%= 1;
        if (!self.snapshot.valid) return;
        var paint = switch (r4os.app_gui.beginPaintForSize(&self.ctx.draw, self.w, self.h)) {
            .paint => |value| value,
            .failure => return,
        };
        defer paint.discard();
        const canvas = paint.canvas;
        var scratch: [96]u8 = .{0} ** 96;
        const seconds = self.snapshot.status.local_seconds_since_midnight;
        const time = r4std.time.splitTime(seconds);
        const clock_format = @as(u32, self.snapshot.status.clock_format);
        const zone_label = spanZ(self.snapshot.status.zone_label[0..]);

        _ = canvas.clear(app_bg);
        _ = canvas.groupBox(.{ .rect = .{ .x = 12, .y = 10, .w = self.w - 24, .h = self.h - 62 }, .title = "Clock" }, scratch[0..]);
        self.drawAnalog(canvas, time);

        var hms: [12]u8 = .{0} ** 12;
        _ = r4std.time.formatDisplay(hms[0..], time, clock_format);
        _ = canvas.label(.{ .rect = .{ .x = 16, .y = self.h - 44, .w = self.w - 32, .h = 16 }, .text = spanZ(hms[0..]), .alignment = .center, .fg = text, .bg = app_bg }, scratch[0..]);
        _ = canvas.textClipped(16, self.h - 24, self.w - 32, scratch[0..], zone_label, text, app_bg);
        if (paint.present() >= 0) self.metrics.presented_frames +%= 1;
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

    fn reportMetrics(self: *const App) void {
        const lateness = timerStats(self.timer_lateness[0..self.timer_lateness_count]);
        var buffer: [1024]u8 = undefined;
        var length: usize = 0;
        length += (std.fmt.bufPrint(buffer[length..], "CLOCKPERF|2|{d}|{d}|{d}|{d}", .{
            @intFromEnum(self.benchmark_phase),
            benchmark_seconds,
            self.ctx.sys.ticks() -| self.metrics.started_tick,
            self.ctx.sys.monotonicHz(),
        }) catch return).len;
        length += (std.fmt.bufPrint(buffer[length..], "|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{
            self.metrics.wait_calls,
            self.metrics.timer_wakes,
            self.metrics.load_timer_wakes,
            self.metrics.gui_wakes,
            self.metrics.wait_failures,
            self.metrics.missed_timer_periods,
            lateness.count,
            lateness.minimum,
            lateness.p50,
            lateness.p95,
            lateness.p99,
            lateness.maximum,
            lateness.mean,
        }) catch return).len;
        length += (std.fmt.bufPrint(buffer[length..], "|{d}|{d}|{d}", .{
            self.metrics.initial_samples,
            self.metrics.timer_samples,
            self.metrics.fallback_wait_samples,
        }) catch return).len;
        length += (std.fmt.bufPrint(buffer[length..], "|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}|{d}", .{
            self.metrics.service_calls,
            self.metrics.service_successes,
            self.metrics.service_failures,
            self.metrics.open_attempts,
            self.metrics.open_successes,
            self.metrics.reconnect_successes,
            self.metrics.close_attempts,
            self.metrics.close_successes,
            self.metrics.fallback_samples,
        }) catch return).len;
        length += (std.fmt.bufPrint(buffer[length..], "|{d}|{d}|{d}|{d}|{d}", .{
            self.metrics.render_attempts,
            self.metrics.presented_frames,
            self.metrics.second_changes,
            self.metrics.format_changes,
            self.metrics.zone_changes,
        }) catch return).len;
        length += (std.fmt.bufPrint(buffer[length..], "|{d}|{d}|{d}|{d}|{d}", .{
            self.metrics.remote_status_samples,
            self.metrics.remote_status_first,
            self.metrics.remote_status_last,
            self.metrics.remote_status_delta_sum,
            self.metrics.remote_status_resets,
        }) catch return).len;
        length += (std.fmt.bufPrint(buffer[length..], "|{d}|{d}|{d}|{d}|{d}", .{
            self.metrics.phase_actions,
            self.metrics.phase_action_failures,
            self.metrics.recovery_stop_result,
            self.metrics.recovery_start_result,
            @intFromBool(self.snapshot.from_service),
        }) catch return).len;
        const line = buffer[0..length];
        const line_result = self.ctx.sys.fileAppend(benchmark_output_path, line);
        const newline_result = self.ctx.sys.fileAppend(benchmark_output_path, "\r\n");
        if (line_result != @as(i32, @intCast(line.len)) or newline_result != 2) {
            var error_buffer: [96]u8 = undefined;
            const error_line = std.fmt.bufPrint(error_buffer[0..], "CLOCKPERFERR|{d}|{d}|{d}\r\n", .{
                @intFromEnum(self.benchmark_phase),
                line_result,
                newline_result,
            }) catch return;
            _ = self.ctx.sys.fileWrite(benchmark_error_path, error_line);
        }
        self.ctx.sys.println(line);
    }
};

const TimerStats = struct {
    count: usize = 0,
    minimum: u64 = 0,
    p50: u64 = 0,
    p95: u64 = 0,
    p99: u64 = 0,
    maximum: u64 = 0,
    mean: u64 = 0,
};

fn timerStats(values: []const u64) TimerStats {
    if (values.len == 0) return .{};
    var sorted: [timer_lateness_capacity]u64 = .{0} ** timer_lateness_capacity;
    @memcpy(sorted[0..values.len], values);
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = sorted[index];
        var position = index;
        while (position > 0 and sorted[position - 1] > value) : (position -= 1) {
            sorted[position] = sorted[position - 1];
        }
        sorted[position] = value;
    }
    var sum: u64 = 0;
    for (sorted[0..values.len]) |value| sum +%= value;
    return .{
        .count = values.len,
        .minimum = sorted[0],
        .p50 = nearestRank(sorted[0..values.len], 50),
        .p95 = nearestRank(sorted[0..values.len], 95),
        .p99 = nearestRank(sorted[0..values.len], 99),
        .maximum = sorted[values.len - 1],
        .mean = sum / values.len,
    };
}

fn nearestRank(sorted: []const u64, percentile: usize) u64 {
    const rank = (percentile * sorted.len + 99) / 100;
    return sorted[@max(rank, 1) - 1];
}

fn displaySnapshotChanged(previous: DisplaySnapshot, next: DisplaySnapshot) bool {
    return previous.status.local_seconds_since_midnight != next.status.local_seconds_since_midnight or
        previous.status.clock_format != next.status.clock_format or
        !std.mem.eql(u8, previous.status.zone_label[0..], next.status.zone_label[0..]);
}

fn runRecoveryTest(ctx: *AppApi) i32 {
    ctx.sys.println("CLOCK recovery test");
    var app = App{ .ctx = ctx };
    app.loadConfig();
    defer ensureTimeServiceRunning(&ctx.sys);
    defer app.closeTimeConnection();

    var status: r4os.abi.TimeServiceStatus = .{};
    if (!app.readTimeServiceStatus(&status)) return fail(&ctx.sys, "initial-service");
    ctx.sys.println("CLOCK recovery: initial connection OK");

    var info: r4os.abi.ServiceInfo = .{};
    ctx.sys.println("CLOCK recovery: stopping TIMESVC");
    const stop = ctx.sys.serviceStop(time_service_name, &info, ctx.sys.ticksFromMilliseconds(2000));
    if (stop != r4os.abi.service_api_result_ok) return fail(&ctx.sys, "service-stop");
    ctx.sys.println("CLOCK recovery: TIMESVC stopped");

    var unavailable: r4os.abi.TimeServiceStatus = .{};
    if (app.readTimeServiceStatus(&unavailable)) return fail(&ctx.sys, "stale-service");
    if (app.time_connection != null) return fail(&ctx.sys, "stale-connection");
    _ = app.refreshSnapshot(.timer);
    if (!app.snapshot.valid or app.snapshot.from_service) return fail(&ctx.sys, "fallback");
    ctx.sys.println("CLOCK recovery: fallback OK");

    const start = ctx.sys.serviceStart(time_service_name, &info);
    if (start != r4os.abi.service_api_result_ok and start != r4os.abi.service_api_result_running) {
        return fail(&ctx.sys, "service-start");
    }

    var recovered = false;
    var tick: u32 = 0;
    while (tick < 160) : (tick += 1) {
        if (app.readTimeServiceStatus(&status)) {
            recovered = true;
            break;
        }
        ctx.sys.sleepTicks(1);
    }
    if (!recovered) return fail(&ctx.sys, "reconnect");
    if (app.metrics.open_successes < 2 or app.metrics.reconnect_successes == 0) {
        return fail(&ctx.sys, "reconnect-accounting");
    }
    app.closeTimeConnection();
    app.closeTimeConnection();
    if (app.metrics.close_attempts != 1 or app.metrics.close_successes != 1) {
        return fail(&ctx.sys, "idempotent-close");
    }

    ctx.sys.println("CLOCK recovery: reconnect OK");
    ctx.sys.println("CLOCK recovery test: OK");
    return 0;
}

fn ensureTimeServiceRunning(ctx: *const r4os.r4sys.Context) void {
    var tick: u32 = 0;
    while (tick < 160) : (tick += 1) {
        var info: r4os.abi.ServiceInfo = .{};
        const status = ctx.serviceStatus(time_service_name, &info);
        if (status == r4os.abi.service_api_result_ok and info.state == r4os.abi.service_state_running) return;
        if (status == r4os.abi.service_api_result_ok and
            info.state != r4os.abi.service_state_starting and
            info.state != r4os.abi.service_state_stopping)
        {
            const start = ctx.serviceStart(time_service_name, &info);
            if (start != r4os.abi.service_api_result_ok and start != r4os.abi.service_api_result_running) return;
        }
        ctx.sleepTicks(1);
    }
}

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
    var first = DisplaySnapshot{ .valid = true };
    first.status.local_seconds_since_midnight = 42;
    first.status.clock_format = @intCast(r4os.abi.clock_format_24h);
    first.status.zone_label[0] = 'A';
    var second = first;
    if (displaySnapshotChanged(first, second)) return fail(ctx, "snapshot-stable");
    second.status.local_seconds_since_midnight += 1;
    if (!displaySnapshotChanged(first, second)) return fail(ctx, "snapshot-second");
    second = first;
    second.status.clock_format = @intCast(r4os.abi.clock_format_12h);
    if (!displaySnapshotChanged(first, second)) return fail(ctx, "snapshot-format");
    second = first;
    second.status.zone_label[0] = 'B';
    if (!displaySnapshotChanged(first, second)) return fail(ctx, "snapshot-zone");
    const lateness = timerStats(&.{ 5, 1, 9, 3 });
    if (lateness.count != 4 or lateness.minimum != 1 or lateness.p50 != 3 or
        lateness.p95 != 9 or lateness.p99 != 9 or lateness.maximum != 9 or lateness.mean != 4)
    {
        return fail(ctx, "timer-stats");
    }
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
    ctx.write("CLOCK test FAILED: ");
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
