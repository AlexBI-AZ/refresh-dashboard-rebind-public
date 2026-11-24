# -*- coding: utf-8 -*-
"""Builds docs/manual/PowerBI-Control-Panel-Manual-RU.html, the illustrated user manual.

One self-contained file: the screenshots are embedded as base64, the stylesheet and the
script are inlined, and nothing is loaded from the network. Screenshots come from
shots/*.png; shots/badges.json holds the boxes of the numbered controls in CSS pixels of
the 1440x900 window they were taken in (see capture/capture.mjs). A figure can be cropped,
and its badges are placed from those boxes and explained in a numbered legend below it.
build.ps1 runs this script and then prints the PDF with headless Chrome.
"""
import base64
import html
import io
import json
import os
import re
import sys

from PIL import Image

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")
SRC = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(SRC), "PowerBI-Control-Panel-Manual-RU.html")
SHOTS = os.path.join(SRC, "shots")
META = json.load(open(os.path.join(SHOTS, "badges.json"), encoding="utf-8"))
VIEW_W, VIEW_H = META["viewport"]
BOXES = META["boxes"]

VERSION = "v0.5.0"
MONTH = "Ноябрь 2026"


# ---------------------------------------------------------------- text helpers
def md(text):
    """[[Label]] marks a label as it appears in the app, `x` marks code. The rest is HTML."""
    text = re.sub(r"\[\[(.+?)\]\]", lambda m: '<b class="ui">' + html.escape(m.group(1), quote=False) + "</b>", text)
    return re.sub(r"`([^`]+?)`", lambda m: "<code>" + html.escape(m.group(1), quote=False) + "</code>", text)


def p(text, cls=""):
    return f'<p class="{cls}">' + md(text) + "</p>" if cls else "<p>" + md(text) + "</p>"


def ul(items):
    return "<ul>" + "".join("<li>" + md(i) + "</li>" for i in items) + "</ul>"


def steps(items):
    return '<ol class="steps">' + "".join("<li>" + md(i) + "</li>" for i in items) + "</ol>"


def table(head, rows, cls="t"):
    h = "".join("<th>" + md(c) + "</th>" for c in head)
    b = "".join("<tr>" + "".join("<td>" + md(c) + "</td>" for c in r) + "</tr>" for r in rows)
    return f'<div class="tw"><table class="{cls}"><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table></div>'


def box(kind, text):
    return f'<div class="{kind}">' + md(text) + "</div>"


def code(text):
    return '<pre class="code"><code>' + html.escape(text.strip("\n"), quote=False) + "</code></pre>"


# ---------------------------------------------------------------- figures
FIG = {"n": 0}
FIGURES = []  # (number, caption, kind, key) for the list in the last section
# Text refers to a figure as {{fig:key}}; build() swaps in "рис. N" once all are numbered.
KIND_TAG = {
    "real": ("real", "Снимок экрана"),
    "sim": ("sim", "Снимок экрана, вымышленные данные"),
    "schema": ("schema", "Схема"),
}


def anchor_point(rect, anchor, dx, dy):
    x, y, w, h = rect
    points = {
        "l": (x - 15, y + h / 2), "r": (x + w + 15, y + h / 2),
        "t": (x + w / 2, y - 6), "b": (x + w / 2, y + h + 8),
        "tl": (x + 14, y + 14), "tr": (x + w - 14, y + 14),
        "li": (x + 16, y + h / 2), "ri": (x + w - 16, y + h / 2), "c": (x + w / 2, y + h / 2),
    }
    px, py = points[anchor]
    return px + dx, py + dy


def shot(name, caption, kind, badges, crop=None, width=None):
    """badges: (number, selector or (x, y), legend text[, anchor[, dx, dy]])."""
    FIG["n"] += 1
    n = FIG["n"]
    FIGURES.append((n, caption, kind, name))
    image = Image.open(os.path.join(SHOTS, name + ".png"))
    scale = image.size[0] / VIEW_W
    cx, cy, cw, ch = crop or (0, 0, VIEW_W, VIEW_H)
    if crop:
        image = image.crop((round(cx * scale), round(cy * scale), round((cx + cw) * scale), round((cy + ch) * scale)))
    buf = io.BytesIO()
    image.save(buf, "PNG", optimize=True)
    src = "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode("ascii")
    marks, legend = [], []
    for badge in badges:
        number, where, text = badge[0], badge[1], badge[2]
        anchor = badge[3] if len(badge) > 3 else "l"
        dx = badge[4] if len(badge) > 4 else 0
        dy = badge[5] if len(badge) > 5 else 0
        if isinstance(where, tuple):
            bx, by = where[0] + dx, where[1] + dy
        else:
            rect = BOXES[name].get(where)
            if not rect or not rect[2]:
                raise SystemExit(f"{name}: no box for {where}")
            bx, by = anchor_point(rect, anchor, dx, dy)
        left = min(max((bx - cx) / cw * 100, 1.2), 98.8)
        top = min(max((by - cy) / ch * 100, 1.6), 98.4)
        marks.append(f'<a class="badge" href="#f{n}-{number}" style="left:{left:.2f}%;top:{top:.2f}%">{number}</a>')
        legend.append(f'<li id="f{n}-{number}"><span class="num">{number}</span><span>{md(text)}</span></li>')
    tag_cls, tag_text = KIND_TAG[kind]
    style = f' style="max-width:{width}"' if width else ""
    alt = html.escape(re.sub(r"\[\[|\]\]|`", "", caption))
    out = (f'<figure class="shot" id="fig{n}"{style}><div class="shot-wrap"><img src="{src}" alt="{alt}">'
           + "".join(marks) + f'</div><figcaption><span class="tag {tag_cls}">{tag_text}</span>Рис. {n}. {md(caption)}</figcaption></figure>')
    if legend:
        out += '<ol class="legend">' + "".join(legend) + "</ol>"
    return out


def schema(caption, body, key=""):
    FIG["n"] += 1
    n = FIG["n"]
    FIGURES.append((n, caption, "schema", key))
    return (f'<figure class="schema-fig shot" id="fig{n}"><div class="schema">{body}</div>'
            f'<figcaption><span class="tag schema">Схема</span>Рис. {n}. {md(caption)}</figcaption></figure>')


def console(lines):
    """lines: (css class or '', text). Drawn, not captured."""
    rows = []
    for cls, text in lines:
        t = html.escape(text, quote=False)
        rows.append(f'<span class="{cls}">{t}</span>' if cls else t)
    return '<div class="console">' + "\n".join(rows) + "</div>"


def flow(boxes):
    """boxes: (css class, title, text). Arrows are drawn between them."""
    parts = []
    for i, (cls, title, text) in enumerate(boxes):
        if i:
            parts.append('<div class="farrow" aria-hidden="true"></div>')
        parts.append(f'<div class="fbox {cls}"><b>{md(title)}</b><span>{md(text)}</span></div>')
    return '<div class="flow">' + "".join(parts) + "</div>"


# ---------------------------------------------------------------- sections
SECTIONS = []  # (id, title, css class, html, starts a new printed page)


def section(sid, title, body, cls="", newpage=False):
    SECTIONS.append((sid, title, cls, body, newpage))


# 1 ---------------------------------------------------------------------------------
section("about", "Что делает панель", "".join([
    p("Power BI Dashboard Control Panel - небольшое приложение для Windows. По сохраненным профилям оно запускает обновление dataflow и семантических моделей в Power BI Service, точечно обновляет исторические партиции и переносит PBIP-проекты между средами, заменяя в них GUID.", "lede"),
    p("Панель состоит из двух частей. Окно - страница `index.html` - открывается в Microsoft Edge. Работу делает небольшой сервер на PowerShell (`server.ps1`), который запускается на вашем компьютере по адресу `http://localhost:8765` и обращается к Power BI REST API от имени того, кто вошел. На серверы организации ничего не устанавливается; в облаке нужен только необязательный flow Power Automate для писем."),
    table(["Вкладка", "Что делает", "Нужен вход в Power BI"], [
        ["[[Refresh]]", "Запускает все dataflow профиля одновременно, а после успеха каждого из них - все семантические модели. Проверяет модели до и после обновления и может отправить одно итоговое письмо.", "Да"],
        ["[[Partition]] (Partition Refresh)", "Отправляет Enhanced Refresh для точно названных партиций одной таблицы одной модели. Удобно для исторических партиций.", "Да"],
        ["[[Rebind]]", "Заменяет GUID рабочих областей, dataflow и dataset в файлах `.tmdl` и `.json` локального PBIP-проекта. Сначала показывает, что изменится, и меняет файлы только после вашего решения.", "Нет"],
    ]),
    "<h3>Как читать это руководство</h3>",
    p("Руководство написано для коллег и клиентов, которые получили панель в виде ZIP-архива или публичного репозитория. Предполагается, что вы знаете Power BI, рабочие области, семантические модели и dataflow, но эту панель видите впервые."),
    p("Названия кнопок, вкладок и полей даны так, как они написаны в панели, по-английски, и выделены жирным: [[Start Refresh]]. Номера в красных кружках на рисунках соответствуют строкам под рисунком; в HTML-версии по номеру можно щелкнуть."),
    p("Все снимки сделаны с вымышленными данными: рабочие области Contoso, Fabrikam и Northwind, адреса `example.com` и GUID вида `00000000-0000-0000-0000-...`. В подписи каждого рисунка сказано, что это: снимок экрана или схема."),
]))

# 2 ---------------------------------------------------------------------------------
READINESS = console([
    ("c", "Readiness check (read-only)"),
    ("g", "  OK    Windows PowerShell  version 5.1.x"),
    ("g", "  OK    Files               not blocked"),
    ("g", "  OK    Microsoft Edge      found"),
    ("g", "  OK    MSAL.PS             installed"),
    ("g", "  OK    Sign-in             device code; sign in from the panel with Authenticate for Refresh"),
    ("m", "  INFO  Email               no flow URL; refreshes run without email (dry run still works)"),
    ("g", "  OK    Shortcuts           Desktop and Start menu"),
    ("", ""),
    ("g", "  Ready"),
])

