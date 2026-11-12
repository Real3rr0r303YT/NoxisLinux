"""Noxis languages: German, Turkish, English, French, Bulgarian, Russian, Ukrainian."""
import os

# code: (native name, locale, xkb layout, default time zone or None, country for suggestions)
LANGS = {
    "de": ("Deutsch",     "de_DE.UTF-8", "de", "Europe/Berlin",   "DE"),
    "tr": ("Türkçe",      "tr_TR.UTF-8", "tr", "Europe/Istanbul", "TR"),
    "en": ("English",     "en_US.UTF-8", "us", None,              None),
    "fr": ("Français",    "fr_FR.UTF-8", "fr", "Europe/Paris",    "FR"),
    "bg": ("Български",   "bg_BG.UTF-8", "bg", "Europe/Sofia",    "BG"),
    "ru": ("Русский",     "ru_RU.UTF-8", "ru", "Europe/Moscow",   "RU"),
    "uk": ("Українська",  "uk_UA.UTF-8", "ua", "Europe/Kyiv",     "UA"),
}
ORDER = ["de", "tr", "en", "fr", "bg", "ru", "uk"]

T = {
    "mobile":      ["Mobil", "Mobil", "Mobile", "Mobile", "Мобилен", "Мобильный", "Мобільний"],
    "desktop":     ["Desktop", "Masaüstü", "Desktop", "Bureau", "Работен плот", "Рабочий стол", "Робочий стіл"],
    "reboot":      ["Neustart", "Yeniden başlat", "Restart", "Redémarrer", "Рестартиране", "Перезагрузка", "Перезавантаження"],
    "poweroff":    ["Ausschalten", "Kapat", "Power off", "Éteindre", "Изключване", "Выключение", "Вимкнення"],
    "wrong_pin":   ["Falsche PIN", "Yanlış PIN", "Wrong PIN", "Code PIN incorrect", "Грешен ПИН", "Неверный PIN-код", "Неправильний PIN-код"],
    "checking":    ["Prüfe …", "Kontrol ediliyor …", "Checking …", "Vérification …", "Проверка …", "Проверка …", "Перевірка …"],
    "wait":        ["Zu viele Fehlversuche – {s} s warten", "Çok fazla hatalı deneme – {s} sn bekleyin",
                    "Too many attempts – wait {s} s", "Trop de tentatives – patientez {s} s",
                    "Твърде много опити – изчакайте {s} с", "Слишком много попыток – подождите {s} с",
                    "Забагато спроб – зачекайте {s} с"],
    "no_user":     ["Kein Benutzer gefunden", "Kullanıcı bulunamadı", "No user found", "Aucun utilisateur trouvé",
                    "Няма намерен потребител", "Пользователь не найден", "Користувача не знайдено"],
    "error":       ["Fehler", "Hata", "Error", "Erreur", "Грешка", "Ошибка", "Помилка"],
    "extra":       ["Zusätzliche Abfrage – bitte am Terminal anmelden", "Ek doğrulama gerekli – lütfen terminalden giriş yapın",
                    "Additional prompt – please log in on a terminal", "Vérification supplémentaire – connectez-vous dans un terminal",
                    "Допълнителна проверка – влезте от терминал", "Требуется доп. проверка – войдите через терминал",
                    "Потрібна додаткова перевірка – увійдіть через термінал"],
    "pin_expired": ["PIN abgelaufen", "PIN süresi doldu", "PIN expired", "Code PIN expiré", "ПИН-ът е изтекъл",
                    "Срок действия PIN-кода истёк", "Термін дії PIN-коду минув"],
    "welcome":     ["Willkommen bei Noxis", "Noxis'e hoş geldiniz", "Welcome to Noxis", "Bienvenue sur Noxis",
                    "Добре дошли в Noxis", "Добро пожаловать в Noxis", "Ласкаво просимо до Noxis"],
    "choose_lang": ["Sprache wählen", "Dil seçin", "Choose your language", "Choisissez votre langue",
                    "Изберете език", "Выберите язык", "Оберіть мову"],
    "timezone":    ["Zeitzone", "Saat dilimi", "Time zone", "Fuseau horaire", "Часова зона", "Часовой пояс", "Часовий пояс"],
    "det_network": ["Erkannt über Mobilfunknetz", "Mobil ağdan algılandı", "Detected from mobile network",
                    "Détecté via le réseau mobile", "Открито чрез мобилната мрежа", "Определено по мобильной сети",
                    "Визначено за мобільною мережею"],
    "det_lang":    ["Vorschlag passend zur Sprache", "Dile göre öneri", "Suggested for your language",
                    "Suggéré selon la langue", "Предложение според езика", "Предложено по языку", "Запропоновано за мовою"],
    "search":      ["Suchen …", "Ara …", "Search …", "Rechercher …", "Търсене …", "Поиск …", "Пошук …"],
    "next":        ["Weiter", "İleri", "Continue", "Continuer", "Напред", "Далее", "Далі"],
    "set_pin":     ["PIN festlegen", "PIN belirle", "Set a PIN", "Définir un code PIN",
                    "Задайте ПИН", "Задайте PIN-код", "Задайте PIN-код"],
    "pin_repeat":  ["PIN wiederholen", "PIN'i yinele", "Repeat the PIN", "Répétez le code PIN",
                    "Повторете ПИН", "Повторите PIN-код", "Повторіть PIN-код"],
    "pin_mismatch": ["PINs stimmen nicht überein", "PIN'ler aynı değil", "PINs do not match",
                     "Les codes PIN ne correspondent pas", "ПИН кодовете не съвпадат",
                     "PIN-коды не совпадают", "PIN-коди не збігаються"],
    "pin_short":   ["Mindestens 4 Ziffern", "En az 4 hane", "At least 4 digits", "4 chiffres minimum",
                    "Поне 4 цифри", "Не менее 4 цифр", "Щонайменше 4 цифри"],
    "later":       ["Später", "Daha sonra", "Later", "Plus tard", "По-късно", "Позже", "Пізніше"],
    "back":        ["Zurück", "Geri", "Back", "Retour", "Назад", "Назад", "Назад"],
    "applying":    ["Wird eingerichtet …", "Ayarlanıyor …", "Setting up …", "Configuration …", "Настройване …",
                    "Настройка …", "Налаштування …"],
    "setup_fail":  ["Einrichtung fehlgeschlagen", "Kurulum başarısız", "Setup failed", "Échec de la configuration",
                    "Неуспешна настройка", "Ошибка настройки", "Помилка налаштування"],
    "vpn_on":      ["VPN aktiv", "VPN etkin", "VPN active", "VPN actif", "VPN активен", "VPN активен", "VPN активний"],
    "vpn_off":     ["Kein VPN – Internet gesperrt", "VPN yok – internet engelli", "No VPN – internet blocked",
                    "Pas de VPN – Internet bloqué", "Няма VPN – интернет блокиран", "Нет VPN – интернет заблокирован",
                    "Немає VPN – інтернет заблоковано"],
    "battery":     ["Akku", "Pil", "Battery", "Batterie", "Батерия", "Батарея", "Батарея"],
    "network":     ["Netzwerk", "Ağ", "Network", "Réseau", "Мрежа", "Сеть", "Мережа"],
}

