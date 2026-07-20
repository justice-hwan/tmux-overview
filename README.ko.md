# tmux-overview

> 모든 tmux 세션을 한 화면에서 — 읽기전용 실시간 타일 대시보드 + 줌.

[English README](./README.md) · [설계 문서 (영문)](./docs/DESIGN.md)

여러 AI 코딩 에이전트(Claude Code 등)를 세션마다 하나씩 띄워 두면, 상태를 보려고 세션을 하나씩 넘겨 다녀야 합니다. **tmux-overview**는 모든 세션의 활성 pane을 타일 그리드 하나로 실시간 미러링해서, 누가 작업 중(**RUN**, 녹색)이고 누가 입력을 기다리는지(**IDLE Ns**, 노랑)를 한눈에 보여줍니다. 미러링은 순수 읽기전용이라 작업 세션에 어떤 영향(리사이즈·입력·중단)도 주지 않으며, 의존성 없는 POSIX 셸 스크립트 하나로 동작합니다.

![tmux-overview — 여섯 개 세션을 한 그리드에 실시간 미러링](./assets/overview.png)

<details>
<summary>텍스트 미리보기 (이미지가 안 뜨는 환경용)</summary>

```
┌ RUN  agent-api [node] ────────────┐┌ IDLE 42s  agent-web [node] ───────┐
│ ⏺ Running tests…                  ││ ❯ Plan ready. Proceed? (y/n)      │
│                                   ││                                   │
└───────────────────────────────────┘└───────────────────────────────────┘
```

</details>

## 핵심 동작

- 타일마다 대상 세션의 활성 pane을 `tmux capture-pane -ep`로 약 1초 주기 미러 (ANSI 색 보존, 하단 정렬, 각 줄을 타일 너비로 잘라내 넓은 TUI도 안 깨짐, 깜빡임 없음)
- **타일 상단 구분선(border)** — 세션명이 표시되는 그 자리 — 에 세션명 + 실행 중인 명령 + 상태를 표시. 최근 3초 내 출력 있으면 **RUN**(녹색), 아니면 **IDLE Ns**(노랑), 세션이 사라지면 **DEAD**(빨강). tmux가 구분선을 직접 그리므로 깜빡임 없이 상태에 따라 색이 실시간으로 바뀜
- `session-created`/`session-closed` 전역 훅(인덱스 `[99]`, 기존 훅과 공존)으로 세션 생성/종료 시 타일 자동 추가/제거. 대시보드가 없어지면 훅은 스스로 해제
- 타일에 포커스를 두고 키 하나로 그 세션에 full-screen 진입(`switch-client` — 같은 클라이언트라 리사이즈 부작용 없음), 같은 키로 대시보드 복귀

## 요구사항

tmux **3.2 이상** (3.6에서 개발·검증), POSIX `sh`. macOS/Linux.

## 설치

### 수동 설치

```sh
# 1. overview.sh를 PATH 어딘가에 배치 (위치는 자유):
mkdir -p ~/.local/bin
curl -fLo ~/.local/bin/overview.sh \
  https://raw.githubusercontent.com/justice-hwan/tmux-overview/main/overview.sh
chmod +x ~/.local/bin/overview.sh

# 2. tmux 설정 파일(보통 ~/.tmux.conf; ~/.config/tmux/tmux.conf를 쓰면 거기에)에 키바인딩 추가:
cat >> ~/.tmux.conf <<'EOF'

# tmux-overview
bind-key a     run-shell "$HOME/.local/bin/overview.sh toggle"
bind-key A     run-shell "$HOME/.local/bin/overview.sh rebuild"
bind-key Enter run-shell "$HOME/.local/bin/overview.sh zoom"

# 필터/픽 컨트롤은 작은 팝업 메뉴(tmux display-menu)에 둬서 전역 prefix 키를
# 덮어쓰지 않습니다(기존 find-window / previous-window 그대로 유지). <prefix> C-a로
# 열고, 메뉴 안에서 f=필터, p=픽, c=해제, r=갱신주기 — 또는 화살표 키 / 마우스로 이동.
bind-key C-a display-menu -T "#[align=centre] overview " \
  "Filter (regex)…" f "command-prompt -p \"overview filter (ERE):\" \"run-shell \\\"$HOME/.local/bin/overview.sh filter '%%'\\\"\"" \
  "Pick sessions…"  p "run-shell \"$HOME/.local/bin/overview.sh pickmenu\"" \
  "Clear filter"    c "run-shell \"$HOME/.local/bin/overview.sh unfilter\"" \
  "Refresh interval…" r "run-shell \"$HOME/.local/bin/overview.sh intervalmenu\""
EOF

# 3. 리로드 후 반드시 등록 확인 — 4줄이 안 나오면 tmux가 안 읽는 파일에 넣은 것
#    (실제 로드 파일 확인: tmux display -p '#{config_files}')
tmux source-file ~/.tmux.conf
tmux list-keys | grep overview.sh          # 4줄(a/A/Enter + C-a 메뉴) 나와야 정상; 비면 아래 '문제 해결' 참고
```

