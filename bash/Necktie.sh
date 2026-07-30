#!/usr/bin/env bash
# Discover and launch Linux-friendly tools from this repository.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_PATH="$(cd "${SCRIPT_PATH}/.." && pwd)"
CURRENT_PATH="$ROOT_PATH"
FILTER=""

SUPPORTED_EXTENSIONS=("sh" "bash")
IGNORED_DIRECTORIES=(".git" ".agents" ".codex" "node_modules" "vendor")

ENTRY_TYPES=()
ENTRY_NAMES=()
ENTRY_PATHS=()
ENTRY_DESCRIPTIONS=()
TOOLS=()

contains_ignored_dir() {
  local path="$1"
  local rel="${path#${ROOT_PATH}/}"
  local part
  IFS='/' read -r -a parts <<< "$rel"
  for part in "${parts[@]}"; do
    for ignored in "${IGNORED_DIRECTORIES[@]}"; do
      if [[ "$part" == "$ignored" ]]; then
        return 0
      fi
    done
  done
  return 1
}

is_supported_tool() {
  local file="$1"
  local ext="${file##*.}"
  local basename_file
  basename_file="$(basename "$file")"

  for supported in "${SUPPORTED_EXTENSIONS[@]}"; do
    if [[ "$ext" == "$supported" ]]; then
      return 0
    fi
  done

  if [[ -x "$file" && "$basename_file" != .* ]]; then
    return 0
  fi

  return 1
}

tool_description() {
  local file="$1"
  local line
  local count=0

  while IFS= read -r line; do
    count=$((count + 1))
    if (( count > 20 )); then
      break
    fi
    if [[ "$line" =~ ^#! ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*#[[:space:]]+(.+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return
    fi
  done < "$file"

  echo ""
}

refresh_tools() {
  TOOLS=()
  local file
  while IFS= read -r file; do
    if [[ "$file" == "$0" ]]; then
      continue
    fi
    if contains_ignored_dir "$file"; then
      continue
    fi
    if is_supported_tool "$file"; then
      TOOLS+=("$file")
    fi
  done < <(find "$ROOT_PATH" -type f 2>/dev/null)
}

relative_path() {
  local path="$1"
  if [[ "$path" == "$ROOT_PATH" ]]; then
    echo "."
  else
    echo "${path#${ROOT_PATH}/}"
  fi
}

build_entries() {
  ENTRY_TYPES=()
  ENTRY_NAMES=()
  ENTRY_PATHS=()
  ENTRY_DESCRIPTIONS=()

  local -a directories=()
  local -A seen_directories=()
  local tool rel remainder first_part dirpath name desc

  for tool in "${TOOLS[@]}"; do
    if [[ "$tool" != "$CURRENT_PATH/"* ]]; then
      continue
    fi
    rel="${tool#${CURRENT_PATH}/}"
    remainder="${rel%%/*}"
    if [[ "$rel" == "$remainder" ]]; then
      continue
    fi
    dirpath="${CURRENT_PATH}/${remainder}"
    if [[ -z "${seen_directories[$dirpath]+x}" ]]; then
      seen_directories["$dirpath"]=1
      directories+=("$dirpath")
    fi
  done

  IFS=$'\n' directories=($(printf '%s\n' "${directories[@]}" | sort))
  unset IFS

  for dirpath in "${directories[@]}"; do
    name="$(basename "$dirpath")"
    local count=0
    for tool in "${TOOLS[@]}"; do
      if [[ "$tool" == "$dirpath/"* ]]; then
        count=$((count + 1))
      fi
    done
    ENTRY_TYPES+=("directory")
    ENTRY_NAMES+=("$name")
    ENTRY_PATHS+=("$dirpath")
    ENTRY_DESCRIPTIONS+=("$count tool(s)")
  done

  for tool in "${TOOLS[@]}"; do
    local parent
    parent="$(dirname "$tool")"
    if [[ "$parent" != "$CURRENT_PATH" ]]; then
      continue
    fi
    ENTRY_TYPES+=("tool")
    ENTRY_NAMES+=("$(basename "$tool")")
    ENTRY_PATHS+=("$tool")
    ENTRY_DESCRIPTIONS+=("$(tool_description "$tool")")
  done

  if [[ -n "$FILTER" ]]; then
    local -a f_types=()
    local -a f_names=()
    local -a f_paths=()
    local -a f_desc=()
    local i lower_filter lower_name lower_desc
    lower_filter="$(printf '%s' "$FILTER" | tr '[:upper:]' '[:lower:]')"
    for i in "${!ENTRY_TYPES[@]}"; do
      lower_name="$(printf '%s' "${ENTRY_NAMES[$i]}" | tr '[:upper:]' '[:lower:]')"
      lower_desc="$(printf '%s' "${ENTRY_DESCRIPTIONS[$i]}" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_name" == *"$lower_filter"* || "$lower_desc" == *"$lower_filter"* ]]; then
        f_types+=("${ENTRY_TYPES[$i]}")
        f_names+=("${ENTRY_NAMES[$i]}")
        f_paths+=("${ENTRY_PATHS[$i]}")
        f_desc+=("${ENTRY_DESCRIPTIONS[$i]}")
      fi
    done
    ENTRY_TYPES=("${f_types[@]}")
    ENTRY_NAMES=("${f_names[@]}")
    ENTRY_PATHS=("${f_paths[@]}")
    ENTRY_DESCRIPTIONS=("${f_desc[@]}")
  fi
}

