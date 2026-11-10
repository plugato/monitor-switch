#!/usr/bin/env python3
"""Testes das regras de troca do monitor-kvm.py (python3 -m unittest linux/test_monitor_kvm.py)."""
import importlib.util
import os
import unittest

_spec = importlib.util.spec_from_file_location("monitor_kvm", os.path.join(os.path.dirname(os.path.abspath(__file__)), "monitor-kvm.py"))
mk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mk)


def st(**kw):
    base = dict(enabled=True, peer_enabled=True, kbd=True, pending=False, peer_seen_ever=True, peer_ready=True,
                peer_kbd=False, my_input="DP", peer_input="HDMI")
    base.update(kw)
    return mk.State(**base)


def kinds(acts, kind):
    return [a[1] for a in acts if a[0] == kind]


class Regras(unittest.TestCase):
    def test_saiu_com_outro_pronto_troca(self):
        s = st()
        a = mk.decide(s, "kbd_left")
        self.assertEqual(kinds(a, "ddc"), ["HDMI"])
        self.assertFalse(s.pending)

    def test_saiu_com_outro_indisponivel_fica(self):
        s = st(peer_ready=False)
        a = mk.decide(s, "kbd_left")
        self.assertEqual(kinds(a, "ddc"), [])
        self.assertTrue(s.pending)
        self.assertTrue(kinds(a, "notify"))

    def test_saiu_sem_nunca_ter_visto_o_outro_troca_como_antes(self):
        a = mk.decide(st(peer_ready=False, peer_seen_ever=False), "kbd_left")
        self.assertEqual(kinds(a, "ddc"), ["HDMI"])

    def test_saiu_com_rede_desligada_troca_como_antes(self):
        a = mk.decide(st(peer_ready=False, peer_enabled=False), "kbd_left")
        self.assertEqual(kinds(a, "ddc"), ["HDMI"])

    def test_outro_ficou_pronto_com_pendencia_reconecta(self):
        s = st(kbd=False, pending=True)
        a = mk.decide(s, "peer_ready")
        self.assertEqual(kinds(a, "ddc"), ["HDMI"])
        self.assertFalse(s.pending)

    def test_outro_ficou_pronto_com_o_teclado_reconecta(self):
        a = mk.decide(st(kbd=False, peer_kbd=True), "peer_ready")
        self.assertEqual(kinds(a, "ddc"), ["HDMI"])

    def test_outro_ficou_pronto_mas_teclado_aqui_nao_troca(self):
        self.assertEqual(mk.decide(st(kbd=True, peer_kbd=False, pending=True), "peer_ready"), [])

    def test_outro_pronto_sem_teclado_e_sem_pendencia_nao_troca(self):
        self.assertEqual(mk.decide(st(kbd=False, peer_kbd=False), "peer_ready"), [])

    def test_voltou_troca_aqui_e_pede_ao_outro(self):
        s = st(kbd=False, pending=True)
        a = mk.decide(s, "kbd_arrived")
        self.assertEqual(kinds(a, "ddc"), ["DP"])
        self.assertEqual(kinds(a, "tell"), ["DP"])
        self.assertFalse(s.pending)
        self.assertTrue(s.kbd)

    def test_reivindicar_com_teclado(self):
        a = mk.decide(st(kbd=True), "claim", "voltou da suspensao")
        self.assertEqual(kinds(a, "ddc"), ["DP"])
        self.assertEqual(kinds(a, "tell"), ["DP"])

    def test_reivindicar_sem_teclado_nao_faz_nada(self):
        self.assertEqual(mk.decide(st(kbd=False), "claim", "inicio"), [])

    def test_pedido_do_outro_executa(self):
        a = mk.decide(st(kbd=False), "switch_req", "HDMI")
        self.assertEqual(kinds(a, "ddc"), ["HDMI"])

    def test_pedido_do_outro_ignorado_com_teclado_aqui(self):
        a = mk.decide(st(kbd=True), "switch_req", "HDMI")
        self.assertEqual(kinds(a, "ddc"), [])

    def test_pedido_para_a_propria_entrada_com_teclado_aqui_executa(self):
        a = mk.decide(st(kbd=True), "switch_req", "DP")
        self.assertEqual(kinds(a, "ddc"), ["DP"])

    def test_kvm_desligado_nao_troca(self):
        for ev in ("kbd_left", "kbd_arrived"):
            self.assertEqual(kinds(mk.decide(st(enabled=False), ev), "ddc"), [])
        self.assertEqual(mk.decide(st(enabled=False, kbd=False, pending=True), "peer_ready"), [])


class Mensagens(unittest.TestCase):
    def test_ida_e_volta(self):
        cfg = {"peer": {"key": "abc"}}
        m = mk.make_message("hello", cfg, kbd=1, mon=1, **{"in": "HDMI"})
        d = mk.parse_message(m, cfg, "outro/linux")
        self.assertEqual((d["t"], d["in"], d["kbd"]), ("hello", "HDMI", 1))

    def test_ignora_propria_chave_errada_e_lixo(self):
        cfg = {"peer": {"key": "abc"}}
        m = mk.make_message("hello", cfg)
        self.assertIsNone(mk.parse_message(m, cfg, mk.json.loads(m[5:])["id"]))
        self.assertIsNone(mk.parse_message(m, {"peer": {"key": "xyz"}}, "outro"))
        self.assertIsNone(mk.parse_message(b"lixo", cfg, "outro"))
        self.assertIsNone(mk.parse_message(b"MSW1 {nao json", cfg, "outro"))

    def test_override_linux(self):
        cfg = {"doubleClick": "DP", "linux": {"doubleClick": "HDMI"}, "kvm": {"onLeave": "DP", "linux": {"onLeave": "HDMI"}}}
        self.assertEqual(mk.cfg_get(cfg, "doubleClick"), "HDMI")
        self.assertEqual(mk.kvm_cfg(cfg, "onLeave"), "HDMI")
        self.assertEqual(mk.kvm_cfg(cfg, "delayMs"), 400)

    def test_usb_ids(self):
        self.assertEqual(mk.usb_ids("USB\\VID_046D&PID_C33A"), ("046d", "c33a"))
        self.assertEqual(mk.usb_ids("046d:c33a"), ("046d", "c33a"))
        self.assertIsNone(mk.usb_ids("teclado"))


if __name__ == "__main__":
    unittest.main()