또는 repo를 클론해서 번들 설치 스크립트를 실행하면 `${XDG_BIN_HOME:-$HOME/.local/bin}`에 복사하고 키바인딩 스니펫을 출력해줍니다:

```sh
git clone https://github.com/justice-hwan/tmux-overview.git
cd tmux-overview && ./install.sh
```

키는 자유롭게 바꿀 수 있어요(제안일 뿐). 특히 **`C-a`를 prefix로 쓰면** `prefix + a`가 충돌할 수 있으니 다른 키(`bind-key g ...` 등)로 하세요. `C-a` 메뉴 리더도 마찬가지로 기본값일 뿐이니 `C-a`가 이미 쓰이면 다른 빈 키로 바꾸면 됩니다. 스크립트 자체는 키를 바인딩하지 않습니다.

### TPM (Tmux Plugin Manager)

`~/.tmux.conf`에 아래 한 줄을 넣고 `prefix + I`:

```tmux
set -g @plugin 'justice-hwan/tmux-overview'
```

기본 키 커스터마이즈:

```tmux
set -g @overview-key 'a'            # 토글 (기본: a)
set -g @overview-rebuild-key 'A'    # 강제 리빌드 (기본: A)
set -g @overview-enter-key 'Enter'  # 타일 진입 (기본: Enter)
set -g @overview-menu-key 'C-a'     # 필터/픽 팝업 메뉴 (기본: C-a)
set -g @overview-interval '1'       # 갱신 주기(초) 또는 'auto' (기본: 1)
```

필터/픽 컨트롤은 `prefix + C-a`로 여는 작은 팝업 메뉴(tmux `display-menu`)에 있어서 전역 prefix 키를 절대 덮어쓰지 않습니다 — tmux 내장 `find-window`(`f`)와 `previous-window`(`p`)가 그대로 유지됩니다. 메뉴 안에서 `f` 필터, `p` 픽, `c` 해제 — 또는 화살표 키 / 마우스로 이동; 그 밖의 키(또는 Escape)는 닫기. 메뉴는 클라이언트 오버레이라 키를 메뉴가 소비하므로 미러 타일로 새지 않습니다.

## 업그레이드

이미 설치했다면, 설치한 방식 그대로 새 버전을 받으면 됩니다.

- **TPM.** `prefix + U`(TPM 업데이트)로 최신 리비전을 받으면 `overview.tmux`가 다음 리로드 때 `prefix + C-a` 메뉴를 포함한 키바인딩을 자동 재등록합니다. 그 외 할 일 없음. 대시보드가 열려 있으면 `overview.sh kill` 한 번(또는 `prefix + a`로 나갔다 다시 열기)이면 다음 실행부터 새 스크립트가 적용됩니다.
- **번들 설치 스크립트.** 업데이트한 클론에서 `./install.sh`를 다시 실행하면 `overview.sh`를 그 자리에 덮어씁니다. 스크립트가 **키바인딩 스니펫도 다시 출력**하니 `~/.tmux.conf`와 비교해 새로 생긴 것(예: 이전 버전에서 올라온 경우 `bind-key C-a display-menu …` 블록)을 추가한 뒤 `tmux source-file ~/.tmux.conf`.
- **수동 설치.** 새 `overview.sh`를 기존 경로(예: `~/.local/bin/overview.sh`)에 덮어쓰고, `~/.tmux.conf`에 붙여넣은 바인딩 블록을 위 설치 섹션의 현재 스니펫에 맞춰 갱신한 뒤 리로드.

`~/.tmux.conf`에 붙여넣은 바인딩은 **스냅샷**이라 TPM만 자동 동기화됩니다. 따라서 수동/설치 스크립트 사용자는 키가 바뀐 릴리스(예: `C-a` 메뉴 도입) 이후엔 스니펫을 다시 확인하세요. 변경 내역은 [CHANGELOG.md](./CHANGELOG.md) 참고.

## 사용 흐름

