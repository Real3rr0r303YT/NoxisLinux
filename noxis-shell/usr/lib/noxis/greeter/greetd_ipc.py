"""greetd-IPC: Länge (u32, native Byte-Reihenfolge) + JSON über $GREETD_SOCK."""
import json
import os
import socket
import struct


class GreetdError(Exception):
    pass


class Greetd:
    def __init__(self, path=None):
        self.path = path or os.environ.get("GREETD_SOCK")
        if not self.path:
            raise GreetdError("GREETD_SOCK fehlt")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise GreetdError("greetd hat die Verbindung geschlossen")
            buf += chunk
        return buf

    def request(self, msg):
        data = json.dumps(msg).encode()
        self.sock.sendall(struct.pack("=I", len(data)) + data)
        (n,) = struct.unpack("=I", self._recv_exact(4))
        return json.loads(self._recv_exact(n))

    def cancel(self):
        try:
            return self.request({"type": "cancel_session"})
        except (GreetdError, OSError):
            return None

    def login(self, username, secret, cmd, env=()):
        """Ein Anmeldeversuch. Rückgabe: (True, None) oder (False, Meldung).
        Jede geheime Abfrage (PIN/Passwort) bekommt `secret`, sichtbare Fragen werden abgebrochen."""
        resp = self.request({"type": "create_session", "username": username})
        asked = 0
        while resp.get("type") == "auth_message":
            kind = resp.get("auth_message_type")
            if kind == "secret":
                asked += 1
                if asked > 1:  # zweite PIN-Frage = PAM will mehr (z. B. abgelaufen) → nicht raten
                    self.cancel()
                    return False, "Zusätzliche Abfrage – bitte am Terminal anmelden"
                resp = self.request({"type": "post_auth_message_response", "response": secret})
            elif kind in ("info", "error"):
                resp = self.request({"type": "post_auth_message_response", "response": None})
            else:  # visible: Fragen ohne Antwort aus der UI
                self.cancel()
                return False, resp.get("auth_message") or "Unbekannte Abfrage"
        if resp.get("type") == "error":
            self.cancel()
            if resp.get("error_type") == "auth_error":
                return False, "Falsche PIN"
            return False, resp.get("description") or "Fehler"
        if resp.get("type") != "success":
            self.cancel()
            return False, "Unerwartete Antwort"
        resp = self.request({"type": "start_session", "cmd": list(cmd), "env": list(env)})
        if resp.get("type") != "success":
            self.cancel()
            return False, resp.get("description") or "Sitzung startet nicht"
        return True, None
