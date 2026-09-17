#!/usr/bin/env bash
#
# install-remmina-indicator.sh
#
# Installs a native wingpanel indicator for Remmina on elementary OS 8
# (Pantheon). It lists your saved Remmina connection profiles in the panel and
# launches them.
#
# elementary runs no StatusNotifierWatcher, so Remmina's own tray applet
# (remmina -i) can never appear. Generic tray hosts draw a foreign dbusmenu
# popup that GDK cannot assign to a monitor on Wayland, so it renders blurry and
# unthemed. This indicator uses wingpanel's own popover instead, so it inherits
# the panel's scale factor and elementary styling.
#
# Usage:  ./install-remmina-indicator.sh              install
#         ./install-remmina-indicator.sh --revert     uninstall
#         ./install-remmina-indicator.sh --no-install  build only (no sudo)
#
set -euo pipefail

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

PLUGIN=libwingpanel-indicator-remmina.so

# Restart wingpanel by resolving /proc/PID/exe. Never match on the command line:
# that also matches this script and would kill it.
restart_wingpanel() {
    local pid ex
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        ex=$(readlink "$p/exe" 2>/dev/null) || continue
        case "$ex" in
            *io.elementary.wingpanel*) kill "$pid" 2>/dev/null || true ;;
        esac
    done
    sleep 3
}

# ------------------------------------------------------------------- revert
if [ "${1:-}" = "--revert" ]; then
    dir=$(pkg-config --variable=indicatorsdir wingpanel 2>/dev/null \
          || echo /usr/lib/x86_64-linux-gnu/wingpanel)
    [ -e "$dir/$PLUGIN" ] || die "Not installed: $dir/$PLUGIN"
    sudo rm -f "$dir/$PLUGIN"
    say "Removed $dir/$PLUGIN"
    restart_wingpanel
    say "Done."
    exit 0
fi

BUILD_ONLY=0
[ "${1:-}" = "--no-install" ] && BUILD_ONLY=1

# ---------------------------------------------------------------- preflight
say "Checking system"
[ -r /etc/os-release ] && . /etc/os-release
[ "${ID:-}" = "elementary" ] || warn "Not elementary OS (ID=${ID:-?}); continuing anyway."
command -v /usr/bin/io.elementary.wingpanel >/dev/null \
    || die "wingpanel not found -- is this a Pantheon desktop?"

if ! command -v remmina >/dev/null \
   && ! flatpak info org.remmina.Remmina >/dev/null 2>&1; then
    warn "Remmina does not appear to be installed."
    warn "The indicator will stay hidden until it is."
fi

# ------------------------------------------------------------- build deps
need=0
for m in wingpanel granite gtk+-3.0 glib-2.0 gobject-2.0 gio-2.0; do
    pkg-config --exists "$m" 2>/dev/null || need=1
done
for c in valac meson ninja; do command -v $c >/dev/null || need=1; done

if [ "$need" = 1 ]; then
    [ "$BUILD_ONLY" = 1 ] && die "Build dependencies missing (and --no-install given)."
    say "Installing build dependencies (needs your password)"
    # granite (6) is required, NOT granite-7: wingpanel 8 is GTK3 and links
    # libgranite.so.6. granite-7 is the GTK4 build and is the wrong one here.
    sudo apt-get install -y meson ninja-build valac libwingpanel-dev \
        libgranite-dev libglib2.0-dev libgtk-3-dev pkg-config
else
    say "Build dependencies already present"
fi

pkg-config --exists granite 2>/dev/null \
    || die "pkg-config cannot find 'granite' (granite 6). Install libgranite-dev."

# ------------------------------------------------------------------ sources
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"

cat > "$WORK/meson.build" <<'MESON_EOF'
project(
    'wingpanel-indicator-remmina', 'vala', 'c',
    version: '1.0.0',
    meson_version: '>=0.58'
)

gtk_dep = dependency('gtk+-3.0')
granite_dep = dependency('granite')
wingpanel_dep = dependency('wingpanel')
glib_dep = dependency('glib-2.0')
gobject_dep = dependency('gobject-2.0')
gio_dep = dependency('gio-2.0')

# Ask wingpanel itself where indicators belong, rather than hardcoding a path.
indicatorsdir = wingpanel_dep.get_variable(pkgconfig: 'indicatorsdir')