section("install", "Установка", "".join([
    p("Установка идет для текущего пользователя Windows и не требует прав администратора. Python, Node.js и Docker не нужны.", "lede"),
    "<h3>Что нужно компьютеру</h3>",
    table(["Что нужно", "Кто обеспечивает", "Для чего"], [
        ["Windows 10 или 11", "Компьютер", "Все вкладки"],
        ["Windows PowerShell 5.1", "Уже есть в Windows. PowerShell 7 не подходит: запускайте `setup.bat`, а не `setup.ps1` из PowerShell 7", "Сервер панели и установка"],
        ["Microsoft Edge", "Обычно уже есть в Windows", "Отдельное окно панели. Без Edge панель откроется в браузере по умолчанию"],
        ["Модуль MSAL.PS", "Ставит `setup.bat` для текущего пользователя из PowerShell Gallery; нужен интернет", "Вход для Refresh и Partition Refresh. Rebind работает без него"],
        ["Учетная запись Power BI с ролью Member или выше в рабочих областях профиля", "Администратор рабочих областей", "Refresh и Partition Refresh"],
        ["Емкость Premium, PPU или Embedded у модели", "Администратор Power BI", "Только Partition Refresh"],
        ["URL flow Power Automate", "Владелец панели, лично", "Только письма о результате (раздел 8)"],
    ]),
    "<h3>Установка по шагам</h3>",
    steps([
        "Распакуйте архив в постоянную папку, например `Documents\\Power BI Control Panel`. Ярлыки будут указывать на эту папку, поэтому не распаковывайте во временную папку.",
        "Дважды щелкните `setup.bat`. Он пройдет по шагам из таблицы ниже и задаст не больше двух вопросов.",
        "В конце setup показывает проверку готовности. При <b>Ready</b> он сам откроет панель. При <b>Not ready</b> причины перечислены под этими словами: исправьте их и запустите `setup.bat` еще раз.",
        "Дальше - вход (раздел 3) и первый профиль (раздел 5).",
    ]),
    "<h3>Что делает setup.bat</h3>",
    p("В окне setup шаги называются так же, как в первой колонке."),
    table(["Шаг в окне setup", "Что происходит"], [
        ["Unblocking the files in this folder", "Снимает пометку «скачано из интернета» со всех файлов папки."],
        ["Checking Windows PowerShell and Microsoft Edge", "Проверяет, что запущен Windows PowerShell 5.1, и ищет Edge."],
        ["Checking MSAL.PS (the sign-in module)", "Ставит модуль MSAL.PS для текущего пользователя (при необходимости и поставщик пакетов NuGet), без вопросов про NuGet и PSGallery. Занимает около минуты."],
        ["Sign-in", "Выбирает вход по коду (device code). Только если на компьютере уже настроен рабочий сертификат, спрашивает `Use the certificate? [Y/n]`; ответ n оставляет device code. Сертификаты setup не создает."],
        ["Email notifications (optional)", "Один раз просит URL flow Power Automate. Ввод скрыт, Enter пропускает шаг. URL сохраняется только в переменной пользователя `REFRESH_EMAIL_WEBHOOK_URL`, не в файле."],
        ["Shortcuts", "Создает ярлыки «Power BI Control Panel» на рабочем столе и в меню «Пуск»."],
        ["Readiness check (read-only)", "Проверяет все, ничего не меняя, пишет Ready или Not ready и открывает панель."],
    ], cls="t k"),
    schema("Конец работы `setup.bat` на готовом компьютере. Строки повторяют формат проверки готовности из `setup.ps1`; номер версии условный.", READINESS),
    p("`setup.bat` можно запускать сколько угодно раз: он меняет только то, чего не хватает. Параметры передаются через `setup.bat`, например `setup.bat -CheckOnly`."),
    table(["Параметр", "Что делает"], [
        ["без параметров", "Полная установка и проверка"],
        ["`-CheckOnly`", "Только проверка готовности, ничего не меняет"],
        ["`-DryRun`", "Показывает, что было бы изменено, и ничего не меняет"],
        ["`-SkipWebhook`", "Не спрашивает URL flow"],
        ["`-NoLaunch`", "Не открывает панель в конце"],
        ["`-SignIn DeviceCode` или `-SignIn Certificate`", "Заранее отвечает на вопрос о сертификате. Certificate действует, только если рабочий сертификат уже настроен"],
    ], cls="t k"),
    "<h3>Что остается на компьютере</h3>",
    table(["Где", "Что", "Кто создает"], [
        ["Папка программы", "Файлы без пометки «из интернета»; позже - профили, файлы статуса и папка `logs\\`", "setup, затем панель"],
        ["Папка модулей пользователя (обычно `Документы\\WindowsPowerShell\\Modules`)", "Модуль MSAL.PS. Если поставщика пакетов NuGet не было, он ставится в `%LOCALAPPDATA%\\PackageManagement`", "setup"],
        ["Переменные среды пользователя", "`REFRESH_EMAIL_WEBHOOK_URL`, если вы ввели URL flow. `POWERBI_REFRESH_AUTH_MODE`, только если способ входа нужно задать явно", "setup"],
        ["`%LOCALAPPDATA%\\PowerBIControlPanel\\app.ico`", "Значок для ярлыков", "setup"],
        ["Рабочий стол и меню «Пуск»", "Ярлык «Power BI Control Panel», который запускает `launch-app.bat`", "setup"],
        ["`%LOCALAPPDATA%\\PowerBIControlPanel\\EdgeAppProfile`", "Отдельный профиль Edge для окна панели, без входа в учетную запись и синхронизации", "панель при первом запуске ярлыком"],
        ["`%LOCALAPPDATA%\\PowerBIChainedRefresh\\msalcache.bin3`", "Зашифрованный кэш входа по коду", "панель после первого входа"],
        ["`%LOCALAPPDATA%\\PowerBIChainedRefresh\\runs\\`", "Папка каждого запуска Refresh: журнал, итоги, снимки проверки, копия письма", "панель при каждом Refresh"],
    ]),
    "<h3>Запуск панели</h3>",
    table(["Как запустить", "Что происходит"], [
        ["Ярлык «Power BI Control Panel» или `launch-app.bat`", "Открывается отдельное окно Edge без адресной строки, консоль сервера свернута. Закрытие последнего окна панели останавливает сервер. Повторный запуск при открытой панели открывает еще одно окно той же панели."],
        ["`launch.bat`", "Сервер работает в видимой консоли, панель открывается в обычном браузере. Консоль нельзя закрывать, пока панель нужна."],
    ], cls="t k"),
    p("Сервер занимает порт 8765. Если он занят, запустите сервер на другом порту: `powershell -ExecutionPolicy Bypass -File .\\server.ps1 -Port 8877`. Страница сама использует тот адрес и порт, с которого открыта."),
    "<h3>Переход на новую версию</h3>",
    steps([
        "Закройте окно панели.",
        "Распакуйте новую версию в новую папку и скопируйте в нее из старой папки файлы профилей, которые у вас есть: `profiles.json`, `partition-refresh-profiles.json`, `rebind-profiles.json`.",
        "Запустите `setup.bat` в новой папке. Ярлыки, которые указывают на старую папку, он перенаправит на новую.",
        "Вход повторять не нужно: кэш входа лежит в `%LOCALAPPDATA%`, а не в папке программы.",
    ]),
    "<h3>Как убрать панель с компьютера</h3>",
    ul([
        "Удалите ярлыки «Power BI Control Panel» с рабочего стола и из меню «Пуск» и папку программы (вместе с профилями).",
        "Удалите `%LOCALAPPDATA%\\PowerBIControlPanel` и, если вход больше не нужен, `%LOCALAPPDATA%\\PowerBIChainedRefresh` (кэш входа и история запусков).",
        "Удалите переменные пользователя `REFRESH_EMAIL_WEBHOOK_URL` и `POWERBI_REFRESH_AUTH_MODE`, если они заданы.",
        "Модуль MSAL.PS можно оставить или удалить командой `Uninstall-Module MSAL.PS`, если он больше ничем не используется.",
    ]),
]))

# 3 ---------------------------------------------------------------------------------
DEVICE_CODE = console([
    ("y", "Device-code sign-in for Refresh (this PC does not use a certificate)."),
    ("y", "Use the device URL and code shown below. Rebind itself never requires this step."),
    ("m", "[здесь Microsoft печатает адрес страницы входа и код, например EXAMPLE12]"),
    ("g", "Authenticated. Refresh is ready."),
])

section("signin", "Вход и токены", "".join([
    p("Вход нужен только для вкладок Refresh и Partition. Rebind работает с локальными файлами и не требует ни входа, ни MSAL.PS. Окно панели открывается до любого входа.", "lede"),
    "<h3>Два способа входа</h3>",
    table(["Способ", "Для кого", "Как настроить"], [
        ["Device code (по умолчанию)", "Для тех, кто запускает обновления вручную. Вход под своей учетной записью: свои права на рабочие области, свое имя в журнале обновлений", "Ничего настраивать не нужно. Нажмите [[Authenticate for Refresh]] и введите код из консоли сервера"],
        ["Сертификат (service principal)", "Для компьютеров, где обновления идут без участия человека", "Настраивается отдельно, не через setup: сертификат с закрытым ключом в `Cert:\\CurrentUser\\My` и переменные пользователя `POWERBI_REFRESH_TENANT_ID`, `POWERBI_REFRESH_CLIENT_ID`, `POWERBI_REFRESH_CERT_THUMBPRINT`. Приложение должно быть участником (Member) рабочих областей из профилей. Если такой сертификат уже работает, `setup.bat` предлагает его"],
    ]),
    p("Какой способ используется: переменная `POWERBI_REFRESH_AUTH_MODE` (`delegated` или `service-principal`) задает его явно. Без нее используется сертификат, если заданы все три переменные сертификата, иначе device code. Способ виден на значке входа в заголовке окна."),
    "<h3>Вход по коду, шаг за шагом</h3>",
    steps([
        "Откройте вкладку [[Refresh]]. В заголовке стоит красный значок [[Not signed in]], под ним желтая полоса с кнопкой [[Authenticate for Refresh]] ({{fig:01-first-launch}}, номер 9).",
        "Нажмите [[Authenticate for Refresh]]. Кнопка меняется на [[Waiting for sign-in...]]; если панель запущена ярлыком, свернутая консоль сервера сама разворачивается.",
        "В консоли появятся адрес страницы входа и код. Откройте страницу в любом браузере (README и подсказка панели называют `https://login.microsoft.com/device`), введите код и войдите своей рабочей учетной записью.",
        "Когда в консоли появится `Authenticated. Refresh is ready.`, значок станет зеленым: [[Signed in (device code)]], и кнопка [[Start Refresh]] станет доступной.",
        "Если за 10 минут вход не завершен или не удался, в полосе появится `Authentication failed: ...`, а кнопка станет [[Try authentication again]].",
    ]),
    schema("Консоль сервера во время входа по коду. Первые две и последняя строки печатает `server.ps1`; строку с кодом печатает служба Microsoft, ее текст здесь не воспроизводится.", DEVICE_CODE),
    "<h3>Что показывает значок входа</h3>",
    table(["Значок или кнопка", "Что значит"], [
        ["[[Checking sign-in]]", "Панель еще не спросила сервер. Так бывает на вкладке Partition, если после запуска вы не открывали Refresh: вход проверяется при открытии вкладки Refresh"],
        ["[[Signed in (device code)]]", "Вход по коду выполнен"],
        ["[[Signed in (certificate)]]", "Вход сертификатом выполнен"],
        ["[[Not signed in]]", "Входа нет. Кнопки запуска недоступны"],
        ["[[Server offline]]", "Страница не может связаться с сервером: сервер остановлен или перезапускается"],
        ["[[MSAL.PS not installed]]", "Кнопка входа неактивна, модуль не установлен. Запустите `setup.bat`. Rebind работает и без него"],
        ["[[Try the certificate again]]", "Компьютер настроен на сертификат, и вход им не удался. Причина видна в полосе; подробности покажет `setup.bat -CheckOnly`"],
    ], cls="t k"),
    p("На вкладке Rebind значок входа и полоса не показываются."),
    "<h3>Где хранятся токены и сколько живут</h3>",
    table(["Что", "Где", "Срок"], [
        ["Вход по коду", "Кэш `%LOCALAPPDATA%\\PowerBIChainedRefresh\\msalcache.bin3`, зашифрованный для вашей учетной записи Windows. В папке программы токены не хранятся", "Повторный вход обычно не нужен месяцами, пока действует refresh-токен в кэше"],
        ["Access-токен", "Только в памяти сервера. Запущенному обновлению он передается через переменные окружения его процесса, не в аргументах и не в файле", "Около часа. Сервер берет новый каждые 40 минут, процесс обновления продлевает свой каждые 45 минут"],
        ["Токен Power Automate", "Только в памяти процесса обновления. Нужен для отправки письма, если flow принимает только вошедших пользователей (раздел 8). Берется тем же входом, что и обновление", "Около часа. Используется только на время отправки письма"],
        ["Сертификат", "`Cert:\\CurrentUser\\My`. Закрытый ключ не покидает компьютер, файл `.pfx` никто не копирует и не пересылает", "Пока действует сертификат. Дату покажет `setup.bat -CheckOnly`; за 30 дней до конца он предупреждает"],
        ["Файл `.token`", "Больше не используется; старый файл можно удалить", "-"],
    ]),
    box("info", "Одно обновление никогда не меняет учетную запись посередине: и сервер, и процесс обновления продлевают токен через один и тот же модуль `runtime\\powerbi-auth.ps1`."),
]))

