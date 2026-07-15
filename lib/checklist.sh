#!/usr/bin/env bash

# Reusable terminal checklist.
#
# Callers populate these arrays before calling checklist_run:
#   CHECKLIST_IDS               stable values returned to the caller
#   CHECKLIST_LABELS            optional display labels (defaults to the ID)
#   CHECKLIST_DETAILS           optional status/description text
#   CHECKLIST_INITIAL_SELECTED  optional 0/1 selection state
#
# Callers may also set CHECKLIST_TITLE and CHECKLIST_NOTE. On confirmation,
# CHECKLIST_RESULT contains the selected IDs. Cancellation returns 1 and leaves
# the caller's own configuration arrays untouched.

CHECKLIST_IDS=()
CHECKLIST_LABELS=()
CHECKLIST_DETAILS=()
CHECKLIST_INITIAL_SELECTED=()
CHECKLIST_RESULT=()
CHECKLIST_TITLE='Select items'
CHECKLIST_NOTE='Selections are saved after confirmation.'

_CHECKLIST_SELECTED=()
_CHECKLIST_UI_ACTIVE=false

_checklist_restore_terminal() {
  if [[ "$_CHECKLIST_UI_ACTIVE" == 'true' ]]; then
    printf '\033[?25h\033[?1049l'
    _CHECKLIST_UI_ACTIVE=false
  fi
}

_checklist_handle_interrupt() {
  _checklist_restore_terminal
  printf '\nSelection cancelled.\n'
  exit 130
}

_checklist_restore_traps() {
  local old_exit="$1"
  local old_int="$2"
  local old_term="$3"

  trap - EXIT INT TERM
  [[ -z "$old_exit" ]] || eval "$old_exit"
  [[ -z "$old_int" ]] || eval "$old_int"
  [[ -z "$old_term" ]] || eval "$old_term"
}

_checklist_terminal_size() {
  local variable_name="$1"
  local capability="$2"
  local fallback="$3"
  local value=''

  if command -v tput >/dev/null 2>&1; then
    value="$(tput "$capability" 2>/dev/null || true)"
  fi
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || value="$fallback"
  printf -v "$variable_name" '%s' "$value"
}