shared_module(
    meson.project_name(),
    'src/Indicator.vala',
    dependencies: [gtk_dep, granite_dep, wingpanel_dep, glib_dep, gobject_dep, gio_dep],
    install: true,
    install_dir: indicatorsdir
)
MESON_EOF

cat > "$WORK/src/Indicator.vala" <<'VALA_EOF'
/*
 * Wingpanel indicator for Remmina.
 *
 * Lists the saved Remmina connection profiles in wingpanel's own popover and
 * launches them. Using wingpanel's popover (rather than the app's dbusmenu via
 * a StatusNotifierItem host) means the menu is drawn by the panel itself, so it
 * picks up the panel's scale factor and elementary styling instead of being
 * rendered blurry and unthemed.
 */

public class RemminaIndicator : Wingpanel.Indicator {
    // Where Remmina keeps *.remmina profiles, and how to launch it. The flatpak
    // build is checked first because that is what is installed here; a distro
    // package is supported as a fallback.
    private const string FLATPAK_ID = "org.remmina.Remmina";

    private Gtk.Image? icon = null;
    private Gtk.Box? main_box = null;
    private Gtk.Box? profiles_box = null;

    private string profile_dir;
    private bool is_flatpak;

    public RemminaIndicator () {
        Object (code_name: "remmina-indicator");
    }

    construct {
        var flatpak_dir = Path.build_filename (
            Environment.get_home_dir (), ".var", "app", FLATPAK_ID, "data", "remmina"
        );
        var native_dir = Path.build_filename (
            Environment.get_user_data_dir (), "remmina"
        );

        if (FileUtils.test (flatpak_dir, FileTest.IS_DIR)) {
            profile_dir = flatpak_dir;
            is_flatpak = true;
        } else {
            profile_dir = native_dir;
            is_flatpak = false;
        }

        // Only show the indicator if Remmina is actually installed.
        visible = FileUtils.test (profile_dir, FileTest.IS_DIR)
            || Environment.find_program_in_path ("remmina") != null;
    }

    public override Gtk.Widget get_display_widget () {
        if (icon == null) {
            // Remmina ships org.remmina.Remmina-symbolic via its flatpak icon
            // export, which is on XDG_DATA_DIRS. Fall back to a stock icon if
            // it is not in the theme.
            var theme = Gtk.IconTheme.get_default ();
            var icon_name = theme.has_icon ("org.remmina.Remmina-symbolic")
                ? "org.remmina.Remmina-symbolic"
                : "preferences-desktop-remote-desktop-symbolic";

            icon = new Gtk.Image.from_icon_name (icon_name, Gtk.IconSize.MENU);
            icon.tooltip_text = "Remmina";
        }

        return icon;
    }

    public override Gtk.Widget? get_widget () {
        if (main_box == null) {
            profiles_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);

            var new_button = make_button ("Nieuwe verbinding", "list-add-symbolic");
            new_button.clicked.connect (() => {
                launch_remmina ({ "-n" });
            });

            var main_window_button = make_button ("Hoofdvenster openen", "window-new-symbolic");
            main_window_button.clicked.connect (() => {
                launch_remmina ({});
            });

            var prefs_button = make_button ("Voorkeuren", "preferences-system-symbolic");
            prefs_button.clicked.connect (() => {
                launch_remmina ({ "-p", "0" });
            });

            main_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            main_box.width_request = 260;
            main_box.add (profiles_box);
            main_box.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
            main_box.add (new_button);
            main_box.add (main_window_button);
            main_box.add (prefs_button);
            main_box.show_all ();
        }