# 4 ---------------------------------------------------------------------------------
section("window", "Окно панели", "".join([
    p("У всех трех вкладок одинаковое устройство: слева список профилей, в середине форма профиля, справа запуск, ход операции и журнал. У каждой вкладки свой цвет: Refresh синий, Partition бирюзовый, Rebind фиолетовый.", "lede"),
    shot("01-first-launch", "Первый запуск: вход еще не выполнен, профилей нет.", "real", [
        (1, ".tab-toggle", "Вкладки [[Refresh]], [[Partition]] и [[Rebind]]. У каждой свой список профилей, своя форма и свой журнал. Переключение не прерывает идущую операцию.", "r", -6),
        (2, "#profileList", "[[Saved profiles]] - сохраненные профили текущей вкладки. Щелчок по карточке загружает профиль в форму.", "tl", 120, -30),
        (3, (290, 834), "[[New profile]] создает профиль, [[Delete]] удаляет выбранный после подтверждения."),
        (4, ".version-pill", "Номер версии. Щелчок открывает окно «Версии и изменения».", "r", 4),
        (5, "#pageTitle", "Имя выбранного профиля и подзаголовок вкладки.", "r", 12),
        (6, "#authBadge", "Значок входа (раздел 3). На вкладке Rebind скрыт.", "b", 0, 2),
        (7, "#statusBadge", "Состояние операции: [[Idle]], [[Running]], [[Done]], [[Failed]] и другие (разделы 7, 9, 11).", "b", 0, 2),
        (8, ".btn-help", "[[?]] - встроенная справка на русском языке. Местами она устарела, см. раздел 16.", "b", 0, 2),
        (9, (1170, 112), "Полоса входа с кнопкой [[Authenticate for Refresh]]. Видна, пока вход не выполнен; на вкладке Rebind не показывается."),
        (10, ".config-pane", "Форма профиля: что обновлять или что заменять.", "tl", -14, -14),
        (11, "#btnStart", "Индикаторы хода и кнопка запуска текущей вкладки.", "b", 0, 2),
        (12, "#logsRefresh", "Журнал операции: каждая строка с временем. Журналы вкладок ведутся отдельно и сохраняются при переключении.", "tl", 4, 4),
    ], width="94%"),
    p("На узком экране три части окна идут друг под другом. Внизу слева - автор и номер версии; кнопка [[?]] открывает справку, номер версии - список изменений."),
]))

# 5 ---------------------------------------------------------------------------------
section("first", "Первые шаги: от нуля до первого обновления", "".join([
    p("Путь для нового пользователя. Каждый шаг подробно описан в своем разделе.", "lede"),
    box("warn", "Обновление настоящее: оно идет в Power BI Service и меняет данные моделей. Для первого запуска выберите тестовую рабочую область и включите [[Dry run]], чтобы письмо не ушло коллегам."),
    steps([
        "Установите панель: `setup.bat` должен закончиться словом <b>Ready</b> (раздел 2).",
        "Запустите панель ярлыком «Power BI Control Panel». Откроется вкладка [[Refresh]].",
        "Войдите: [[Authenticate for Refresh]], код из консоли, вход в браузере (раздел 3). Значок станет [[Signed in (device code)]].",
        "В поле [[Workspace]] начните вводить название рабочей области и выберите ее из списка.",
        "В поле [[Add a report or semantic model]] выберите отчет или модель. Панель сама найдет dataflow, из которых читает модель, и добавит их; под полем появится сообщение, сколько найдено.",
        "Проверьте список [[Dataflows]]: лишние уберите кнопкой ✕, недостающие добавьте через [[Add a dataflow]].",
        "Впишите свой адрес в [[Notify colleagues]] и отметьте [[Dry run]].",
        "Нажмите [[New profile]], введите имя и нажмите [[Create]]. Профиль создается из того, что сейчас в форме. Можно и иначе: вписать имя в [[Profile name]] и нажать [[Save Profile]].",
        "Нажмите [[Start Refresh]] и следите за точками и журналом справа (раздел 7).",
        "Когда статус станет [[Done]], найдите в журнале строки письма. Чтобы проверить настоящую отправку, снимите [[Dry run]] и повторите запуск на свой адрес, и только потом добавляйте коллег.",
    ]),
]))

# 6 ---------------------------------------------------------------------------------
section("refresh-profiles", "Refresh: профиль и форма", "".join([
    p("Профиль Refresh хранит, что обновлять: одну или несколько семантических моделей, dataflow, из которых они читают, и адреса для итогового письма. В одном профиле можно смешивать объекты из разных рабочих областей.", "lede"),
    shot("02-refresh-profile", "Вкладка Refresh с выбранным профилем после входа.", "sim", [
        (1, ".profile-card.selected", "Выбранный профиль. На карточке - число dataflow и моделей и рабочая область.", "ri"),
        (2, "#profileName", "[[Profile name]] - имя профиля.", "ri"),
        (3, "#wsPickerInput", "[[Workspace]] - поиск рабочей области по названию. В ней ищутся отчеты, модели и dataflow для полей ниже.", "ri"),
        (4, "#semanticModelList", "[[Semantic models]] - модели профиля с рабочей областью каждой. ✕ убирает строку.", "l", -4),
        (5, "#modelPickerInput", "[[Add a report or semantic model]] - добавить отчет или модель ({{fig:03-model-picker}}).", "ri"),
        (6, "#dfList", "[[Dataflows]] - dataflow профиля с рабочей областью каждого. ✕ убирает строку.", "l", -4),
        (7, "#dfPickerInput", "[[Add a dataflow]] - добавить dataflow выбранной рабочей области вручную.", "ri"),
        (8, "#btnStart", "[[Start Refresh]] - запуск (раздел 7). Доступна только после входа.", "b", 0, 2),
        (9, "#authBadge", "Значок входа: [[Signed in (device code)]].", "l"),
    ]),
    "<h3>Поиск по названию</h3>",
    p("Поля с лупой ищут объекты в Power BI по названию. Начните вводить часть названия: список фильтруется по каждому слову. Стрелки и Enter тоже работают. Поиск только читает данные Power BI и ничего не меняет, поэтому требует входа. Списки показывают только те рабочие области и объекты, к которым у вас есть доступ; список рабочих областей сервер запоминает на 5 минут."),
    shot("03-model-picker", "Список поля [[Add a report or semantic model]]: сначала отчеты, затем модели.", "sim", [
        (1, "#modelPickerInput", "Поле поиска. Щелчок открывает список объектов выбранной рабочей области.", "l"),
        (2, "#modelPickerList .picker-group", "Группа [[Reports]]. При выборе отчета добавляется его модель.", "ri"),
        (3, "#modelPickerList .picker-option.disabled", "Серые строки выбрать нельзя: [[Its semantic model is already added]] или [[Already added]]. Так же серым показана модель с подписью [[Cannot be refreshed: DirectQuery or live connection]].", "ri"),
        (4, (770, 615), "Подсвеченную строку выбирает Enter."),
        (5, (770, 711), "Группа [[Semantic models]] - сами модели рабочей области."),
    ], crop=(300, 440, 540, 410), width="74%"),
    p("После выбора отчета или модели панель ищет по lineage dataflow, из которых модель читает данные, и добавляет их в список [[Dataflows]]. Под полем появляется одно из сообщений:"),
    table(["Сообщение", "Что значит"], [
        ["Added … and the N dataflows it reads from.", "Модель и ее dataflow добавлены"],
        ["Added … It reads from no dataflow, so only the model will be refreshed.", "Модель читает напрямую из базы или файла; обновится только она"],
        ["… cannot be refreshed (DirectQuery or live connection), so it was not added.", "Такую модель обновлять нечего, она не добавлена"],
        ["Added the semantic model, but its dataflows could not be found: …", "Модель добавлена, dataflow не нашлись. Добавьте их вручную, если они нужны"],
        ["Dataflow lineage could not be read for this semantic model; add its dataflows by hand.", "Lineage не прочитан; добавьте dataflow вручную"],
    ]),
    "<h3>Создание, сохранение и удаление профиля</h3>",
    shot("04-new-profile", "Окно [[New profile]] на вкладке Refresh.", "sim", [
        (1, "#modalName", "Имя нового профиля. Профиль создается из того, что сейчас в форме.", "l"),
        (2, "#modalNew .btn-row .btn-save", "[[Cancel]] закрывает окно; Esc и щелчок по затемненному фону тоже.", "b"),
        (3, "#modalNew .btn-start", "[[Create]] сохраняет профиль; Enter в поле имени делает то же.", "b"),
    ], crop=(480, 300, 480, 300), width="62%"),
    table(["Кнопка", "Что делает"], [
        ["Щелчок по карточке профиля", "Загружает профиль в форму. Флажок [[Model only]] при этом снимается"],
        ["[[New profile]]", "Открывает окно ({{fig:04-new-profile}}). Имя должно быть новым, иначе `Profile with this name already exists.`"],
        ["[[Save Profile]]", "Сохраняет форму под именем из [[Profile name]]. Профиль с тем же именем перезаписывается"],
        ["[[Delete]]", "Удаляет выбранный профиль после вопроса `Delete profile \"…\"?`"],
    ], cls="t k"),
    p("Профили лежат в файле `profiles.json` в папке программы и в Git не попадают. В профиле хранятся ID объектов, а названия сохраняются рядом только для показа, поэтому переименование в Power BI ничего не ломает. Старые профили без названий показывают их после входа; файл при этом не меняется, пока вы не нажмете [[Save Profile]]. Несохраненные строки формы переживают перезагрузку страницы."),
    "<h3>Нижняя часть формы</h3>",
    shot("02b-refresh-profile-end", "Нижняя часть формы Refresh.", "sim", [
        (1, "#modelOnly", "[[Model only]] - обновить только модели, без dataflow (раздел 7). Действует на один запуск и не сохраняется.", "l"),
        (2, "#notifyEmails", "[[Notify colleagues]] - адреса для итогового письма через запятую или точку с запятой. Пробелы и повторы удаляются.", "l"),
        (3, "#emailDryRun", "[[Dry run]] - не отправлять письмо, а показать его в журнале (раздел 8).", "l"),
        (4, "#refreshAdvanced > summary", "[[IDs and manual entry]] - свернутый раздел для ввода GUID.", "l"),
        (5, "#formRefresh .form-footer .btn-save", "[[Save Profile]] - сохранить профиль.", "l"),
    ], crop=(300, 480, 540, 400), width="62%"),
    p("Раздел [[IDs and manual entry]] - запасной путь, когда списков нет или прав на поиск не хватает:"),
    table(["Поле", "Что вводить"], [
        ["[[Workspace ID]]", "GUID рабочей области из поля [[Workspace]]. К ней относятся dataflow, добавленные по ID"],
        ["[[Add a dataflow by ID]] и [[Add]]", "GUID dataflow в этой рабочей области"],
        ["[[Add a semantic model by ID]] и [[Add]]", "Два GUID: рабочая область модели и сама модель (dataset)"],
    ], cls="t k"),
    p("Названия для добавленных по ID объектов подтягиваются сами после входа. Ошибки формы: неверный адрес в [[Notify colleagues]] подсвечивается и подписывается `Invalid email: …`; без имени профиля - `Enter a profile name.`; строка модели без полных GUID - `Every semantic model row must contain valid workspace and dataset GUIDs.`"),
]), "refresh")

