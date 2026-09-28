#!/usr/bin/env bash

# Color codes — $'...' gives the real ESC byte (0x1b), not the 4-char literal \033
BOLD=$'\033[1m'
UNDERLINE=$'\033[4m'
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m' # No Color

log() { printf "[%s] ${BLUE}INFO${NC}  %s
" "$(date '+%F %T')" "$*"; }
warn() { printf "[%s] ${YELLOW}WARN${NC}  %s
" "$(date '+%F %T')" "$*"; }
error() { printf "[%s] ${RED}ERROR${NC} %s
" "$(date '+%F %T')" "$*"; }
success() { printf "[%s] ${GREEN}OK${NC}    %s\n" "$(date '+%F %T')" "$*"; }

run_logged() {
  local cmd_label="$1"
  shift
  log "Запуск: $cmd_label"
  if ! "$@"; then
    error "ОШИБКА: Команда '$cmd_label' (выполнялось: $*) завершилась неудачно."
    return 1
  fi
  return 0
}

die() {
  local message="$*"
  [[ -n "$message" ]] || message="Unknown error."
  error "$message"
  exit 1
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}
