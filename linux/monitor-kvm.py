#!/usr/bin/env python3
"""monitor-kvm.py - "seguir o KVM" com conversa entre os dois PCs (so biblioteca padrao).

Observa o teclado-sentinela atras do KVM (udevadm monitor, ou polling) e troca a entrada do monitor:
  sentinela SAIU   -> kvm.onLeave  (a entrada do outro PC)
  sentinela VOLTOU -> kvm.onArrive (a entrada deste PC)
e conversa com o outro PC por UDP (bloco "peer" do config.json), com a regra "o PC que tem o teclado e o dono
do monitor":
  - so manda o monitor para o outro PC se ele estiver vivo e com o monitor conectado; senao o monitor fica
    aqui (mandar para uma entrada sem sinal faz o monitor dormir e parar de responder pelas duas entradas);
  - quando o outro PC fica pronto (acordou, ligou, voltou para a dock) e o teclado esta com ele, o monitor vai
    para ele sozinho;
  - quem recebe o teclado pede ao PC que esta na tela para trocar (o monitor sempre atende a entrada ativa).

Uso (normalmente via monitor-kvm.sh / servico systemd de usuario):
  monitor-kvm.py                 roda em primeiro plano
  monitor-kvm.py --tell-peer X   pede ao outro PC que mande o monitor para X (usado por set-monitor-input.sh)
  monitor-kvm.py --peer-status   mostra o que se sabe do outro PC
Protocolo: datagramas "MSW1 " + JSON: hello (a cada 5 s), bye, switch. Ver README.
"""
import json
import os
import selectors
import signal
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
PROTO = b"MSW1 "
HELLO_EVERY = 5.0
CLAIM_DELAY = 3.0
RETRY_AFTER = (1.5, 4.0, 8.0, 15.0)   # segundos apos a primeira tentativa, quando nenhum monitor aceitou
DEDUPE_SEC = 3.0                      # o mesmo comando repetido dentro desse prazo nao e reenviado
RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
STATE_FILE = os.path.join(RUNTIME, "monitor-peer.json")
SEEN_FILE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "monitor-switch", "peer-seen")


# ---------------------------------------------------------------- configuracao (mesmas regras do ddcci.sh)
def config_path():
    env = os.environ.get("DDC_CONFIG")
    if env and os.path.isfile(env):
        return env
    local = os.path.join(HERE, "config.json")
    return local if os.path.isfile(local) else os.path.join(HERE, "..", "config.json")