# 7 ---------------------------------------------------------------------------------
CHAIN = flow([
    ("", "1. Dataflow", "Все dataflow профиля запускаются одновременно. Статус каждого проверяется каждые 30 секунд."),
    ("", "2. Строгий шлюз", "Если хоть один dataflow не завершился успешно, модели получают Skipped и не запускаются."),
    ("", "3. Модели", "Все модели запускаются одновременно и опрашиваются до своего результата: Succeeded или Failed."),
    ("g", "4. Проверка и письмо", "Снимок каждой модели после обновления сравнивается со снимком до. Затем одно итоговое письмо."),
])

section("refresh-run", "Refresh: запуск и ход выполнения", "".join([
    p("Кнопка [[Start Refresh]] запускает цепочку: сначала все dataflow профиля, потом все его модели. Модели стартуют только после успеха каждого dataflow, чтобы обновиться уже на свежих данных.", "lede"),
    "<h3>Что происходит после нажатия</h3>",
    steps([
        "Панель проверяет форму. Если что-то не так, появляется сообщение, например `Choose the workspace of the dataflows, or tick \"Model only\".`, `Add at least one semantic model with valid workspace and dataset GUIDs.` или `Correct the notification email addresses before starting.`",
        "Сервер запускает скрытый процесс обновления и передает ему план и токен. Статус - [[Starting...]].",
        "Процесс не начинает обновление модели, которая уже обновляется в Power BI Service или в другом запуске (`... is already refreshing in the Power BI service` или `... is already active`).",
        "Перед запуском снимается состояние каждой модели для проверки.",
        "Все dataflow запускаются одновременно. Если статус временно не читается, процесс повторяет попытки около 10 минут и только потом пишет `Unknown` (результат не подтвержден), а не Failed.",
        "После успеха всех dataflow запускаются все модели. Если модель в этот момент обновляется по чужому запросу, процесс ждет окончания и запускает свое обновление; отказ службы из-за параллельного обновления повторяется не более 3 раз.",
        "Каждая модель получает свой результат: ошибка одной не останавливает остальные. Затем снимается состояние моделей после обновления и сравнивается с исходным.",
        "Отправляется одно итоговое письмо (раздел 8) и пишется последняя строка журнала, например `SUCCESS: All refreshes completed (3 dataflow(s) + 1 semantic model(s)).`",
    ]),
    p("Если цепочка не закончилась за 11 часов, незавершенные элементы получают Failed. Одновременно панель ведет только одно обновление: второй запуск получит `A refresh is already running`."),
    schema("Цепочка Refresh. С флажком [[Model only]] шаги 1 и 2 пропускаются.", CHAIN),
    shot("05-refresh-running", "Обновление идет: все dataflow готовы, модель обновляется.", "sim", [
        (1, "#dotDataflow", "Точка [[Dataflow]]: зеленая галочка - все dataflow успешны.", "b", 0, 6),
        (2, "#dotDataset", "Точка [[Semantic models]]: синяя - модели обновляются.", "b", 0, 6),
        (3, "#semanticStatusList", "Строка каждой модели: «модель - рабочая область: статус».", "ri"),
        (4, "#statusBadge", "Статус операции: [[Running]].", "b", 0, 2),
        (5, "#logsRefresh", "Журнал запуска. Строки с ERROR и FAILED красные, с completed и SUCCESS зеленые, с WARNING желтые.", "tr", -6, 6),
        (6, (1321, 148), "[[Start Refresh]] недоступна, пока идет обновление."),
    ], crop=(816, 0, 624, 600), width="72%"),
    shot("06-refresh-done", "Обновление закончено: модель обновлена, проверка пройдена, письмо отправлено.", "sim", [
        (1, "#progressRow", "Обе точки зеленые.", "b"),
        (2, "#semanticStatusList", "Итог модели: [[Succeeded]].", "ri"),
        (3, "#statusBadge", "Статус [[Done]].", "b", 0, 2),
        (4, "#logsRefresh .log-entry:last-child", "Итоговая строка журнала. Выше - результат проверки модели (PASS) и отправка письма.", "l", -6),
    ], crop=(816, 0, 624, 800), width="72%"),
    p("Журнал на этих рисунках составлен из сообщений процесса обновления для вымышленного профиля. В настоящем запуске из панели строка способа входа выглядит так: `Authentication: delegated (Control Panel sign-in).`", "note"),
    "<h3>Индикаторы и статусы</h3>",
    table(["Что видно", "Что значит"], [
        ["Серая точка", "Этап еще не начался"],
        ["Синяя точка", "Этап идет"],
        ["Зеленая точка с галочкой", "Этап успешно закончен"],
        ["Красная точка", "Ошибка: Failed, Cancelled, Disabled или Unknown"],
        ["[[Dataflow (skipped)]]", "Запуск в режиме Model only: точка остается серой"],
        ["[[Starting...]]", "Процесс обновления запускается"],
        ["[[Running]]", "Обновление идет"],
        ["[[Done]]", "Все успешно"],
        ["[[Done - email warning]]", "Обновление успешно, а письмо не ушло. Причина - в желтой строке над журналом"],
        ["[[Failed]]", "Хотя бы один элемент с ошибкой; подробности в журнале и в строке модели"],
        ["[[Error]]", "Страница не смогла связаться с сервером"],
        ["[[Worker died]]", "Процесс обновления неожиданно завершился. Смотрите `logs\\refresh-worker-errors.log`; следующий запуск не заблокирован"],
    ], cls="t k"),
    p("Строка модели показывает Pending, Running, Succeeded, Failed, Skipped или Unknown, а при ошибке - текст ответа службы."),
    "<h3>Model only</h3>",
    p("Флажок [[Model only]] обновляет только модели профиля, без dataflow. Он действует на один запуск: dataflow остаются в профиле (их строки становятся бледными), флажок не сохраняется и снимается при выборе другого профиля. Профиль без dataflow всегда запускается в этом режиме, флажок для него не нужен. Запрет параллельного обновления модели действует и здесь."),
    "<h3>Проверка моделей до и после</h3>",
    p("Перед обновлением снимается состояние каждой модели, после обновления - еще раз, и снимки сравниваются. Если для модели есть конфиг отчета в `validation\\reports\\` (совпадают рабочая область и имя модели), используются его проверки. Иначе - универсальные проверки из `validation\\universal-checks.json`:"),
    ul([
        "число строк в каждой таблице: предупреждение (WARN) при изменении от 10%, ошибка (FAIL) от 25% или если таблица с данными опустела;",
        "структура модели (таблицы, столбцы, меры, связи) - для сведения, на результат не влияет.",
    ]),
    p("Проверка, которая не смогла выполниться, не останавливает обновление: в письме будет причина. Снимок «до» берется уже после развертывания модели, поэтому влияние самого развертывания он не покажет; как сравнить первый запуск после развертывания с прогоном до него (`-BaselineRunsBack`), описано в `validation\\README.md`."),
    "<h3>Что остается после запуска</h3>",
    p("Каждый запуск получает свою папку в `%LOCALAPPDATA%\\PowerBIChainedRefresh\\runs\\`: журнал `refresh-log.txt`, итоги `summary.json`, снимки и сравнение каждой модели (`validation-<n>-before.json`, `validation-<n>-after.json`, `validation-<n>-compare.json`) и копия письма `email.html` или, при Dry run, `email-preview.html`."),
]), "refresh")

