"""Run account/RLS tests in a fresh PostgreSQL container, without published ports."""
from pathlib import Path
import concurrent.futures
import subprocess
import time
import uuid

root = Path(__file__).resolve().parent.parent
name = 'coltrain-security-' + uuid.uuid4().hex[:10]
image = 'postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24'

def sql(text, check=True):
    result = subprocess.run(
        ['docker', 'exec', '-i', name, 'psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-U', 'postgres'],
        input=text, text=True, capture_output=True,
    )
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result

subprocess.run(['docker', 'run', '--rm', '-d', '--name', name, '--network', 'none',
                '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', image], check=True, capture_output=True)
try:
    for attempt in range(60):
        if subprocess.run(['docker', 'exec', name, 'pg_isready', '-h', '127.0.0.1', '-U', 'postgres'], capture_output=True).returncode == 0:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError('PostgreSQL did not become ready')
    sql((root / 'tests/supabase-auth-fixture.sql').read_text())
    for migration in sorted((root / 'supabase/migrations').glob('*.sql')):
        sql(migration.read_text())
    result = sql((root / 'tests/accounts-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/team-media-security.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    result = sql((root / 'tests/email-invitations.sql').read_text())
    print(next(line for line in result.stdout.splitlines() if line.startswith('Passed ')))
    store = sql("select id from public.organizations where name='Concurrency test store';").stdout.strip()
    def reserve(index):
        return sql(f"""begin; set local role authenticated;
          set local request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
          select invitation_id from public.create_invitation('{store}','race{index}@example.test');
          select pg_sleep(0.25); commit;""", check=False)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(reserve, [1, 2]))
    assert sum(result.returncode == 0 for result in outcomes) == 1, 'A single free seat must have one successful reservation'
    assert all(result.returncode == 0 or 'No available seats' in result.stderr for result in outcomes)
    assert sql(f"select count(*) from public.invitations where organization_id='{store}' and revoked_at is null;").stdout.strip() == '1'
    print('Passed concurrent seat reservation test (one seat, two requests).')
finally:
    subprocess.run(['docker', 'stop', name], check=False, capture_output=True)
