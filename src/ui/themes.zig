//! The window's themes: the randomizer's own (Raven's glass dark look: frosted glass panels and widgets, with the
//! Kokiri green accent and the night-sky wallpaper behind them) and
//! every built-in look of Raven, chosen on the General Settings tab and kept in user_settings.toml ([app] theme).
//!
//! What the window colours itself goes through style classes, so each theme can give them its own colours:
//!   Heading      the gold card titles (Label)
//!   Muted        the grey help text (Label)
//!   PickerFace   a search drop-down's field (Border; src/ui/SearchPicker.zig)
//!   PickerPopup  the search drop-down's popup (Border)
//! The randomizer's theme keeps the colours the window always had; Raven's looks take them from the look itself
//! (its control, popup, success and danger colours), so light looks stay readable.
//!
//! Buttons are pills in every theme: their corner radius is half their height, and they get extra room left and
//! right for the rounded ends (`applyButtonShape`).

const std = @import("std");
const r = @import("raven");

pub const Theme = struct {
    /// the value user_settings.toml keeps
    value: []const u8,
    label: [:0]const u8,
    look: r.Look,
    /// the randomizer's own colours, accent and wallpaper over the look
    is_randomizer_theme: bool = false,
};

pub const default_value = "goggles_of_truth";

pub const themes = [_]Theme{
    .{ .value = default_value, .label = "Goggles of Truth (default)", .look = .raven_glass_dark, .is_randomizer_theme = true },
    .{ .value = "raven_dark", .label = "Raven Dark", .look = .raven_dark },
    .{ .value = "raven_light", .label = "Raven Light", .look = .raven_light },
    .{ .value = "raven_glass_dark", .label = "Raven Glass Dark", .look = .raven_glass_dark },
    .{ .value = "raven_glass_light", .label = "Raven Glass Light", .look = .raven_glass_light },
    .{ .value = "raven_high_contrast_dark", .label = "High Contrast Dark", .look = .raven_high_contrast_dark },
    .{ .value = "raven_high_contrast_light", .label = "High Contrast Light", .look = .raven_high_contrast_light },
    .{ .value = "windows_dark", .label = "Windows Dark", .look = .windows_dark },
    .{ .value = "windows_light", .label = "Windows Light", .look = .windows_light },
    .{ .value = "macos_dark", .label = "macOS Dark", .look = .macos_dark },
    .{ .value = "macos_light", .label = "macOS Light", .look = .macos_light },
    .{ .value = "macos_glass_dark", .label = "macOS Glass Dark", .look = .macos_glass_dark },
    .{ .value = "macos_glass_light", .label = "macOS Glass Light", .look = .macos_glass_light },
    .{ .value = "gnome_dark", .label = "GNOME Dark", .look = .gnome_dark },
    .{ .value = "gnome_light", .label = "GNOME Light", .look = .gnome_light },
    .{ .value = "native_dark", .label = "This System's Look, Dark", .look = .native_dark },
    .{ .value = "native_light", .label = "This System's Look, Light", .look = .native_light },
};

/// The picker's rows, index for index with `themes`.
pub const theme_labels = blk: {
    var labels: [themes.len][:0]const u8 = undefined;
    for (themes, 0..) |t, i| labels[i] = t.label;
    break :blk labels;
};
pub const theme_values = blk: {
    var values: [themes.len][]const u8 = undefined;
    for (themes, 0..) |t, i| values[i] = t.value;
    break :blk values;
};

/// The index of the theme user_settings.toml names, or null for an unknown name.
pub fn indexOfTheme(value: []const u8) ?usize {
    for (themes, 0..) |t, i| if (std.mem.eql(u8, t.value, value)) return i;
    return null;
}

const kokiri_green_accent = [3]f32{ 0.36, 0.80, 0.56 };

