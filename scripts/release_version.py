#!/usr/bin/env python3
"""Stable version selection; prerelease/build tags never affect stable numbering."""
import re

STABLE_TAG = re.compile(r'^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')

def stable_version(tag):
    match = STABLE_TAG.fullmatch(tag)
    return tuple(map(int, match.groups())) if match else None

def next_version(previous, messages):
    markers = set(re.findall(r'\b(?:major|minor|patch)\b', messages.lower()))
    major, minor, patch = previous
    if 'major' in markers:
        return f'v{major + 1}.0.0'
    if 'minor' in markers:
        return f'v{major}.{minor + 1}.0'
    return f'v{major}.{minor}.{patch + 1}'