def load_config():
    try:
        with open(config_path(), encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def _dig(d, keys):
    for k in keys:
        if not isinstance(d, dict) or k not in d:
            return None
        d = d[k]
    return d


def cfg_get(cfg, *keys, default=None):
    """Valor de config.json; o bloco de topo "linux" sobrescreve qualquer chave neste PC."""
    for v in (_dig(cfg, ("linux",) + keys), _dig(cfg, keys)):
        if v is not None and v != "":
            return v
    return default


KVM_DEFAULTS = {"enabled": False, "sentinel": "USB\\VID_046D&PID_C33A", "onLeave": "DP", "onArrive": "HDMI", "delayMs": 400}
PEER_DEFAULTS = {"enabled": True, "port": 47321, "host": "", "timeoutSec": 15, "key": ""}


def kvm_cfg(cfg, key):
    v = _dig(cfg, ("kvm", "linux", key))     # kvm.linux.<chave> tem prioridade, como no ddcci.sh
    if v is None or v == "":
        v = cfg_get(cfg, "kvm", key, default=KVM_DEFAULTS[key])
    return v


def peer_cfg(cfg, key):
    return cfg_get(cfg, "peer", key, default=PEER_DEFAULTS[key])


def as_bool(v):
    return v is True or str(v).lower() in ("true", "1", "yes", "on")


def inputs(cfg):
    d = cfg_get(cfg, "inputs")
    return d if isinstance(d, dict) and d else {"HDMI": 6, "DP": 9}


def log_file(cfg):
    f = str(cfg_get(cfg, "logFile", default="logs/monitor.log")).replace("\\", "/")
    return f if f.startswith("/") else os.path.join(os.path.dirname(os.path.abspath(config_path())), f)


def log(cfg, msg):
    """Mesmo formato e rotacao (1 MB) do ddc_log; nunca falha."""
    try:
        f = log_file(cfg)
        os.makedirs(os.path.dirname(f), exist_ok=True)
        if os.path.isfile(f) and os.path.getsize(f) > 1048576:
            os.replace(f, f + ".old")
        with open(f, "a", encoding="utf-8") as fh:
            fh.write("%s  %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except OSError:
        pass


def monitor_title(cfg):
    v = str(cfg_get(cfg, "monitor", default=""))
    if v and v.lower() != "auto":
        return v
    try:
        with open(os.path.join(RUNTIME, "monitor-input.name"), encoding="utf-8") as f:
            return f.read().strip() or "Monitor"
    except OSError:
        return "Monitor"


def notify(cfg, text, icon="video-display"):
    try:
        subprocess.Popen(["notify-send", "-a", "monitor-input", "-i", icon, "-t", "1500", monitor_title(cfg), text],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


# ---------------------------------------------------------------- sentinela USB (porte de ddc_device_present)
def usb_ids(sentinel):
    import re
    s = str(sentinel).lower()
    m = re.search(r"vid_([0-9a-f]{4}).*pid_([0-9a-f]{4})", s) or re.match(r"^([0-9a-f]{4}):([0-9a-f]{4})$", s)
    return (m.group(1), m.group(2)) if m else None


def device_present(ids, root=None):
    root = root or os.environ.get("DDC_SYS_USB") or "/sys/bus/usb/devices"
    try:
        names = os.listdir(root)
    except OSError:
        return False
    for n in names:
        try:
            with open(os.path.join(root, n, "idVendor")) as f:
                if f.read().strip() != ids[0]:
                    continue
            with open(os.path.join(root, n, "idProduct")) as f:
                if f.read().strip() == ids[1]:
                    return True
        except OSError:
            continue
    return False


# ---------------------------------------------------------------- DDC/CI via ddcutil (porte de ddc_set_input)
class Ddc:
    """Envia o VCP 0x60 por '--bus N' (poucos ms). Barramentos e conectores DRM detectados uma vez (~0,7 s)."""

    def __init__(self):
        self.buses = None
        self.connectors = []

    def detect(self):
        bus = os.environ.get("DDC_BUS")
        if bus:
            self.buses, self.connectors = [bus], []
            return
        buses, conns, valid, cur_bus = [], [], False, None
        try:
            out = subprocess.run(["ddcutil", "detect", "--terse"], capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        for line in out.splitlines():
            s = line.strip()
            if line.startswith("Display "):
                valid, cur_bus = True, None
            elif line.startswith("Invalid"):
                valid = False
            elif valid and s.startswith("I2C bus:"):
                cur_bus = s.rsplit("i2c-", 1)[-1]
                buses.append(cur_bus)
            elif valid and s.startswith("DRM connector:"):
                conns.append(s.split(":", 1)[1].strip())
        self.buses, self.connectors = buses, conns

    def set_input(self, cfg, name):
        """Envia a todos os displays; retorna quantos aceitaram (0 -> redetecta e tenta de novo uma vez)."""
        val = inputs(cfg).get(name)
        if val is None:
            log(cfg, "entrada desconhecida '%s'" % name)
            return 0
        val = int(str(val), 0) if isinstance(val, str) else int(val)
        sent = self._send(val)
        if sent == 0:
            self.detect()
            sent = self._send(val)
        log(cfg, "entrada -> %s (0x%02X) enviado a %d monitor(es)" % (name, val, sent))
        return sent

    def _send(self, val):
        if self.buses is None:
            self.detect()
        sent = 0
        for b in self.buses:
            try:
                r = subprocess.run(["ddcutil", "--bus", b, "setvcp", "60", str(val), "--noverify"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
                sent += r.returncode == 0
            except (OSError, subprocess.SubprocessError):
                pass
        return sent

    def monitor_attached(self):
        """True se algum conector DRM do monitor DDC esta 'connected'; sem conector conhecido, assume True."""
        if not self.connectors:
            return True
        for c in self.connectors:
            try:
                with open("/sys/class/drm/%s/status" % c) as f:
                    if f.read().strip() == "connected":
                        return True
            except OSError:
                return True
        return False


# ---------------------------------------------------------------- regras (funcao pura, testada em test_monitor_kvm.py)
class State:
    def __init__(self, **kw):
        self.enabled = True          # kvm.enabled
        self.peer_enabled = True     # peer.enabled
        self.kbd = None              # sentinela presente aqui (None = ainda nao lida)
        self.pending = False         # o teclado foi para o outro PC, mas o monitor ficou aqui (outro PC indisponivel)
        self.peer_seen_ever = False  # ja houve contato com o outro PC (marcador em ~/.cache); antes disso, nao exige
        self.peer_ready = False      # outro PC vivo (hello recente, sem bye) e com o monitor conectado
        self.peer_kbd = False        # o outro PC disse que o teclado esta com ele
        self.my_input = "DP"         # kvm.onArrive
        self.peer_input = "HDMI"     # kvm.onLeave
        self.__dict__.update(kw)


def decide(st, event, arg=None):
    """Aplica um evento ao estado e devolve a lista de acoes:
    ('ddc', entrada) envia ao monitor daqui; ('tell', entrada) pede ao outro PC; ('log', texto); ('notify', texto, icone).
    Eventos: kbd_left, kbd_arrived, peer_ready, claim (arg = motivo), switch_req (arg = entrada)."""
    acts = []
    if event == "kbd_left":
        st.kbd = False
        if not st.enabled:
            return [("log", "KVM: teclado saiu (ignorado: kvm.enabled=false)")]
        if st.peer_enabled and st.peer_seen_ever and not st.peer_ready:
            st.pending = True
            return [("log", "KVM: teclado saiu; outro PC indisponivel (dormindo, desligado ou sem monitor): monitor fica em %s" % st.my_input),
                    ("notify", "Outro PC indisponivel: o monitor fica aqui. Ele vai sozinho quando o outro PC voltar.", "dialog-information")]
        st.pending = False
        return [("log", "KVM: teclado saiu"), ("ddc", st.peer_input)]
    if event == "kbd_arrived":
        st.kbd, st.pending = True, False
        if not st.enabled:
            return [("log", "KVM: teclado voltou (ignorado: kvm.enabled=false)")]
        acts = [("log", "KVM: teclado voltou"), ("ddc", st.my_input)]
        if st.peer_enabled:
            acts.append(("tell", st.my_input))
        return acts
    if event == "peer_ready":
        if st.enabled and st.peer_enabled and st.kbd is False and (st.pending or st.peer_kbd):
            st.pending = False
            return [("log", "outro PC pronto com o teclado: monitor -> %s" % st.peer_input), ("ddc", st.peer_input)]
        return []
    if event == "claim":
        if st.enabled and st.kbd:
            acts = [("log", "%s com o teclado aqui: monitor -> %s" % (arg or "reivindicar", st.my_input)), ("ddc", st.my_input)]
            if st.peer_enabled:
                acts.append(("tell", st.my_input))
        return acts
    if event == "switch_req":
        if st.kbd and arg != st.my_input:
            return [("log", "pedido do outro PC para %s ignorado: o teclado esta aqui" % arg)]
        return [("log", "pedido do outro PC: monitor -> %s" % arg), ("ddc", arg)]
    return acts


# ---------------------------------------------------------------- rede
def make_message(t, cfg, **fields):
    d = {"t": t, "id": "%s/linux" % socket.gethostname(), "os": "linux"}
    d.update(fields)
    key = str(peer_cfg(cfg, "key") or "")
    if key:
        d["key"] = key
    return PROTO + json.dumps(d, separators=(",", ":")).encode()


def parse_message(data, cfg, my_id):
    """bytes -> dict, ou None se nao for nosso protocolo, for nossa propria mensagem ou a chave nao conferir."""
    if not data.startswith(PROTO):
        return None
    try:
        d = json.loads(data[len(PROTO):].decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(d, dict) or d.get("id") == my_id:
        return None
    key = str(peer_cfg(cfg, "key") or "")
    if key and d.get("key") != key:
        return None
    return d


def targets(cfg, addr=None):
    port = int(peer_cfg(cfg, "port"))
    out = [("255.255.255.255", port)]
    host = str(peer_cfg(cfg, "host") or "").strip()
    if host:
        out.append((host, port))
    if addr and addr not in [h for h, _ in out]:
        out.append((addr, port))
    return out


def send_all(sock, cfg, payload, addr=None):
    for t in targets(cfg, addr):
        try:
            sock.sendto(payload, t)
        except OSError:
            pass


def read_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


# ---------------------------------------------------------------- daemon
class Daemon:
    def __init__(self):
        self.cfg = load_config()
        self.ids = usb_ids(kvm_cfg(self.cfg, "sentinel"))
        self.ddc = Ddc()
        self.st = State(peer_seen_ever=os.path.isfile(SEEN_FILE))
        self.my_id = "%s/linux" % socket.gethostname()
        self.peer = {}                     # id, addr, last (monotonic), kbd, mon, in, bye
        self.timers = []                   # [(quando, funcao)]
        self.retry_gen = 0
        self.last_sent = (None, 0.0)
        self.warned_never_seen = False
        self.mon = True
        self.suspend_ref = self._suspend_offset()
        self.sock = None
        self.quiet = False

    # -- utilitarios
    def refresh_cfg(self):
        self.cfg = load_config()
        self.st.enabled = as_bool(kvm_cfg(self.cfg, "enabled"))
        self.st.peer_enabled = as_bool(peer_cfg(self.cfg, "enabled"))
        self.st.my_input = str(kvm_cfg(self.cfg, "onArrive"))
        self.st.peer_input = str(kvm_cfg(self.cfg, "onLeave"))
        self.st.peer_ready, self.st.peer_kbd = self.peer_ready(), bool(self.peer.get("kbd"))

    @staticmethod
    def _suspend_offset():
        try:
            return time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()
        except (AttributeError, OSError):
            return 0.0

    def later(self, delay, fn):
        self.timers.append((time.monotonic() + delay, fn))

    def present(self):
        return bool(self.ids) and device_present(self.ids)

    def peer_ready(self):
        p = self.peer
        if not p or p.get("bye"):
            return False
        return time.monotonic() - p.get("last", -1e9) < float(peer_cfg(self.cfg, "timeoutSec")) and bool(p.get("mon"))

    def save_state(self):
        p = self.peer
        d = {"id": p.get("id"), "addr": p.get("addr"), "input": p.get("in"), "kbd": p.get("kbd"), "mon": p.get("mon"),
             "bye": p.get("bye", False), "ready": self.peer_ready(),
             "lastSeen": time.time() - (time.monotonic() - p["last"]) if p.get("last") else None,
             "pending": self.st.pending, "kbdHere": self.st.kbd}
        try:
            tmp = STATE_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(d, f)
            os.replace(tmp, STATE_FILE)
        except OSError:
            pass

    # -- acoes
    def run(self, actions):
        for a in actions:
            if a[0] == "log":
                log(self.cfg, a[1])
            elif a[0] == "notify":
                notify(self.cfg, a[1], a[2] if len(a) > 2 else "video-display")
            elif a[0] == "ddc":
                self.switch(a[1])
            elif a[0] == "tell":
                if self.sock:
                    send_all(self.sock, self.cfg, make_message("switch", self.cfg, to=a[1]), self.peer.get("addr"))
        self.save_state()

    def switch(self, name, attempt=0, gen=None):
        now = time.monotonic()
        if attempt == 0:
            if self.last_sent[0] == name and now - self.last_sent[1] < DEDUPE_SEC:
                return
            self.retry_gen += 1
            gen = self.retry_gen
        elif gen != self.retry_gen:
            return                                     # um evento mais novo cancelou esta retentativa
        n = self.ddc.set_input(self.cfg, name)
        if n > 0:
            self.last_sent = (name, time.monotonic())
            if not self.quiet:
                notify(self.cfg, "Monitor -> %s" % name)
            return
        if attempt < len(RETRY_AFTER):
            wait = RETRY_AFTER[attempt] - (RETRY_AFTER[attempt - 1] if attempt else 0)
            self.later(wait, lambda: self.switch(name, attempt + 1, gen))
        else:
            log(self.cfg, "nenhum monitor aceitou %s depois de %d tentativas" % (name, attempt + 1))
            notify(self.cfg, "Nenhum monitor aceitou o comando (%s)" % name, "dialog-warning")

    # -- eventos
    def check_kbd(self):
        now = self.present()
        if now == self.st.kbd:
            return
        first = self.st.kbd is None
        self.refresh_cfg()
        if first:
            self.st.kbd = now
            return
        if not now and self.st.peer_enabled and not self.st.peer_seen_ever and not self.warned_never_seen:
            self.warned_never_seen = True
            log(self.cfg, "aviso: sem contato com o outro PC ate agora (bandeja dele fechada ou firewall bloqueando UDP %s?); "
                          "trocando sem conferir" % peer_cfg(self.cfg, "port"))
        self.run(decide(self.st, "kbd_arrived" if now else "kbd_left"))
        self.hello()

    def claim(self, reason):
        self.check_kbd()                         # processa antes uma mudanca do teclado ainda nao vista
        self.refresh_cfg()
        self.quiet = reason == "inicio"
        try:
            self.run(decide(self.st, "claim", reason))
        finally:
            self.quiet = False

    def hello(self):
        if self.sock and as_bool(peer_cfg(self.cfg, "enabled")):
            msg = make_message("hello", self.cfg, **{"in": str(kvm_cfg(self.cfg, "onArrive")), "kbd": int(bool(self.st.kbd)), "mon": int(self.mon)})
            send_all(self.sock, self.cfg, msg, self.peer.get("addr"))

    def on_datagram(self, data, addr):
        d = parse_message(data, self.cfg, self.my_id)
        if not d:
            return
        t = d.get("t")
        was_ready, was_kbd, known = self.peer_ready(), bool(self.peer.get("kbd")), bool(self.peer)
        if t in ("hello", "bye"):
            if self.peer.get("id") != d.get("id"):
                self.peer = {"id": d.get("id")}
            self.peer.update({"addr": addr[0], "last": time.monotonic(), "bye": t == "bye"})
            if t == "hello":
                self.peer.update({"kbd": bool(d.get("kbd")), "mon": bool(d.get("mon")), "in": d.get("in")})
            if not self.st.peer_seen_ever:
                self.st.peer_seen_ever = True
                try:
                    os.makedirs(os.path.dirname(SEEN_FILE), exist_ok=True)
                    open(SEEN_FILE, "a").close()
                except OSError:
                    pass
            if not known or not was_ready:
                self.hello()                     # responde logo, para o outro lado nao esperar 5 s
        elif t == "switch":
            self.check_kbd()
            self.refresh_cfg()
            self.run(decide(self.st, "switch_req", str(d.get("to"))))
            return
        self.refresh_cfg()
        ready = self.peer_ready()
        self.st.peer_ready, self.st.peer_kbd = ready, bool(self.peer.get("kbd"))
        if ready and (not was_ready or (self.st.peer_kbd and not was_kbd and self.st.pending)):
            log(self.cfg, "outro PC %s pronto (%s)" % (self.peer.get("id"), addr[0]))
            self.run(decide(self.st, "peer_ready"))
        elif was_ready and not ready:
            log(self.cfg, "outro PC %s indisponivel (%s)" % (self.peer.get("id"), "bye" if self.peer.get("bye") else "sem monitor"))
        self.save_state()

    def tick(self):
        # outro PC que parou de mandar hello
        if self.st.peer_ready and not self.peer_ready():
            self.st.peer_ready = False
            log(self.cfg, "outro PC %s sem resposta ha %s s" % (self.peer.get("id"), peer_cfg(self.cfg, "timeoutSec")))
            self.save_state()
        # volta da suspensao: CLOCK_BOOTTIME conta o tempo suspenso, CLOCK_MONOTONIC nao
        off = self._suspend_offset()
        if off - self.suspend_ref > 5:
            log(self.cfg, "voltou da suspensao")
            self.later(CLAIM_DELAY, lambda: self.claim("voltou da suspensao"))
        self.suspend_ref = off
        # monitor reconectado a este PC
        mon = self.ddc.monitor_attached()
        if mon != self.mon:
            self.mon = mon
            log(self.cfg, "monitor %s neste PC" % ("conectado" if mon else "desconectado"))
            self.hello()
            if mon:
                self.later(CLAIM_DELAY, lambda: self.claim("monitor reconectado"))

    def open_socket(self):
        port = int(peer_cfg(self.cfg, "port"))
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.bind(("", port))
            s.setblocking(False)
            return s
        except OSError as e:
            log(self.cfg, "rede: nao consegui abrir UDP %d (%s); seguindo sem o outro PC" % (port, e))
            return None

    def main(self):
        self.refresh_cfg()
        if not self.ids:
            print("Sentinela invalida em config.json (kvm.sentinel): %r" % kvm_cfg(self.cfg, "sentinel"), file=sys.stderr)
            return 1
        self.ddc.detect()
        self.mon = self.ddc.monitor_attached()
        self.check_kbd()
        if self.st.peer_enabled:
            self.sock = self.open_socket()
        log(self.cfg, "KVM: sentinela %s %s; seguir=%s; saiu->%s voltou->%s; rede=%s" % (
            kvm_cfg(self.cfg, "sentinel"), "presente" if self.st.kbd else "ausente", str(self.st.enabled).lower(),
            self.st.peer_input, self.st.my_input, "UDP %s" % peer_cfg(self.cfg, "port") if self.sock else "desligada"))
        print("Seguindo o KVM (sentinela %s; kvm.enabled=%s; rede %s). Ctrl+C para sair." % (
            "presente" if self.st.kbd else "ausente", str(self.st.enabled).lower(), "ligada" if self.sock else "desligada"), flush=True)
        self.hello()
        self.later(CLAIM_DELAY, lambda: self.claim("inicio"))

        sel = selectors.DefaultSelector()
        if self.sock:
            sel.register(self.sock, selectors.EVENT_READ, "udp")
        udev = None
        try:
            if os.environ.get("DDC_SYS_USB"):
                raise OSError("sysfs de teste: polling")   # pasta falsa nao gera eventos udev
            udev = subprocess.Popen(["udevadm", "monitor", "--udev", "--subsystem-match=usb"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            sel.register(udev.stdout, selectors.EVENT_READ, "udev")
        except OSError:
            log(self.cfg, "KVM: udevadm monitor indisponivel, usando polling de 2 s")
        delay = max(int(kvm_cfg(self.cfg, "delayMs") or 400), 50) / 1000.0
        kbd_at = None                               # agrupa a rajada de eventos USB de uma troca
        next_tick = next_hello = next_poll = time.monotonic()
        try:
            while True:
                now = time.monotonic()
                deadlines = [next_tick, next_hello] + [t for t, _ in self.timers]
                if kbd_at:
                    deadlines.append(kbd_at)
                if not udev:
                    deadlines.append(next_poll)
                for key, _ in sel.select(max(0.0, min(deadlines) - now)):
                    if key.data == "udp":
                        try:
                            while True:
                                data, addr = self.sock.recvfrom(2048)
                                self.on_datagram(data, addr)
                        except (BlockingIOError, InterruptedError):
                            pass
                    else:
                        if udev.stdout.readline():
                            kbd_at = time.monotonic() + delay
                        else:                       # udevadm morreu: polling
                            sel.unregister(udev.stdout)
                            udev = None
                            log(self.cfg, "KVM: udevadm monitor terminou, usando polling de 2 s")
                now = time.monotonic()
                if kbd_at and now >= kbd_at:
                    kbd_at = None
                    self.check_kbd()
                if not udev and now >= next_poll:
                    next_poll = now + 2
                    self.check_kbd()
                due = [t for t in self.timers if t[0] <= now]
                self.timers = [t for t in self.timers if t[0] > now]
                for _, fn in due:
                    fn()
                if now >= next_tick:
                    next_tick = now + 1
                    self.tick()
                if now >= next_hello:
                    next_hello = now + HELLO_EVERY
                    self.hello()
        finally:
            if self.sock and as_bool(peer_cfg(self.cfg, "enabled")):
                send_all(self.sock, self.cfg, make_message("bye", self.cfg), self.peer.get("addr"))
            if udev:
                udev.terminate()


# ---------------------------------------------------------------- linha de comando
def tell_peer(name):
    cfg = load_config()
    if not as_bool(peer_cfg(cfg, "enabled")):
        return 0
    if name not in inputs(cfg):
        print("Entrada desconhecida '%s'" % name, file=sys.stderr)
        return 1
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    send_all(s, cfg, make_message("switch", cfg, to=name), read_state().get("addr"))
    s.close()
    return 0


def peer_status():
    cfg = load_config()
    d = read_state()
    print("Rede:       %s  (peer.enabled; UDP %s%s)" % ("ligada" if as_bool(peer_cfg(cfg, "enabled")) else "desligada",
          peer_cfg(cfg, "port"), ", host %s" % peer_cfg(cfg, "host") if peer_cfg(cfg, "host") else ""))
    if not d.get("id"):
        seen = "ja houve contato antes" if os.path.isfile(SEEN_FILE) else "nunca visto: bandeja do outro PC fechada ou firewall?"
        print("Outro PC:   sem contato nesta sessao (%s)" % seen)
        return 0
    ago = "ha %d s" % (time.time() - d["lastSeen"]) if d.get("lastSeen") else "?"
    print("Outro PC:   %s em %s, %s, ultimo contato %s" % (d.get("id"), d.get("addr"), "PRONTO" if d.get("ready") else "indisponivel", ago))
    print("            entrada %s; teclado %s; monitor %s" % (d.get("input"), "la" if d.get("kbd") else "nao",
          "conectado" if d.get("mon") else "desconectado"))
    if d.get("pending"):
        print("Pendente:   o teclado foi para o outro PC, o monitor ficou aqui; troca quando ele ficar pronto")
    return 0


def main(argv):
    if len(argv) > 1 and argv[1] == "--tell-peer":
        return tell_peer(argv[2] if len(argv) > 2 else "")
    if len(argv) > 1 and argv[1] == "--peer-status":
        return peer_status()
    if len(argv) > 1 and argv[1] not in ("--run",):
        print(__doc__)
        return 1
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        return Daemon().main()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
