"""Linux-PAM via ctypes (only what noxis-dm needs)."""
import ctypes
import ctypes.util

PAM_SUCCESS = 0
PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON, PAM_ERROR_MSG, PAM_TEXT_INFO = 1, 2, 3, 4
PAM_TTY = 3
PAM_ESTABLISH_CRED, PAM_DELETE_CRED = 0x2, 0x4
PAM_CONV_ERR = 19
PAM_AUTH_ERR, PAM_USER_UNKNOWN, PAM_MAXTRIES = 7, 10, 11
PAM_NEW_AUTHTOK_REQD, PAM_ACCT_EXPIRED, PAM_PERM_DENIED = 12, 13, 6

_libpam = ctypes.CDLL(ctypes.util.find_library("pam") or "libpam.so.0", use_errno=True)
_libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
_libc.calloc.restype = ctypes.c_void_p
_libc.calloc.argtypes = [ctypes.c_size_t, ctypes.c_size_t]
_libc.strdup.restype = ctypes.c_void_p
_libc.strdup.argtypes = [ctypes.c_char_p]
_libc.free.argtypes = [ctypes.c_void_p]


class PamMessage(ctypes.Structure):
    _fields_ = [("msg_style", ctypes.c_int), ("msg", ctypes.c_char_p)]


class PamResponse(ctypes.Structure):
    _fields_ = [("resp", ctypes.c_void_p), ("resp_retcode", ctypes.c_int)]


CONV_FUNC = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(PamMessage)),
                             ctypes.POINTER(ctypes.POINTER(PamResponse)), ctypes.c_void_p)


class PamConv(ctypes.Structure):
    _fields_ = [("conv", CONV_FUNC), ("appdata_ptr", ctypes.c_void_p)]


_libpam.pam_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(PamConv), ctypes.POINTER(ctypes.c_void_p)]
_libpam.pam_end.argtypes = [ctypes.c_void_p, ctypes.c_int]
for _f in ("pam_authenticate", "pam_acct_mgmt", "pam_setcred", "pam_open_session", "pam_close_session"):
    getattr(_libpam, _f).argtypes = [ctypes.c_void_p, ctypes.c_int]
_libpam.pam_set_item.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
_libpam.pam_putenv.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
_libpam.pam_getenvlist.argtypes = [ctypes.c_void_p]
_libpam.pam_getenvlist.restype = ctypes.POINTER(ctypes.c_void_p)
_libpam.pam_strerror.argtypes = [ctypes.c_void_p, ctypes.c_int]
_libpam.pam_strerror.restype = ctypes.c_char_p
_HAS_CONFDIR = hasattr(_libpam, "pam_start_confdir")
if _HAS_CONFDIR:
    _libpam.pam_start_confdir.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(PamConv),
                                          ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]


class PamError(Exception):
    def __init__(self, code, text):
        super().__init__(text)
        self.code = code


class Pam:
    """One PAM transaction. `ask(style, text) -> str|None` answers prompts (None = cancel)."""

    def __init__(self, service, user, ask, confdir=None):
        self.ask = ask
        self.handle = ctypes.c_void_p()
        self._conv_cb = CONV_FUNC(self._conv)          # keep a reference (else GC)
        self._convstruct = PamConv(self._conv_cb, None)
        if confdir:
            if not _HAS_CONFDIR:
                raise PamError(-1, "pam_start_confdir missing")
            rc = _libpam.pam_start_confdir(service.encode(), user.encode(), ctypes.byref(self._convstruct),
                                           confdir.encode(), ctypes.byref(self.handle))
        else:
            rc = _libpam.pam_start(service.encode(), user.encode(), ctypes.byref(self._convstruct), ctypes.byref(self.handle))
        if rc != PAM_SUCCESS:
            raise PamError(rc, "pam_start failed")
        self.last = PAM_SUCCESS

    # PAM calls this with n messages; replies must be allocated with calloc/strdup (PAM frees them)
    def _conv(self, n, msgs, resp, _appdata):
        arr = _libc.calloc(n, ctypes.sizeof(PamResponse))
        if not arr:
            return PAM_CONV_ERR
        out = ctypes.cast(arr, ctypes.POINTER(PamResponse))
        for i in range(n):
            m = msgs[i].contents
            text = (m.msg or b"").decode(errors="replace")
            try:
                answer = self.ask(m.msg_style, text)
            except Exception:  # noqa: BLE001 – errors in the callback must not crash PAM
                answer = None
            if m.msg_style in (PAM_PROMPT_ECHO_OFF, PAM_PROMPT_ECHO_ON):
                if answer is None:
                    for j in range(i):
                        if out[j].resp:
                            _libc.free(out[j].resp)
                    _libc.free(arr)
                    return PAM_CONV_ERR
                out[i].resp = _libc.strdup(answer.encode())
            out[i].resp_retcode = 0
        resp[0] = out
        return PAM_SUCCESS

    def _check(self, rc, what):
        self.last = rc
        if rc != PAM_SUCCESS:
            raise PamError(rc, f"{what}: {self.strerror(rc)}")

    def strerror(self, rc):
        s = _libpam.pam_strerror(self.handle, rc)
        return s.decode() if s else str(rc)

    def set_tty(self, tty):
        self._tty = ctypes.c_char_p(tty.encode())
        _libpam.pam_set_item(self.handle, PAM_TTY, ctypes.cast(self._tty, ctypes.c_void_p))

    def putenv(self, key, value):
        _libpam.pam_putenv(self.handle, f"{key}={value}".encode())

    def authenticate(self):
        self._check(_libpam.pam_authenticate(self.handle, 0), "authenticate")

    def acct_mgmt(self):
        self._check(_libpam.pam_acct_mgmt(self.handle, 0), "account")

    def setcred(self, establish=True):
        self._check(_libpam.pam_setcred(self.handle, PAM_ESTABLISH_CRED if establish else PAM_DELETE_CRED), "credentials")

    def open_session(self):
        self._check(_libpam.pam_open_session(self.handle, 0), "session")

    def close_session(self):
        self.last = _libpam.pam_close_session(self.handle, 0)

    def envlist(self):
        lst = _libpam.pam_getenvlist(self.handle)
        env = {}
        if not lst:
            return env
        i = 0
        while lst[i]:
            kv = ctypes.cast(lst[i], ctypes.c_char_p).value.decode(errors="replace")
            if "=" in kv:
                k, v = kv.split("=", 1)
                env[k] = v
            _libc.free(lst[i])
            i += 1
        _libc.free(ctypes.cast(lst, ctypes.c_void_p))
        return env

    def end(self):
        if self.handle:
            _libpam.pam_end(self.handle, self.last)
            self.handle = ctypes.c_void_p()
