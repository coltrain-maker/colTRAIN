"""Package only public website artifacts for static HTTPS hosting."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import shutil

root = Path(__file__).resolve().parent.parent
output = root / 'hosting'
output.mkdir(exist_ok=True)
(output / 'accounts').mkdir(exist_ok=True)
for source, target in [(root/'index.html', output/'index.html'), (root/'accounts/index.html', output/'accounts/index.html')]:
    shutil.copyfile(source, target)
with ZipFile(root/'design/coltrain-website.zip', 'w', ZIP_DEFLATED) as archive:
    archive.write(output/'index.html', 'index.html')
    archive.write(output/'accounts/index.html', 'accounts/index.html')
print('Built hosting/ and design/coltrain-website.zip (public pages only; no server credentials).')
