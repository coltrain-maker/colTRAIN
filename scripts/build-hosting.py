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
with ZipFile(root/'design/coltrain-website.zip', 'w', ZIP_DEFLATED) as archive:
    for path in ('index.html','accounts/index.html','preview/index.html'):
        archive.write(output/path, path)
print('Built hosting/ and design/coltrain-website.zip (real account entry + separate sample preview; no server credentials).')