# 8 ---------------------------------------------------------------------------------
section("email", "Письмо о результате", "".join([
    p("Если в профиле заполнено [[Notify colleagues]], после всей цепочки уходит одно письмо: карточка обновления (время, длительность, статус и ошибка каждого элемента) и раздел проверки для каждой модели.", "lede"),
    p("Письмо отправляет flow Power Automate, поэтому почта не выходит за пределы Microsoft 365. URL этого flow вам лично передает владелец панели. Панель читает его только из переменной пользователя `REFRESH_EMAIL_WEBHOOK_URL`; в профиле и в файлах он не хранится."),
    "<h3>Как подключить письма</h3>",
    steps([
        "Получите URL flow у владельца панели.",
        "Запустите `setup.bat` и вставьте URL, когда он спросит (ввод скрыт). Чтобы заменить URL позже, запустите `setup.bat` еще раз.",
        "Перезапустите панель.",
    ]),
    p("Отдельный вход для писем не нужен: панель отправляет письмо тем же входом, что и обновление."),
    box("warn", "Храните URL триггера как пароль: не вставляйте его в профили, письма, задачи и файлы. Если URL попал к посторонним, пересоздайте его в Power Automate и запустите `setup.bat` с новым URL."),
    "<h3>Безопасная проверка</h3>",
    steps([
        "Впишите в [[Notify colleagues]] только свой адрес и отметьте [[Dry run]].",
        "Запустите обновление. В журнале появятся получатели, тема и строки сводки, но запроса к flow не будет. Само обновление при этом настоящее. Копия письма - `email-preview.html` в папке запуска.",
        "Снимите [[Dry run]] и проверьте один живой запуск на свой адрес.",
        "Только после этого добавляйте коллег.",
    ]),
    "<h3>Как ведет себя письмо</h3>",
    ul([
        "Список адресов пуст - шаг письма пропускается без сообщений.",
        "Flow не настроен или вернул ошибку - в журнале строка WARNING, над журналом желтое предупреждение, статус [[Done - email warning]]. Результат обновления при этом не меняется.",
        "После отправки в журнале строка `Notification email submitted for N recipient(s).` Если письмо ушло с токеном, перед ней строка `The flow only accepts signed-in callers; the email was sent with a Power Automate token (...)`.",
    ]),
]), "refresh")

# 9 ---------------------------------------------------------------------------------
CONFIRM = ('<div class="dialog"><pre>REAL REMOTE REFRESH\n\nWorkspace: Contoso Sales TEST\n'
           'Workspace ID: 00000000-0000-0000-0000-000000000102\nSemantic model: Sales Overview\n'
           'Dataset ID: 00000000-0000-0000-0000-000000000201\nTable: Sales\nPartitions:\n- Sales 2025-01\n'
           '- Sales 2025-02\n- Sales 2025-03\n\nCommit mode: Transactional\nApply refresh policy: No\n\n'
           'Submit this enhanced refresh now?</pre><div class="btns"><span class="ok">OK</span><span>Cancel</span></div></div>')

section("partition", "Partition Refresh", "".join([
    p("Вкладка [[Partition]] обновляет точно названные партиции одной таблицы одной модели через Enhanced Refresh API. Это удобно, когда нужно пересчитать, например, три исторических месяца и не трогать остальную модель.", "lede"),
    shot("07-partition", "Вкладка Partition: профиль, статус последнего запроса и история.", "sim", [
        (1, "#pillPartitionRefresh", "Вкладка [[Partition]].", "b"),
        (2, "#pwsPickerInput", "[[Workspace]] - рабочая область, поиск по названию.", "ri"),
        (3, "#pmodelPickerInput", "[[Semantic model]] - модель, поиск по названию.", "ri"),
        (4, "#partitionTableName", "[[Exact table name]] - точное имя таблицы модели.", "ri"),
        (5, "#partitionNames", "[[Exact partition names, one per line]] - точные имена партиций, по одному на строку.", "ri"),
        (6, "#partitionAdvanced > summary", "[[IDs]] - свернутые поля [[Workspace ID]] и [[Semantic model / dataset ID]] для ввода GUID.", "l"),
        (7, (666, 628), "[[Save Profile]] - сохранить профиль."),
        (8, "#btnStartPartitionRefresh", "[[Start Partition Refresh]] - отправить запрос после подтверждения.", "b", 0, 6),
        (9, "#controlsPartitionRefresh .btn-save", "[[Refresh History]] - последние 10 обновлений модели, только чтение.", "r"),
        (10, "#partitionRefreshState", "Статус последнего принятого запроса.", "ri", 0, -100),
        (11, "#logsPartitionRefresh", "Журнал вкладки: история и сообщения.", "tr", -6, 6),
    ]),
    "<h3>Поля и правила</h3>",
    p("Имена партиций отправляются точно так, как введены; пустые строки и повторы отклоняются (`Every partition line must contain an exact partition name.`, `Duplicate partition names are not allowed.`). Запрос всегда идет с `type: full`, `commitMode: transactional` и `applyRefreshPolicy: false`, без `notifyOption`."),
    table(["Кнопка", "Что делает"], [
        ["[[New profile]]", "Очищает форму для нового профиля"],
        ["[[Save Profile]]", "Сохраняет форму под именем из [[Profile name]] в `partition-refresh-profiles.json`"],
        ["[[Delete]]", "Удаляет выбранный профиль после вопроса `Delete partition refresh profile \"…\"?`"],
        ["[[Start Partition Refresh]]", "Показывает окно подтверждения со всеми параметрами запроса ({{fig:confirm}}) и после [[OK]] отправляет запрос. Это настоящая удаленная операция: нажимайте [[OK]], только если все верно"],
        ["[[Refresh History]]", "Пишет в журнал последние 10 обновлений модели: ID запроса, статус, время начала. Только чтение"],
    ], cls="t k"),
    schema("Окно подтверждения перед [[Start Partition Refresh]]. Текст повторяет код страницы; данные вымышленные, вид окна зависит от браузера.", CONFIRM, "confirm"),
    "<h3>После отправки</h3>",
    ul([
        "В журнале появляется `Accepted as request <ID>. Processing continues server-side.` Обработка продолжается в Power BI Service, даже если панель или компьютер отключатся.",
        "Пока запрос выполняется, панель проверяет статус каждые 10 секунд. Проверка статуса и история используют только чтение (GET) и никогда не отправляют запрос повторно.",
        "Карточка статуса показывает [[Request ID]], [[Submitted]], [[Status]], [[Extended]], [[Start]], [[End]], [[Attempts]], статус каждой партиции и время последней проверки.",
        "Сочетание `Status: Unknown` и `Extended: InProgress` означает, что запрос выполняется нормально. Конечные статусы - Completed, Failed, Cancelled, Disabled.",
        "Если подробный статус недоступен, итог берется из истории обновлений с пометкой `Final status from refresh history. Partition details are unavailable there.`",
        "Пока предыдущий запрос не закончен, новый не отправится: `The current partition refresh is still in progress. Check its status before starting another request.`",
    ]),
    p("Если вход истек, карточка помечается `Last known status. Authenticate to verify the current state.`: войдите снова на вкладке Refresh. Уже принятый запрос при этом продолжает работать. Требования: MSAL.PS, права на модель и емкость Premium, PPU или Embedded."),
]), "partition", newpage=True)

# 10 --------------------------------------------------------------------------------
REBIND_FLOW = flow([
    ("v", "1. Scan", "Только чтение. Находит старые GUID и запоминает файлы."),
    ("v", "2. Резюме", "Сколько файлов и замен, какие предупреждения."),
    ("v", "3. Ваше решение", "[[Continue with Apply]] или [[Do not continue]]."),
    ("g", "4. Apply", "Замена в файлах из Scan, затем проверка: старых GUID не осталось."),
])

section("rebind-what", "Rebind: что это и когда нужен", "".join([
    p("Rebind заменяет GUID рабочих областей, dataflow и dataset в исходниках PBIP-проекта. Это нужно, когда вы копируете проект между средами, например из DEV в TEST, и ссылки в M-запросах или метаданных отчета должны указывать на объекты новой среды.", "lede"),
    p("Так выглядит типичный источник данных в `.tmdl`-файле модели; Rebind меняет GUID внутри кавычек:"),
    code('Workspace = Workspaces{[workspaceId="00000000-0000-0000-0000-0000000000d1"]}[Data],\n'
         'Dataflow = Workspace{[dataflowId="00000000-0000-0000-0000-0000000000d2"]}[Data],'),
    "<h3>Где идет замена</h3>",
    ul([
        "файлы `.tmdl` семантической модели (блоки `source =` в партициях);",
        "`expressions.tmdl` (общие M-запросы и параметры);",
        "JSON-файлы отчета, если GUID встречается в них.",
    ]),
    p("Rebind проверяет все файлы `.tmdl` и `.json` проекта во всех вложенных папках. Исключаются только папки `.pbi` (локальный кэш Power BI Desktop). Любой другой TMDL- или JSON-файл со старым GUID будет изменен."),
    schema("Порядок работы Rebind. Пока вы не выбрали [[Continue with Apply]], файлы не меняются.", REBIND_FLOW),
    "<h3>Перед началом</h3>",
    ul([
        "Rebind не требует входа и MSAL.PS и работает на любом компьютере с Windows.",
        "Apply меняет файлы на месте. Убедитесь, что проект под контролем версий (Git), чтобы изменения можно было посмотреть и откатить.",
        "Для каждой пары нужны старый и новый GUID. Одинаковые старый и новый GUID, повторяющийся старый GUID и цепочки (новый GUID одной пары - старый в другой) сервер отклоняет. Цепочку делайте двумя отдельными запусками.",
    ]),
]), "rebind")

