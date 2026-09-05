#!/usr/bin/env bash
# Deterministic checks on a pull request diff.
#
# These are the actual merge gate. They are pattern matches, not judgement,
# so nothing written in the diff can argue with them. They exist to catch
# the realistic attack: not a derailed agent, but a well-behaved agent
# carrying a payload in an artefact. A dependency added to a lockfile, a
# hostname in a config, a lifecycle script that runs on install. None of
# that looks wrong in a diff read quickly.
#
# An LLM reviewer is advisory and runs separately. It can be prompt-injected
# by the diff it is reading, so it must never hold merge authority.
#
# Usage: check-diff.sh <base-ref>
# Exits non-zero if anything is flagged.

set -uo pipefail

BASE="${1:-origin/main}"
FLAGS=0

flag() {
  echo "::error::$1"
  FLAGS=$((FLAGS + 1))
}

note() {
  echo "  - $1"
}

changed() {
  git diff --name-only "$BASE"...HEAD
}

added_lines() {
  git diff -U0 "$BASE"...HEAD -- "$@" | grep '^+' | grep -v '^+++' || true
}

echo "Checking diff against $BASE"
echo

# --- CI configuration -------------------------------------------------------
# The agent's token deliberately lacks workflow scope, so it cannot push
# these. If one changes in an agent PR, something is wrong with the token
# or the PR did not come from where it claims.
if changed | grep -qE '^\.github/workflows/'; then
  flag "Diff modifies .github/workflows/"
  note "The agent token lacks workflow scope and should not be able to do this."
  changed | grep -E '^\.github/workflows/' | sed 's/^/    /'
fi

# --- Git hooks --------------------------------------------------------------
# Repository-supplied hooks execute on ordinary git operations. The container
# sets core.hooksPath to /dev/null, but your desktop may not.
if changed | grep -qE '(^|/)\.githooks/|(^|/)hooks/'; then
  flag "Diff adds or changes git hooks"
fi

if added_lines . | grep -qE 'core\.hooksPath'; then
  flag "Diff sets core.hooksPath"
fi

# --- Package lifecycle scripts ----------------------------------------------
# npm runs preinstall/install/postinstall/prepare on a plain install. These
# are the classic way for a dependency to execute code on a reviewer's
# machine.
if added_lines 'package.json' | grep -qE '"(preinstall|install|postinstall|prepare|prepublish)"'; then
  flag "Diff adds or changes a package.json lifecycle script"
  added_lines 'package.json' | grep -E '"(preinstall|install|postinstall|prepare|prepublish)"' | sed 's/^/    /'
fi

# Ruby equivalents: gemspecs and extension build files run at install time.
if changed | grep -qE '\.gemspec$|(^|/)extconf\.rb$'; then
  flag "Diff changes a gemspec or extconf.rb"
  note "Both execute during gem installation."
fi

# --- Lockfile drift ---------------------------------------------------------
# A lockfile changing without its manifest means a dependency moved without
# anyone asking for it. That is how a substituted package arrives.
lock_without_manifest() {
  local lock="$1" manifest="$2"
  if changed | grep -qx "$lock" && ! changed | grep -qx "$manifest"; then
    flag "$lock changed but $manifest did not"
    note "A dependency moved without a corresponding request."
  fi
}
lock_without_manifest "Gemfile.lock" "Gemfile"
lock_without_manifest "package-lock.json" "package.json"
lock_without_manifest "yarn.lock" "package.json"

# --- Editor and shell auto-run ----------------------------------------------
# VS Code tasks with runOn: folderOpen execute when a directory is opened.
# direnv runs .envrc on cd. Neither requires you to run anything explicitly.
if changed | grep -qE '^\.vscode/'; then
  flag "Diff changes .vscode/ configuration"
  note "tasks.json can run commands on folder open."
fi

if changed | grep -qE '(^|/)\.envrc$'; then
  flag "Diff adds or changes .envrc"
  note "direnv executes this on entering the directory."
fi

# --- Credentials ------------------------------------------------------------
if changed | grep -qE '(^|/)(master\.key|credentials/.*\.key|\.env($|\.))'; then
  flag "Diff contains a credential file"
fi

# Loose check for pasted secrets in added lines. Deliberately narrow: broad
# entropy checks produce noise, and noise is how a gate stops being read.
if added_lines . | grep -qE '(ghp_|github_pat_|sk-ant-|AKIA[0-9A-Z]{16})'; then
  flag "Diff contains something shaped like a credential"
fi

# --- Encoded payloads -------------------------------------------------------
# Long base64 runs in source are rare and worth a look. Skips lockfiles and
# anything under vendor/, where legitimate long strings are common.
if git diff -U0 "$BASE"...HEAD -- . \
    ':(exclude)*.lock' ':(exclude)vendor/**' ':(exclude)*.svg' \
    | grep '^+' | grep -v '^+++' \
    | grep -qE '[A-Za-z0-9+/]{200,}={0,2}'; then
  flag "Diff adds a long encoded string"
  note "Check it is not a payload."
fi

# --- Outbound URLs ----------------------------------------------------------
# New network destinations in code are worth seeing. Reported, not blocking
# on their own, because legitimate additions are common.
NEWURLS=$(added_lines . ':(exclude)*.lock' ':(exclude)vendor/**' \
  | grep -oE 'https?://[a-zA-Z0-9./_-]+' \
  | sort -u || true)
if [[ -n "$NEWURLS" ]]; then
  echo "::notice::Diff adds outbound URLs:"
  echo "$NEWURLS" | sed 's/^/    /'
fi

echo
if [[ "$FLAGS" -gt 0 ]]; then
  echo "$FLAGS check(s) flagged. Review before merging."
  echo "To merge anyway, add the 'override-checks' label to the PR."
  exit 1
fi

echo "No checks flagged."