`prefix + a`로 열기 → 그리드 훑기 → 평소 pane 이동 키(또는 마우스)로 타일 포커스 → `prefix + a`(또는 `prefix + Enter`)로 진입 → 작업 → `prefix + a`로 복귀. 세션이 생기고 사라지는 것은 그리드가 알아서 따라갑니다.

## 설정 (환경변수)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `OVERVIEW_SESSION` | `overview` | 대시보드 세션 이름 |
| `OVERVIEW_WIDTH` / `OVERVIEW_HEIGHT` | `188` / `53` | 대시보드 세션 생성 크기 (터미널 크기에 맞추면 타일 배치가 정확) |
| `OVERVIEW_IDLE_SEC` | `3` | RUN → IDLE 판정 기준 (초) |
| `OVERVIEW_INTERVAL` | `1` | 기본 미러 갱신 주기 — 초(소수 가능), 또는 `auto`. `set -g @overview-interval`로도 설정, 또는 **Refresh interval** 메뉴에서 실시간 변경(아래 참고). |
| `OVERVIEW_EXCLUDE_SELF` | (미설정) | 설정 시 대시보드를 연 세션을 그리드에서 제외 (build 시점에만 적용) |

키바인딩에서 인라인으로 지정:

```tmux
bind-key a run-shell "OVERVIEW_WIDTH=220 OVERVIEW_HEIGHT=60 $HOME/.local/bin/overview.sh toggle"
```

### 필터링

세션 일부만 보는 방법은 두 가지입니다. 내부적으로는 필터 하나를 공유하며 서로 배타적입니다 — 한쪽을 켜면 다른 쪽은 해제됩니다. 둘 다 대시보드 세션 옵션(`@overview_filter`, 픽 모드는 추가로 `@overview_pick`)에 저장되므로, 훅 기반 자동 갱신에도 계속 적용되고 `rebuild`/`toggle` 후에도 유지됩니다.

**Regex 모드.** ERE(POSIX 확장 정규식 — `grep -E`와 같은 문법)를 입력하면 검증 후 즉시 적용되고 기억됩니다:

```sh
overview.sh filter '^agent-'   # 이름이 "agent-"로 시작하는 세션만
overview.sh filter             # 현재 필터 출력
overview.sh unfilter           # 필터 해제, 전체 세션 표시
```

`prefix + C-a`로 컨트롤 메뉴를 열고 **Filter**(`f`)로 패턴을 입력하거나(`command-prompt`), **Clear filter**(`c`)로 필터를 지웁니다. 잘못된 정규식이거나 매칭되는 세션이 0개면 거부되고 이전 필터가 유지됩니다 — 오타 하나로 대시보드가 텅 비는 일은 없습니다. `build [pattern]`도 스크립팅/바인딩용으로 동일하게 동작합니다(같은 ERE 문법, 같은 옵션):

```tmux
# 항상 필터링된 대시보드를 여는 바인딩:
bind-key A run-shell "$HOME/.local/bin/overview.sh build '^agent-'"
```

**픽(Pick) 모드.** 정규식 대신 이름으로 체크박스 선택하고 싶다면 `prefix + C-a` 다음 **Pick sessions**(`p`)로 살아있는 세션 목록 위에 `display-menu` 체크박스가 뜹니다 — 항목을 누르면 그 세션이 토글되고 메뉴가 다시 열립니다. 내부적으로는 선택된 이름들을 앵커된 ERE 대체 패턴(`^(name1|name2)$`)으로 컴파일해서 regex 모드와 동일한 `@overview_filter` 경로로 적용하므로, 훅 기반 자동 갱신 로직에는 별도 분기가 전혀 없습니다.

```sh
overview.sh pickmenu            # 체크박스 메뉴 열기 (attach된 클라이언트 필요)
overview.sh pick 'agent-a'      # CLI에서 세션 하나 토글 (헤드리스에서도 동작)
overview.sh pick                # 현재 픽 목록 출력
overview.sh unpick              # 픽 목록 초기화 (unfilter의 별칭)
```