show_menu() {
  clear
  echo " NECKTIE (Linux) "
  echo " Location: [$(relative_path "$CURRENT_PATH")]"
  if [[ -n "$FILTER" ]]; then
    echo " Filter:   $FILTER"
  else
    echo " Filter:   (none)"
  fi
  echo " Commands: number=open/run  b=back  h=home  f=filter  c=clear filter  r=refresh  q=quit"
  echo

  if [[ "${#ENTRY_TYPES[@]}" -eq 0 ]]; then
    if [[ -n "$FILTER" ]]; then
      echo "No entries match the current filter."
    else
      echo "This folder contains no supported tools."
    fi
    return
  fi

  local i label desc
  for i in "${!ENTRY_TYPES[@]}"; do
    if [[ "${ENTRY_TYPES[$i]}" == "directory" ]]; then
      label="+--> [${ENTRY_NAMES[$i]}]"
    else
      label="     ${ENTRY_NAMES[$i]}"
    fi
    printf " [%d] %-36s %s\n" "$((i + 1))" "$label" "${ENTRY_DESCRIPTIONS[$i]}"
  done
}

run_tool() {
  local tool="$1"
  clear
  echo "Running $tool"
  echo "------------------------------------------------------------------------"
  echo

  (
    cd "$(dirname "$tool")"
    if [[ -x "$tool" ]]; then
      "$tool"
    else
      bash "$tool"
    fi
  )

  echo
  read -r -p "Press Enter to return to Necktie... " _
}

list_mode() {
  refresh_tools
  local tool desc
  for tool in "${TOOLS[@]}"; do
    desc="$(tool_description "$tool")"
    printf "%-30s | %-50s | %s\n" "$(basename "$tool")" "$desc" "$(relative_path "$(dirname "$tool")")"
  done
}

if [[ "${1:-}" == "-l" || "${1:-}" == "--list" ]]; then
  list_mode
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  if [[ -d "$1" ]]; then
    ROOT_PATH="$(cd "$1" && pwd)"
    CURRENT_PATH="$ROOT_PATH"
  else
    echo "Path does not exist: $1"
    exit 1
  fi
fi

refresh_tools

while true; do
  build_entries
  show_menu
  echo
  read -r -p "Choice: " choice

  case "$choice" in
    q|Q)
      clear
      exit 0
      ;;
    b|B)
      if [[ "$CURRENT_PATH" != "$ROOT_PATH" ]]; then
        CURRENT_PATH="$(dirname "$CURRENT_PATH")"
      fi
      ;;
    h|H)
      CURRENT_PATH="$ROOT_PATH"
      ;;
    r|R)
      refresh_tools
      ;;
    f|F)
      read -r -p "Filter by name/description [${FILTER:-none}]: " new_filter
      if [[ -n "$new_filter" ]]; then
        FILTER="$new_filter"
      fi
      ;;
    c|C)
      FILTER=""
      ;;
    '' )
      ;;
    * )
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        index=$((choice - 1))
        if (( index >= 0 && index < ${#ENTRY_TYPES[@]} )); then
          if [[ "${ENTRY_TYPES[$index]}" == "directory" ]]; then
            CURRENT_PATH="${ENTRY_PATHS[$index]}"
          else
            run_tool "${ENTRY_PATHS[$index]}"
            refresh_tools
          fi
        fi
      fi
      ;;
  esac
done