# 11 --------------------------------------------------------------------------------
section("rebind-run", "Rebind: Scan и Apply", "".join([
    p("Работа в два шага: [[Scan]] показывает, что изменится, [[Apply]] заменяет и проверяет. Между ними - понятное резюме и ваше решение.", "lede"),
    shot("08-rebind-form", "Вкладка Rebind с выбранным профилем до Scan.", "real", [
        (1, "#pillRebind", "Вкладка [[Rebind]].", "b"),
        (2, "#rebindProfileList .profile-card", "Профиль Rebind: число пар и папка проекта.", "ri"),
        (3, "#rebindProfileName", "[[Profile name]]. Если оставить пустым, при сохранении подставится `Rebind-<дата>`.", "ri"),
        (4, "#reportPath", "[[Report folder path]] - полный путь к папке PBIP-проекта. В ней должен быть файл `.pbip` или папка `.Report` или `.SemanticModel`. Путь вписывается вручную.", "ri"),
        (5, "#mappingList .mapping-row select", "[[Type]]: Workspace, Dataflow или Dataset.", "r"),
        (6, (420, 412), "[[Old GUID]] - что заменить."),
        (7, (805, 434), "⇅ меняет местами старый и новый GUID."),
        (8, (420, 456), "[[New GUID]] - на что заменить. Зеленая рамка - GUID верный, красная - нет."),
        (9, (805, 368), "✕ удаляет пару (последнюю пару удалить нельзя)."),
        (10, ".btn-add-mapping", "[[Add mapping]] - добавить пару.", "r", 12),
        (11, "#formRebind .form-footer .btn-save", "[[Save Profile]] - сохранить профиль.", "l"),
        (12, "#controlsRebind .pipeline", "Точки этапов [[Scan]], [[Replace]], [[Verify]].", "b", -40),
        (13, "#btnScan", "[[Scan]] - шаг 1.", "b", 0, 6),
        (14, "#btnApply", "[[Apply]] - шаг 2. Доступна только после успешного Scan.", "b", 0, 6),
    ]),
    p("Пары и путь сохраняются в браузере и не теряются при перезапуске. Профили лежат в `rebind-profiles.json`; сохранить можно и черновик с пустой папкой или неполным GUID (панель спросит `No mappings have valid GUIDs on both sides. Save anyway?`), но в Scan пойдут только полные пары. [[New profile]] очищает форму, [[Delete]] спрашивает `Delete rebind profile \"…\"?`."),
    "<h3>Шаг 1. Scan</h3>",
    p("Нажмите [[Scan]]. Статус - [[Scanning...]], точка [[Scan]] синяя. Фоновый процесс:"),
    steps([
        "находит все `.tmdl` и `.json` файлы проекта, кроме папок `.pbi`;",
        "для каждой пары ищет все вхождения старого GUID и показывает до 2 строк с совпадениями для каждого файла;",
        "проверяет, нет ли нового GUID уже в проекте (частично перенесенный проект);",
        "отмечает совпадения в необычных местах, например в JSON вне отчета;",
        "запоминает список файлов со старыми GUID и отпечаток каждого (SHA-256, размер, кодировка) - к нему будет привязан Apply.",
    ]),
    p("Scan ничего не меняет. Журнал заканчивается строками `SCAN DONE: …`, `Total hits: …` и `=== Review scan results, then click Apply to proceed ===`, а под журналом появляется резюме."),
    shot("09-rebind-scan", "После Scan: технический журнал и резюме с решением.", "real", [
        (1, "#controlsRebind .pipeline", "Точка [[Scan]] зеленая.", "b", -40),
        (2, "#logsRebind", "Технический журнал: какие файлы и строки содержат старые GUID.", "tr", -6, 6),
        (3, "#rebindLogResizeHandle", "Ручку можно тянуть, чтобы изменить высоту журнала.", "c", 60),
        (4, (1035, 447), "Заголовок резюме: [[Ready to apply]], [[Review before continuing]] (есть предупреждения) или [[Nothing to rebind]] (совпадений нет, Apply недоступна)."),
        (5, "#rebindSummaryStats", "[[files inspected]], [[files containing old GUIDs]], [[replacements proposed]], [[items to review]].", "tr", -4, -2),
        (6, "#rebindSummaryDetails", "Предупреждения простыми словами или `No warnings were found.`", "l", -2),
        (7, "#btnSummaryApply", "[[Continue with Apply]] - перейти к замене.", "l", -2),
        (8, "#btnSummaryStop", "[[Do not continue]] - остановиться; проект не меняется.", "r"),
        (9, "#btnApply", "[[Apply]] делает то же, что [[Continue with Apply]].", "b", 0, 2),
    ], crop=(816, 90, 624, 630), width="66%"),
    table(["Предупреждение в резюме", "Что значит"], [
        ["N mapping(s) have no matches", "Старый GUID этой пары не найден"],
        ["N new GUID occurrence(s) already exist", "Новый GUID уже есть в проекте: возможно, его уже частично перенесли"],
        ["N match(es) are in an unexpected JSON context", "Совпадение в JSON-файле вне отчета: проверьте по журналу"],
        ["N file(s) or folder(s) could not be inspected (…), so Apply is disabled", "Файл не прочитан, например из-за неподдерживаемой кодировки. Apply недоступна до исправления и нового Scan"],
    ]),
    "<h3>Решение</h3>",
    p("Отдельного окна подтверждения нет: резюме Scan и есть точка решения."),
    ul([
        "[[Continue with Apply]] (или [[Apply]] вверху) запускает шаг 2.",
        "[[Do not continue]] просит сервер отменить результат Scan. После подтверждения сервера резюме показывает [[Stopped - nothing was changed]], статус - [[Not applied]]. Если сервер не подтвердил, резюме показывает [[Stop was not confirmed]]: Apply остается недоступной, перед любым Apply нужен новый Scan.",
        "Любое изменение пути или пар после Scan отменяет его результат, и Scan нужно повторить.",
    ]),
    "<h3>Шаг 2. Apply</h3>",
    p("Статус - [[Applying...]], затем точки [[Replace]] и [[Verify]]. Перед записью сервер проверяет, что путь и пары не изменились и что Apply относится именно к показанному Scan. Затем фоновый процесс:"),
    steps([
        "работает только с файлами из списка Scan и перед первой записью сверяет каждый с отпечатком. Если файл изменился, исчез или не читается, ничего не записывается, а резюме называет этот файл;",
        "заменяет старые GUID файл за файлом. Каждый файл записывается целиком через временный файл и сохраняет свою кодировку (UTF-8 с BOM или без, UTF-16 с BOM). При первой ошибке записи процесс останавливается и сообщает, какие файлы уже изменены, а какие нет;",
        "проверяет результат: перечитывает файлы из списка Scan и все текущие TMDL- и JSON-файлы проекта. Успех - только если старых GUID нигде нет; каждая оставшаяся строка попадает в журнал;",
        "пишет итоги в журнал и в резюме.",
    ]),
    shot("10-rebind-apply", "После Apply: замена выполнена и проверена.", "real", [
        (1, "#controlsRebind .pipeline", "Все три точки зеленые.", "b", -40),
        (2, "#logsRebind", "Журнал: `OK:` по каждой паре, `=== PASS ===` и напоминание открыть отчет в Power BI Desktop.", "tr", -6, 6),
        (3, (1145, 447), "[[Rebind completed and verified]] или, если проверка не прошла, [[Rebind needs attention]]."),
        (4, "#rebindSummaryStats", "[[files changed]], [[replacements written]], [[mappings processed]], [[old-GUID lines remaining]].", "tr", -4, -2),
        (5, "#rebindSummaryDetails", "Следующий шаг или, при ошибке, список проблем.", "l", -2),
        (6, "#btnSummaryReset", "[[Run another scan]] - начать заново.", "r"),
    ], crop=(816, 90, 624, 630), width="66%"),
    "<h3>После Rebind</h3>",
    steps([
        "Откройте проект в Power BI Desktop и обновите данные, чтобы убедиться, что источники подключаются. Панель не может проверить живое соединение.",
        "Посмотрите изменения в Git и зафиксируйте их.",
    ]),
    "<h3>Защиты и журналы</h3>",
    ul([
        "Одновременно идет только одна операция Rebind; это гарантирует файл блокировки `rebind.lock`, который процесс держит открытым до конца работы, даже после перезапуска сервера.",
        "Текущее состояние операции хранится в `rebind-status.json`; непредвиденные ошибки процесса дописываются в `logs\\rebind-worker-errors.log`.",
        "Если процесс завершился, не закончив работу, статус помечается как прерванный. После прерванного Apply часть файлов может быть уже изменена: сделайте новый Scan.",
        "Если другая операция заменила вашу, резюме покажет `Another Rebind operation replaced this one`: запустите Scan заново.",
    ]),
]), "rebind")

# 12 --------------------------------------------------------------------------------
section("files", "Где лежат файлы и журналы", "".join([
    p("Все, что панель создает сама, лежит в папке программы или в `%LOCALAPPDATA%`. Локальные профили, пути, ID, адреса, журналы и статусы исключены из Git через `.gitignore`.", "lede"),
    "<h3>Папка программы</h3>",
    table(["Файл или папка", "Что это"], [
        ["`setup.bat`, `setup.ps1`", "Установка для текущего пользователя и проверка готовности"],
        ["`launch-app.bat`", "Запуск в отдельном окне Edge (на него указывают ярлыки)"],
        ["`launch.bat`", "Запуск сервера в видимой консоли с обычным браузером"],
        ["`server.ps1`", "Сервер панели и все его команды"],
        ["`index.html`, `favicon.png`", "Окно панели и его значок"],
        ["`partition-refresh.ps1`", "Проверка запроса Partition Refresh и чтение его статуса"],
        ["`refresh-email.ps1`", "Отправка готового письма в flow Power Automate"],
        ["`runtime\\`", "Процессы обновления и Rebind, вход (`powerbi-auth.ps1`), поиск по названию"],
        ["`validation\\`", "Проверки до и после обновления и итоговое письмо; описание в `validation\\README.md`"],
        ["`profiles.json`", "Профили Refresh (создается при первом сохранении)"],
        ["`partition-refresh-profiles.json`", "Профили Partition Refresh"],
        ["`rebind-profiles.json`", "Профили Rebind"],
        ["`*.example.json`", "Примеры формата профилей с вымышленными значениями"],
        ["`refresh-status.json`, `refresh-worker.json`", "Текущий статус обновления и номер его процесса (создаются сами)"],
        ["`partition-refresh-status.json`", "Последний принятый запрос Partition Refresh"],
        ["`rebind-status.json`, `rebind.lock`", "Текущий статус Rebind и его блокировка (создаются сами)"],
        ["`logs\\`", "`refresh-worker-errors.log`, `rebind-worker-errors.log` - ошибки фоновых процессов"],
        ["`README.md`, `REQUIREMENTS.md`, `SECURITY.md`, `LICENSE`", "Описание, требования, правила по секретам, лицензия"],
        ["`release-check.ps1`, `_validate.ps1`, `_*-tests.*`", "Проверки для тех, кто меняет код"],
        ["`docs\\manual\\`", "Это руководство (HTML и PDF) и его исходники"],
    ]),
    "<h3>Папки пользователя</h3>",
    table(["Путь", "Что это"], [
        ["`%LOCALAPPDATA%\\PowerBIChainedRefresh\\msalcache.bin3`", "Зашифрованный кэш входа по коду"],
        ["`%LOCALAPPDATA%\\PowerBIChainedRefresh\\runs\\`", "Папка каждого запуска Refresh: `refresh-log.txt`, `summary.json`, снимки проверки, `email.html` или `email-preview.html`"],
        ["`%LOCALAPPDATA%\\PowerBIControlPanel\\`", "Профиль Edge для окна панели и значок ярлыков"],
    ]),
]))

