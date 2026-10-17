"""Combine the ordered new-project migrations for the Supabase SQL editor."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
migrations = sorted((root / 'supabase/migrations').glob('*.sql'))
header = '-- colTRAIN: run once in a NEW Supabase project. No sample users or passwords are included.\n'
(root / 'supabase/SETUP.sql').write_text(header + '\n\n'.join('-- ' + p.name + '\n' + p.read_text() for p in migrations))
print('Built supabase/SETUP.sql from', len(migrations), 'migrations.')