        return main_box;
    }

    // Rebuild the profile list every time the popover opens, so profiles added
    // or removed in Remmina show up without restarting the panel.
    public override void opened () {
        refresh_profiles ();
    }

    public override void closed () { }

    private Gtk.ModelButton make_button (string label, string icon_name) {
        var button = new Gtk.ModelButton ();
        button.text = label;
        button.get_child ().destroy ();

        var image = new Gtk.Image.from_icon_name (icon_name, Gtk.IconSize.MENU);
        var text = new Gtk.Label (label) {
            halign = Gtk.Align.START,
            hexpand = true,
            ellipsize = Pango.EllipsizeMode.END
        };

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        box.add (image);
        box.add (text);
        button.add (box);

        return button;
    }

    private void refresh_profiles () {
        if (profiles_box == null) {
            return;
        }

        foreach (unowned Gtk.Widget child in profiles_box.get_children ()) {
            profiles_box.remove (child);
        }

        var profiles = read_profiles ();

        if (profiles.length () == 0) {
            var empty = new Gtk.Label ("Geen verbindingen") {
                halign = Gtk.Align.START,
                margin_start = 12,
                margin_end = 12,
                margin_top = 6,
                margin_bottom = 6,
                sensitive = false
            };
            profiles_box.add (empty);
        } else {
            foreach (var profile in profiles) {
                var subtitle = profile.protocol;
                if (profile.server != "") {
                    subtitle = "%s · %s".printf (profile.protocol, profile.server);
                }

                var button = make_button (profile.name, "network-workgroup-symbolic");
                button.tooltip_text = subtitle;

                var path = profile.path;
                button.clicked.connect (() => {
                    launch_remmina ({ "-c", path });
                });

                profiles_box.add (button);
            }
        }

        profiles_box.show_all ();
    }

    private class Profile {
        public string name;
        public string protocol;
        public string server;
        public string path;
    }

    private List<Profile> read_profiles () {
        var result = new List<Profile> ();

        Dir dir;
        try {
            dir = Dir.open (profile_dir);
        } catch (FileError e) {
            debug ("Remmina profile directory unavailable: %s", e.message);
            return result;
        }

        string? entry;
        while ((entry = dir.read_name ()) != null) {
            if (!entry.has_suffix (".remmina")) {
                continue;
            }

            var path = Path.build_filename (profile_dir, entry);
            var key_file = new KeyFile ();

            try {
                key_file.load_from_file (path, KeyFileFlags.NONE);
            } catch (Error e) {
                warning ("Could not read Remmina profile %s: %s", path, e.message);
                continue;
            }

            var profile = new Profile ();
            profile.path = path;
            profile.name = read_key (key_file, "name");
            profile.protocol = read_key (key_file, "protocol");
            profile.server = read_key (key_file, "server");

            if (profile.name == "") {
                profile.name = entry.substring (0, entry.length - ".remmina".length);
            }

            result.append (profile);
        }

        result.sort ((a, b) => a.name.collate (b.name));

        return result;
    }

    private static string read_key (KeyFile key_file, string key) {
        try {
            return key_file.get_string ("remmina", key);
        } catch (Error e) {
            return "";
        }
    }

    private void launch_remmina (string[] args) {
        string[] argv;

        if (is_flatpak) {
            argv = { "flatpak", "run", FLATPAK_ID };
        } else {
            argv = { "remmina" };
        }

        foreach (var arg in args) {
            argv += arg;
        }

        try {
            Process.spawn_async (
                null, argv, null,
                SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL,
                null, null
            );
        } catch (SpawnError e) {
            warning ("Could not launch Remmina: %s", e.message);
        }

        close ();
    }
}

public Wingpanel.Indicator? get_indicator (Module module,
                                           Wingpanel.IndicatorManager.ServerType server_type) {
    // Nothing useful to show on the login screen.
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }

    return new RemminaIndicator ();
}
VALA_EOF

# ------------------------------------------------------------------- build
say "Building"
meson setup "$WORK/build" "$WORK" --prefix=/usr >"$WORK/meson.log" 2>&1 \
    || { tail -25 "$WORK/meson.log"; die "meson setup failed."; }
ninja -C "$WORK/build" >"$WORK/build.log" 2>&1 \
    || { grep -E "error:" "$WORK/build.log" | head -20; die "Build failed."; }
say "Built $(basename "$(find "$WORK/build" -name '*.so' | head -1)")"

if [ "$BUILD_ONLY" = 1 ]; then
    say "--no-install given; stopping before install."
    exit 0
fi

# ----------------------------------------------------------------- install
say "Installing (needs your password)"
sudo ninja -C "$WORK/build" install >/dev/null

dir=$(pkg-config --variable=indicatorsdir wingpanel)
[ -e "$dir/$PLUGIN" ] || die "Install did not produce $dir/$PLUGIN"

say "Restarting wingpanel"
restart_wingpanel

for p in /proc/[0-9]*; do
    ex=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$ex" in *io.elementary.wingpanel*)
        if grep -q 'indicator-remmina' "$p/maps" 2>/dev/null; then
            say "Success -- the Remmina indicator is loaded."
            echo
            echo "  Click the Remmina icon in the panel to see your connections."
            echo "  Revert: $0 --revert"
            exit 0
        fi
    ;; esac
done

warn "Installed, but the panel does not show it loaded yet."
warn "Try logging out and back in. To undo: $0 --revert"