# 13 --------------------------------------------------------------------------------
section("timing", "Настройка таймингов", "".join([
    p("Два значения Refresh можно менять в файле `runtime\\refresh-engine.ps1`. После правки перезапустите панель: закройте ее окно или консоль и снова запустите ярлык.", "lede"),
    table(["Что", "Сейчас", "Строка в `runtime\\refresh-engine.ps1`"], [
        ["Интервал проверки статуса dataflow и моделей", "30 секунд", "`$script:RefreshPollSeconds = 30`"],
        ["Максимальное время ожидания всей цепочки", "11 часов", "`$script:RefreshBudgetHours = 11`"],
    ]),
    p("Интервал общий для dataflow и моделей. Элементы, не закончившиеся за отведенное время, получают Failed. У Rebind таймингов нет: он работает локально, и время зависит только от размера проекта."),
    "<h3>Другие интервалы (для справки)</h3>",
    p("Эти значения заданы в коде; README их менять не предлагает.", "note"),
    table(["Что", "Значение", "Где"], [
        ["Сколько подряд непрочитанных статусов до Unknown", "20 проверок, около 10 минут", "`$script:RefreshUnreadableLimit`"],
        ["Повторы запуска модели при параллельном обновлении", "до 3", "`$script:RefreshModelRefusalLimit`"],
        ["Продление токена процессом обновления", "каждые 45 минут", "`$script:RefreshTokenRenewal`"],
        ["Продление токена сервером", "каждые 40 минут", "`server.ps1`"],
        ["Ожидание входа по коду", "10 минут", "`server.ps1`"],
        ["Список рабочих областей для поиска", "кэш 5 минут", "`server.ps1`"],
        ["Опрос статуса страницей", "Refresh 2 с, Rebind 1 с, Partition 10 с", "`index.html`"],
    ]),
]))

# 14 --------------------------------------------------------------------------------
LAYERS = ('<div class="layers">'
          '<div class="layer"><b>Окно</b><span>`index.html` в Edge. Показывает формы, точки и журналы и раз в несколько секунд спрашивает у сервера статус.</span></div>'
          '<div class="layer-arrow">↕</div>'
          '<div class="layer"><b>Сервер</b><span>`server.ps1` на `localhost:8765`. Хранит профили, держит токен в памяти, запускает фоновые процессы и отдает их статус.</span></div>'
          '<div class="layer-arrow">↕</div>'
          '<div class="layer"><b>Фоновые процессы</b><span>`runtime\\Invoke-RefreshRun.ps1` для Refresh и `runtime\\Invoke-RebindRun.ps1` для одного Scan или Apply. Пишут ход работы в файлы статуса.</span></div>'
          '<div class="layer-arrow">↕</div>'
          '<div class="layer"><b>Снаружи</b><span>Power BI REST API (Refresh, Partition, поиск по названию), flow Power Automate (письмо). Rebind наружу не обращается.</span></div>'
          '</div>')

section("inside", "Как это работает внутри", "".join([
    p("Короткое описание для тех, кому интересно, что происходит за кнопками.", "lede"),
    schema("Части панели и как они связаны.", md(LAYERS)),
    ul([
        "<b>Refresh.</b> Сервер проверяет ID и адреса и запускает скрытый процесс `runtime\\Invoke-RefreshRun.ps1`. План передается закодированным JSON, токен - только через переменные окружения процесса. Номер процесса записывается в `refresh-worker.json`, чтобы вкладка заметила, если процесс умер. Ход работы процесс пишет в `refresh-status.json`, страница его читает. Тот же процесс обновления использует и Claude-скилл `powerbi-chained-refresh`.",
        "<b>Partition Refresh.</b> Сервер сам отправляет один POST в Enhanced Refresh API и запоминает ID запроса в `partition-refresh-status.json`. Дальше он только читает статус и историю (GET).",
        "<b>Rebind.</b> Сервер проверяет запрос и запускает `runtime\\Invoke-RebindRun.ps1` в режиме Scan или Apply. Процесс захватывает `rebind.lock` и пишет статус в `rebind-status.json`; сервер отвечает странице, только когда процесс уже владеет статусом. Apply привязан к списку файлов и отпечаткам из Scan.",
        "<b>Поиск по названию.</b> Сервер читает рабочие области, отчеты, модели, dataflow и lineage из Power BI REST API только на чтение; в профиль сохраняются ID и названия для показа.",
    ]),
]))

# 15 --------------------------------------------------------------------------------
section("trouble", "Когда что-то идет не так", "".join([
    p("Сначала посмотрите журнал вкладки и строку статуса: в них почти всегда есть причина. Для проблем установки и входа запустите `setup.bat -CheckOnly` - он ничего не меняет.", "lede"),
    table(["Что видно", "Что сделать"], [
        ["Окно открылось, но страница пустая", "Сервер стартует несколько секунд. Подождите и обновите страницу"],
        ["[[Not signed in]] на вкладке Refresh", "Нажмите [[Authenticate for Refresh]] и завершите вход кодом из консоли"],
        ["Код для входа не появляется", "Проверьте интернет. `setup.bat -CheckOnly` покажет, установлен ли MSAL.PS"],
        ["[[MSAL.PS not installed]]", "Запустите `setup.bat` еще раз. Rebind работает и без MSAL.PS"],
        ["`setup.bat` пишет Not ready", "Причины перечислены под этими словами; исправьте их и запустите `setup.bat` снова"],
        ["`setup.bat` пишет `Could not unblock the files` или в проверке строка `Files FAIL`", "Запустите `setup.bat` еще раз. Если не помогло, разблокируйте сам ZIP-архив (Свойства, флажок Разблокировать) и распакуйте его заново"],
        ["Вход сертификатом не проходит ([[Try the certificate again]])", "`setup.bat -CheckOnly` покажет, найден ли сертификат и ключ. Проверьте, что открытая часть сертификата загружена в регистрацию приложения и что приложение - участник рабочей области"],
        ["Списки поиска пустые или `Sign in first to look up names.`", "Войдите. Список показывает только то, к чему у вас есть доступ; иначе используйте [[IDs and manual entry]]"],
        ["Ошибка `Dataflow refresh FAILED`", "Проверьте роль в рабочей области (нужна Member или выше) и ID в профиле"],
        ["Ошибка 404 или UnknownError", "Dataflow или модель не найдены: проверьте ID в профиле"],
        ["Статус [[Starting...]] не меняется или [[Worker died]]", "Процесс обновления не запустился или остановился. Смотрите `logs\\refresh-worker-errors.log` и журнал последнего запуска в `%LOCALAPPDATA%\\PowerBIChainedRefresh\\runs\\`"],
        ["`A refresh is already running`", "Дождитесь конца текущего обновления. Если его процесс уже завершился, кнопка снова доступна без перезапуска"],
        ["`... is already refreshing in the Power BI service` или `... is already active`", "Модель уже обновляется в службе или в другом запуске. Дождитесь окончания"],
        ["Статус Unknown у dataflow или модели", "Статус не читался около 10 минут. Обновление могло закончиться: проверьте историю обновлений в Power BI. Модели после такого dataflow не запускаются"],
        ["Предупреждение о письме: webhook не настроен", "Запустите `setup.bat`, вставьте URL flow и перезапустите панель; либо включите [[Dry run]]"],
        ["Обновление успешно, письмо с ошибкой", "Результат обновления сохранен. Сообщите владельцу панели текст ошибки из журнала"],
        ["Письмо: `The flow refused the signed-in call (HTTP 403)`", "Flow не принял ваш вход. Сообщите владельцу панели, под какой учетной записью вы вошли"],
        ["Письмо: `... a Power Automate token could not be obtained ...`", "Войдите заново на вкладке Refresh. Если не помогло, сообщите владельцу панели"],
        ["Partition: `Power BI rejected the partition refresh request: …`", "Проверьте имена таблицы и партиций, права на модель и емкость Premium, PPU или Embedded"],
        ["Partition: `Authenticate again to view status.`", "Войдите снова на вкладке Refresh. Принятый запрос продолжает работать"],
        ["Rebind: Scan не запускается", "Проверьте путь: `Report path does not exist` или `The selected folder does not look like a PBIP project`. Нужна папка с `.pbip`, `.Report` или `.SemanticModel`"],
        ["Rebind: [[Apply]] неактивна", "Сначала Scan и [[Continue with Apply]] в резюме. После изменения пути или пар Scan нужно повторить. При [[Nothing to rebind]] или непрочитанных файлах Apply недоступна"],
        ["Rebind: `Chained mappings are unsafe`", "Новый GUID одной пары совпадает со старым в другой. Разделите замену на два запуска"],
        ["Rebind: GUID не найден", "Проверьте GUID и что это PBIP-проект с файлами `.tmdl`"],
        ["Rebind: после Apply старые GUID остались", "Резюме [[Rebind needs attention]] и журнал называют файлы и строки. Исправьте причину и сделайте новый Scan"],
        ["Порт 8765 занят", "Закройте другой экземпляр или запустите `server.ps1 -Port 8877` (раздел 2)"],
        ["Значок вкладки браузера пустой", "Нажмите Ctrl+Shift+R"],
    ]),
]))

# 16 --------------------------------------------------------------------------------
section("limits", "Известные ограничения", "".join([
    ul([
        "Только Windows и Windows PowerShell 5.1. Сервер доступен только с этого же компьютера.",
        "Одновременно идет одно обновление Refresh и одна операция Rebind. Отмены начатого обновления и расписания нет.",
        "Partition Refresh отправляет только полное транзакционное обновление (`full`, `transactional`) без политики инкрементального обновления и хранит статус только последнего принятого запроса. Нужна емкость Premium, PPU или Embedded.",
        "Поиск по названию видит только то, к чему у вас есть доступ. Ручной ввод ID остается.",
        "Письма уходят только через flow Power Automate.",
        "Снимок проверки «до» берется после развертывания модели и не показывает влияние самого развертывания.",
        "Rebind меняет только файлы `.tmdl` и `.json`, пропускает папки `.pbi`, читает кодировки UTF-8 (с BOM или без) и UTF-16 с BOM, не проверяет живое соединение и не делает цепочки замен за один запуск. Папку проекта нужно вписать вручную: кнопки выбора папки в окне нет.",
        "На вкладке Partition значок входа показывает [[Checking sign-in]], пока после запуска не открыта вкладка Refresh.",
        "Встроенная справка [[?]] местами устарела: она говорит о двух операциях вместо трех, о строке `SCAN COMPLETE` (в журнале пишется `SCAN DONE`) и о файле `logs\\worker-start.log` (ошибки процесса пишутся в `logs\\refresh-worker-errors.log`). Ориентируйтесь на это руководство.",
    ]),
]))

