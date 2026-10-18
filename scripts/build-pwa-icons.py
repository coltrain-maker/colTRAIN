"""Render the existing colTRAIN C/arrow mark as install icons (Pillow required).
PNG files are committed, so normal app builds do not need an image dependency.
"""
from pathlib import Path
from PIL import Image, ImageDraw
root = Path(__file__).resolve().parent.parent
scale = 16
image = Image.new('RGB', (128*scale, 128*scale), '#214bd7')
draw = ImageDraw.Draw(image)
# Round strokes match accounts/icons/coltrain.svg. Keep the mark inside the
# central maskable safe circle so Android can crop square/circle/squircle icons.
width = 9*scale
points = lambda values: tuple(round(v*scale) for v in values)
draw.arc(points((24, 64, 58, 98)), 50, 310, fill='white', width=width)
for x,y in [(51.93,67.98),(51.93,94.02)]:
 draw.ellipse(points((x-4.5,y-4.5,x+4.5,y+4.5)),fill='white')
draw.line([points((44,85)),points((92,37))],fill='white',width=width)
draw.line([points((72,37)),points((92,37)),points((92,57))],fill='white',width=width,joint='curve')
for x,y in [(44,85),(72,37),(92,37),(92,57)]:
 draw.ellipse(points((x-4.5,y-4.5,x+4.5,y+4.5)),fill='white')
for name,size in [('icon-192.png',192),('icon-512.png',512),('icon-maskable-512.png',512),('apple-touch-icon.png',180)]:
 image.resize((size,size),Image.Resampling.LANCZOS).save(root/'accounts/icons'/name)
print('Built four opaque colTRAIN installation icons.')