/// The randomizer theme's colours (the ones the window had before themes could be chosen).
const randomizer_heading = r.Color.rgba(0.961, 0.800, 0.380, 1.0); // #F5CC61
const randomizer_muted = r.Color.rgba(0.780, 0.820, 0.859, 0.85); // #C7D1DBD9
const randomizer_face_background = r.Color.rgba(1.0, 1.0, 1.0, 0.05); // #FFFFFF0D
const randomizer_outline = r.Color.rgba(1.0, 1.0, 1.0, 0.18); // #FFFFFF2E
const randomizer_popup_background = r.Color.rgba(0.118, 0.129, 0.149, 1.0); // #1E2126
const randomizer_success = r.Color.rgba(0.40, 0.86, 0.52, 1.0);
const randomizer_danger = r.Color.rgba(0.96, 0.46, 0.44, 1.0);
/// Raven's looks: the gold titles, darker on a light look so they stay readable on white
const heading_on_dark = randomizer_heading;
const heading_on_light = r.Color.rgba(0.545, 0.388, 0.0, 1.0); // #8B6300

/// The colours the window's code sets itself (the game check's line, the drop-downs' text), for the theme in use.
pub const CodeColors = struct {
    muted: r.Color,
    success: r.Color,
    danger: r.Color,
    placeholder: r.Color,
};

var current_code_colors = CodeColors{
    .muted = randomizer_muted,
    .success = randomizer_success,
    .danger = randomizer_danger,
    .placeholder = r.Color.rgba(0.78, 0.82, 0.86, 0.6),
};

pub fn codeColors() CodeColors {
    return current_code_colors;
}

/// Makes `theme` the window's theme: its look, then the window's styles over it (a look change drops every style
/// and theme colour, so all of them are set again each time). `wallpaper` is the randomizer theme's background.
pub fn applyTheme(theme: Theme, wallpaper: ?r.Texture) void {
    r.lookSet(theme.look);
    if (theme.is_randomizer_theme) {
        r.themeSetAccent(kokiri_green_accent[0], kokiri_green_accent[1], kokiri_green_accent[2]);
        r.themeSetWallpaper(wallpaper);
        setClassColor("Label", "Heading", .text, randomizer_heading);
        setClassColor("Label", "Muted", .text, randomizer_muted);
        setClassColor("Border", "PickerFace", .panel, randomizer_face_background);
        setClassColor("Border", "PickerFace", .border, randomizer_outline);
        setClassColor("Border", "PickerPopup", .panel, randomizer_popup_background);
        setClassColor("Border", "PickerPopup", .border, randomizer_outline);
        current_code_colors = .{
            .muted = randomizer_muted,
            .success = randomizer_success,
            .danger = randomizer_danger,
            .placeholder = r.Color.rgba(0.78, 0.82, 0.86, 0.6),
        };
    } else {
        r.themeSetWallpaper(null);
        const dark = r.themeIsDark();
        const text = r.themeGetColor(.text);
        // help text: the look's text colour, a little faded
        const muted = r.Color.rgba(text.r, text.g, text.b, 0.72);
        setClassColor("Label", "Heading", .text, if (dark) heading_on_dark else heading_on_light);
        setClassColor("Label", "Muted", .text, muted);
        setClassColor("Border", "PickerFace", .panel, r.themeGetColor(.control));
        setClassColor("Border", "PickerFace", .border, r.themeGetColor(.control_border));
        setClassColor("Border", "PickerPopup", .panel, r.themeGetColor(.popup));
        setClassColor("Border", "PickerPopup", .border, r.themeGetColor(.popup_border));
        current_code_colors = .{
            .muted = muted,
            .success = r.themeGetColor(.success),
            .danger = r.themeGetColor(.danger),
            .placeholder = r.themeGetColor(.text_placeholder),
        };
    }
    applyButtonShape();
}

fn setClassColor(widget: [:0]const u8, class: [:0]const u8, role: r.ColorRole, color: r.Color) void {
    r.themeSetStyleColor(widget, class, role, color);
}

/// Pill buttons: the corner radius is half the button height (the look's control height: no button in the window
/// sets a height of its own), and the padding left and right grows by a quarter of the height, so a button wider
/// than it is tall has room for its rounded ends.
fn applyButtonShape() void {
    const button_height = r.themeGetMetric(.control_height);
    const look_padding_x = r.themeGetMetric(.padding_x);
    r.themeSetStyleMetric("Button", "", .corner_radius, button_height / 2.0);
    r.themeSetStyleMetric("Button", "", .padding_x, look_padding_x + button_height / 4.0);
}
