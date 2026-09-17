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
