#!/bin/bash
#
# check-no-logging.sh — release 构建中禁止任何日志输出。
#
# 规则(全局规则 6): 所有 print / debugPrint / NSLog / os_log / Logger / fputs / puts / printf
# 调用都必须包在 #if DEBUG 里; release 构建必须完全没有日志。
#
# 用法:
#   Scripts/check-no-logging.sh [SourceDir...]   # 默认检查 Sources/
#   Scripts/check-no-logging.sh --strict          # 连 Tests/ 一起检查
#
# 退出码: 0 = 通过, 1 = 发现未受保护的日志调用, 2 = 用法错误。

set -uo pipefail

script_path="${BASH_SOURCE[0]}"
repo_root="$(cd "$(dirname "$script_path")/.." && pwd)"
strict=0
dirs=""

for arg in "$@"; do
  case "$arg" in
    --strict) strict=1 ;;
    -h|--help)
      sed -n '2,12p' "$script_path" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "check-no-logging: 未知选项 $arg" >&2; exit 2 ;;
    *) dirs="$dirs $arg" ;;
  esac
done

if [ -z "$dirs" ]; then
  dirs="$repo_root/Sources"
  if [ "$strict" -eq 1 ]; then
    dirs="$dirs $repo_root/Tests"
  fi
fi

# 一个日志调用: print( debugPrint( Logger( os_log( NSLog( fputs( puts( printf( fprintf( dlog(
# 关键字前面不能紧贴标识符字符(reprint( / vprintf( 不会误判); 关键字后面允许空白再接左括号。
log_re='(^|[^[:alnum:]_])(print|debugPrint|Logger|os_log|NSLog|fputs|puts|printf|fprintf|dlog)[[:space:]]*\('

# awk 程序通过 heredoc 传入, 正则通过环境变量传入 ——
# macOS 的 awk 用 -v 传正则会多加一层反斜杠转义。
awk_prog=$(cat <<'AWK'
BEGIN {
  re = ENVIRON["LOG_RE"]
  depth = 0
  bad = 0
}

{
  trimmed = $0
  sub(/^[[:space:]]+/, "", trimmed)

  if (trimmed ~ /^#if[[:space:]]/) {
    depth++
    stack[depth] = (trimmed ~ /^#if[[:space:]]+DEBUG([[:space:]]|$)/) ? 1 : 0
    next
  }
  if (trimmed ~ /^#elseif([[:space:]]|$)/ || trimmed ~ /^#else([[:space:]]|$)/) {
    # #if DEBUG 的 else 分支在 release 中生效, 因此未受保护。
    if (depth > 0) stack[depth] = 0
    next
  }
  if (trimmed ~ /^#endif([[:space:]]|$)/) {
    if (depth > 0) { delete stack[depth]; depth-- }
    next
  }

  inside_debug = 0
  for (i = 1; i <= depth; i++) if (stack[i] == 1) { inside_debug = 1; break }
  if (inside_debug) next

  # 单行条件保护: #if DEBUG print(x) #endif
  if (trimmed ~ /#if[[:space:]]+DEBUG/ && trimmed ~ /#endif/) next

  code = $0
  sub(/\/\/.*$/, "", code)
  if (code ~ re) {
    printf "%s:%d: 未受 #if DEBUG 保护的日志调用: %s\n", file, NR, $0
    bad = 1
  }
}

END { exit (bad ? 1 : 0) }
AWK
)

failures=0
checked=0

for dir in $dirs; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' file; do
    checked=$((checked + 1))
    grep -Eq "$log_re" "$file" || continue
    if ! LOG_RE="$log_re" awk -v file="$file" "$awk_prog" "$file"; then
      failures=$((failures + 1))
    fi
  done < <(
    find "$dir" -type f \
      -not -path '*/.build/*' -not -path '*/build/*' \
      -not -path '*/DerivedData/*' -not -path '*/xcuserdata/*' \
      -not -path '*/.git/*' \
      \( -name '*.swift' -o -name '*.m' -o -name '*.mm' \
         -o -name '*.h' -o -name '*.c' -o -name '*.cc' \) \
      -print0
  )
done

if [ "$checked" -eq 0 ]; then
  echo "check-no-logging: 没有找到可检查的源文件 (检查目录: $dirs)" >&2
  exit 1
fi

if [ "$failures" -ne 0 ]; then
  echo "" >&2
  echo "check-no-logging: 失败 — 发现 $failures 个文件含未受保护的日志调用。" >&2
  echo "请把每处日志调用包进 #if DEBUG ... #endif, 或直接删除。" >&2
  exit 1
fi

echo "check-no-logging: 通过 (已检查 $checked 个文件, 无 release 日志输出)。"
exit 0
