"""LinkedIn slides (1080x1350, 4:5) from the QField and dashboard screenshots."""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SHOTS = os.environ.get("SHOTS", os.path.expandvars("$S/e2e/promo_shots/screenshots"))
DASH = os.environ.get("DASH", "dashboard")
QR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "docs", "media", "install-qr.png")
OUT = os.environ.get("OUT", "slides")
W, H = 1080, 1350
FOREST, GRASS, LIGHT, NIGHT, POLAR = "#004C45", "#73D19C", "#EFF5F3", "#12181F", "#FFFFFF"
F = "/usr/share/fonts/google-noto/NotoSans-%s.ttf"
font = lambda w, s: ImageFont.truetype(F % w, s)


def wrap(draw, text, fnt, width):
    lines, line = [], ""
    for word in text.split():
        trial = (line + " " + word).strip()
        if draw.textlength(trial, font=fnt) <= width:
            line = trial
        else:
            lines.append(line); line = word
    lines.append(line)
    return lines


def text_block(draw, xy, text, fnt, fill, width, spacing=1.25):
    x, y = xy
    for ln in wrap(draw, text, fnt, width):
        draw.text((x, y), ln, font=fnt, fill=fill)
        y += int(fnt.size * spacing)
    return y


def rounded(img, r):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], r, fill=255)
    out = img.convert("RGBA"); out.putalpha(mask)
    return out


def shadow(canvas, box, r, offset=18, blur=28, alpha=70):
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    x0, y0, x1, y1 = box
    ImageDraw.Draw(sh).rounded_rectangle([x0, y0 + offset, x1, y1 + offset], r, fill=(0, 0, 0, alpha))
    canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur)))


