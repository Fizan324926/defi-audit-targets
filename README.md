# defi-audit-targets

Research repository for identifying and prioritizing Immunefi bug bounty programs best suited for code-audit-style vulnerability research.

## Contents

| File | Description |
|---|---|
| `scraper.py` | Fetches all Immunefi programs (information, scope, resources pages) into a single structured text file |
| `all_programs.txt` | Full data dump: 257 programs with rewards, assets, impacts, scope, policies, and resource links |
| `ANALYSIS.md` | Detailed prioritization analysis — which programs to target first, why, and what vulnerability classes to focus on |

## Usage

```bash
# Re-scrape all programs (updates all_programs.txt)
python3 scraper.py

# Output: /root/immunefi/all_programs.txt (or update path in scraper.py)
```

Requirements: Python 3.8+, standard library only (no external packages).

## Focus

- Smart contract programs only (code review, not manual request testing)
- Scoring by: max bounty, response time, payment history, Primacy of Impact, in-scope impact count, asset surface
- Vulnerability classes: arithmetic, access control, reentrancy, oracle manipulation, cross-chain, upgradeable contracts

See `ANALYSIS.md` for the full breakdown.
