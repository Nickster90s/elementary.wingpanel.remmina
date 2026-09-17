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
