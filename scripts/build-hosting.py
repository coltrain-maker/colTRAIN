"""Package the connected website and a clearly separate sample preview."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import shutil

root = Path(__file__).resolve().parent.parent
output = root / 'hosting'
for directory in (output, output/'accounts', output/'preview'):
    directory.mkdir(exist_ok=True)
# The deployed home must not look like a signed-in app while using sample data.
(output/'index.html').write_text('''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="0;url=/accounts/"><title>colTRAIN</title></head><body><p><a href="/accounts/">Open colTRAIN</a></p><script>location.replace('/accounts/'+location.search+location.hash);</script></body></html>''')
shutil.copyfile(root/'accounts/index.html', output/'accounts/index.html')
shutil.copyfile(root/'index.html', output/'preview/index.html')
# Explicit public allowlist: never ship account sources, SQL, configuration, or server code.
public_files = ['index.html','accounts/index.html','preview/index.html','_headers']
shutil.copyfile(root/'accounts/netlify-headers', output/'_headers')
for filename in ('manifest.webmanifest','sw.js'):
    shutil.copyfile(root/'accounts'/filename, output/'accounts'/filename)
    public_files.append('accounts/'+filename)
(output/'accounts/icons').mkdir(exist_ok=True)
for filename in ('coltrain.svg','icon-192.png','icon-512.png','icon-maskable-512.png','apple-touch-icon.png'):
    shutil.copyfile(root/'accounts/icons'/filename, output/'accounts/icons'/filename)
    public_files.append('accounts/icons/'+filename)
with ZipFile(root/'design/coltrain-website.zip', 'w', ZIP_DEFLATED) as archive:
    for path in public_files:
        archive.write(output/path, path)
print('Built hosting/ and design/coltrain-website.zip (real account entry + separate sample preview; no server credentials).')