def phone(canvas, shot, x, y, sw):
    """Screenshot (1:2) in a simple phone frame; (x, y) = top-left of the frame."""
    sh = int(sw * 2); bezel = max(12, sw // 32); r = sw // 9
    fw, fh = sw + 2 * bezel, sh + 2 * bezel
    shadow(canvas, (x, y, x + fw, y + fh), r + bezel)
    body = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle([0, 0, fw - 1, fh - 1], r + bezel, fill=NIGHT)
    canvas.alpha_composite(body, (x, y))
    screen = rounded(Image.open(shot).convert("RGB").resize((sw, sh), Image.LANCZOS), r)
    canvas.alpha_composite(screen, (x + bezel, y + bezel))
    return fw, fh


def card(canvas, img, x, y, w, r=24):
    im = Image.open(img).convert("RGB") if isinstance(img, str) else img
    h = int(im.size[1] * w / im.size[0])
    shadow(canvas, (x, y, x + w, y + h), r, offset=12, blur=22, alpha=55)
    canvas.alpha_composite(rounded(im.resize((w, h), Image.LANCZOS), r), (x, y))
    return h


def slide(bg, kicker, title, subtitle, n, dark=False):
    c = Image.new("RGBA", (W, H), bg)
    d = ImageDraw.Draw(c)
    fg = POLAR if dark else FOREST
    sub = "#CFE3DD" if dark else NIGHT
    y = 70
    if kicker:
        d.text((72, y), kicker.upper(), font=font("SemiBold", 26), fill=GRASS if dark else "#2E7D5B"); y += 48
    y = text_block(d, (72, y), title, font("Bold", 60), fg, W - 144, 1.15) + 8
    if subtitle:
        y = text_block(d, (72, y), subtitle, font("Regular", 31), sub, W - 144, 1.35)
    # footer
    d.text((72, H - 62), "QField plugin for Mergin Maps", font=font("SemiBold", 22), fill=fg)
    t = f"{n}/6"
    d.text((W - 72 - d.textlength(t, font=font("Regular", 22)), H - 62), t, font=font("Regular", 22), fill=sub)
    return c, d, y


def save(c, name):
    path = os.path.join(OUT, name)
    c.convert("RGB").save(path, quality=95)
    return path


os.makedirs(OUT, exist_ok=True)
paths = []

# 1 cover
c, d, y = slide(FOREST, "QField × Mergin Maps", "Collect in QField. Sync with Mergin Maps.",
                "An open-source QField plugin: sign in, download your projects, edit offline and sync, with Mergin's own geodiff engine.", 1, dark=True)
phone(c, f"{SHOTS}/03_map.png", (W - 430) // 2 - 13, y + 40, 430)
paths.append(save(c, "01-cover.png"))

# 2 sign in
c, d, y = slide(LIGHT, "Sign in", "Your Mergin Maps account, in QField",
                "app.merginmaps.com by default, or your own Enterprise or Community Edition server. New users can sign up.", 2)
phone(c, f"{SHOTS}/01_login.png", (W - 420) // 2 - 13, y + 36, 420)
paths.append(save(c, "02-sign-in.png"))

# 3 workspaces and projects
c, d, y = slide(LIGHT, "Projects", "Every workspace, every project",
                "Switch workspaces, search, and download a project in one tap, laid out like Mergin Maps mobile.", 3)
sw = 400; gap = 56; x0 = (W - (2 * (sw + 26) + gap)) // 2
phone(c, f"{SHOTS}/08_workspaces.png", x0, y + 40, sw)
phone(c, f"{SHOTS}/09_my_team.png", x0 + sw + 26 + gap, y + 40, sw)
paths.append(save(c, "03-projects.png"))

# 4 sync
c, d, y = slide(LIGHT, "Sync", "Edit offline. Sync in one tap.",
                "Your edits are merged feature by feature with your colleagues', and conflicts are handled the same way as in the other Mergin Maps apps.", 4)
phone(c, f"{SHOTS}/04_syncing.png", x0, y + 40, sw)
phone(c, f"{SHOTS}/05_synced.png", x0 + sw + 26 + gap, y + 40, sw)
paths.append(save(c, "04-sync.png"))

# 5 dashboard
c, d, y = slide(LIGHT, "Mergin Maps dashboard", "Every field edit, in the version history",
                "QField pushes real geodiff changesets. The dashboard shows exactly what changed, feature by feature.", 5)
changes = Image.open(f"{DASH}/dash_changes.png").convert("RGB").crop((440, 250, 1770, 935))
version = Image.open(f"{DASH}/dash_version.png").convert("RGB")
vx = int(version.size[0] * 0.625)
version = version.crop((vx, 150, version.size[0] - 40, 930))   # version, author, date, user agent
h1 = card(c, changes, 72, y + 36, W - 144)
y2 = y + 36 + h1 + 34
h2 = card(c, version, 72, y2, 380)
tx = 72 + 380 + 40
d.text((tx, y2 + 10), "Pushed from QField", font=font("SemiBold", 32), fill=FOREST)
text_block(d, (tx, y2 + 62), "The version's user agent is QField 4.3.6 with the plugin. Above: the new apiary added in the field (+) and an edited attribute (10 to 12 boxes).", font("Regular", 26), NIGHT, W - tx - 72, 1.4)
paths.append(save(c, "05-dashboard.png"))

# 6 how it works
c, d, y = slide(FOREST, "Under the hood", "geodiff, compiled to JavaScript",
                None, 6, dark=True)
bullets = [
    ("Same engine as Mergin Maps", "geodiff (C++) and SQLite compiled with Emscripten, running inside QField's QML engine. No native code, no QField fork."),
    ("Tested against the original", "geodiff's own test suite passes in Qt (85/85), and 1,000 random GeoPackage cases match native geodiff exactly."),
    ("Tested in real QField", "Every commit runs sign-in, downloads and two-user sync scenarios in QField 4.3.6."),
    ("Open source", "Plugin (GPL) and geodiff-js (MIT) on GitHub."),
]
y += 24
for head, body in bullets:
    d.ellipse([72, y + 12, 92, y + 32], fill=GRASS)
    d.text((116, y), head, font=font("SemiBold", 34), fill=POLAR)
    y = text_block(d, (116, y + 50), body, font("Regular", 27), "#CFE3DD", W - 116 - 72, 1.35) + 26
qr = Image.open(QR).convert("RGB").resize((230, 230), Image.NEAREST)
qy = H - 62 - 40 - 230
c.alpha_composite(rounded(qr, 16), (72, qy))
d.text((330, qy + 30), "Install in QField", font=font("SemiBold", 32), fill=POLAR)
text_block(d, (330, qy + 80), "Settings › Manage plugins › Install plugin from URL, then scan this code.", font("Regular", 25), "#CFE3DD", W - 330 - 72)
d.text((330, qy + 175), "github.com/saberraz/qfield-plugin-merginmaps", font=font("Medium", 23), fill=GRASS)
paths.append(save(c, "06-how-it-works.png"))

# PDF for a LinkedIn document (carousel) post
imgs = [Image.open(p).convert("RGB") for p in paths]
imgs[0].save(os.path.join(OUT, "qfield-mergin-maps-carousel.pdf"), save_all=True, append_images=imgs[1:], resolution=150)
print("\n".join(paths))
