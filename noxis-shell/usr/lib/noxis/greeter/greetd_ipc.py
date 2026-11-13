"""greetd IPC: length (u32, native byte order) + JSON over $GREETD_SOCK (spoken by noxis-dm)."""
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
            raise GreetdError("GREETD_SOCK not set")
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
                raise GreetdError("display manager closed the connection")
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
        """One login attempt. Returns (True, None) or (False, code) with code in
        wrong_pin | extra | pin_expired | error  (details in self.detail).
        The first secret prompt gets `secret`; anything else is cancelled, never guessed."""
        self.detail = ""
        resp = self.request({"type": "create_session", "username": username})
        asked = 0
        while resp.get("type") == "auth_message":
            kind = resp.get("auth_message_type")
            if kind == "secret":
                asked += 1
                if asked > 1:  # second secret prompt = PAM wants more (e.g. expired) → do not guess
                    self.cancel()
                    return False, "extra"
                resp = self.request({"type": "post_auth_message_response", "response": secret})
            elif kind in ("info", "error"):
                resp = self.request({"type": "post_auth_message_response", "response": None})
            else:  # visible prompt: the UI has no answer for it
                self.cancel()
                self.detail = resp.get("auth_message") or ""
                return False, "extra"
        if resp.get("type") == "error":
            self.cancel()
            if resp.get("error_type") == "auth_error":
                return False, "wrong_pin"
            self.detail = resp.get("description") or ""
            return False, "pin_expired" if "expired" in self.detail else "error"
        if resp.get("type") != "success":
            self.cancel()
            self.detail = "unexpected reply"
            return False, "error"
        resp = self.request({"type": "start_session", "cmd": list(cmd), "env": list(env)})
        if resp.get("type") != "success":
            self.cancel()
            self.detail = resp.get("description") or "session refused"
            return False, "error"
        return True, None

    def setup_info(self, lang):
        return self.request({"type": "noxis_setup_info", "lang": lang})

    def setup_user(self, pin=None, name=None, username=None):
        msg = {"type": "noxis_setup_user"}
        if username:
            msg["username"] = username
        if pin:
            msg["pin"] = pin
        if name:
            msg["name"] = name
        r = self.request(msg)
        return r.get("type") == "success", r.get("description", "")

    def setup(self, lang, timezone):
        r = self.request({"type": "noxis_setup", "lang": lang, "timezone": timezone})
        return r.get("type") == "success", r.get("description", "")

    def wifi_list(self):
        r = self.request({"type": "noxis_wifi_list"})
        if r.get("type") != "noxis_wifi_list":
            raise GreetdError(r.get("description") or "WLAN unavailable")
        return r.get("networks") or []

    def wifi_connect(self, ssid, psk):
        r = self.request({"type": "noxis_wifi_connect", "ssid": ssid, "psk": psk or ""})
        return r.get("type") == "success", r.get("description", "")
