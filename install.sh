#!/usr/bin/env bash
# agent-fundamentals: installs the skills into a repository, or into the agent
# directories on this machine, and reports when an installed copy has drifted.
#
#   ./install.sh <repo>        install into <repo> (.claude/, .agents/, AGENTS.md)
#   ./install.sh --global      install into this machine's agent directories
#   ./install.sh --check <repo>   report drift without changing anything
#   ./install.sh --check --global
#
# Safe to run again: it replaces its own files and its own AGENTS.md block, and
# never touches anything else. It never overwrites an existing HOUSE-RULES.md.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS="$SRC/skills"
BEGIN='<!-- agent-fundamentals:begin -->'
END='<!-- agent-fundamentals:end -->'

CHECK=0
TARGET=""
GLOBAL=0

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --check)  CHECK=1; shift ;;
    --global) GLOBAL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done

[ -d "$SKILLS" ] || { echo "No skills/ directory beside install.sh" >&2; exit 1; }
names=()
for d in "$SKILLS"/*/; do [ -f "$d/SKILL.md" ] && names+=("$(basename "$d")"); done
[ ${#names[@]} -gt 0 ] || { echo "No skills found in $SKILLS" >&2; exit 1; }

# --- where the files go -----------------------------------------------------
dests=()
if [ $GLOBAL -eq 1 ]; then
  [ -n "$TARGET" ] && { echo "Use either --global or a repository path." >&2; exit 2; }
  # Claude Code and Antigravity read the same SKILL.md format.
  dests+=("$HOME/.claude/skills")
  [ -d "$HOME/.gemini/config" ] && dests+=("$HOME/.gemini/config/skills")
else
  [ -n "$TARGET" ] || { echo "Give a repository path, or --global." >&2; usage >&2; exit 2; }
  [ -d "$TARGET" ] || { echo "Not a directory: $TARGET" >&2; exit 1; }
  TARGET="$(cd "$TARGET" && pwd)"
  dests+=("$TARGET/.claude/skills" "$TARGET/.agents/skills")
fi

# --- check mode: report drift, change nothing -------------------------------
if [ $CHECK -eq 1 ]; then
  drift=0; missing=0
  for dest in "${dests[@]}"; do
    echo "== $dest"
    for n in "${names[@]}"; do
      if [ ! -d "$dest/$n" ]; then
        printf "  %-22s not installed\n" "$n"; missing=$((missing + 1)); continue
      fi
      if diff -rq "$SKILLS/$n" "$dest/$n" >/dev/null 2>&1; then
        printf "  %-22s current\n" "$n"
      else
        printf "  %-22s DRIFTED\n" "$n"
        # pipefail would otherwise propagate diff's non-zero status and, under
        # set -e, end the run at the first drift instead of reporting them all.
        diff -rq "$SKILLS/$n" "$dest/$n" 2>&1 | sed 's/^/      /' || true
        drift=$((drift + 1))
      fi
    done
  done
  echo
  if [ $drift -eq 0 ] && [ $missing -eq 0 ]; then echo "All skills installed and current."
  else echo "$drift drifted, $missing not installed."; fi
  exit $(( drift > 0 ? 1 : 0 ))
fi

# --- install ----------------------------------------------------------------
for dest in "${dests[@]}"; do
  mkdir -p "$dest"
  for n in "${names[@]}"; do
    rm -rf "${dest:?}/$n"            # replace our own copy only
    cp -R "$SKILLS/$n" "$dest/$n"
  done
  echo "installed ${#names[@]} skills -> $dest"
done

[ $GLOBAL -eq 1 ] && { echo; echo "Done. Skills are available in every repository on this machine."; exit 0; }

# --- repository extras: AGENTS.md and HOUSE-RULES.md ------------------------
block="$(mktemp)"
{
  echo "$BEGIN"
  echo "<!-- Managed by agent-fundamentals. Edit the skills, not this block. -->"
  echo
  echo "## Working agreements"
  echo
  echo "Read the skill that covers what you are about to do, and follow it."
  echo "They live in \`.claude/skills/\` (and \`.agents/skills/\`, identical copies)."
  echo
  for n in "${names[@]}"; do
    # First sentence only: the whole description is long by design, and a
    # pointer list reads better than a wall of trigger phrases.
    desc="$(awk '/^description:/{sub(/^description: */,""); gsub(/^"|"$/,""); print; exit}' "$SKILLS/$n/SKILL.md" \
      | sed 's/\([.!?]\) .*/\1/')"
    echo "- **\`$n\`** — $desc"
    echo "  - \`.claude/skills/$n/SKILL.md\`"
  done
  echo
  echo "Anything specific to this repository — commands, layout, names, ports,"
  echo "counts — belongs in [\`HOUSE-RULES.md\`](HOUSE-RULES.md), not in a skill."
  echo "The skills stay portable; the house rules are what make them concrete here."
  echo "$END"
} > "$block"

agents="$TARGET/AGENTS.md"
if [ ! -f "$agents" ]; then
  { echo "# Agent instructions"; echo; cat "$block"; } > "$agents"
  echo "wrote AGENTS.md"
elif grep -qF "$BEGIN" "$agents"; then
  python3 - "$agents" "$block" "$BEGIN" "$END" <<'PY'
import pathlib, sys
f, b, begin, end = sys.argv[1:5]
p = pathlib.Path(f); t = p.read_text()
new = pathlib.Path(b).read_text().rstrip("\n")
head, _, rest = t.partition(begin)
_, _, tail = rest.partition(end)
p.write_text(head + new + tail)
PY
  echo "refreshed the agent-fundamentals block in AGENTS.md"
else
  { echo; cat "$block"; } >> "$agents"
  echo "appended the agent-fundamentals block to AGENTS.md"
fi
rm -f "$block"

house="$TARGET/HOUSE-RULES.md"
if [ -f "$house" ]; then
  echo "HOUSE-RULES.md already exists — left untouched"
else
  cp "$SRC/HOUSE-RULES.md.template" "$house"
  echo "wrote HOUSE-RULES.md (fill it in)"
fi

cat <<EOF

Done. In $TARGET:
  .claude/skills/   ${#names[@]} skills (Claude Code)
  .agents/skills/   the same copies (Antigravity and anything reading .agents)
  AGENTS.md         pointer for Codex and other agents
  HOUSE-RULES.md    this repository's own facts

Add .claude/ and .agents/ to version control if the team should share them.
Re-run this to update; run with --check to see whether a copy has drifted.
EOF
