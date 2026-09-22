#!/usr/bin/env python3
import json
import re
import subprocess
import sys
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk


ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "config.json"


class MonitorControl:
    def __init__(self):
        self.config = self.load_config()
        self.bus = None
        self.refreshing = False
        self.pending = {}
        self.sliders = {}
        self.combos = {}
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_monospace(True)
        self.status = Gtk.Label(xalign=0)
        self.window = Gtk.Window(title=f"{self.config.get('monitor', 'Monitor')} - Controle DDC/CI")
        self.window.set_default_size(820, 700)
        self.window.set_border_width(10)
        self.window.connect("destroy", Gtk.main_quit)
        self.build_window()
        GLib.timeout_add(200, self.flush_pending)
        GLib.idle_add(self.refresh)

    @staticmethod
    def load_config():
        try:
            return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {"inputs": {"HDMI": 6, "DP": 9}}

    def log(self, message):
        timestamp = GLib.DateTime.new_now_local().format("%H:%M:%S")
        buffer = self.log_view.get_buffer()
        buffer.insert(buffer.get_end_iter(), f"[{timestamp}] {message}\n")
        buffer.place_cursor(buffer.get_end_iter())
        mark = buffer.create_mark(None, buffer.get_end_iter(), False)
        self.log_view.scroll_to_mark(mark, 0.0, True, 0.0, 1.0)

    def run(self, args, check=False):
        try:
            return subprocess.run(args, capture_output=True, text=True, timeout=20, check=check)
        except (OSError, subprocess.SubprocessError) as exc:
            self.log(f"Falha ao executar {' '.join(args)}: {exc}")
            return None

    def find_bus(self):
        result = self.run(["ddcutil", "detect", "--terse"])
        if result:
            match = re.search(r"/dev/i2c-(\d+)", result.stdout)
            self.bus = match.group(1) if match else None
        else:
            self.bus = None
        return self.bus

    def read_vcp(self, code):
        if self.bus is None and self.find_bus() is None:
            return None
        result = self.run(["ddcutil", "--bus", self.bus, "getvcp", f"{code:02X}", "--terse"])
        if not result or result.returncode != 0:
            return None
        fields = result.stdout.split()
        if len(fields) < 4 or fields[0] != "VCP":
            return None
        try:
            current = int(fields[3].removeprefix("x"), 16) if fields[3].startswith("x") else int(fields[3])
            maximum = int(fields[4].removeprefix("x"), 16) if len(fields) > 4 and fields[4].startswith("x") else int(fields[4])
            return current, maximum
        except (ValueError, IndexError):
            return None

    def write_vcp(self, code, value, description):
        if self.bus is None and self.find_bus() is None:
            return False
        result = self.run(["ddcutil", "--bus", self.bus, "setvcp", f"{code:02X}", str(value), "--noverify"])
        ok = bool(result and result.returncode == 0)
        self.log(f"{description}: 0x{code:02X} <- {value} (0x{value:02X}) {'ok' if ok else 'FALHOU'}")
        return ok

    def label(self, text, width=220):
        widget = Gtk.Label(label=text, xalign=0)
        widget.set_size_request(width, -1)
        return widget

    def row(self, parent, label, widget):
        box = Gtk.Box(spacing=8)
        box.pack_start(self.label(label), False, False, 0)
        box.pack_start(widget, True, True, 0)
        parent.pack_start(box, False, False, 5)
        return box

    def add_slider(self, parent, label, code):
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 100, 1)
        scale.set_hexpand(True)
        scale.set_digits(0)
        spin = Gtk.SpinButton.new_with_range(0, 100, 1)
        spin.set_width_chars(5)
        self.sliders[code] = (scale, spin, label)

        def changed(widget):
            if self.refreshing:
                return
            value = int(widget.get_value())
            if widget is scale:
                spin.set_value(value)
            else:
                scale.set_value(value)
            self.pending[code] = value

        scale.connect("value-changed", changed)
        spin.connect("value-changed", changed)
        box = Gtk.Box(spacing=8)
        box.pack_start(self.label(label), False, False, 0)
        box.pack_start(scale, True, True, 0)
        box.pack_start(spin, False, False, 0)
        parent.pack_start(box, False, False, 4)

    def add_combo(self, parent, label, code, values):
        combo = Gtk.ComboBoxText()
        for value, text in values:
            combo.append(str(value), f"{value:3d}  (0x{value:02X})  {text}")
        button = Gtk.Button(label="Aplicar")
        button.set_tooltip_text("Aplicar o valor selecionado")
        button.connect("clicked", lambda *_: self.apply_combo(code, label))
        self.combos[code] = (combo, values)
        box = Gtk.Box(spacing=8)
        box.pack_start(self.label(label), False, False, 0)
        box.pack_start(combo, True, True, 0)
        box.pack_start(button, False, False, 0)
        parent.pack_start(box, False, False, 4)

    def apply_combo(self, code, label):
        combo, _ = self.combos[code]
        value = combo.get_active_id()
        if value is not None:
            self.write_vcp(code, int(value), label)

    def make_tab(self, notebook, title):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        page.set_border_width(10)
        notebook.append_page(page, Gtk.Label(label=title))
        return page

    def build_window(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        notebook = Gtk.Notebook()
        root.pack_start(notebook, True, True, 0)
        self.build_image_tab(self.make_tab(notebook, "Entrada e imagem"))
        self.build_color_tab(self.make_tab(notebook, "Cor e modo"))
        self.build_system_tab(self.make_tab(notebook, "Sistema"))
        self.build_advanced_tab(self.make_tab(notebook, "Avançado"))

        refresh = Gtk.Button(label="Atualizar valores do monitor")
        refresh.connect("clicked", lambda *_: self.refresh())
        root.pack_start(refresh, False, False, 0)
        root.pack_start(self.status, False, False, 0)
        log_scroll = Gtk.ScrolledWindow()
        log_scroll.set_min_content_height(110)
        log_scroll.add(self.log_view)
        root.pack_start(log_scroll, False, True, 0)
        self.window.add(root)
        self.window.show_all()

    def build_image_tab(self, page):
        page.pack_start(self.label("Fonte de entrada", 500), False, False, 0)
        inputs = self.config.get("inputs", {"HDMI": 6, "DP": 9})
        input_box = Gtk.Box(spacing=8)
        for name, value in inputs.items():
            button = Gtk.Button(label=f"{name}  (0x{int(value):02X})")
            button.connect("clicked", lambda _, n=name: self.change_input(n))
            input_box.pack_start(button, False, False, 0)
        page.pack_start(input_box, False, False, 4)
        page.pack_start(self.label("Ajustes de imagem", 500), False, False, 8)
        for label, code in (("Brilho (0x10)", 0x10), ("Contraste (0x12)", 0x12), ("Nitidez (0x87)", 0x87),
                            ("Ganho R (0x16)", 0x16), ("Ganho G (0x18)", 0x18), ("Ganho B (0x1A)", 0x1A)):
            self.add_slider(page, label, code)

    def build_color_tab(self, page):
        self.add_combo(page, "Preset de cor (0x14)", 0x14, [(1, "sRGB"), (2, "Nativo / Normal"), (3, "4000K"),
                       (4, "5000K"), (5, "6500K"), (6, "7500K"), (8, "9300K"), (11, "Usuario 1"), (12, "Usuario 2")])
        self.add_combo(page, "Modo de imagem (0xDC)", 0xDC, [(i, text) for i, text in enumerate(("Padrao", "Produtividade", "Misto", "Filme", "Usuario", "Jogo"))])
        languages = [(1, "Chines (trad.)"), (2, "Ingles"), (3, "Frances"), (4, "Alemao"), (5, "Italiano"), (6, "Japones"),
                     (7, "Coreano"), (8, "Portugues (Portugal)"), (9, "Russo"), (10, "Espanhol"), (14, "Portugues (Brasil)"), (15, "Arabe")]
        self.add_combo(page, "Idioma OSD (0xCC)", 0xCC, languages)
        for code in (0xE0, 0xE1, 0xE2):
            self.add_combo(page, f"0x{code:02X} Samsung", code, [(i, str(i)) for i in range(6)])
        self.add_combo(page, "0xE5 Samsung", 0xE5, [(0, "Desligado"), (1, "Ligado")])
        self.add_combo(page, "0xE6 Samsung", 0xE6, [(0, "Desligado"), (1, "Ligado")])
        self.add_combo(page, "0xF3 Samsung", 0xF3, [(i, str(i)) for i in range(3)])
        self.add_combo(page, "0xF7 Samsung", 0xF7, [(i, str(i)) for i in range(4)])

    def build_system_tab(self, page):
        page.pack_start(self.label("Energia (VCP 0xD6)"), False, False, 0)
        buttons = Gtk.Box(spacing=8)
        for text, value, confirm in (("Ligar (1)", 1, False), ("Standby (4)", 4, True), ("Desligar (5)", 5, True)):
            button = Gtk.Button(label=text)
            button.connect("clicked", lambda _, v=value, c=confirm: self.power(v, c))
            buttons.pack_start(button, False, False, 0)
        page.pack_start(buttons, False, False, 5)
        page.pack_start(self.label("Restaurar padroes"), False, False, 10)
        for text, code, description in (("Brilho e contraste de fabrica", 0x05, "Restaurar brilho/contraste"),
                                        ("Cores de fabrica", 0x08, "Restaurar cores"),
                                        ("TUDO de fabrica", 0x04, "Restaurar tudo"),
                                        ("Salvar ajustes atuais", 0xB0, "Salvar ajustes")):
            button = Gtk.Button(label=text)
            button.connect("clicked", lambda _, c=code, d=description: self.write_vcp(c, 1, d))
            page.pack_start(button, False, False, 3)
        page.pack_start(self.label("Informacoes"), False, False, 10)
        self.info = Gtk.Label(xalign=0)
        self.info.set_selectable(True)
        page.pack_start(self.info, False, False, 0)

    def build_advanced_tab(self, page):
        page.pack_start(self.label("Enviar qualquer codigo VCP em hexadecimal."), False, False, 0)
        fields = Gtk.Box(spacing=8)
        code = Gtk.Entry(); code.set_text("60"); code.set_width_chars(6)
        value = Gtk.Entry(); value.set_text("09"); value.set_width_chars(6)
        fields.pack_start(self.label("Codigo"), False, False, 0); fields.pack_start(code, False, False, 0)
        fields.pack_start(self.label("Valor"), False, False, 0); fields.pack_start(value, False, False, 0)
        read = Gtk.Button(label="Ler")
        send = Gtk.Button(label="Enviar")
        read.connect("clicked", lambda *_: self.manual_read(code, value))
        send.connect("clicked", lambda *_: self.manual_write(code, value))
        fields.pack_start(read, False, False, 0); fields.pack_start(send, False, False, 0)
        page.pack_start(fields, False, False, 8)
        scan = Gtk.Button(label="Varrer todos os codigos legiveis (0x00-0xFF)")
        scan.connect("clicked", lambda *_: self.scan())
        page.pack_start(scan, False, False, 3)
        caps = Gtk.Button(label="Mostrar capabilities")
        caps.connect("clicked", lambda *_: self.show_capabilities())
        page.pack_start(caps, False, False, 3)
        page.pack_start(self.label("Referencia: 0x10 brilho, 0x12 contraste, 0x14 preset, 0x60 entrada, 0xD6 energia."), False, False, 12)

    def change_input(self, name):
        script = Path(__file__).resolve().parent / "set-monitor-input.sh"
        result = self.run([str(script), "--notify", name])
        count = result.stdout.strip() if result else "0"
        self.log(f"Entrada -> {name}: comando aceito por {count} monitor(es)")

    def power(self, value, confirm):
        if confirm:
            dialog = Gtk.MessageDialog(self.window, Gtk.DialogFlags.MODAL, Gtk.MessageType.WARNING,
                                       Gtk.ButtonsType.YES_NO, "Confirmar alteracao de energia?")
            response = dialog.run(); dialog.destroy()
            if response != Gtk.ResponseType.YES:
                return
        self.write_vcp(0xD6, value, f"Energia: {value}")

    def refresh(self):
        self.refreshing = True
        if self.find_bus() is None:
            self.status.set_text("Monitor nao encontrado ou DDC/CI desligado")
            self.refreshing = False
            return False
        for code, (scale, spin, _) in self.sliders.items():
            result = self.read_vcp(code)
            if result:
                current, maximum = result
                scale.set_range(0, max(1, maximum)); spin.set_range(0, max(1, maximum))
                scale.set_value(min(current, maximum)); spin.set_value(min(current, maximum))
        for code, (combo, _) in self.combos.items():
            result = self.read_vcp(code)
            if result:
                combo.set_active_id(str(result[0]))
        info = []
        for code, name in ((0xC9, "Firmware"), (0xC8, "Controlador"), (0xDF, "Versao MCCS"), (0xD6, "Energia"), (0x60, "Entrada")):
            result = self.read_vcp(code)
            if result:
                info.append(f"{name}: 0x{code:02X} = {result[0]} (max {result[1]})")
        self.info.set_text("\n".join(info))
        self.status.set_text(f"Monitor /dev/i2c-{self.bus} respondendo")
        self.refreshing = False
        return False

    def flush_pending(self):
        pending, self.pending = self.pending, {}
        for code, value in pending.items():
            self.write_vcp(code, value, self.sliders[code][2])
        return True

    def manual_read(self, code_entry, value_entry):
        try:
            code = int(code_entry.get_text(), 16)
            result = self.read_vcp(code)
            self.log(f"Leitura 0x{code:02X}: {result or 'monitor nao respondeu'}")
        except ValueError:
            self.log("Codigo invalido")

    def manual_write(self, code_entry, value_entry):
        try:
            self.write_vcp(int(code_entry.get_text(), 16), int(value_entry.get_text(), 16), "Manual")
        except ValueError:
            self.log("Codigo ou valor invalido")

    def scan(self):
        self.log("Varrendo 0x00-0xFF...")
        found = 0
        for code in range(256):
            result = self.read_vcp(code)
            if result:
                self.log(f"0x{code:02X}: atual={result[0]} max={result[1]}")
                found += 1
        self.log(f"Varredura concluida: {found} codigos respondem.")

    def show_capabilities(self):
        if self.bus is None and self.find_bus() is None:
            return
        result = self.run(["ddcutil", "--bus", self.bus, "capabilities"])
        self.log(result.stdout.strip() if result and result.stdout else "Falha ao ler capabilities")

    def run_loop(self):
        Gtk.main()


if __name__ == "__main__":
    MonitorControl().run_loop()
