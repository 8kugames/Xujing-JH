#!/usr/bin/env bash
# ============================================================================
# verify-version-hook.sh — pre-commit 版本双轨制回归自检
#   · crate 轨: 暂存 crates/** 变更 → 该 crate patch+1 + path 依赖 version 引用同步
#   · 发版轨: ./Version 仅由发版流程推进, hook 不读不写(零触碰不变式)
#   · 隔离手段: GIT_INDEX_FILE 临时索引, 真实索引零触碰(与 hook 设计红线一致);
#     hook 会修改工作树中的 Cargo.toml(其正常行为), 演练后恢复原值
#   · 副作用面: cargo update -w 刷新本地 Cargo.lock(untrack 决策, 不入库)
#   · SKIP_GIT=1 可跳过索引演练, 仅做纯逻辑自检
# 依赖: bash, git, cargo, perl
# ============================================================================
set -eu

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

VERSION_FILE="Version"
HOOK="githooks/pre-commit"
FAIL=0

ok()  { echo "  [PASS] $1"; }
bad() { echo "  [FAIL] $1"; FAIL=1; }

# --- 1) 发版轨被动检查: ./Version 当前内容必须是合法 semver ---
RX='^([1-9][0-9]*|0)\.([1-9][0-9]*|0)\.([1-9][0-9]*|0)$'
echo "== 发版轨 ./Version 被动检查"
cur_version=$(tr -d '[:space:]' < "$VERSION_FILE")
printf '%s' "$cur_version" | grep -qE "$RX" && ok "./Version = $cur_version 合法 semver" || bad "./Version 非法: '$cur_version'"

# --- 2) bump 进位 (10# 强制十进制, 防八进制) ---
echo "== patch 进位"
bump() {
    local major minor patch
    major=$(echo "$1" | cut -d. -f1)
    minor=$(echo "$1" | cut -d. -f2)
    patch=$(echo "$1" | cut -d. -f3)
    echo "${major}.${minor}.$((10#$patch + 1))"
}
[ "$(bump 0.2.9)" = "0.2.10" ] && ok "0.2.9 → 0.2.10" || bad "0.2.9 进位错误"
[ "$(bump 0.2.19)" = "0.2.20" ] && ok "0.2.19 → 0.2.20" || bad "0.2.19 进位错误"
[ "$(bump 0.2.0)" = "0.2.1" ] && ok "0.2.0 → 0.2.1" || bad "0.2.0 进位错误"

if [ "${SKIP_GIT:-0}" = "1" ]; then
    echo "== 跳过索引演练 (SKIP_GIT=1)"
else
    # --- 3) 演练 A: 暂存 protocol 假变更 → protocol bump + 依赖方 version 同步 ---
    echo "== 索引演练 A: crate 轨 bump + 依赖同步"
    git diff --cached --name-only > tmp/verify-real-index-before.txt
    TMPDIR_V="tmp/verify.$$"
    mkdir -p "$TMPDIR_V"

    # 字节级备份(cp)。禁止 $(cat) 备份——命令替换剥尾换行, printf '%s' 写回会污染工作树
    cp crates/protocol/Cargo.toml "$TMPDIR_V/proto.bak"
    cp crates/server/Cargo.toml "$TMPDIR_V/server.bak"
    cp crates/agent/Cargo.toml "$TMPDIR_V/agent.bak"

    old_proto=$(grep -E '^version' crates/protocol/Cargo.toml | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
    new_proto=$(bump "$old_proto")

    printf 'version = "0.0.0"\n' > "$TMPDIR_V/fake.toml"
    blob=$(git hash-object -w "$TMPDIR_V/fake.toml")
    GIT_INDEX_FILE="$TMPDIR_V/idx" git read-tree HEAD
    GIT_INDEX_FILE="$TMPDIR_V/idx" git update-index --add --cacheinfo "100644,$blob,crates/protocol/Cargo.toml"

    out=$(GIT_INDEX_FILE="$TMPDIR_V/idx" bash "$HOOK" 2>&1) || bad "演练 A: hook 非零退出"

    now_proto=$(grep -E '^version' crates/protocol/Cargo.toml | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
    [ "$now_proto" = "$new_proto" ] && ok "protocol: $old_proto → $now_proto" || bad "protocol 版本不符: $now_proto (期望 $new_proto)"
    grep -q "xujing-jh-protocol = { version = \"$new_proto\"" crates/server/Cargo.toml \
        && ok "server 依赖行同步至 $new_proto" || bad "server 依赖行未同步"
    grep -q "xujing-jh-protocol = { version = \"$new_proto\"" crates/agent/Cargo.toml \
        && ok "agent 依赖行同步至 $new_proto" || bad "agent 依赖行未同步"
    GIT_INDEX_FILE="$TMPDIR_V/idx" git diff --cached --name-only | sort | tr '\n' ' ' | grep -q "crates/agent/Cargo.toml crates/protocol/Cargo.toml crates/server/Cargo.toml" \
        && ok "3 个 Cargo.toml 已并入 commit 索引" || bad "暂存内容不符: $(GIT_INDEX_FILE="$TMPDIR_V/idx" git diff --cached --name-only | tr '\n' ' ')"

    # --- 4) 发版轨零触碰不变式: hook 全程不读不写 ./Version ---
    [ "$cur_version" = "$(tr -d '[:space:]' < "$VERSION_FILE")" ] \
        && ok "发版轨零触碰: crates 变更时 ./Version 保持 $cur_version" \
        || bad "./Version 被 hook 修改! ($cur_version → $(cat "$VERSION_FILE"))"

    # 恢复工作树原值(字节级 cp, 与备份逐字节一致含尾换行)
    cp "$TMPDIR_V/proto.bak" crates/protocol/Cargo.toml
    cp "$TMPDIR_V/server.bak" crates/server/Cargo.toml
    cp "$TMPDIR_V/agent.bak" crates/agent/Cargo.toml

    # --- 5) 演练 B: 仅 CHANGELOG 变更 → 零输出零 bump ---
    echo "== 索引演练 B: 非 crates 变更放行"
    printf '# notes\n' > "$TMPDIR_V/fake.md"
    blob=$(git hash-object -w "$TMPDIR_V/fake.md")
    GIT_INDEX_FILE="$TMPDIR_V/idx2" git read-tree HEAD
    GIT_INDEX_FILE="$TMPDIR_V/idx2" git update-index --add --cacheinfo "100644,$blob,CHANGELOG.md"
    out=$(GIT_INDEX_FILE="$TMPDIR_V/idx2" bash "$HOOK" 2>&1) || bad "演练 B: hook 非零退出"
    [ -z "$out" ] && ok "CHANGELOG-only 零输出零 bump" || bad "演练 B 出现意外输出: $out"
    cmp -s "$TMPDIR_V/proto.bak" crates/protocol/Cargo.toml && ok "protocol 字节级保持原值" || bad "protocol 被误改(含尾换行检查)"

    # --- 6) 真实索引零触碰断言 + 清理 ---
    git diff --cached --name-only > tmp/verify-real-index-after.txt
    diff -q tmp/verify-real-index-before.txt tmp/verify-real-index-after.txt > /dev/null \
        && ok "真实索引零触碰" || bad "真实索引被污染!"
    rm -rf "$TMPDIR_V" tmp/verify-real-index-before.txt tmp/verify-real-index-after.txt
fi

echo "== 结论"
[ "$FAIL" -eq 0 ] && echo "verify-version-hook: ALL PASS" || { echo "verify-version-hook: FAILED"; exit 1; }
