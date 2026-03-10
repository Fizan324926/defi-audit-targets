#!/usr/bin/env python3
"""
Immunefi Bug Bounty Comprehensive Scraper
Fetches all programs: information, scope, and resources pages
Outputs a single well-formatted text file
"""

import re
import json
import time
import sys
import os
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime

BASE_URL = "https://immunefi.com"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
}
MAX_WORKERS = 6
RATE_LIMIT_DELAY = 0.25

# Noise patterns to filter from extracted text
NOISE_PATTERNS = [
    r'^\s*\w+:I\[',             # RSC component references like "2a:I[..."
    r'^\s*[\da-f]+:\["\$"',    # RSC component trees like '6:["$",...'
    r'^\s*[\da-f]+:\[',        # RSC arrays
    r'^\s*[\da-f]+:T[\da-f]+,', # RSC text segments like "2c:T490,..."
    r'className',
    r'precedence',
    r'nonce.*YzQ',
    r'_next/static',
    r'googletagmanager',
    r'GTM-',
    r'crossOrigin',
    r'fetchPriority',
    r'async.*true',
    r'stylesheet.*href',
    r'webkit.*gecko',
    r'"children":\s*\[',
    r'rubik_cd38',
    r'unbounded_',
    r'terminalgrotesque',
    r'ot2049_',
    r'geist_',
]

NOISE_RE = re.compile('|'.join(NOISE_PATTERNS), re.IGNORECASE)


def fetch_url(url, retries=3):
    for attempt in range(retries):
        try:
            req = Request(url, headers=HEADERS)
            with urlopen(req, timeout=30) as resp:
                return resp.read().decode('utf-8', errors='replace')
        except (URLError, HTTPError) as e:
            if attempt < retries - 1:
                time.sleep(2 ** attempt)
            else:
                return None
    return None


def decode_rsc_string(s):
    """Decode a Next.js RSC push string (JSON-encoded string content)."""
    try:
        decoded = json.loads('"' + s + '"')
        return decoded
    except Exception:
        try:
            return s.encode('utf-8').decode('unicode_escape')
        except Exception:
            return s


def extract_rsc_pushes(html):
    """Extract all self.__next_f.push([1,"..."]) payloads from HTML."""
    pattern = r'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)'
    matches = re.findall(pattern, html, re.DOTALL)
    results = []
    for m in matches:
        decoded = decode_rsc_string(m)
        results.append(decoded)
    return results


def is_plain_text_block(text):
    """Return True if text appears to be actual readable content."""
    if not text or len(text.strip()) < 80:
        return False
    stripped = text.strip()
    # Filter RSC/React noise
    if NOISE_RE.search(stripped):
        return False
    # Must contain some words (not just code)
    word_count = len(re.findall(r'[a-zA-Z]{4,}', stripped))
    if word_count < 10:
        return False
    # Reject if it looks like JSON/code structures
    if stripped.startswith(('{', '[', 'I[', 'self.')):
        return False
    # Reject hex-prefixed RSC references
    if re.match(r'^[\da-f]{1,3}:["\[]', stripped):
        return False
    # Has sentence-like content
    has_sentences = bool(re.search(r'[a-zA-Z]{5,}\s+[a-zA-Z]{3,}', stripped))
    return has_sentences


def extract_bounty_data(pushes):
    """Extract the main bounty JSON object from RSC pushes."""
    for push in pushes:
        if '"slug"' not in push or '"rewards"' not in push:
            continue
        # Find "bounty":{ pattern
        m = re.search(r'"bounty"\s*:\s*(\{)', push)
        if not m:
            continue
        start = m.start(1)
        depth = 0
        i = start
        while i < len(push):
            c = push[i]
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(push[start:i+1])
                    except Exception:
                        break
            i += 1
    return None


