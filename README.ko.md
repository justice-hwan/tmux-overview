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
EOF

# 3. 리로드 후 반드시 등록 확인 — 3줄이 안 나오면 tmux가 안 읽는 파일에 넣은 것
#    (실제 로드 파일 확인: tmux display -p '#{config_files}')
tmux source-file ~/.tmux.conf
tmux list-keys | grep overview.sh          # 3줄 나와야 정상; 비면 아래 '문제 해결' 참고
```

또는 repo를 클론해서 번들 설치 스크립트를 실행하면 `${XDG_BIN_HOME:-$HOME/.local/bin}`에 복사하고 키바인딩 스니펫을 출력해줍니다:

```sh
git clone https://github.com/justice-hwan/tmux-overview.git
cd tmux-overview && ./install.sh
```

키는 자유롭게 바꿀 수 있어요(제안일 뿐). 특히 **`C-a`를 prefix로 쓰면** `prefix + a`가 충돌할 수 있으니 다른 키(`bind-key g ...` 등)로 하세요. 스크립트 자체는 키를 바인딩하지 않습니다.

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
```

## 사용 흐름

`prefix + a`로 열기 → 그리드 훑기 → 평소 pane 이동 키(또는 마우스)로 타일 포커스 → `prefix + a`(또는 `prefix + Enter`)로 진입 → 작업 → `prefix + a`로 복귀. 세션이 생기고 사라지는 것은 그리드가 알아서 따라갑니다.

## 설정 (환경변수)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `OVERVIEW_SESSION` | `overview` | 대시보드 세션 이름 |
| `OVERVIEW_WIDTH` / `OVERVIEW_HEIGHT` | `188` / `53` | 대시보드 세션 생성 크기 (터미널 크기에 맞추면 타일 배치가 정확) |
| `OVERVIEW_IDLE_SEC` | `3` | RUN → IDLE 판정 기준 (초) |
| `OVERVIEW_INTERVAL` | `1` | 미러 갱신 주기 (초) |
| `OVERVIEW_EXCLUDE_SELF` | (미설정) | 설정 시 대시보드를 연 세션을 그리드에서 제외 (build 시점에만 적용) |

키바인딩에서 인라인으로 지정:

```tmux
bind-key a run-shell "OVERVIEW_WIDTH=220 OVERVIEW_HEIGHT=60 $HOME/.local/bin/overview.sh toggle"
```

세션 필터: `overview.sh build '^agent-'` — 패턴은 `@overview_filter` 세션 옵션에 저장되어 자동 갱신에도 유지됩니다.

## 한계 (정직하게)

- **읽기전용 + 최대 1초 지연.** 타일에서 입력·스크롤백 불가. 개입은 줌으로.
- 대상이 타일보다 넓으면 각 줄을 타일 너비로 **잘라냄**(ANSI·UTF-8 인식) — 래핑으로 깨지는 대신 왼쪽 일부만 깔끔하게 보임. 실용 타일 수는 약 190×50 기준 **6~9개** (초과 시 경고 후 스킵) — 필터 사용 권장.
- 각 세션의 **활성 window의 활성 pane**만 미러링.
- RUN/IDLE은 출력 기반 휴리스틱 (조용히 생각 중인 에이전트는 IDLE로 보임).
- `OVERVIEW_EXCLUDE_SELF`는 build 시점에만 적용 — 훅 자동 갱신이 런처 세션을 다시 추가할 수 있음 (지속 제외는 필터 패턴 사용).

## 문제 해결

**`prefix + a` 무반응.** 스크립트·tmux는 대개 정상이고, 키바인딩이 안 올라간 겁니다 (제일 흔한 설치 실수). 먼저 확인:

```sh
tmux list-keys | grep overview.sh   # 3줄 나와야 정상
```

- **아무것도 안 나옴** → 바인딩 미로드. bind-key를 안 넣었거나, 리로드를 안 했거나, tmux가 안 읽는 파일에 넣은 것. `tmux display -p '#{config_files}'`로 실제 로드되는 파일을 확인해 거기에 넣고 `tmux source-file`. 도구 동작만 먼저 확인하려면 실행 중 tmux에 직접 바인딩: `tmux bind-key a run-shell "$HOME/.local/bin/overview.sh toggle"`.
- **3줄 나오는데도 안 됨** → prefix를 잘못 눌렀거나 키 충돌. `tmux show -g prefix`로 prefix 확인(기본 `C-b`) 후 그 prefix + `a`. `C-a`가 prefix면 `a`와 충돌할 수 있으니 다른 키로.

## 제거

```sh
# 1. 대시보드 세션 + 전역 훅 제거:
~/.local/bin/overview.sh kill

# 2. tmux 설정 파일에서 bind-key 3줄 삭제 후 리로드
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
