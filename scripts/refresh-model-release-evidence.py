#!/usr/bin/env python3
"""Observe official evidence and optional account model lists without fabricating release dates.

The resulting report is review input, not a capability overlay. Account discovery
uses the install helper's existing discover_models ABI; a listing's created/date
fields cannot enter official release evidence. No model turns are sent.
"""
import argparse
import datetime as dt
import hashlib
import json
import runpy
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def strict_json(contents):
    def unique_fields(pairs):
        fields = dict(pairs)
        if len(fields) != len(pairs):
            raise ValueError('duplicate JSON fields')
        return fields
    return json.loads(contents, object_pairs_hook=unique_fields)


def calendar_date(value):
    if not isinstance(value, str):
        raise ValueError('calendar date must be text')
    date = dt.date.fromisoformat(value)
    if date.isoformat() != value:
        raise ValueError('calendar date must be YYYY-MM-DD')
    return date


def public_url(value):
    if not isinstance(value, str):
        raise ValueError('source URL must be text')
    url = urlsplit(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError('source must be public HTTPS without credential components')
    return value


def validate_catalog(catalog):
    if set(catalog) != {'schema', 'models'} or catalog['schema'] != 'masc.model_release_evidence.v1' or not isinstance(catalog['models'], list):
        raise ValueError('unknown release evidence schema')
    seen = set()
    for row in catalog['models']:
        if set(row) != {'publisher', 'model_id', 'release'}:
            raise ValueError('unexpected release identity fields')
        identity = (row['publisher'], row['model_id'])
        if any(not isinstance(v, str) or not v or v.strip() != v for v in identity) or identity in seen:
            raise ValueError('invalid or duplicate release identity')
        seen.add(identity)
        release = row['release']
        if release == {'status': 'unknown'}:
            continue
        if set(release) != {'status', 'released_on', 'kind', 'source_url', 'checked_on'} or release['status'] != 'official_release':
            raise ValueError('unrecognized release evidence')
        if release['kind'] not in ('general_availability', 'limited_release', 'preview'):
            raise ValueError('unknown release kind')
        if calendar_date(release['checked_on']) < calendar_date(release['released_on']):
            raise ValueError('evidence checked before release date')
        public_url(release['source_url'])
    return catalog


def fetch_source(url, timeout):
    try:
        request = Request(public_url(url), headers={'User-Agent': 'MASC-model-evidence-refresh', 'Accept': 'text/html,application/json'})
        with build_opener(NoRedirect()).open(request, timeout=timeout) as response:
            payload = response.read()
        return {'status': 'observed', 'sha256': hashlib.sha256(payload).hexdigest(), 'bytes': len(payload)}
    except HTTPError as error:
        return {'status': 'unavailable', 'http_status': error.code}
    except (URLError, OSError, ValueError):
        return {'status': 'unavailable'}


def observe(catalog, *, observed_at, fetch, discovery=None, discover=None):
    validate_catalog(catalog)
    sources = sorted({row['release']['source_url'] for row in catalog['models'] if row['release']['status'] == 'official_release'})
    report = {'schema': 'masc.model_catalog_refresh.v1', 'observed_at': observed_at,
              'release_evidence_updated': False, 'account_discovery': [],
              'sources': [{'source_url': url, **fetch(url)} for url in sources]}
    if discovery is None:
        return report
    if set(discovery) != {'schema', 'connections'} or discovery['schema'] != 'masc.model_discovery_request.v1' or not isinstance(discovery['connections'], list):
        raise ValueError('invalid discovery request schema')
    identifiers = set()
    for connection in discovery['connections']:
        if set(connection) != {'id', 'publisher', 'choice', 'endpoint', 'api_key_env', 'command'}:
            raise ValueError('unexpected discovery connection fields')
        if any(not isinstance(value, str) for value in connection.values()) or not connection['id'] or connection['id'] in identifiers:
            raise ValueError('invalid or duplicate discovery connection identity')
        identifiers.add(connection['id'])
        if connection['choice'] not in ('codex', 'ollama', 'llama_cpp', 'vllm', 'openai_compatible'):
            report['account_discovery'].append({'connection_id': connection['id'], 'status': 'unsupported'})
            continue
        rows, _ = discover(connection['choice'], endpoint=connection['endpoint'],
                           api_key_env=connection['api_key_env'], command=connection['command'])
        # Select only safe ABI outputs. Raw provider rows, auth paths, endpoint,
        # credentials and any created/listed timestamps never reach the report.
        models = []
        for row in rows:
            model_id = row.get('id')
            if isinstance(model_id, str) and model_id and model_id.strip() == model_id:
                evidence = next((r['release'] for r in catalog['models'] if r['publisher'] == connection['publisher'] and r['model_id'] == model_id), {'status': 'unknown'})
                models.append({'model_id': model_id, 'release': evidence})
        report['account_discovery'].append({'connection_id': connection['id'], 'publisher': connection['publisher'],
                                            'status': 'observed' if models else 'unavailable_or_empty', 'models': models})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--discovery-request', type=Path)
    parser.add_argument('--timeout', type=float, default=15)
    args = parser.parse_args()
    try:
        catalog_bytes = args.catalog.read_bytes()
        catalog = strict_json(catalog_bytes)
        request = strict_json(args.discovery_request.read_text()) if args.discovery_request else None
        discover = None
        if request:
            helper = runpy.run_path(str(Path(__file__).with_name('install-runtime-setup.py')))
            def discover(choice, **kwargs):
                try:
                    return helper['discover_models'](choice, timeout=args.timeout, **kwargs)
                except helper['SetupError']:
                    return [], 'unavailable'

        report = observe(catalog, observed_at=dt.datetime.now(dt.timezone.utc).isoformat(),
                         fetch=lambda url: fetch_source(url, args.timeout), discovery=request, discover=discover)
        report['catalog_sha256'] = hashlib.sha256(catalog_bytes).hexdigest()
        report['producer_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    except (OSError, ValueError, TypeError, KeyError):
        parser.exit(1, 'Model evidence refresh failed; existing release evidence was not changed.\n')


if __name__ == '__main__':
    main()