def extract_plain_text_blocks(pushes, bounty_data=None):
    """Extract readable text content from RSC pushes, filtering noise."""
    seen = set()
    blocks = []

    # Build a set of known bounty data strings to avoid duplicating structured info
    bounty_strings = set()
    if bounty_data:
        for key in ['description', 'prohibitedActivities', 'defaultProhibitedActivities',
                    'defaultOutOfScopeGeneral', 'defaultOutOfScopeSmartContract',
                    'defaultOutOfScopeBlockchain', 'defaultOutOfScopeWebAndApplications']:
            val = bounty_data.get(key, '')
            if val and isinstance(val, str) and len(val) > 20:
                # Only add first 100 chars as signature
                bounty_strings.add(val[:100].strip())

    for push in pushes:
        stripped = push.strip()

        # Strip RSC text segment prefix like "2c:T490," or "2c:T1a4,"
        rsc_prefix_m = re.match(r'^[\da-f]{1,4}:T[\da-f]+,', stripped)
        if rsc_prefix_m:
            stripped = stripped[rsc_prefix_m.end():]

        # Case 1: Push looks like a pure text block (not JSON)
        if not stripped.startswith(('{', '[')) and not re.match(r'^[\da-f]{1,3}:["\[]', stripped):
            if is_plain_text_block(stripped):
                sig = stripped[:150]
                if sig not in seen:
                    seen.add(sig)
                    blocks.append(stripped)
            continue

        # Case 2: Push is JSON/RSC tree - extract embedded long text strings
        # Find strings that look like text content (>200 chars, not code)
        text_parts = re.findall(r'"([^"\\]{200,}(?:\\.[^"\\]*)*)"', push)
        for part in text_parts:
            # Unescape
            try:
                unescaped = part.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\')
            except Exception:
                unescaped = part

            if not is_plain_text_block(unescaped):
                continue

            # Skip if it duplicates bounty structured data
            sig_check = unescaped[:100].strip()
            if any(sig_check.startswith(bs[:80]) for bs in bounty_strings if bs):
                continue

            sig = unescaped[:150]
            if sig not in seen:
                seen.add(sig)
                blocks.append(unescaped)

    return blocks


def extract_resource_links(pushes, slug):
    """Extract external resource links from RSC pushes for the resources page."""
    seen_links = set()
    items = []

    # Domains to skip (internal/social/tracking/footer boilerplate)
    skip_domains = {
        'immunefi.com', 'twitter.com', 'linkedin.com', 'youtube.com',
        'instagram.com', 'greenhouse.io', 'googletagmanager.com',
        'slite.page', 'zendesk.com', 'ctfassets.net', 'next.js',
        'apple-touch', 'favicon', 'webmanifest', 'opengraph', 'googleapis',
        't.me', 'telegram.', 'discord.com', 'discord.gg', 'farcaster.xyz',
        'immunefi.foundation', 'drive.google.com', 'x.com',
    }

    for push in pushes:
        # Find href: "URL" patterns from React props
        for m in re.finditer(r'"href"\s*:\s*"(https?://[^"]+)"', push):
            url = m.group(1).strip()
            if any(d in url for d in skip_domains):
                continue
            # Extract label from surrounding context
            ctx_start = max(0, m.start() - 200)
            ctx = push[ctx_start:m.end() + 200]
            label_m = re.search(r'"children"\s*:\s*"([^"]{3,80})"', ctx)
            label = label_m.group(1) if label_m else ''
            key = url.split('?')[0]
            if key not in seen_links:
                seen_links.add(key)
                items.append((label, url))

        # Find markdown links in text portions
        for m in re.finditer(r'\[([^\]]{2,80})\]\((https?://[^)]+)\)', push):
            label, url = m.group(1), m.group(2)
            if any(d in url for d in skip_domains):
                continue
            key = url.split('?')[0]
            if key not in seen_links:
                seen_links.add(key)
                items.append((label, url))

        # Find raw URLs in text (github, docs, etc.)
        for m in re.finditer(r'(?<!["\(])(https?://(?:github\.com|docs\.|wiki\.|medium\.com|etherscan\.io|polygonscan\.com|bscscan\.com)[^\s"\')\]>]{5,})', push):
            url = m.group(1).rstrip('.,;')
            key = url.split('?')[0]
            if key not in seen_links:
                seen_links.add(key)
                items.append(('', url))

    return items


