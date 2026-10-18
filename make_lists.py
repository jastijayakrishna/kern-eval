import hashlib, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEBUG_COUNT = 12


def order(m):
    return hashlib.sha256(('kern-eval-v1/b/' + m['id']).encode()).hexdigest()


def entry(m):
    return {'key': f"{m['repo'].replace('/', '__')}__{m['number']}", 'repo': m['repo'], 'old_sha': m['old_sha'], 'head_sha': m['head_sha']}


def main():
    manifest = [json.loads(l) for l in open(os.path.join(ROOT, 'corpus', 'pr-manifest.jsonl'), encoding='utf-8')]
    os.makedirs(os.path.join(HERE, 'lists'), exist_ok=True)
    lists = {}
    for split in ('dev', 'sealed'):
        lists[split] = [entry(m) for m in sorted((m for m in manifest if m['split'] == split), key=order)]
    debug, repos = [], set()
    for e in lists['dev']:
        if e['repo'] not in repos:
            repos.add(e['repo'])
            debug.append(e)
        if len(debug) == DEBUG_COUNT:
            break
    lists['debug'] = debug
    for name, rows in lists.items():
        with open(os.path.join(HERE, 'lists', f'{name}.json'), 'w', encoding='utf-8', newline='\n') as f:
            json.dump(rows, f, indent=0)
        print(name, len(rows))


if __name__ == '__main__':
    sys.exit(main())
