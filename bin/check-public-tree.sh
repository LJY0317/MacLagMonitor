#!/bin/zsh

# Conservative publication check for the small public allowlist.

set -u
ROOT="${0:A:h:h}"
cd "$ROOT" || exit 1

allowed=(
  .gitignore
  README.md
  CHANGELOG.md
  VERSION
  config.example.conf
  install.command
  uninstall.command
  bin/mac-lag-monitor.sh
  bin/mac-lag-monitorctl.sh
  bin/check-public-tree.sh
)

failures=0

for path in "${allowed[@]}"; do
  if [[ ! -f "$path" ]]; then
    print -u2 -- "MISSING PUBLIC FILE: $path"
    failures=$(( failures + 1 ))
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked=("${(@f)$(git ls-files 2>/dev/null)}")
  for path in "${tracked[@]}"; do
    (( ${allowed[(Ie)$path]} )) && continue
    print -u2 -- "UNAPPROVED TRACKED FILE: $path"
    failures=$(( failures + 1 ))
  done
fi

scan_files=()
for path in "${allowed[@]}"; do
  [[ -f "$path" && "$path" != "bin/check-public-tree.sh" ]] && scan_files+=("$path")
done

patterns=(
  '/Users/[A-Za-z0-9._-]+/'
  '/home/[A-Za-z0-9._-]+/'
  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
  'github_pat_[A-Za-z0-9_]+'
  'gh[pousr]_[A-Za-z0-9_]+'
  'AKIA[0-9A-Z]{16}'
  'sk-[A-Za-z0-9]{20,}'
)

for pattern in "${patterns[@]}"; do
  matches="$(grep -InE -I -- "$pattern" "${scan_files[@]}" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    print -u2 -- "SENSITIVE PATTERN: $pattern"
    print -u2 -- "$matches"
    failures=$(( failures + 1 ))
  fi
done

if (( failures > 0 )); then
  print -u2 -- "Public-tree check failed with $failures finding(s)."
  exit 1
fi

print -r -- "Public-tree check passed (${#allowed[@]} allowed files)."