def format_rewards(bounty_data):
    lines = []
    if not bounty_data:
        return lines

    rewards = bounty_data.get('rewards', [])

    if rewards:
        lines.append("REWARDS BY SEVERITY:")
        for r in rewards:
            severity = r.get('severity', '').upper()
            asset_type = r.get('assetType', '').replace('_', ' ').title()
            model = r.get('rewardModel', '')
            if model == 'fixed':
                amount = f"USD ${r.get('fixedReward', 0):,}"
            elif model == 'range':
                min_r = r.get('minReward', 0)
                max_r = r.get('maxReward', 0)
                pct = r.get('rewardCalculationPercentage', '')
                amount = f"USD ${min_r:,} to USD ${max_r:,}"
                if pct:
                    amount += f" ({pct}% of affected funds)"
            else:
                amount = str(r)
            lines.append(f"  [{asset_type}] {severity}: {amount}")
    else:
        legacy = bounty_data.get('legacy', {})
        for key in ['smartcontract_rewards', 'web_rewards', 'blockchain_rewards']:
            items = legacy.get(key, [])
            if items:
                label = key.replace('_rewards', '').replace('smartcontract', 'Smart Contract').title()
                lines.append(f"{label.upper()} REWARDS:")
                for item in items:
                    lines.append(f"  {item.get('level', '')}: {item.get('payout', '')}")

    return lines


def format_assets(bounty_data):
    lines = []
    if not bounty_data:
        return lines

    assets = bounty_data.get('assets', [])
    if not assets:
        return lines

    lines.append("IN-SCOPE ASSETS:")
    for asset in assets:
        asset_type = asset.get('type', '').replace('_', ' ').title()
        desc = asset.get('description', '')
        url = asset.get('url', '')
        is_poi = asset.get('isPrimacyOfImpact', False)
        poi_tag = " [Primacy of Impact]" if is_poi else ""
        lines.append(f"  [{asset_type}]{poi_tag} {desc}")
        if url and 'immunefi.com' not in url:
            lines.append(f"    {url}")
        added = asset.get('addedAt', '')
        if added:
            lines.append(f"    Added: {added[:10]}")

    return lines


def format_impacts(bounty_data):
    lines = []
    if not bounty_data:
        return lines

    impacts = bounty_data.get('impacts', [])
    if not impacts:
        return lines

    grouped = {}
    for imp in impacts:
        itype = imp.get('type', 'other').replace('_', ' ').title()
        severity = imp.get('severity', '').upper()
        key = (itype, severity)
        if key not in grouped:
            grouped[key] = []
        grouped[key].append(imp.get('title', ''))

    lines.append("IMPACTS IN SCOPE:")
    severity_order = ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']
    all_types = list(dict.fromkeys(k[0] for k in grouped))

    for itype in all_types:
        type_items = {k: v for k, v in grouped.items() if k[0] == itype}
        if not type_items:
            continue
        lines.append(f"\n  {itype.upper()}:")
        for sev in severity_order:
            items = type_items.get((itype, sev), [])
            if items:
                lines.append(f"    {sev}:")
                for item in items:
                    lines.append(f"      - {item}")

    return lines


def format_tags(bounty_data):
    lines = []
    if not bounty_data:
        return lines
    tags = bounty_data.get('tags', {})
    if not tags:
        return lines

    parts = []
    if tags.get('ecosystem'):
        parts.append(f"Ecosystem: {', '.join(tags['ecosystem'])}")
    if tags.get('language'):
        parts.append(f"Language: {', '.join(tags['language'])}")
    if tags.get('programType'):
        parts.append(f"Program Type: {', '.join(tags['programType'])}")
    if tags.get('projectType'):
        parts.append(f"Project Type: {', '.join(tags['projectType'])}")
    if tags.get('productType'):
        parts.append(f"Product Type: {', '.join(tags['productType'])}")
    if tags.get('general'):
        parts.append(f"Features: {', '.join(tags['general'])}")

    if parts:
        lines.append("TAGS:")
        for p in parts:
            lines.append(f"  {p}")

    return lines


