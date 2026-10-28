#!/usr/bin/env python3
"""Reports play sessions logged by the public game server's login shell.

The wrapper `invaders-login` writes two journal entries a session, both
tagged `sh-invaders`:

    START sid=1234 start=1761696000 account=game cols=80 rows=24
    END   sid=1234 end=1761696252 status=0

A session is one SSH connection. The accounts are shared, so this
counts sessions, not people. No addresses are logged.
"""
import argparse
import csv
import json
import math
import shutil
import statistics
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

TAG = 'sh-invaders'


class Session:
    __slots__ = ('boot', 'sid', 'account', 'start', 'end', 'status',
                 'cols', 'rows')

    def __init__(self, boot, sid, account, start, cols, rows):
        self.boot = boot
        self.sid = sid
        self.account = account
        self.start = start
        self.end = None
        self.status = None
        self.cols = cols
        self.rows = rows

    @property
    def duration(self):
        if self.end is None:
            return None
        return max(0, self.end - self.start)


def parse_when(text):
    if not text:
        return None
    value = text.strip()
    if value.endswith('Z'):
        value = value[:-1] + '+00:00'
    try:
        when = datetime.fromisoformat(value)
    except ValueError:
        raise SystemExit('session-report.py: bad date: %s' % text)
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when.astimezone(timezone.utc)


def as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def event_lines(args, since):
    if args.input:
        with open(args.input, encoding='utf-8') as stream:
            yield from stream
        return
    journalctl = shutil.which('journalctl')
    if journalctl is None:
        raise SystemExit('session-report.py: journalctl not found')
    # No --until: an END after the window's end is still needed to close
    # a session that started inside it. The window is applied locally.
    command = [journalctl, '-t', TAG, '--output=json', '--no-pager',
               '--since', since.isoformat()]
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True,
                                check=True)
    except subprocess.CalledProcessError as error:
        message = error.stderr.strip() or 'journalctl failed'
        raise SystemExit('session-report.py: ' + message)
    yield from result.stdout.splitlines()


def read_sessions(lines):
    sessions = {}
    orphans = 0
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            raise SystemExit('session-report.py: bad journal entry')
        message = entry.get('MESSAGE')
        if isinstance(message, list):
            message = bytes(message).decode('utf-8', 'replace')
        if not isinstance(message, str):
            continue
        words = message.split()
        if not words or words[0] not in ('START', 'END'):
            continue
        fields = {}
        for word in words[1:]:
            if '=' in word:
                key, value = word.split('=', 1)
                fields[key] = value
        sid = fields.get('sid')
        if not sid:
            continue
        key = (entry.get('_BOOT_ID', ''), sid)
        if words[0] == 'START':
            start = as_int(fields.get('start'))
            if start is None:
                continue
            sessions[key] = Session(
                key[0], sid, fields.get('account', '?'), start,
                as_int(fields.get('cols')) or 0,
                as_int(fields.get('rows')) or 0)
        elif key in sessions:
            sessions[key].end = as_int(fields.get('end'))
            sessions[key].status = as_int(fields.get('status'))
        else:
            orphans += 1
    return list(sessions.values()), orphans


def peak_concurrency(sessions):
    events = []
    for session in sessions:
        if session.end is None or session.end <= session.start:
            continue
        events.append((session.start, 1))
        events.append((session.end, -1))
    events.sort(key=lambda event: (event[0], event[1]))
    current = peak = 0
    when = None
    for moment, change in events:
        current += change
        if current > peak:
            peak = current
            when = moment
    return peak, when


def percentile(values, percent):
    if not values:
        return None
    ordered = sorted(values)
    index = math.ceil(percent / 100 * len(ordered)) - 1
    return ordered[max(0, min(index, len(ordered) - 1))]


