//! goggles_launcher on every release with the window: a small splash screen (src/ui/launcher_splash.xml) that shows
//! the launcher's steps (src/launcher_flow.zig) while it checks for a newer version, downloads it with a progress bar
//! and installs it, then opens the randomizer and closes. The command-line only releases use src/launcher.zig (the
//! console) instead; build.zig picks one of the two.
//!
//! ELM architecture (Agents.md section 4):
//!   Model    `SplashModel` (src/launcher_splash_model.zig): what the splash screen shows, nothing else
//!   Message  `SplashMessage` (same file): what the flow reports from its worker thread (a phase, bytes, the end)
//!   Update   `updateSplash` (same file): a pure function from a model and a message to the next model
//!   View     `viewSplash` (here): puts a model into the XML's widgets
//! The flow runs on a worker thread (it waits on the network); its messages go through `SplashMailbox`, which a
//! timer on the UI thread drains (Raven belongs to the thread that started it).
//!
//! Without Raven (no Vulkan driver), the flow runs without a splash screen and the randomizer starts as usual.

const std = @import("std");
const r = @import("raven");
const FixedString = @import("string").FixedString;
const version = @import("version.zig");
const flow = @import("launcher_flow.zig");
const splash_model = @import("launcher_splash_model.zig");
const themes = @import("ui/themes.zig");
const wallpaper = @import("ui/wallpaper.zig");
const toml = @import("formats/toml.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const splash_xml = @embedFile("ui/launcher_splash.xml");
/// the splash screen's size (its content is src/ui/launcher_splash.xml)
const splash_width = 480;
const splash_height = 230;
const app_icon_png = @embedFile("ui/GogglesRandoAppIcon.png");

const SplashText = splash_model.SplashText;
const SplashModel = splash_model.SplashModel;
const SplashMessage = splash_model.SplashMessage;
const updateSplash = splash_model.updateSplash;

// ------------------------------------------------------------------------------------------------------ the view

/// The widgets of src/ui/launcher_splash.xml.
const SplashWidgets = struct {
    status: r.Label,
    detail: r.Label,
    version_label: r.Label,
    progress: r.ProgressBar,

    fn find(root: r.Widget) ?SplashWidgets {
        return .{
            .status = (root.find("splash_status") orelse return null).as(r.Label) orelse return null,
            .detail = (root.find("splash_detail") orelse return null).as(r.Label) orelse return null,
            .version_label = (root.find("splash_version") orelse return null).as(r.Label) orelse return null,
            .progress = (root.find("splash_progress") orelse return null).as(r.ProgressBar) orelse return null,
        };
    }
};

fn viewSplash(model: *const SplashModel, widgets: SplashWidgets) void {
    var status = model.status_line;
    var detail = model.detail_line;
    widgets.status.setText(status.cStr() catch "");
    widgets.detail.setText(detail.cStr() catch "");
    widgets.progress.setValue(model.progress);
}

// -------------------------------------------------------------------------------------------------- the mailbox

/// The worker's messages on their way to the UI thread.
const SplashMailbox = struct {
    allocator: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    messages: std.ArrayList(SplashMessage) = .empty,

    fn post(self: *SplashMailbox, message: SplashMessage) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // a download's bytes: only the newest count matters, so it replaces the one still waiting
        if (message == .download_advanced and self.messages.items.len > 0) {
            const last = &self.messages.items[self.messages.items.len - 1];
            if (last.* == .download_advanced) {
                last.* = message;
                return;
            }
        }
        self.messages.append(self.allocator, message) catch {}; // out of memory: the splash shows an older step
    }

    /// Moves every waiting message into `out`.
    fn takeAll(self: *SplashMailbox, out: *std.ArrayList(SplashMessage)) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        out.appendSlice(self.allocator, self.messages.items) catch return;
        self.messages.clearRetainingCapacity();
    }

    fn deinit(self: *SplashMailbox) void {
        self.messages.deinit(self.allocator);
    }

    fn reporter(self: *SplashMailbox) flow.StatusReporter {
        return .{ .context = self, .report_phase = onPhase, .report_download = onDownload };
    }

    fn onPhase(context: ?*anyopaque, phase: flow.Phase, line: []const u8) void {
        const self: *SplashMailbox = @ptrCast(@alignCast(context.?));
        self.post(.{ .phase_changed = .{ .phase = phase, .line = SplashText.fromTruncate(line) } });
    }

    fn onDownload(context: ?*anyopaque, received: u64, total: u64) void {
        const self: *SplashMailbox = @ptrCast(@alignCast(context.?));
        self.post(.{ .download_advanced = .{ .received = received, .total = total } });
    }
};