def format_codebases(bounty_data):
    lines = []
    if not bounty_data:
        return lines
    codebases = bounty_data.get('programCodebases', [])
    docs = bounty_data.get('programDocumentations', [])
    if not codebases and not docs:
        return lines

    if codebases:
        lines.append("CODEBASES:")
        for cb in codebases:
            title = cb.get('title', cb.get('description', ''))
            url = cb.get('url', '')
            lines.append(f"  {title}: {url}")

    if docs:
        lines.append("DOCUMENTATION:")
        for doc in docs:
            title = doc.get('title', doc.get('description', ''))
            url = doc.get('url', '')
            lines.append(f"  {title}: {url}")

    return lines


def clean_text(text):
    """Clean text for output."""
    # Convert markdown links to plain text
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'\1 (\2)', text)
    # Remove excessive blank lines
    text = re.sub(r'\n{3,}', '\n\n', text)
    # Remove __bold__ markers
    text = re.sub(r'__([^_]+)__', r'\1', text)
    # Remove *emphasis* markers
    text = re.sub(r'\*{1,2}([^*]+)\*{1,2}', r'\1', text)
    # Fix unicode escapes
    text = text.replace('â€™', "'").replace('â€"', '-').replace('Â', '')
    return text.strip()


def fetch_program_pages(slug):
    """Fetch all 3 pages for a program."""
    pages = {
        'information': f"{BASE_URL}/bug-bounty/{slug}/information/",
        'scope': f"{BASE_URL}/bug-bounty/{slug}/scope/",
        'resources': f"{BASE_URL}/bug-bounty/{slug}/resources/",
    }
    result = {'slug': slug, 'pages': {}}
    for page_name, url in pages.items():
        time.sleep(RATE_LIMIT_DELAY)
        html = fetch_url(url)
        if html:
            pushes = extract_rsc_pushes(html)
            result['pages'][page_name] = {'pushes': pushes, 'url': url}
    return result


def format_duration(minutes):
    """Format minutes into a human-readable duration."""
    if minutes is None:
        return None
    minutes = int(minutes)
    if minutes < 60:
        return f"{minutes} min"
    hours = minutes // 60
    mins = minutes % 60
    if hours < 24:
        return f"{hours}h {mins}m" if mins else f"{hours}h"
    days = hours // 24
    hrs = hours % 24
    return f"{days}d {hrs}h" if hrs else f"{days}d"