WEEKDAYS = {
    "de": ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"],
    "tr": ["Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi", "Pazar"],
    "en": ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
    "fr": ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"],
    "bg": ["понеделник", "вторник", "сряда", "четвъртък", "петък", "събота", "неделя"],
    "ru": ["понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"],
    "uk": ["понеділок", "вівторок", "середа", "четвер", "пʼятниця", "субота", "неділя"],
}
MONTHS = {  # Genitiv, wo die Sprache ihn im Datum nutzt
    "de": ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"],
    "tr": ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"],
    "en": ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
    "fr": ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"],
    "bg": ["януари", "февруари", "март", "април", "май", "юни", "юли", "август", "септември", "октомври", "ноември", "декември"],
    "ru": ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"],
    "uk": ["січня", "лютого", "березня", "квітня", "травня", "червня", "липня", "серпня", "вересня", "жовтня", "листопада", "грудня"],
}
DATE_FMT = {
    "de": "{wd}, {d}. {m}", "tr": "{d} {m} {wd}", "en": "{wd}, {m} {d}", "fr": "{wd} {d} {m}",
    "bg": "{wd}, {d} {m}", "ru": "{wd}, {d} {m}", "uk": "{wd}, {d} {m}",
}


def lang_from_env(env=None):
    e = env if env is not None else os.environ
    for var in ("LC_ALL", "LC_MESSAGES", "LANG"):
        v = (e.get(var) or "").split(".")[0].split("_")[0].lower()
        if v in LANGS:
            return v
    return "en"


def tr(lang, key, **kw):
    s = T[key][ORDER.index(lang if lang in LANGS else "en")]
    return s.format(**kw) if kw else s


def date_text(lang, tm):
    lang = lang if lang in LANGS else "en"
    s = DATE_FMT[lang].format(wd=WEEKDAYS[lang][tm.tm_wday], d=tm.tm_mday, m=MONTHS[lang][tm.tm_mon - 1])
    return s[:1].upper() + s[1:]