// ------------------------------------------------------------------------------------------------- the program

/// What the worker thread needs.
const FlowJob = struct {
    gpa: Allocator,
    io: Io,
    options: flow.LaunchOptions,
    launcher_path: []const u8,
    app_folder: []const u8,
};

/// Runs on the worker thread: the whole flow, then the end message.
fn runFlowOnWorker(job: *const FlowJob, mailbox: *SplashMailbox) void {
    const status = mailbox.reporter();
    const outcome = flow.runUpdate(job.gpa, job.io, status, job.options, job.launcher_path, job.app_folder);
    if (job.options.install_only) {
        return mailbox.post(.{ .flow_finished = .{ .exit_code = @intFromEnum(outcome.install_only_exit_code), .needs_attention = outcome.needs_attention } });
    }
    var started = true;
    if (job.options.startsWindow()) {
        var arena = std.heap.ArenaAllocator.init(job.gpa);
        defer arena.deinit();
        started = flow.startWindow(arena.allocator(), job.io, status, job.app_folder);
    } else if (job.options.simulate) {
        status.phase(.finished, "Simulation done: the randomizer would open now.", .{});
    }
    mailbox.post(.{ .flow_finished = .{ .exit_code = if (started) 0 else 1, .needs_attention = outcome.needs_attention or !started } });
}

/// The UI thread's state: the model, the widgets, the mailbox.
const SplashProgram = struct {
    model: SplashModel = .{},
    widgets: SplashWidgets,
    mailbox: *SplashMailbox,
    pending: std.ArrayList(SplashMessage) = .empty,
    allocator: Allocator,
    close_timer_started: bool = false,

    /// The timer on the UI thread: every waiting message through `updateSplash`, then the view.
    fn onTick(self: *SplashProgram, _: r.Timer) void {
        self.mailbox.takeAll(&self.pending);
        if (self.pending.items.len == 0) return;
        for (self.pending.items) |message| self.model = updateSplash(self.model, message);
        self.pending.clearRetainingCapacity();
        viewSplash(&self.model, self.widgets);
        if (self.model.finished and !self.close_timer_started) {
            self.close_timer_started = true;
            _ = r.Timer.create(self.model.close_after_seconds, false, self, onClose);
        }
    }

    fn onClose(self: *SplashProgram, _: r.Timer) void {
        r.quit(self.model.exit_code);
    }
};

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const all_arguments = init.minimal.args.toSlice(arena) catch return 1;
    const options = flow.parseLaunchOptions(if (all_arguments.len > 1) all_arguments[1..] else &.{}) catch return 2;
    const launcher_path = std.process.executablePathAlloc(io, arena) catch return 1;
    const job = FlowJob{
        .gpa = gpa,
        .io = io,
        .options = options,
        .launcher_path = launcher_path,
        .app_folder = std.fs.path.dirname(launcher_path) orelse ".",
    };
    var mailbox = SplashMailbox{ .allocator = gpa, .io = io };
    defer mailbox.deinit();

    // no splash screen without Raven (no Vulkan driver): the same flow, quietly
    const theme = themes.themes[savedThemeIndex(gpa, io, job.app_folder)];
    const splash = openSplashWindow(gpa, options, theme) orelse {
        runFlowOnWorker(&job, &mailbox);
        var last = SplashModel{};
        for (mailbox.messages.items) |message| last = updateSplash(last, message);
        return last.exit_code;
    };
    defer r.shutdown();
    defer if (splash.wallpaper_texture) |texture| texture.destroy();

    var program = SplashProgram{ .widgets = splash.widgets, .mailbox = &mailbox, .allocator = gpa };
    defer program.pending.deinit(gpa);
    viewSplash(&program.model, program.widgets);
    splash.window.show();

    const worker = std.Thread.spawn(.{}, runFlowOnWorker, .{ &job, &mailbox }) catch {
        // no thread: run it here (the splash screen stays on its first line meanwhile)
        runFlowOnWorker(&job, &mailbox);
        program.onTick(undefined);
        return program.model.exit_code;
    };
    _ = r.Timer.create(0.03, true, &program, SplashProgram.onTick);
    while (r.waitFrame(-1.0)) {}
    worker.join();
    return program.model.exit_code;
}