def format_duration(seconds):
    if seconds is None:
        return '-'
    whole = int(round(seconds))
    hours, rest = divmod(whole, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return '%dh %02dm %02ds' % (hours, minutes, secs)
    if minutes:
        return '%dm %02ds' % (minutes, secs)
    return '%ds' % secs


def format_time(moment):
    return datetime.fromtimestamp(moment, timezone.utc).strftime(
        '%Y-%m-%d %H:%M UTC')


def summarize(sessions, since, until, excluded, orphans):
    finished = [s for s in sessions if s.end is not None]
    durations = [s.duration for s in finished]
    peak, peak_at = peak_concurrency(finished)
    accounts = defaultdict(lambda: {'sessions': 0, 'seconds': 0})
    days = defaultdict(lambda: {'sessions': 0, 'seconds': 0})
    for session in sessions:
        account = accounts[session.account]
        account['sessions'] += 1
        if session.duration is not None:
            account['seconds'] += session.duration
        day = datetime.fromtimestamp(
            session.start, timezone.utc).date().isoformat()
        days[day]['sessions'] += 1
        if session.duration is not None:
            days[day]['seconds'] += session.duration
    return {
        'since': since.isoformat(),
        'until': until.isoformat(),
        'window': {
            'since': format_time(since.timestamp()),
            'until': format_time(until.timestamp()),
        },
        'sessions': {
            'total': len(sessions),
            'finished': len(finished),
            'unfinished': len(sessions) - len(finished),
            'excluded_short': excluded,
            'orphan_ends': orphans,
        },
        'duration_seconds': {
            'total': sum(durations),
            'median': statistics.median(durations) if durations else None,
            'mean': statistics.mean(durations) if durations else None,
            'p90': percentile(durations, 90),
            'longest': max(durations) if durations else None,
        },
        'peak_concurrent': {
            'count': peak,
            'at': format_time(peak_at) if peak_at is not None else None,
        },
        'accounts': dict(sorted(accounts.items())),
        'days': [dict(date=day, **values)
                 for day, values in sorted(days.items())],
    }


def print_summary(summary, per_day):
    counts = summary['sessions']
    length = summary['duration_seconds']
    peak = summary['peak_concurrent']
    print('Window: %s to %s' % (summary['window']['since'],
                                summary['window']['until']))
    print('Sessions: %d' % counts['total'])
    print('Finished: %d' % counts['finished'])
    print('Unfinished (no END): %d' % counts['unfinished'])
    if counts['excluded_short']:
        print('Excluded under minimum duration: %d'
              % counts['excluded_short'])
    if counts['orphan_ends']:
        print('END without START: %d' % counts['orphan_ends'])
    print('Total play time: %s' % format_duration(length['total']))
    print('Median session: %s' % format_duration(length['median']))
    print('Mean session: %s' % format_duration(length['mean']))
    print('90th percentile: %s' % format_duration(length['p90']))
    print('Longest: %s' % format_duration(length['longest']))
    if peak['count']:
        print('Peak concurrent: %d, at %s' % (peak['count'], peak['at']))
    else:
        print('Peak concurrent: 0')
    if summary['accounts']:
        parts = []
        for account, values in summary['accounts'].items():
            parts.append('%s %d' % (account, values['sessions']))
        print('By account: %s' % ', '.join(parts))
    if per_day and summary['days']:
        print()
        print('By day:')
        for day in summary['days']:
            print('  %s  %3d sessions  %s'
                  % (day['date'], day['sessions'],
                     format_duration(day['seconds'])))


def write_csv(sessions):
    writer = csv.writer(sys.stdout)
    writer.writerow(['start', 'end', 'duration_seconds', 'account',
                     'cols', 'rows', 'status', 'finished'])
    for session in sorted(sessions, key=lambda s: (s.start, s.sid)):
        start = datetime.fromtimestamp(
            session.start, timezone.utc).isoformat()
        end = (datetime.fromtimestamp(
            session.end, timezone.utc).isoformat()
            if session.end is not None else '')
        writer.writerow([
            start, end,
            session.duration if session.duration is not None else '',
            session.account, session.cols, session.rows,
            session.status if session.status is not None else '',
            'yes' if session.end is not None else 'no'])


def print_active(sessions):
    active = [s for s in sessions if s.end is None]
    now = datetime.now(timezone.utc).timestamp()
    print('Open sessions: %d' % len(active))
    for session in sorted(active, key=lambda s: s.start):
        print('  %s  %s  %s  %dx%d'
              % (format_time(session.start), session.account,
                 format_duration(max(0, now - session.start)),
                 session.cols, session.rows))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--days', type=float, default=30,
                        help='days to report (default 30)')
    parser.add_argument('--since', help='start, ISO 8601 (overrides --days)')
    parser.add_argument('--until', help='end, ISO 8601 (default now)')
    parser.add_argument('--min-duration', type=float, default=0,
                        metavar='SECONDS',
                        help='ignore finished sessions shorter than this')
    parser.add_argument('--input', metavar='FILE',
                        help='read journal JSON from a file, not journalctl')
    output = parser.add_mutually_exclusive_group()
    output.add_argument('--json', action='store_true',
                        help='print the summary as JSON')
    output.add_argument('--csv', action='store_true',
                        help='print one row a session')
    output.add_argument('--active', action='store_true',
                        help='list sessions with no END')
    parser.add_argument('--per-day', action='store_true',
                        help='add a daily table')
    args = parser.parse_args()

    until = parse_when(args.until) or datetime.now(timezone.utc)
    since = parse_when(args.since)
    if since is None:
        if args.days <= 0:
            raise SystemExit('session-report.py: --days must be positive')
        since = until - timedelta(days=args.days)
    if since >= until:
        raise SystemExit('session-report.py: empty window')

    sessions, orphans = read_sessions(event_lines(args, since))
    since_epoch = since.timestamp()
    until_epoch = until.timestamp()
    sessions = [s for s in sessions
                if since_epoch <= s.start < until_epoch]
    excluded = 0
    if args.min_duration:
        kept = []
        for session in sessions:
            if (session.duration is not None
                    and session.duration < args.min_duration):
                excluded += 1
            else:
                kept.append(session)
        sessions = kept

    if args.active:
        print_active(sessions)
        return
    if args.csv:
        write_csv(sessions)
        return
    summary = summarize(sessions, since, until, excluded, orphans)
    if args.json:
        print(json.dumps(summary, indent=2))
        return
    print_summary(summary, args.per_day)


if __name__ == '__main__':
    main()
