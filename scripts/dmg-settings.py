# dmgbuild settings for the T3 Notch DMG. scripts/make-dmg.sh passes the paths with -D.
# dmgbuild writes the Finder layout (.DS_Store) itself, so no Finder or GUI session is needed.
# The icon positions must match the arrow in scripts/dmg-background.swift.
import os.path

application = defines["app"]
appname = os.path.basename(application)

# APFS with LZFSE (ULFO): the fastest to open. Both need macOS 10.13 or later, and the app
# needs macOS 26.
format = "ULFO"
filesystem = "APFS"

files = [application]
symlinks = {"Applications": "/Applications"}
hide_extensions = [appname]

# The volume icon, shown on the desktop and in the Finder sidebar while the DMG is mounted.
icon = defines["volume_icon"]

# dmgbuild finds dmg-background@2x.png next to this file and makes a Retina TIFF of both.
background = defines["background"]

# The window is as big as the background, in points, plus the 32 pt title bar.
window_rect = ((200, 140), (660, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
icon_size = 128
text_size = 13
icon_locations = {
    appname: (180, 196),
    "Applications": (480, 196),
}