def format_program(program_data, explore_metrics=None):
    """Format a program's data into clean text."""
    slug = program_data['slug']
    pages = program_data.get('pages', {})
    em = explore_metrics or {}
    lines = []
    sep = "=" * 80

    # Global dedup tracker to avoid repeating content across sections
    global_seen_sigs = set()

    def add_text_block(text, output_lines):
        """Add a text block if not already seen."""
        cleaned = clean_text(text)
        if not cleaned or len(cleaned) < 80:
            return False
        sig = cleaned[:120]
        if sig in global_seen_sigs:
            return False
        global_seen_sigs.add(sig)
        output_lines.append(cleaned)
        output_lines.append('')
        return True

    # Pre-populate seen sigs with bounty_data field content to prevent duplication
    def register_bounty_field(val):
        if val and isinstance(val, str) and not re.match(r'^\$[\da-f]+$', val.strip()):
            cleaned = clean_text(val)
            if cleaned:
                global_seen_sigs.add(cleaned[:120])

    # Get bounty data (same on all pages)
    bounty_data = None
    for page_name in ['information', 'scope', 'resources']:
        if page_name in pages:
            bounty_data = extract_bounty_data(pages[page_name]['pushes'])
            if bounty_data:
                break

    project_name = (bounty_data.get('project', '') if bounty_data else '') or slug

    # ── Header ──────────────────────────────────────────────────────────────
    lines.append(sep)
    lines.append(f"PROGRAM: {project_name}")
    lines.append(f"SLUG: {slug}")
    lines.append(f"URL: {BASE_URL}/bug-bounty/{slug}/")

    if bounty_data:
        if bounty_data.get('ticker'):
            lines.append(f"REWARD TOKEN: {bounty_data['ticker']}")
        lines.append(f"KYC REQUIRED: {'Yes' if bounty_data.get('kyc') else 'No'}")
        if bounty_data.get('date'):
            lines.append(f"LAUNCH DATE: {bounty_data['date'][:10]}")
        if bounty_data.get('endDate'):
            lines.append(f"END DATE: {bounty_data['endDate'][:10]}")
        primacy = bounty_data.get('primacy', '')
        if primacy:
            lines.append(f"PRIMACY: {primacy.replace('_', ' ').title()}")
        if bounty_data.get('inviteOnly'):
            lines.append("INVITE ONLY: Yes")

    # Max bounty (prefer explore page value which may differ from bounty_data)
    max_r = em.get('maxBounty') or (bounty_data.get('maxBounty', 0) if bounty_data else 0) or (bounty_data.get('maximum_reward', 0) if bounty_data else 0)
    if max_r:
        lines.append(f"MAX BOUNTY: USD ${int(max_r):,}")

    # Vault balance (explore metrics take priority; bounty_data 'project' may be str or dict)
    vault = em.get('vaultBalance')
    if not vault and bounty_data:
        proj = bounty_data.get('project')
        if isinstance(proj, dict):
            vault = proj.get('vault', {}).get('vaultBalance')
    if vault:
        lines.append(f"VAULT TVL: USD ${int(vault):,}")

    # Performance metrics from explore page
    if em.get('totalPaidAmount') is not None:
        paid = em['totalPaidAmount']
        reports = em.get('totalPaidReports')
        if reports:
            lines.append(f"TOTAL PAID: USD ${int(paid):,} (from {reports} reports)")
        else:
            lines.append(f"TOTAL PAID: USD ${int(paid):,}")

    if em.get('medianResponseTimeInMinutes') is not None:
        dur = format_duration(em['medianResponseTimeInMinutes'])
        lines.append(f"MEDIAN RESPONSE TIME: {dur}")

    # Last updated
    updated = em.get('updatedDate') or (bounty_data.get('updatedDate', '') if bounty_data else '')
    if updated:
        lines.append(f"LAST UPDATED: {updated[:10]}")

    lines.append(sep)
    lines.append('')

    # ── Tags ─────────────────────────────────────────────────────────────────
    if bounty_data:
        tag_lines = format_tags(bounty_data)
        if tag_lines:
            lines.extend(tag_lines)
            lines.append('')

    # ── INFORMATION ─────────────────────────────────────────────────────────
    lines.append("━" * 40 + " INFORMATION " + "━" * 27)
    lines.append('')

    # Project description
    if bounty_data:
        desc = bounty_data.get('description', '')
        if desc:
            cleaned_desc = clean_text(desc)
            lines.append("OVERVIEW:")
            lines.append(cleaned_desc)
            lines.append('')
            global_seen_sigs.add(cleaned_desc[:120])

    # Pre-register structured bounty fields so they don't get duplicated as raw text
    if bounty_data:
        for field in ['prohibitedActivities', 'defaultProhibitedActivities',
                      'defaultOutOfScopeGeneral', 'defaultOutOfScopeSmartContract',
                      'defaultOutOfScopeBlockchain', 'defaultOutOfScopeWebAndApplications',
                      'outOfScopeGeneral', 'outOfScopeSmartContract', 'outOfScopeBlockchain',
                      'outOfScopeWebAndApplications', 'defaultFeasibilityLimitations',
                      'customOutOfScopeInformation']:
            register_bounty_field(bounty_data.get(field, ''))

    # Free-text blocks from information page
    if 'information' in pages:
        pushes = pages['information']['pushes']
        blocks = extract_plain_text_blocks(pushes, bounty_data)
        for block in blocks:
            add_text_block(block, lines)

    # Rewards
    if bounty_data:
        reward_lines = format_rewards(bounty_data)
        if reward_lines:
            lines.extend(reward_lines)
            lines.append('')

    # ── SCOPE ────────────────────────────────────────────────────────────────
    lines.append("━" * 40 + " SCOPE " + "━" * 33)
    lines.append('')

    if bounty_data:
        asset_lines = format_assets(bounty_data)
        if asset_lines:
            lines.extend(asset_lines)
            lines.append('')

        impact_lines = format_impacts(bounty_data)
        if impact_lines:
            lines.extend(impact_lines)
            lines.append('')

        # Out of scope / policies from bounty_data fields
        oos_fields = [
            ('Out of Scope - General', 'outOfScopeGeneral', 'defaultOutOfScopeGeneral'),
            ('Out of Scope - Smart Contract', 'outOfScopeSmartContract', 'defaultOutOfScopeSmartContract'),
            ('Out of Scope - Blockchain', 'outOfScopeBlockchain', 'defaultOutOfScopeBlockchain'),
            ('Out of Scope - Web/Apps', 'outOfScopeWebAndApplications', 'defaultOutOfScopeWebAndApplications'),
            ('Prohibited Activities', 'prohibitedActivities', 'defaultProhibitedActivities'),
            ('Feasibility Limitations', None, 'defaultFeasibilityLimitations'),
            ('Custom Out of Scope', 'customOutOfScopeInformation', None),
        ]
        for label, custom_key, default_key in oos_fields:
            val = ''
            if custom_key:
                val = bounty_data.get(custom_key, '') or ''
            if not val and default_key:
                val = bounty_data.get(default_key, '') or ''
            if val and not re.match(r'^\$[\da-f]+$', val.strip()):
                cleaned_val = clean_text(val)
                if cleaned_val:
                    lines.append(f"{label.upper()}:")
                    lines.append(cleaned_val)
                    lines.append('')

    # Text blocks from scope page (unique content only)
    if 'scope' in pages:
        pushes = pages['scope']['pushes']
        blocks = extract_plain_text_blocks(pushes, bounty_data)
        for block in blocks:
            add_text_block(block, lines)

    # ── RESOURCES ────────────────────────────────────────────────────────────
    lines.append("━" * 40 + " RESOURCES " + "━" * 29)
    lines.append('')

    # Codebases and docs from bounty_data
    if bounty_data:
        cb_lines = format_codebases(bounty_data)
        if cb_lines:
            lines.extend(cb_lines)
            lines.append('')

    # Resource links from resources page
    if 'resources' in pages:
        pushes = pages['resources']['pushes']
        links = extract_resource_links(pushes, slug)
        if links:
            lines.append("RESOURCE LINKS:")
            for label, url in links:
                if label and label.lower() not in (url.lower(), ''):
                    lines.append(f"  {label}: {url}")
                else:
                    lines.append(f"  {url}")
            lines.append('')

        # Text blocks from resources page (unique only)
        blocks = extract_plain_text_blocks(pushes, bounty_data)
        for block in blocks:
            add_text_block(block, lines)

    lines.append('')
    return '\n'.join(lines)