/// The theme chosen in the window (General Settings, saved as [app] theme in user_settings.toml next to the programs),
/// so the splash screen looks like the window it opens. The default theme (index 0) when there's no file yet, or it
/// names no known theme; the window reports a bad file itself when it opens.
fn savedThemeIndex(gpa: Allocator, io: Io, app_folder: []const u8) usize {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const path = std.fs.path.join(arena, &.{ app_folder, user_settings_file_name }) catch return 0;
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 * 1024 * 1024)) catch return 0;
    return themeIndexFromSettingsText(arena, text);
}

/// The theme index `text` (user_settings.toml's contents) names, else 0.
fn themeIndexFromSettingsText(arena: Allocator, text: []const u8) usize {
    const document = toml.parse(arena, text, null) catch return 0;
    const app_table = document.table("app") orelse return 0;
    const value = app_table.get("theme") orelse return 0;
    if (value != .string) return 0;
    return themes.indexOfTheme(value.string) orelse 0;
}

/// settings/usersettings.zig's file_name (that module is part of the engine, which the launcher doesn't link)
const user_settings_file_name = "user_settings.toml";

const SplashWindow = struct {
    window: r.Window,
    widgets: SplashWidgets,
    wallpaper_texture: ?r.Texture,
};

/// Starts Raven and opens the splash screen; null when Raven can't start or the layout is broken (the flow then runs
/// without it).
fn openSplashWindow(gpa: Allocator, options: flow.LaunchOptions, theme: themes.Theme) ?SplashWindow {
    r.init(.vulkan) catch return null;
    // the night sky behind the cards belongs to the randomizer's own theme; Raven's looks bring their own background
    var wallpaper_texture: ?r.Texture = null;
    if (theme.is_randomizer_theme) {
        if (wallpaper.png(gpa, splash_width, splash_height)) |png| {
            defer gpa.free(png);
            if (r.Texture.create(png)) |texture| wallpaper_texture = texture else |_| {}
        } else |_| {}
    }
    themes.applyTheme(theme, wallpaper_texture);
    // the content comes from the XML; the window is made here, as a splash screen (see the XML's comment)
    const root = r.Widget.createFromXml(splash_xml) catch {
        r.shutdown();
        return null;
    };
    const window = r.Window.create(version.name, splash_width, splash_height, .{ .splash_screen = true });
    window.setContent(root);
    const widgets = SplashWidgets.find(root) orelse {
        r.shutdown();
        return null;
    };
    if (r.imageDecode(gpa, app_icon_png)) |icon| {
        defer icon.deinit(gpa);
        window.setIcon(icon.pixels, icon.width, icon.height);
    } else |_| {}
    var version_text = FixedString(64).fmt("version {s}", .{options.installedVersion()}) catch FixedString(64).init();
    widgets.version_label.setText(version_text.cStr() catch "");
    return .{ .window = window, .widgets = widgets, .wallpaper_texture = wallpaper_texture };
}
