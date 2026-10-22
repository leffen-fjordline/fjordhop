# Regenerate the app's icons from the source images in resources/.
#   uv run --with pillow python app/make-icons.py
# Writes AppIcon.icns and MenuBarIcon{,@2x}.png next to this file. Only needed
# when the source images change; build.sh uses the committed outputs.
import shutil, subprocess, tempfile
from pathlib import Path
from PIL import Image

here = Path(__file__).parent
src = here.parent / "resources"

# App icon: drop the near-transparent specks the generator left around the
# squircle, then fit it to Apple's grid (824 px squircle on a 1024 canvas).
icon = Image.open(src / "app-icon.png").convert("RGBA")
r, g, b, a = icon.split()
a = a.point(lambda v: 0 if v < 32 else v)
icon = Image.merge("RGBA", (r, g, b, a))
icon = icon.crop(a.getbbox())
icon.thumbnail((824, 824), Image.LANCZOS)
canvas = Image.new("RGBA", (1024, 1024))
canvas.paste(icon, ((1024 - icon.width) // 2, (1024 - icon.height) // 2))

iconset = Path(tempfile.mkdtemp()) / "AppIcon.iconset"
iconset.mkdir()
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pt * scale
        name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        canvas.resize((px, px), Image.LANCZOS).save(iconset / name)
subprocess.run(["iconutil", "-c", "icns", "-o", here / "AppIcon.icns", iconset], check=True)
shutil.rmtree(iconset.parent)

# Menu bar icon: a template image, i.e. black on transparent; macOS tints it
# for light and dark menu bars. 18 pt square, with a 1 pt margin.
glyph = Image.open(src / "switcher-1.png").convert("RGBA").getchannel("A")
glyph = glyph.crop(glyph.point(lambda v: 255 if v >= 64 else 0).getbbox())
for scale, name in ((1, "MenuBarIcon.png"), (2, "MenuBarIcon@2x.png")):
    size, inner = 18 * scale, 16 * scale
    g = glyph.copy()
    g.thumbnail((inner, inner), Image.LANCZOS)
    out = Image.new("RGBA", (size, size))
    out.paste(Image.new("RGBA", g.size, (0, 0, 0, 255)), ((size - g.width) // 2, (size - g.height) // 2), g)
    out.save(here / name)
