# Wingpanel indicator for Remmina

A native wingpanel indicator that lists your saved Remmina connection profiles
and launches them, for elementary OS 8 (Pantheon, Wayland).

## Why native rather than a tray-icon host

Remmina ships its own applet (`remmina -i`), which appears on other desktops
because they display StatusNotifierItem/AppIndicator tray icons. elementary
dropped that support — no `StatusNotifierWatcher` runs at all.

The obvious route is a generic tray host such as
[wingpanel-indicator-appicontray](https://github.com/barunespadhy/wingpanel-indicator-appicontray).
That was tried first and needed two Wayland fixes (see *Notes* below), but its
menu is drawn as a foreign GTK `dbusmenu` popup: GDK could not resolve the
popup's monitor (`gdk_wayland_display_get_monitor_at_window` assertion failed),
so it fell back to the wrong scale factor and rendered visibly blurry and
unthemed next to the built-in indicators.

This indicator instead hands its content to **wingpanel's own popover**, the
same one the sound indicator uses, so it inherits the panel's scale factor and
elementary styling.

## What it does

Reads `*.remmina` profiles directly and shows them by name (protocol · server
as tooltip):

- a profile → `remmina -c <profile>`
- **Nieuwe verbinding** → `remmina -n`
- **Hoofdvenster openen** → `remmina`
- **Voorkeuren** → `remmina -p 0`

The list is rebuilt whenever the popover opens, so profiles added or removed in
Remmina appear without restarting the panel. Flatpak and distro installs of
Remmina are both detected; the indicator hides itself if Remmina is absent.

Profiles are read from `~/.var/app/org.remmina.Remmina/data/remmina` (flatpak)
or `$XDG_DATA_HOME/remmina` (distro package).

## Installing on another machine

Copy **one file** -- `install-remmina-indicator.sh` -- to the other machine
and run it:

    ./install-remmina-indicator.sh              # install
    ./install-remmina-indicator.sh --revert     # uninstall
    ./install-remmina-indicator.sh --no-install # build only, no sudo

The meson and Vala sources are embedded in the script, so nothing else is
needed. It checks the system, installs build dependencies if they are missing
(one password prompt), builds, installs to wingpanel's `indicatorsdir`,
restarts the panel and confirms the indicator actually loaded.

Requirements: elementary OS 8 with Pantheon. Remmina need not be installed yet
-- the indicator simply stays hidden until it is.

## Build and install

    sudo apt-get install -y meson ninja-build valac libwingpanel-dev \
        libgranite-dev libglib2.0-dev libgtk-3-dev pkg-config

    meson setup build --prefix=/usr
    ninja -C build
    sudo ninja -C build install

Then restart the panel (it is respawned automatically):

    pkill -x -f io.elementary.wingpanel

Note `libgranite-dev` is granite **6** — wingpanel 8 is GTK3 and links
`libgranite.so.6`. Granite 7 is the GTK4 build and is the wrong one here.

The plugin installs to wingpanel's own `indicatorsdir` (queried from its
pkg-config file, currently `/usr/lib/x86_64-linux-gnu/wingpanel`).

### Uninstall

    sudo rm /usr/lib/x86_64-linux-gnu/wingpanel/libwingpanel-indicator-remmina.so
    pkill -x -f io.elementary.wingpanel

## Notes

Labels are Dutch, matching Remmina's own menu wording on this system.

If you also want tray icons from *other* apps, the appicontray route needs two
fixes, both worth reporting upstream:

1. `DbusmenuGtk.Menu` is never attached to a widget, so on Wayland GDK has no
   parent surface for the menu's `xdg_popup` and `popup_at_pointer()` silently
   fails.
2. The tray icon sets a tooltip, and a shown tooltip is itself a popup surface.
   While it is mapped the panel is no longer the top-most surface, so GDK
   refuses the menu with *"Tried to map a popup with a non-top most parent"*.
   The tooltip has to be dropped before showing the menu.

Its items are also menu-only: Remmina's `org.kde.StatusNotifierItem` exposes no
`Activate` method, so left-click must fall back to opening the menu.
