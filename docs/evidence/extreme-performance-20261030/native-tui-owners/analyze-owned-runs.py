"""Derive phase evidence from completed owned runs, without joining clocks.

This reads native timer records, request intervals and stored decisions. It
does not inspect terminal text/layout or infer acknowledgement from sent keys.
"""
import argparse
import collections
import hashlib
import json
import math
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        return {'samples': 0}
    def percentile(p):
        # Same positive round-to-nearest index as the native histogram.
        return ordered[int(math.floor(p * (len(ordered)-1) + .5))]
    return {'samples': len(ordered), 'min_us': ordered[0],
            'mean_us': sum(ordered)/len(ordered), 'p50_us': percentile(.5),
            'p95_us': percentile(.95), 'p99_us': percentile(.99), 'max_us': ordered[-1]}


def union_size(intervals):
    total = 0
    end = None
    for left, right in sorted(intervals):
        if end is None or left >= end:
            total += right-left
        elif right > end:
            total += right-end
        end = right if end is None else max(end, right)
    return total


def analyze(run):
    observer = json.loads((run/'tui-observer/observation.json').read_text())
    workload = json.loads((run/'summary.json').read_text())
    identity = json.loads((run/'identity.json').read_text())
    cleanup = json.loads((run/'cleanup.json').read_text())
    timing = run/'tui-observer/frame-timing.txt'
    records = [json.loads(line) for line in timing.read_text().splitlines() if line.startswith('{')]
    frames = [r for r in records if r.get('schema') == 'masc.tui.frame.v2']
    stages = [r for r in records if r.get('schema') == 'masc.tui.stage.v1']
    frame_groups = collections.defaultdict(list)
    present_parts = collections.defaultdict(list)
    invalid_windows = []
    for frame in frames:
        started, completed, elapsed = (int(frame[key]) for key in ('started_ns','completed_ns','elapsed_ns'))
        if elapsed != completed-started or elapsed < 0:
            invalid_windows.append({'kind':'frame', 'phase':frame['phase'], 'frame':frame['frame']})
        frame_groups[(frame['phase'], frame['surface'])].append(elapsed/1000)
        if frame['phase'] == 'present' and frame.get('output') is not None:
            output = frame['output']
            write, flush = int(output['write_ns']), int(output['flush_ns'])
            present_parts['write'].append(write/1000)
            present_parts['flush'].append(flush/1000)
            present_parts['other'].append((elapsed-write-flush)/1000)
    builds = {r['frame']:r for r in frames if r['phase']=='build'}
    stage_groups = collections.defaultdict(list)
    stage_by_frame = collections.defaultdict(list)
    by_name_frame = collections.defaultdict(int)
    for stage in stages:
        left, right, elapsed = (int(stage[key]) for key in ('started_ns','completed_ns','elapsed_ns'))
        if elapsed != right-left or elapsed < 0:
            invalid_windows.append({'kind':'stage-duration','frame':stage['frame'],'name':stage['name']})
        if stage['frame'] is not None:
            by_name_frame[(stage['name'],stage['frame'])] += elapsed
            parent = builds.get(stage['frame'])
            if (parent is None or left < int(parent['started_ns'])
                    or right > int(parent['completed_ns'])):
                invalid_windows.append({'kind':'stage-containment','frame':stage['frame'],'name':stage['name']})
            else:
                stage_by_frame[stage['frame']].append((left,right))
    for (name, frame), elapsed in by_name_frame.items():
        stage_groups[name].append(elapsed/1000)
    uncovered = collections.defaultdict(list)
    overlaps = []
    for ordinal, frame in builds.items():
        intervals = stage_by_frame[ordinal]
        union = union_size(intervals)
        summed = sum(right-left for left,right in intervals)
        if summed != union:
            overlaps.append({'frame':ordinal,'sum_ns':summed,'union_ns':union})
        uncovered[frame['surface']].append((int(frame['elapsed_ns'])-union)/1000)
    health = json.loads((run/'latency-samples.json').read_text())
    low, high = int(observer['started_ns']), int(observer['ended_ns'])
    health_groups = collections.defaultdict(list)
    unknown_intervals = 0
    for row in health:
        if not isinstance(row.get('start_ns'),int) or not isinstance(row.get('end_ns'),int):
            unknown_intervals += 1
            health_groups['unknown'].append(row)
            continue
        start, end = row['start_ns'],row['end_ns']
        group = ('inside_child_envelope' if low <= start <= end <= high else
                 'outside_child_envelope' if end <= low or start >= high else
                 'crosses_child_boundary')
        health_groups[group].append(row)
    health_summary = {}
    expected_base = observer['server_before']['paths']['effective_base_path']
    for group, rows in health_groups.items():
        valid_times = []
        invalid = []
        for row in rows:
            try:
                body = json.loads(row.get('body_utf8',''))
                valid = (row.get('valid') is True and row.get('status') == 200
                         and body.get('live') is True
                         and body['startup']['state_ready'] is True
                         and body['startup']['path_diagnostics']['effective_base_path'] == expected_base)
            except (json.JSONDecodeError, KeyError, TypeError):
                valid = False
            if valid and isinstance(row.get('wire_ms'),(int,float)):
                valid_times.append(row['wire_ms']*1000)
            else:
                invalid.append({'start_ns':row.get('start_ns'),'end_ns':row.get('end_ns'),
                                'status':row.get('status'),'error':row.get('error')})
        health_summary[group] = {'total_requests':len(rows),'invalid_or_failed':invalid,
                                 'successful_wire':distribution(valid_times)}
    worst = sorted((r for r in frames if r['phase']=='present'),key=lambda r:int(r['elapsed_ns']),reverse=True)[:5]
    return {'scope':'Native phase wall times under real isolated Keeper owners with scripted loopback provider. Python request/observer envelopes share a clock; native Mtime elapsed is separate and is never joined to input timestamps. Component, frame, request, durable outcome and physical paint are separate evidence.',
            'run':str(run),'source':identity['source'],'server_sha256':identity['sha256'],
            'tui_sha256':observer['binary_sha256'],'capture_qualified':observer.get('capture_qualified'),
            'workload':{k:workload[k] for k in ('keepers','messages','succeeded_operations','actual_model_calls','max_provider_requests_in_flight','rejected_429_count','rate_limit_wait_s')},
            'cleanup':cleanup,'native_declared_frames':observer.get('native_declared_frames'),
            'native_report_consistent':observer.get('native_report_consistent'),
            'native_diagnostic_omissions':observer.get('native_diagnostic_omissions'),
            'invalid_native_windows':invalid_windows,'overlapping_stage_frames':overlaps,
            'frames':[{'phase':phase,'surface':surface,**distribution(values)}
                      for (phase,surface),values in sorted(frame_groups.items())],
            'stages':[{'name':name,**distribution(values)} for name,values in sorted(stage_groups.items())],
            'uncovered_build_wall':[{'surface':surface,**distribution(values)} for surface,values in sorted(uncovered.items())],
            'present_parts':{k:distribution(v) for k,v in present_parts.items()},'worst_presents':worst,
            'health_envelope_overlap':health_summary,'unknown_health_intervals':unknown_intervals,
            'autostart_scope':'Log is a read-time lower bound; empty does not certify no attempts or settlement of delayed detached shims. Actual server execution is blocked by the owned sibling/PATH shim.',
            'input_application_evidence':'not collected','deep_scroll_position_evidence':'not collected',
            'physical_display_evidence':'not collected','target_met':False,
            'inputs':{str(p.relative_to(run)):digest(p) for p in [run/'identity.json',run/'summary.json',run/'cleanup.json',timing,run/'tui-observer/observation.json',run/'latency-samples.json']},
            'analyzer_sha256':digest(Path(__file__))}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runs',nargs='+',type=Path)
    args = parser.parse_args()
    for run in args.runs:
        result = analyze(run)
        target = run.parent/(run.name+'.analysis-v1.json')
        with target.open('x') as stream:
            json.dump(result,stream,indent=2);stream.write('\n')
        print(json.dumps({'run':str(run),'capture_qualified':result['capture_qualified'],
                          'invalid_native_windows':len(result['invalid_native_windows']),
                          'overlapping_stage_frames':len(result['overlapping_stage_frames']),
                          'frames':result['frames'],'present_parts':result['present_parts']}))
