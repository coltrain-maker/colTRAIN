"""Produce a downloadable HTML preview that needs no server or Internet."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent.parent
output = root / 'design'
output.mkdir(exist_ok=True)
html = (root / 'index.html').read_text()
html = html.replace('<link rel="stylesheet" href="styles.css">', '<style>' + (root / 'styles.css').read_text() + '</style>')
html = html.replace('<script src="app.js"></script>', '<script>' + (root / 'app.js').read_text() + '</script>')
for name in ('coltrain-prototype.html', 'coltrain-prototype-restored.html'):
    (output / name).write_text(html)
with zipfile.ZipFile(output / 'coltrain-prototype-backup.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.write(output / 'coltrain-prototype-restored.html', 'coltrain-prototype.html')
    archive.write(root / 'PROTOTYPE.md', 'Instructions.txt')
print('Built standalone HTML and backup ZIP.')
