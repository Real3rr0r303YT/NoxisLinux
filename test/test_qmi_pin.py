#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
"""noxis-qmi-pin: Nachrichtenaufbau und die drei Betriebsarten durchlaufen.

Ein Attrappen-Modem beantwortet die QMI-Aufrufe, damit jeder Pfad wirklich
ausgefuehrt wird - ein Tippfehler in einem Aufruf faellt sonst erst auf dem
Geraet auf.
"""
import importlib.machinery
import importlib.util
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "noxis-hw/usr/lib/noxis/hw/noxis-qmi-pin")
q = importlib.util.module_from_spec(
    importlib.util.spec_from_loader("q", importlib.machinery.SourceFileLoader("q", SRC)))
importlib.machinery.SourceFileLoader("q", SRC).exec_module(q)

ok = fail = 0


def check(name, cond, extra=""):
    global ok, fail
    if cond:
        ok += 1
        print("  \033[32m✓\033[0m %s" % name)
    else:
        fail += 1
        print("  \033[31m✗\033[0m %s %s" % (name, extra))


AID = bytes.fromhex("a0000000871002ffffffff8907090000")


def app(atype=2, p1s=1, p1r=3):
    return bytes([atype, 2, 0, 0, 0, 0, len(AID)]) + AID + bytes([0, p1s, p1r, 10, 1, 3, 10])


def card_status(idx=(0xFFFF,) * 4, cards=((1, (2, 1, 3)), (1, (2, 3, 0)))):
    v = struct.pack("<4H", *idx) + bytes([len(cards)])
    for state, a in cards:
        v += bytes([state, 0, 0, 0, 0, 1]) + app(*a)
    return v


class FakeUim:
    """Beantwortet Get Card Status, Verify PIN und Change Provisioning."""

    def __init__(self, status_tlv, verify=(0, 0, 3), provision=(0, 0)):
        self.status_tlv, self.verify, self.provision = status_tlv, verify, provision
        self.sent = []

    def __call__(self, node, port):
        return self

    def call(self, msg_bytes, msg_id):
        self.sent.append(msg_bytes)
        if msg_id == q.UIM_GET_CARD_STATUS:
            body = struct.pack("<BH", 0x02, 4) + struct.pack("<HH", 0, 0)
            body += struct.pack("<BH", 0x10, len(self.status_tlv)) + self.status_tlv
        elif msg_id == q.UIM_VERIFY_PIN:
            res, err, left = self.verify
            body = struct.pack("<BH", 0x02, 4) + struct.pack("<HH", res, err)
            body += struct.pack("<BH", 0x10, 1) + bytes([left])
        else:
            res, err = self.provision
            body = struct.pack("<BH", 0x02, 4) + struct.pack("<HH", res, err)
        return q.tlvs(struct.pack("<BHHH", 2, 1, msg_id, len(body)) + body, msg_id)


def run(args, fake, pinfile=None):
    q.Uim, q.find_uim = fake, lambda: (0, 70)
    argv = ["noxis-qmi-pin"] + args + ([pinfile] if pinfile else [])
    return q.main(argv)


print("\n\033[1mnoxis-qmi-pin\033[0m")

# --- Nachrichtenaufbau gegen libqmi/den Mitschnitt von ModemManager ---
def head(r):
    kind, _txn, msg, ln = struct.unpack_from("<BHHH", r)
    return kind, msg, ln


r = q.build_verify(2, AID, b"1234")
check("Verify PIN: Kopf, Sitzung card-slot-2, AID, PIN1",
      head(r) == (0, q.UIM_VERIFY_PIN, len(r) - 7)
      and r[7:10] == bytes([1, 18, 0]) and r[10] == 7 and r[11] == 16 and r[12:28] == AID
      and r[28:] == bytes([2, 6, 0]) + b"\x01\x041234", r.hex())
check("Verify PIN fuer Platz 1 nutzt card-slot-1 (wie ModemManager)",
      q.build_verify(1, b"", b"0000")[10] == 6)
r = q.build_provision(2, AID)
check("Change Provisioning: primaere GW-Sitzung aktivieren, Platz + AID",
      head(r) == (0, q.UIM_CHANGE_PROVISIONING_SESSION, len(r) - 7)
      and r[7:12] == bytes([1, 2, 0, q.SESSION_PRIMARY_GW, 1])
      and r[12:17] == bytes([0x10, 18, 0, 2, 16]) and r[17:] == AID, r.hex())

# --- Kartenstatus lesen ---
idx, cards = q.parse_card_status(card_status(idx=(0x0100, 0xFFFF, 0xFFFF, 0xFFFF)))
check("Zuweisung gelesen: Platz 2, Anwendung 1", idx[0] == 0x0100)
check("zwei Plaetze mit je einer USIM", len(cards) == 2 and cards[0]["apps"][0]["aid"] == AID)
check("PIN-Zustand und Versuche je Platz",
      (cards[0]["apps"][0]["pin1_state"], cards[0]["apps"][0]["pin1_retries"]) == (1, 3)
      and cards[1]["apps"][0]["pin1_state"] == 3)

# --- Betriebsarten wirklich durchlaufen ---
f = FakeUim(card_status())
check("status: liest, sendet nichts", run(["status"], f) == 0 and len(f.sent) == 1)

f = FakeUim(card_status())
open("/tmp/noxis-test-pin", "w").write("1234")
check("Platz 1 gesperrt mit 3 Versuchen -> PIN wird gesendet",
      run(["1"], f, "/tmp/noxis-test-pin") == 0 and len(f.sent) == 2)

f = FakeUim(card_status(), verify=(1, q.ERR_INCORRECT_PIN, 2))
check("falsche PIN -> Rueckgabe 12", run(["1"], f, "/tmp/noxis-test-pin") == 12)

f = FakeUim(card_status(cards=((1, (2, 1, 2)), (1, (2, 3, 0)))))
check("nur noch 2 Versuche -> sendet nichts, Rueckgabe 3",
      run(["1"], f, "/tmp/noxis-test-pin") == 3 and len(f.sent) == 1)

f = FakeUim(card_status(cards=((1, (2, 3, 0)), (1, (2, 3, 0)))))
check("PIN abgeschaltet -> nichts zu tun, Rueckgabe 3",
      run(["1"], f, "/tmp/noxis-test-pin") == 3 and len(f.sent) == 1)

f = FakeUim(card_status())
check("provision 2 -> Zuweisung gesendet",
      run(["provision", "2"], f) == 0 and len(f.sent) == 2
      and head(f.sent[1])[1] == q.UIM_CHANGE_PROVISIONING_SESSION)

f = FakeUim(card_status(), provision=(1, 82))
check("abgelehnte Zuweisung -> Rueckgabe 1", run(["provision", "1"], f) == 1)

f = FakeUim(card_status())
check("unsinniger Platz -> Rueckgabe 1, nichts gesendet",
      run(["7"], f, "/tmp/noxis-test-pin") == 1 and len(f.sent) == 1)
check("ohne Argumente -> Hilfe, Rueckgabe 1", run([], FakeUim(card_status())) == 1)

os.remove("/tmp/noxis-test-pin")
print("\n%d passed, %d failed\n" % (ok, fail))
sys.exit(1 if fail else 0)