def get_explore_data():
    """
    Fetch the explore page and extract per-program metrics:
    updatedDate, maxBounty, vaultBalance, totalPaidAmount,
    medianResponseTimeInMinutes, totalPaidReports.
    Returns (slugs_ordered, metrics_by_slug).
    """
    html = fetch_url(f"{BASE_URL}/bug-bounty/")
    if not html:
        print("ERROR: Could not fetch explore page", file=sys.stderr)
        return [], {}

    # Collect slugs from URL patterns (for ordering)
    slug_urls = re.findall(r'bug-bounty/([a-z0-9][a-z0-9-]+)', html)
    seen = set()
    slugs = []
    for s in slug_urls:
        if s not in seen:
            seen.add(s)
            slugs.append(s)

    # Extract RSC pushes and parse program metric objects
    pattern = r'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)'
    pushes = re.findall(pattern, html, re.DOTALL)

    metrics_by_slug = {}
    for p in pushes:
        try:
            decoded = json.loads('"' + p + '"')
        except Exception:
            decoded = p

        if '"performanceMetrics"' not in decoded or '"slug"' not in decoded:
            continue

        for slug_m in re.finditer(r'"slug"\s*:\s*"([^"]+)"', decoded):
            slug = slug_m.group(1)
            obj_start = decoded.rfind('{', 0, slug_m.start())
            if obj_start < 0:
                continue
            depth = 0
            for i, c in enumerate(decoded[obj_start:]):
                if c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0:
                        try:
                            obj = json.loads(decoded[obj_start:obj_start+i+1])
                            if 'performanceMetrics' in obj:
                                pm = obj.get('performanceMetrics', {})
                                metrics_by_slug[slug] = {
                                    'updatedDate': obj.get('updatedDate'),
                                    'maxBounty': obj.get('maxBounty'),
                                    'vaultBalance': obj.get('vaultBalance'),
                                    'totalPaidAmount': pm.get('totalPaidAmount') if pm.get('totalPaidMetricEnabled') else None,
                                    'totalPaidReports': pm.get('totalPaidReports') if pm.get('totalPaidMetricEnabled') else None,
                                    'medianResponseTimeInMinutes': pm.get('medianResponseTimeInMinutes') if pm.get('responseTimeMetricEnabled') else None,
                                }
                        except Exception:
                            pass
                        break

    return slugs, metrics_by_slug