_checklist_truncate() {
  local value="$1"
  local width="$2"

  if (( width < 2 )); then
    printf '%s' "$value"
  elif (( ${#value} > width )); then
    printf '%s\342\200\246' "${value:0:width-1}"
  else
    printf '%s' "$value"
  fi
}

_checklist_draw_row() {
  local row="$1"
  local cursor="$2"
  local columns="$3"
  local selected_count="$4"
  local id_index label detail display checkbox marker

  marker='  '
  (( row == cursor )) && marker=$'\u276f '

  if (( row == 0 )); then
    checkbox=$'\u2610'
    if (( ${#CHECKLIST_IDS[@]} > 0 && selected_count == ${#CHECKLIST_IDS[@]} )); then
      checkbox=$'\u25a0'
    fi
    display='Select all / none'
  else
    id_index=$((row - 1))
    label="${CHECKLIST_LABELS[id_index]-${CHECKLIST_IDS[id_index]}}"
    detail="${CHECKLIST_DETAILS[id_index]-}"
    display="$label"
    [[ -z "$detail" ]] || display+="  $detail"
    checkbox=$'\u2610'
    (( _CHECKLIST_SELECTED[id_index] == 1 )) && checkbox=$'\u25a0'
  fi

  display="$(_checklist_truncate "$display" "$((columns - 6))")"
  if (( row == cursor )); then
    if (( row > 0 && _CHECKLIST_SELECTED[row - 1] == 1 )); then
      printf '\033[36m%s\033[32m%s %s\033[0m\n' "$marker" "$checkbox" "$display"
    else
      printf '\033[36m%s%s %s\033[0m\n' "$marker" "$checkbox" "$display"
    fi
  elif (( row > 0 && _CHECKLIST_SELECTED[row - 1] == 1 )); then
    printf '%s\033[32m%s\033[0m %s\n' "$marker" "$checkbox" "$display"
  else
    printf '%s%s %s\n' "$marker" "$checkbox" "$display"
  fi
}

_checklist_draw() {
  local cursor="$1"
  local selected_count=0
  local lines columns visible_rows total_rows start end row i

  for i in "${!CHECKLIST_IDS[@]}"; do
    (( _CHECKLIST_SELECTED[i] == 1 )) && ((selected_count += 1))
  done

  _checklist_terminal_size lines lines 24
  _checklist_terminal_size columns cols 80
  visible_rows=$((lines - 8))
  (( visible_rows >= 4 )) || visible_rows=4
  total_rows=$((${#CHECKLIST_IDS[@]} + 1))
  (( visible_rows <= total_rows )) || visible_rows="$total_rows"

  start=$((cursor - visible_rows / 2))
  (( start >= 0 )) || start=0
  if (( start + visible_rows > total_rows )); then
    start=$((total_rows - visible_rows))
  fi
  end=$((start + visible_rows - 1))

  printf '\033[H\033[2J'
  printf '%s (%d selected):\n\n' "$CHECKLIST_TITLE" "$selected_count"
  (( start == 0 )) || printf '\033[90m  \342\206\221 %d more above\033[0m\n' "$start"
  for ((row = start; row <= end; row += 1)); do
    _checklist_draw_row "$row" "$cursor" "$columns" "$selected_count"
  done
  if (( end + 1 < total_rows )); then
    printf '\033[90m  \342\206\223 %d more below\033[0m\n' "$((total_rows - end - 1))"
  fi

  printf '\n\033[90m%s\033[0m\n' "$CHECKLIST_NOTE"
  printf '\342\206\221/\342\206\223 navigate  \342\200\242  Space select  \342\200\242  / find  \342\200\242  Enter save  \342\200\242  q cancel\n'
}

checklist_run() {
  local cursor=0
  local item_count key sequence all_selected index i query haystack found
  local page_size lines
  local old_exit old_int old_term

  [[ -t 0 && -t 1 ]] || {
    printf 'Error: Interactive selection requires a terminal.\n' >&2
    return 2
  }
  (( ${#CHECKLIST_LABELS[@]} == 0 || ${#CHECKLIST_LABELS[@]} == ${#CHECKLIST_IDS[@]} )) || {
    printf 'Error: CHECKLIST_LABELS must be empty or match CHECKLIST_IDS.\n' >&2
    return 2
  }
  (( ${#CHECKLIST_DETAILS[@]} == 0 || ${#CHECKLIST_DETAILS[@]} == ${#CHECKLIST_IDS[@]} )) || {
    printf 'Error: CHECKLIST_DETAILS must be empty or match CHECKLIST_IDS.\n' >&2
    return 2
  }
  (( ${#CHECKLIST_INITIAL_SELECTED[@]} == 0 || ${#CHECKLIST_INITIAL_SELECTED[@]} == ${#CHECKLIST_IDS[@]} )) || {
    printf 'Error: CHECKLIST_INITIAL_SELECTED must be empty or match CHECKLIST_IDS.\n' >&2
    return 2
  }

  CHECKLIST_RESULT=()
  _CHECKLIST_SELECTED=()
  for i in "${!CHECKLIST_IDS[@]}"; do
    if [[ "${CHECKLIST_INITIAL_SELECTED[i]-0}" == '1' ]]; then
      _CHECKLIST_SELECTED[i]=1
    else
      _CHECKLIST_SELECTED[i]=0
    fi
  done
  item_count=$((${#CHECKLIST_IDS[@]} + 1))

  old_exit="$(trap -p EXIT || true)"
  old_int="$(trap -p INT || true)"
  old_term="$(trap -p TERM || true)"
  trap _checklist_restore_terminal EXIT
  trap _checklist_handle_interrupt INT TERM
  printf '\033[?1049h\033[?25l'
  _CHECKLIST_UI_ACTIVE=true

  while true; do
    _checklist_draw "$cursor"
    key=''
    IFS= read -rsn1 key || true
    case "$key" in
      '')
        break
        ;;
      ' ')
        if (( cursor == 0 )); then
          all_selected=1
          for i in "${!CHECKLIST_IDS[@]}"; do
            if (( _CHECKLIST_SELECTED[i] == 0 )); then
              all_selected=0
              break
            fi
          done
          for i in "${!CHECKLIST_IDS[@]}"; do
            _CHECKLIST_SELECTED[i]=$((1 - all_selected))
          done
        else
          index=$((cursor - 1))
          _CHECKLIST_SELECTED[index]=$((1 - _CHECKLIST_SELECTED[index]))
        fi
        ;;
      k)
        cursor=$(( (cursor - 1 + item_count) % item_count ))
        ;;
      j)
        cursor=$(( (cursor + 1) % item_count ))
        ;;
      /)
        printf '\033[?25h\033[H\033[2JFind: '
        query=''
        IFS= read -r query || true
        printf '\033[?25l'
        if [[ -n "$query" ]]; then
          found=false
          for i in "${!CHECKLIST_IDS[@]}"; do
            haystack="${CHECKLIST_LABELS[i]-${CHECKLIST_IDS[i]}} ${CHECKLIST_DETAILS[i]-}"
            if [[ "${haystack,,}" == *"${query,,}"* ]]; then
              cursor=$((i + 1))
              found=true
              break
            fi
          done
          [[ "$found" == 'true' ]] || printf '\a'
        fi
        ;;
      q|Q)
        _checklist_restore_terminal
        _checklist_restore_traps "$old_exit" "$old_int" "$old_term"
        return 1
        ;;
      $'\033')
        sequence=''
        IFS= read -rsn3 -t 0.08 sequence || true
        _checklist_terminal_size lines lines 24
        page_size=$((lines - 9))
        (( page_size >= 1 )) || page_size=1
        case "$sequence" in
          '[A') cursor=$(( (cursor - 1 + item_count) % item_count )) ;;
          '[B') cursor=$(( (cursor + 1) % item_count )) ;;
          '[H'|'OH') cursor=0 ;;
          '[F'|'OF') cursor=$((item_count - 1)) ;;
          '[5~')
            cursor=$((cursor - page_size))
            (( cursor >= 0 )) || cursor=0
            ;;
          '[6~')
            cursor=$((cursor + page_size))
            (( cursor < item_count )) || cursor=$((item_count - 1))
            ;;
          '')
            _checklist_restore_terminal
            _checklist_restore_traps "$old_exit" "$old_int" "$old_term"
            return 1
            ;;
        esac
        ;;
    esac
  done

  for i in "${!CHECKLIST_IDS[@]}"; do
    (( _CHECKLIST_SELECTED[i] == 1 )) && CHECKLIST_RESULT+=("${CHECKLIST_IDS[i]}")
  done
  _checklist_restore_terminal
  _checklist_restore_traps "$old_exit" "$old_int" "$old_term"
}