픽 상태에서 세션이 죽으면 (regex 모드와 마찬가지로) 즉시 그리드에서 빠집니다 — 단, 마지막 남은 타일이면 tmux 윈도우는 pane이 최소 1개 있어야 하므로 **DEAD** 타일로 남습니다. 이름은 `@overview_pick`에 그대로 남고 — 같은 이름의 세션이 다시 생기면 자동으로 다시 픽됩니다. 세션명에 메타문자(`( ) [ ] . * + ? ^ $ | \`)가 있어도 자동으로 이스케이프되므로, `pick`은 항상 이름 그대로를 정확히 매칭합니다.

### 갱신 주기

타일은 타이머로 다시 그려집니다(기본 **1초**). `prefix + C-a` → **Refresh interval**(`r`)에서 실시간 변경: 프리셋(0.25 / 0.5 / 1 / 2초), **auto**, **custom…** 중 선택. 현재값은 표시되고, 변경은 한 프레임 안에 적용됩니다(rebuild 불필요).

- **고정** — 초 단위 숫자. 소수(0.25/0.5)는 세션이 몇 개 없을 때 더 빠릿합니다 — 단 `sleep`가 소수를 지원해야 합니다(macOS·GNU는 지원, 엄격 POSIX `sleep`는 1초로 폴백).
- **`auto`** — 타일 수에 따라 조절: 1~2개면 ~0.25초, 4개 이상이면 1초. 볼 게 적을 땐 빠르게, 그리드가 꽉 차면 차분하게.

새로 빌드될 때의 기본값은 `~/.tmux.conf`에서:

```tmux
set -g @overview-interval '0.5'    # 또는 'auto', 또는 초 단위 숫자
```

또는 직접: `overview.sh interval 0.5` / `overview.sh interval auto` / `overview.sh interval`(현재값 출력). 메뉴·CLI 변경은 런타임이며, 전체 rebuild(`prefix + A`)는 `@overview-interval`을 다시 읽습니다.

## 한계 (정직하게)

- **읽기전용 + 최대 1초 지연.** 타일에서 입력·스크롤백 불가. 개입은 줌으로.
- 대상이 타일보다 넓으면 각 줄을 타일 너비로 **잘라냄**(ANSI·UTF-8 인식) — 래핑으로 깨지는 대신 왼쪽 일부만 깔끔하게 보임. 실용 타일 수는 약 190×50 기준 **6~9개** (초과 시 경고 후 스킵) — 필터 사용 권장.
- 각 세션의 **활성 window의 활성 pane**만 미러링.
- RUN/IDLE은 출력 기반 휴리스틱 (조용히 생각 중인 에이전트는 IDLE로 보임).
- `OVERVIEW_EXCLUDE_SELF`는 build 시점에만 적용 — 훅 자동 갱신이 런처 세션을 다시 추가할 수 있음 (지속 제외는 필터 패턴 사용).

## 문제 해결

**`prefix + a` 무반응.** 스크립트·tmux는 대개 정상이고, 키바인딩이 안 올라간 겁니다 (제일 흔한 설치 실수). 먼저 확인:

```sh
tmux list-keys | grep overview.sh   # 4줄 나와야 정상
```

- **아무것도 안 나옴** → 바인딩 미로드. bind-key를 안 넣었거나, 리로드를 안 했거나, tmux가 안 읽는 파일에 넣은 것. `tmux display -p '#{config_files}'`로 실제 로드되는 파일을 확인해 거기에 넣고 `tmux source-file`. 도구 동작만 먼저 확인하려면 실행 중 tmux에 직접 바인딩: `tmux bind-key a run-shell "$HOME/.local/bin/overview.sh toggle"`.
- **4줄 나오는데도 안 됨** → prefix를 잘못 눌렀거나 키 충돌. `tmux show -g prefix`로 prefix 확인(기본 `C-b`) 후 그 prefix + `a`. `C-a`가 prefix면 `a`와 충돌할 수 있으니 다른 키로.

## 제거

```sh
# 1. 대시보드 세션 + 전역 훅 제거:
~/.local/bin/overview.sh kill

# 2. tmux 설정 파일에서 tmux-overview bind-key 줄 삭제 후 리로드
#    (prefix 3키 + C-a 메뉴 바인딩)
#    (파일 경로 확인: tmux display -p '#{config_files}')

# 3. 스크립트 삭제:
rm ~/.local/bin/overview.sh
```

`overview.sh kill`을 안 하고 스크립트부터 지웠다면, 남은 훅은 수동으로:

```sh
tmux set-hook -gu 'session-created[99]'
tmux set-hook -gu 'session-closed[99]'
```

**TPM 사용자:** `set -g @plugin 'justice-hwan/tmux-overview'` 줄을 지우고 `prefix + alt + u`.

자세한 설계 근거는 [README.md](./README.md) · [docs/DESIGN.md](./docs/DESIGN.md).

## 라이선스

[MIT](./LICENSE) © 2026 justice-hwan