# 17 --------------------------------------------------------------------------------
GLOSSARY = [
    ("Рабочая область (workspace)", "Папка в Power BI Service с отчетами, моделями и dataflow. У каждой свой GUID."),
    ("Семантическая модель (semantic model, dataset)", "Модель данных, из которой читает отчет. В API и в Rebind называется dataset."),
    ("Dataflow", "Набор запросов Power Query в Power BI Service, который готовит данные для моделей."),
    ("Lineage", "Связи «откуда читает»: по ним панель находит dataflow выбранной модели."),
    ("Профиль", "Сохраненный набор настроек вкладки: что обновлять или что заменять."),
    ("Device code", "Вход по коду: код из консоли вводится на странице Microsoft, вход идет под вашей учетной записью."),
    ("Service principal (сертификат)", "Вход от имени приложения по сертификату, без участия человека."),
    ("MSAL.PS", "Модуль PowerShell для входа в Microsoft Entra ID. Нужен для Refresh и Partition."),
    ("Access-токен", "Временный пропуск к Power BI API, живет около часа."),
    ("Refresh-токен", "Хранится в кэше входа и позволяет получать новые access-токены без повторного входа."),
    ("Enhanced Refresh", "Режим Power BI REST API для обновления выбранных таблиц и партиций."),
    ("Партиция (partition)", "Часть таблицы модели, например один месяц, которую можно обновлять отдельно."),
    ("Емкость (capacity)", "Premium, PPU или Embedded: нужна для Enhanced Refresh."),
    ("DirectQuery, live connection", "Модели, которые не хранят данные сами. Обновлять их нечего, поэтому панель их не добавляет."),
    ("PBIP", "Проект Power BI в виде папки с текстовыми файлами: `.pbip`, папки `.Report` и `.SemanticModel`."),
    ("TMDL", "Текстовый формат описания модели в PBIP-проекте, файлы `.tmdl`."),
    ("GUID", "Идентификатор вида `00000000-0000-0000-0000-000000000000`."),
    ("Пара (mapping)", "Строка Rebind: тип, старый GUID и новый GUID."),
    ("Scan, Apply, Verify", "Шаги Rebind: поиск без изменений, замена, проверка результата."),
    ("Отпечаток (SHA-256)", "Контрольная сумма файла. Apply сверяет ее, чтобы не менять файл, изменившийся после Scan."),
    ("Dry run", "Пробный режим письма: письмо показывается в журнале и не отправляется."),
    ("Model only", "Запуск только моделей профиля, без dataflow, на один раз."),
    ("Flow, HTTP-триггер, webhook URL", "Поток Power Automate, который запускается POST-запросом на свой URL и отправляет письмо. URL выдает владелец панели."),
    ("Процесс обновления (runner, worker)", "Скрытый процесс PowerShell, который ведет одно обновление или один Scan или Apply."),
    ("Статус Unknown", "Результат не подтвержден: статус не читался около 10 минут."),
    ("Строгий шлюз", "Правило Refresh: модели не запускаются, если хоть один dataflow не закончился успешно."),
]

section("glossary", "Словарь", '<dl class="gloss">' + "".join(
    f'<div class="gloss-item"><dt>{md(t)}</dt><dd>{md(d)}</dd></div>' for t, d in GLOSSARY) + "</dl>")

# 18 --------------------------------------------------------------------------------
FAQ = [
    ("Нужен ли вход для Rebind?", "Нет. Rebind работает с локальными файлами и не требует ни входа, ни MSAL.PS."),
    ("Почему кнопка [[Start Refresh]] неактивна?", "Вход не выполнен: значок показывает [[Not signed in]]. Нажмите [[Authenticate for Refresh]]. Во время обновления кнопка тоже неактивна."),
    ("Почему модель не добавляется в профиль?", "Это модель DirectQuery или live connection: обновлять ее нечего. Под полем будет `... cannot be refreshed (DirectQuery or live connection), so it was not added.`"),
    ("Можно ли в одном профиле объединить разные рабочие области?", "Да. Поле [[Workspace]] только задает, где искать; у каждой строки модели и dataflow своя рабочая область."),
    ("Как обновить только модель, без dataflow?", "Отметьте [[Model only]] перед запуском. Флажок действует на один запуск."),
    ("Где посмотреть письмо, если включен Dry run?", "В журнале вкладки (получатели, тема и строки сводки) и в файле `email-preview.html` в папке запуска в `%LOCALAPPDATA%\\PowerBIChainedRefresh\\runs\\`."),
    ("Что значит Unknown у dataflow?", "Статус не удалось прочитать около 10 минут, поэтому результат не подтвержден. Проверьте историю обновлений в Power BI. Модели после такого dataflow не запускаются."),
    ("Что будет с Partition Refresh, если закрыть панель?", "Принятый запрос продолжит выполняться в Power BI Service. Откройте панель снова и войдите: статус подтянется."),
    ("Можно ли отменить Apply?", "Средствами панели нет. Поэтому перед Apply проект должен быть в Git: изменения можно посмотреть и откатить."),
    ("Почему после Apply нужно открывать Power BI Desktop?", "Панель меняет только текст файлов и не может проверить, что новые источники доступны. Это проверяет обновление данных в Desktop."),
    ("Почему [[Apply]] неактивна?", "Нужен успешный Scan с совпадениями и без непрочитанных файлов. Любая правка пути или пар после Scan требует нового Scan."),
    ("Как войти под другой учетной записью?", "Кнопки выхода в панели нет. Закройте панель, удалите файл `%LOCALAPPDATA%\\PowerBIChainedRefresh\\msalcache.bin3` и запустите панель снова: на вкладке Refresh потребуется новый вход по коду."),
    ("Где хранятся мои профили и попадут ли они к другим?", "В файлах `*.json` в папке программы, только на вашем компьютере. В Git они не попадают."),
    ("Можно ли открыть панель дважды?", "Да: повторный запуск ярлыком открывает еще одно окно той же панели. Но одновременно идет только одно обновление Refresh и одна операция Rebind."),
]

section("faq", "Вопросы и ответы", "".join(
    f'<details class="faq-item" open><summary>{md(q)}</summary><div>{p(a)}</div></details>' for q, a in FAQ))


# ---------------------------------------------------------------- page
def build():
    blocks, toc, ptoc = [], [], []
    for i, (sid, title, cls, body, newpage) in enumerate(SECTIONS, 1):
        classes = " ".join(c for c in ("block", cls, "newpage" if newpage else "") if c)
        blocks.append(f'<section id="{sid}" class="{classes}"><h2><span class="n">{i}.</span>{html.escape(title)}</h2>{body}</section>')
        toc.append(f'<li><a href="#{sid}">{html.escape(title)}</a></li>')
        ptoc.append(f'<li><a href="#{sid}">{html.escape(title)}</a></li>')
    css = open(os.path.join(SRC, "manual.css"), encoding="utf-8").read()
    js = open(os.path.join(SRC, "manual.js"), encoding="utf-8").read()
    cover = ('<section class="cover" aria-label="Титульная страница">'
             '<h2>Power BI Dashboard Control Panel<br>Руководство пользователя</h2>'
             '<p class="sub">Установка панели, вход в Power BI, обновление dataflow и семантических моделей, '
             'обновление отдельных партиций и перенос PBIP-проектов между средами.</p>'
             f'<p class="meta">Для версии {VERSION}\u00a0 · \u00a0{MONTH}</p></section>')
    printed_toc = ('<nav class="ptoc" aria-label="Содержание для печати"><h2>Содержание</h2><ol>' + "".join(ptoc) + "</ol>"
                   + p("Названия кнопок, вкладок и полей даны так, как они написаны в панели, по-английски.", "note") + "</nav>")
    page = f"""<!doctype html>
<html lang="ru" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>Power BI Dashboard Control Panel - руководство пользователя</title>
<style>{css}</style>
</head>
<body>
<header class="top">
  <div class="top-in">
    <div class="brand"><div><p class="eyebrow">Power BI Dashboard Control Panel · {VERSION}</p><h1>Руководство пользователя</h1></div></div>
    <div class="search"><label for="q" class="sr">Поиск по руководству</label><input id="q" type="search" placeholder="Поиск: Dry run, Scan, Unknown, setup..." autocomplete="off"><span id="qn" class="qn" aria-live="polite"></span></div>
  </div>
</header>
<div class="layout">
  <nav class="toc" aria-label="Содержание"><details id="tocd" open><summary>Содержание</summary><ol>{"".join(toc)}</ol></details></nav>
  <main id="main">
  {cover}
  {printed_toc}
  {"".join(blocks)}
  </main>
</div>
<script>{js}</script>
</body>
</html>
"""
    numbers = {key: n for n, _, _, key in FIGURES if key}
    page = re.sub(r"\{\{fig:([\w-]+)\}\}", lambda m: "рис. " + str(numbers[m.group(1)]), page)
    check(page)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
    print("written", OUT, f"{len(page) / 1024 / 1024:.2f} MB", len(FIGURES), "figures", len(SECTIONS), "sections")


def check(page):
    """Refuses to write text that breaks the manual's rules or leaks private data."""
    text = re.sub(r"data:image/png;base64,[A-Za-z0-9+/=]+", "", page)
    problems = []
    for ch, name in (("\u0451", "yo"), ("\u0401", "Yo"), ("\u2014", "em dash"), ("\u2013", "en dash")):
        if ch in text:
            problems.append(f"{name} at: {text[max(0, text.index(ch) - 40):text.index(ch) + 10]!r}")
    for guid in re.findall(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", text):
        if not guid.startswith("00000000-0000-0000-0000-"):
            problems.append("GUID " + guid)
    for domain in re.findall(r"(?i)\b[A-Z0-9._%+-]+@([A-Z0-9-]+(?:\.[A-Z0-9-]+)+)\b", text):
        if domain.lower() not in ("example.com", "example.org", "company.com", "contoso.com"):
            problems.append("email domain " + domain)
    for pattern in (r"(?i)c:\\users\\", r"(?i)\\repos\\", r"(?i)paras(?!chakis)", r"eyJ[A-Za-z0-9_-]{10,}", r"https?://(?!localhost)[^\s\"'<>]*\.(?:css|js|woff2?)"):
        if re.search(pattern, text):
            problems.append("pattern " + pattern)
    if re.search(r"<(?:link|script|img)[^>]+(?:href|src)=\"https?://", text):
        problems.append("external resource")
    if problems:
        raise SystemExit("Manual not written:\n  " + "\n  ".join(problems))


build()