def get_all_slugs():
    """Get all program slugs from the explore page (legacy wrapper)."""
    slugs, _ = get_explore_data()
    return slugs


def main():
    output_file = '/root/immunefi/all_programs.txt'

    print("Step 1: Fetching explore page (program list + metrics)...")
    slugs, explore_metrics = get_explore_data()
    print(f"Found {len(slugs)} programs, {sum(1 for m in explore_metrics.values() if m.get('totalPaidAmount') is not None)} with total paid data")

    with open(output_file, 'w', encoding='utf-8') as f:
        f.write("IMMUNEFI BUG BOUNTY PROGRAMS - COMPREHENSIVE DATA\n")
        f.write(f"Scraped: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"Total Programs: {len(slugs)}\n")
        f.write(f"Source: {BASE_URL}/bug-bounty/\n")
        f.write("=" * 80 + "\n\n")
        f.write("PROGRAM INDEX:\n")
        for i, slug in enumerate(slugs, 1):
            em = explore_metrics.get(slug, {})
            max_b = em.get('maxBounty', 0) or 0
            paid = em.get('totalPaidAmount')
            paid_str = f"  total_paid=${int(paid):,}" if paid else ""
            f.write(f"  {i:3}. {slug:<45} max=${int(max_b):,}{paid_str}\n")
        f.write("\n" + "=" * 80 + "\n\n")

    print(f"Step 2: Fetching program details ({MAX_WORKERS} workers)...")
    completed = 0
    total = len(slugs)
    results = {}

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_slug = {executor.submit(fetch_program_pages, slug): slug for slug in slugs}
        for future in as_completed(future_to_slug):
            slug = future_to_slug[future]
            try:
                results[slug] = future.result()
            except Exception as e:
                print(f"\n  ERROR fetching {slug}: {e}", file=sys.stderr)
            completed += 1
            print(f"  [{completed:3}/{total}] {slug:<40}", end='\r', flush=True)

    print(f"\nStep 3: Writing output to {output_file}...")
    with open(output_file, 'a', encoding='utf-8') as f:
        for slug in slugs:
            if slug in results:
                try:
                    text = format_program(results[slug], explore_metrics.get(slug))
                    f.write(text)
                    f.write('\n')
                except Exception as e:
                    print(f"  ERROR formatting {slug}: {e}", file=sys.stderr)

    size = os.path.getsize(output_file)
    print(f"Done! {output_file}")
    print(f"Size: {size / 1024 / 1024:.1f} MB ({size:,} bytes)")


if __name__ == '__main__':
    main()
