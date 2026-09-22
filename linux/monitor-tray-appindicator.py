#!/usr/bin/env python3
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except ValueError:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator


def run_action(action):
    subprocess.Popen(["/bin/sh", "-c", action])


def build_menu():
    menu = Gtk.Menu()
    for entry in os.environ.get("MONITOR_TRAY_MENU", "").split("|"):
        if not entry:
            continue
        parts = entry.rsplit("!", 2)
        if len(parts) != 3:
            continue
        label, action, icon = parts
        item = Gtk.MenuItem.new_with_label(label)
        if action == "quit":
            item.connect("activate", lambda *_: Gtk.main_quit())
        else:
            item.connect("activate", lambda _, command=action: run_action(command))
        menu.append(item)
    menu.show_all()
    return menu


def main():
    indicator = AppIndicator.Indicator.new(
        "monitor-switch",
        "video-display",
        AppIndicator.IndicatorCategory.APPLICATION_STATUS,
    )
    indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
    indicator.set_title(os.environ.get("MONITOR_TRAY_TEXT", "Monitor input"))
    indicator.set_menu(build_menu())
    Gtk.main()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
