"""Generate the synthetic test scenes (24-bit BMP) used by tests/harness.ahk.

A blocky "game scene" plus versions blended with white (a flash at 0..100 %),
local white areas, a white HUD strip and coloured / bright surfaces.
Usage: python3 gen_scenes.py <output dir>
"""
import struct, random, sys, os
W, H = 64, 36
out = sys.argv[1] if len(sys.argv) > 1 else "img"
os.makedirs(out, exist_ok=True)
random.seed(7)
palette = [(60,50,40),(90,80,70),(40,45,50),(120,100,80),(70,90,60),(150,130,100),(30,30,35),(100,105,110)]
# blocky "game scene": 8x6 blocks with per-pixel noise
blocks = [[random.choice(palette) for _ in range(8)] for _ in range(6)]
def scene(x, y):
    r,g,b = blocks[y*6//H][x*8//W]
    n = random.randint(-12, 12)
    return tuple(max(0, min(255, c+n)) for c in (r,g,b))
base = [[scene(x,y) for x in range(W)] for y in range(H)]
def save(name, px):
    data = b''
    for y in range(H-1, -1, -1):
        data += b''.join(bytes((int(b),int(g),int(r))) for (r,g,b) in px[y])
    hdr = b'BM' + struct.pack('<IHHI', 54+len(data), 0, 0, 54) + struct.pack('<IiiHHIIiiII', 40, W, H, 1, 24, 0, len(data), 2835, 2835, 0, 0)
    open(os.path.join(out, name + '.bmp'), 'wb').write(hdr + data)
def blend(px, f):
    return [[tuple(round(c*(1-f) + 255*f) for c in p) for p in row] for row in px]
def solid(c): return [[c]*W for _ in range(H)]
def noisy(c): return [[tuple(max(0,min(255,v+random.randint(-10,10))) for v in c) for _ in range(W)] for _ in range(H)]
save('normal', base)
for p in range(0, 101, 5):
    save('blend%03d' % p, blend(base, p/100))
loc = [row[:] for row in base]
for y in range(0, int(H*0.40)):
    for x in range(0, int(W*0.30)): loc[y][x] = (255,255,255)
save('localized', loc)
hud = [row[:] for row in base]
for y in range(int(H*0.75), H):
    for x in range(W): hud[y][x] = (255,255,255)
save('hudstrip', hud)
save('yellow', solid((255,230,0)))
sky = [row[:] for row in base]
for y in range(0, int(H*0.40)):
    for x in range(W): sky[y][x] = (150,190,235)
save('sky', sky)
save('sandwall', noisy((205,185,150)))
save('greywall', noisy((200,200,200)))
save('white', solid((255,255,255)))
# partial flash over the sand wall map (bright scene)
save('sand_blend050', blend(noisy((205,185,150)), 0.5))
