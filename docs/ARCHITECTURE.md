# jena-file 기술 구조 설계 (v0.2)

> 작성 2026-11-01 · 근거: [기획서](기획서.md) v0.11, [russh 스파이크](spike/2026-11-01-russh.md), [UniFFI·SwiftTerm 스파이크](spike/2026-11-01-uniffi.md)
> 범위: **MVP 1차**(기획서 §6.1 — 직접 SFTP + bastion 경유 + 같은 세션 터미널 + 전송 대기열 + 서버 관리). 2차(FTP/FTPS·3개 동시 연결 등)와 Windows는 이 구조 위에 얹을 수 있게만 열어 둔다.

---

## 1. 원칙

1. **어려운 건 핵심(Rust)에, 화면은 얇게.** 연결·재연결·전송·호스트 키 판단 같은 상태와 규칙은 전부 Rust 핵심이 가진다. Swift(이후 C#)는 보여주고 입력을 넘길 뿐이다. 그래야 Windows 판에서 같은 버그를 두 번 고치지 않는다.
2. **russh는 한 곳에 가둔다.** russh는 버전 사이 API 변경이 잦다(기획서 §11.1). russh 타입은 `transport` 모듈 밖으로 나가지 않는다.
3. **비밀은 핵심이 저장하지 않는다.** 비밀번호·키 암호는 OS 저장소(키체인 / Windows 자격 증명 관리자)에만. 핵심은 필요할 때 화면 쪽에 물어본다.
4. **서버가 한 말은 버리지 않는다.** 실패할 때 서버의 stderr·종료 코드를 오류에 담아 올린다(실제 서버 스파이크에서 "비밀번호 만료"가 stderr에만 있었다).
5. **어느 구간이 실패했는지 항상 구분한다.** 모든 오류·이벤트는 `hop`(bastion / 대상 서버)을 가진다.

## 2. 저장소 구성

```
jena-file/
├─ core/                          Rust 워크스페이스
│  ├─ crates/jenafile-core/       핵심 로직 (UniFFI 모름 — 순수 Rust, 단위 시험 대상)
│  │  └─ src/
│  │     ├─ transport/            russh를 쓰는 유일한 곳: 접속, 인증, 채널, direct-tcpip
│  │     ├─ connection/           연결 액터, 연결 트리(bastion→자식), 상태 기계, 재연결
│  │     ├─ sftp/                 목록·파일 작업 (transport 위)
│  │     ├─ transfer/             전송 대기열, 작업자, 이어받기
│  │     ├─ terminal/             PTY 셸 채널 ↔ 바이트 스트림
│  │     ├─ prompt/               사용자에게 묻기(호스트 키·비밀번호·OTP·만료) 요청/응답
│  │     ├─ hostkey/              known_hosts 읽기·대조·기록
│  │     ├─ profile/              서버 목록(JSON), ssh 명령 붙여넣기 해석기
│  │     ├─ events.rs             화면으로 나가는 이벤트 타입
│  │     └─ error.rs              CoreError (hop + 종류 + 서버 메시지)
│  └─ crates/jenafile-ffi/        UniFFI 공개 층 (얇게: 타입 변환·내보내기만) + bindgen 실행 파일
├─ apps/macos/                    SwiftPM 패키지
│  ├─ Sources/JenaFileCore/       UniFFI 생성 Swift (빌드 산출물, 커밋 안 함)
│  ├─ Sources/JenaFileKit/        CoreBridge(메인 스레드 어댑터), 화면 모델, 키체인 저장소
│  ├─ Sources/JenaFile/           AppKit 앱: 창 레이아웃, 파일 창, 터미널 탭, 서버 관리자
│  ├─ Tests/JenaFileKitTests/
│  └─ Vendor/                     JenaFileCore.xcframework (빌드 산출물, 커밋 안 함)
├─ scripts/build-core.sh          core → 바인딩 → xcframework → apps/macos/Vendor
├─ tests/docker/                  시험용 SSH 서버(bastion + 내부 서버) — spike/docker를 옮겨 다듬음
├─ docs/
└─ spike/                         기술 검증 코드(보존, 제품 코드 아님)
```

**왜 core와 ffi를 나누나**: 핵심은 UniFFI 없이 `cargo test`로 시험한다. Windows 판에서 다른 바인딩 방식(C# 전용 생성기 또는 C ABI)을 써야 하더라도 ffi 층만 새로 만들면 된다.

## 3. 동시성 모델 — 연결마다 액터 하나

- 핵심 안에 tokio 런타임 하나. UniFFI의 `async_runtime = "tokio"`로 Swift의 `async` 호출이 이 런타임에서 돈다.
- **연결 하나 = tokio 작업 하나(액터).** 그 연결의 russh 핸들, SFTP 세션, 열린 채널, 상태를 그 작업만 가진다. 바깥(화면·다른 연결)은 명령 채널(`mpsc`)로 요청하고 결과를 `oneshot`으로 받는다.
- 이유: 재연결 중 들어온 명령을 줄 세우기 쉽고, 상태 변경이 한 곳에서만 일어나 경쟁 조건이 없다. 스파이크에서 본 "SFTP + 셸 동시 사용"은 액터 안에서 채널별 하위 작업으로 처리한다.

```
Swift ──async call──▶ ffi ──▶ ConnectionManager ──mpsc──▶ ConnectionActor(A)
                                                   └────▶ ConnectionActor(bastion) ──direct-tcpip──▶ ConnectionActor(B)
Swift ◀──EventSink(콜백)── ffi ◀── events (상태·로그·진행률·묻기 요청)
Swift ◀──TerminalSink(바이트)── ffi ◀── 터미널 출력 (일반 이벤트와 분리, 묶어서 전달)
```

## 4. 연결 모델

### 4.1 연결 트리

- `ConnectionId`마다 액터 하나. bastion 경유 연결은 **부모(bastion) 액터에게 direct-tcpip 채널을 요청**해 그 스트림 위에 자기 SSH 세션을 연다(스파이크의 `connect_stream` 방식).
- bastion은 독립된 연결로도 쓸 수 있다(bastion 자체에 SFTP·터미널). 자식이 있는 동안 bastion은 닫지 않는다.
- 동시 연결 상한(기본 3)은 **bastion을 빼고** 센다. 상한은 설정값 하나(기획서 FR-06).

### 4.2 상태 기계

```
Idle → Connecting{step} → AwaitingPrompt{prompt_id} → Ready
                 ↘ Failed{error}            Ready → Suspended(부모 끊김) → Reconnecting{attempt} → Ready
                                            Ready → Closed
```
- `step`은 화면 상태 표시용: `Dialing` · `HostKey` · `Auth` · `Tunnel` · `Sftp`.
- **부모가 끊기면 자식은 모두 `Suspended`**, 부모가 다시 붙으면 자식을 순서대로 재연결(기획서 FR-24, AC-5). 진행 중 전송은 일시정지 → 재연결 후 이어받기.
- 자동 재연결 3회(간격 1s·3s·9s), 그 뒤 `Failed` + 수동 [다시 연결]. OTP가 필요한 서버는 재연결 때 다시 묻는다.

### 4.3 SFTP 열기 (스파이크 교훈)

`request_subsystem`은 응답을 기다리지 않으므로 **`Success/Failure`를 직접 기다리고**, 조기 종료 시 stderr·exit status를 모아 `CoreError::Server{stderr, exit}`로 올린다. stderr에 `password has expired`가 있으면 `CoreError::PasswordExpired{hop}`(기획서 FR-03b).

전송 기본값(스파이크 실측): SFTP 동시 요청 64 · 쓰기 128KB · SSH 채널 창 32MB.

## 5. 사용자에게 묻기 — 비동기 요청/응답

스파이크에서 호스트 키 확인을 **동기 콜백**(`-> Bool`)으로 했더니, 사용자가 답할 때까지 그 연결의 작업이 묶였다. 제품에서는 이렇게 바꾼다.

1. 핵심이 `Event::PromptRequested { prompt_id, connection, hop, kind }`를 보낸다. `kind`:
   - `HostKeyUnknown { algorithm, fingerprint }` / `HostKeyChanged { old, new }`
   - `Password { user }` · `KeyboardInteractive { name, instructions, prompts[] }`(OTP 포함)
   - `PasswordExpired`(→ 화면은 [터미널에서 변경] 안내)
2. 연결 액터는 `oneshot`으로 응답을 **기다리기만** 한다(스레드를 막지 않음 — tokio 작업이 잠들 뿐).
3. Swift가 창을 띄우고 `core.respond(prompt_id, answer)`를 부른다. 취소·창 닫힘은 `Cancelled`로 응답 → 접속 중단.
4. 저장된 비밀번호가 있으면 화면이 묻지 않고 바로 응답한다(아래 §6). 틀리면 다시 묻고 "저장된 비밀번호를 바꿀까요?"(FR-03a).

## 6. 비밀·설정 저장

| 무엇 | 어디 | 누가 |
|---|---|---|
| 서버 목록(이름·호스트·포트·사용자·경유 서버·색상·기본 경로) | `~/Library/Application Support/jena-file/profiles.json` | 핵심(`profile`) |
| 비밀번호·키 암호 | macOS 키체인(서비스 `com.jenalab.jena-file`, 계정 = 프로필 ID + hop) | **Swift**(`JenaFileKit.KeychainStore`) |
| 호스트 키(읽기) | `~/.ssh/known_hosts` + 앱 전용 `known_hosts` | 핵심(`hostkey`) |
| 호스트 키(새로 신뢰) | **앱 전용** `Application Support/jena-file/known_hosts` | 핵심 |
| 전송 대기열(미완료) | `Application Support/jena-file/queue.json` | 핵심 |
| 화면 상태(창 크기·분할 비율) | `UserDefaults` | Swift |

- 비밀은 핵심이 저장하지 않으므로, 프롬프트 응답 경로(§5)로만 핵심에 들어가고 접속이 끝나면 메모리에서 버린다.
- **사용자의 `~/.ssh/known_hosts`엔 쓰지 않는다**(읽기만). 사용자 파일을 앱이 고치는 건 놀라운 동작이고, OpenSSH 해시 형식·정렬과 충돌할 수 있다. — 결정 대기 §12-Q1.

## 7. 전송

- 대기열은 핵심이 가진다. 항목: `id · connection · 방향(업/다운) · 로컬 경로 · 원격 경로 · 크기 · 전송된 바이트 · 상태`.
- 연결마다 작업자 N개(기본 3, 기획서 FR-12). 폴더는 펼쳐서 파일 단위 항목으로.
- **이어받기**: 재시작 시 대상 쪽 현재 크기를 확인하고 그 지점부터(`REST`가 아니라 SFTP open + offset). 완료 후 크기 비교, 해시 비교는 선택(기본 끔 — 대용량에서 비용 큼).
- 진행률 이벤트는 **항목당 초당 최대 10회**로 묶어서 보낸다(화면 과부하 방지).
- 덮어쓰기 규칙(FR-14)은 충돌 시 `PromptRequested{ kind: Overwrite{…} }`로 묻고 "모두 적용"을 대기열 단위로 기억.
- 미완료 항목은 `queue.json`에 남겨 앱 재시작 후 복원(FR-16).

## 8. 터미널

- SFTP와 **같은 SSH 세션**에 셸 채널(PTY `xterm-256color`, 창 크기)을 연다. 탭 하나 = 채널 하나.
- 출력: 핵심이 채널 데이터를 모아 **터미널 전용 콜백**(`TerminalSink.on_output(terminal_id, bytes)`)으로 보낸다. 일반 이벤트와 섞지 않는 이유는 양이 많기 때문(16ms 단위로 묶음).
- 입력: Swift `TerminalView`의 바이트 → `core.terminal_write(id, bytes)`. 창 크기 변경 → `terminal_resize(id, cols, rows)` → `window_change`.
- **SwiftTerm은 jenalab 포크를 SwiftPM 의존성으로** 쓴다(조합 중 커서 가림 수정 — UniFFI 스파이크 보고서). 수정은 원 저장소에 PR. 원본이 받아들이면 포크를 버리고 원본으로 돌아간다.
- 터미널 창 포커스 순서: 앱 활성화 → 창 키 → 다음 실행 주기에 포커스 + `inputContext.activate()`(한글 첫 입력 스파이크 교훈).

## 9. Swift 쪽

- **`CoreBridge`(`@MainActor`)**: UniFFI 콜백은 tokio 스레드에서 온다. `CoreBridge`가 이를 받아 메인 스레드로 넘기고, 화면 모델(`ConnectionsModel`, `TransferQueueModel`, `LogModel`)을 갱신한다. 화면 코드는 UniFFI 타입을 직접 만지지 않는다.
- 레이아웃(기획서 §7.1): `NSSplitView` 3단(위: 상태 로그 | 전송 상태 / 가운데: 로컬 | 원격 / 아래: 터미널 탭). 빠른 접속 바는 툴바 아래 고정.
- 파일 목록: `NSOutlineView`(트리) + `NSTableView`(목록), 1만 개 이상 대비 지연 로딩.
- 시험: `JenaFileKitTests`에서 가짜 핵심(프로토콜로 추상화)으로 화면 모델 시험.

## 10. 빌드

- `scripts/build-core.sh`: `MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release` → `uniffi-bindgen-swift`(헤더·modulemap·Swift) → `xcodebuild -create-xcframework` → `apps/macos/Vendor/`, 생성 Swift는 `apps/macos/Sources/JenaFileCore/`. 둘 다 `.gitignore`.
- 앱: `swift build` + `.app` 번들 조립·서명은 jena-note의 `Makefile`·`scripts/` 방식을 따른다.
- 최소 macOS: **13**(ADR-009).
- arm64 우선. Intel(x86_64) 범용 빌드는 xcframework에 두 아키텍처를 넣으면 되므로 배포 단계에서 결정.

## 11. 시험 전략

| 층 | 무엇 | 어떻게 |
|---|---|---|
| core 단위 | 상태 기계, 대기열, 붙여넣기 해석기, known_hosts 대조, 오류 분류(만료 stderr 등) | `cargo test`, 네트워크 없이 |
| core 통합 | 직접/경유 접속, SFTP, 터미널, 재연결, 이어받기(중간 차단) | `tests/docker`(bastion + 내부 서버) 대상 `cargo test --features docker-tests`. **컨테이너마다 호스트 키를 시작 때 새로 생성**(스파이크에선 같았음 → 키 바뀜 시험 불가) |
| 지연 | 20ms 지연에서 처리량 회귀 | `tc netem`, 스파이크 수치 기준(직접 업로드 ≥ 70 MiB/s 로컬 Docker) |
| Swift | 화면 모델 | 가짜 핵심으로 XCTest |
| 수동 | 한글 입력, 실제 서버 | 체크리스트(UniFFI 스파이크 보고서) |

## 12. 결정 기록 (ADR 요약)

| # | 결정 | 이유 | 상태 |
|---|---|---|---|
| ADR-001 | SSH 라이브러리 russh | 비동기·스트림 채널이 bastion 경유·한 연결 다중 채널에 맞음. 되돌림 기준은 기획서 §11.1 | 확정 |
| ADR-002 | Rust 공통 핵심 + OS별 네이티브 화면(N2), 연결은 UniFFI | 어려운 로직을 한 번만. UniFFI 스파이크 통과 | 확정 |
| ADR-003 | 연결마다 액터(tokio 작업 + 명령 채널) | 재연결·명령 순서·상태 단일 소유 | 확정 |
| ADR-004 | 사용자 묻기는 비동기 요청/응답(prompt_id) | 동기 콜백은 연결 작업을 묶음(스파이크) | 확정 |
| ADR-005 | 비밀은 OS 저장소, 화면 쪽이 관리 | 핵심에 비밀을 두지 않음, OS별 저장소 차이를 화면 층에 가둠 | 확정 |
| ADR-006 | 새 호스트 키는 앱 전용 known_hosts에 기록, `~/.ssh/known_hosts`는 읽기만 | 사용자 파일 불변 | 확정(2026-11-01) |
| ADR-007 | UniFFI 생성물·xcframework는 커밋 안 함 | 빌드 산출물. 소스와 어긋날 위험 제거 | 확정 |
| ADR-008 | SwiftTerm은 jenalab 포크 → 원본 PR | 조합 중 커서 수정 | 확정 |
| ADR-009 | 최소 macOS 13 (Ventura) | SwiftTerm·Swift 동시성 기준 | 확정(2026-11-01) |

Q1·Q2는 2026-11-01 추천안으로 확정(ADR-006, ADR-009).

## 13. MVP 1차 작업 순서

각 단계는 **혼자 끝까지 써 볼 수 있는 상태**에서 끝난다(작은 완료를 자주).

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| **M0 뼈대** ✅ | 저장소 구성(§2), `build-core.sh`, 빈 AppKit 창이 core 버전 문자열을 표시, `tests/docker` 이전 | `make app` 한 번으로 창이 뜸 — **완료 2026-11-01** |
| **M1 직접 SFTP** | 연결 액터·상태 기계, 호스트 키/비밀번호 묻기(§5), 오른쪽 원격 파일 창 목록·폴더 이동 | AC-1 중 "목록" 부분, AC-6(호스트 키 바뀜 차단) |
| **M2 터미널** | 같은 세션 PTY 탭, SwiftTerm 포크(커서 수정), 파일 창 ↔ 터미널 연동(FR-33) | AC-1 전체(한 번 접속 → 목록 + 셸) |
| **M3 bastion** | 경유 연결 트리, bastion 터미널에서 [내부 서버 열기](FR-21), ssh 명령 붙여넣기(FR-09), 비밀번호 만료 안내(FR-03b) | AC-2·3·4 — **초기 의도 해결 시점** |
| **M4 전송** | 대기열·작업자·드래그 앤 드롭·진행률·덮어쓰기·이어받기·재시작 복원 | AC-5, 처리량 회귀 시험 |
| **M5 서버 관리** | 서버 관리자(S-02), 키체인 저장·갱신(FR-03a), 상태 로그 필터 | 저장된 서버 더블클릭으로 접속 |
| **M6 다듬기·실사용** | 재연결 안정화, 오류 문장 정리, 영어 UI | 기획서 1차 완료 기준: **`ssh -L` + FileZilla를 1주간 한 번도 안 띄움** |

M3이 끝나면 제롬님의 원래 불편(창 두 개, 접속 두 번)이 사라진다. M4~M6은 그 위에 편의를 쌓는 단계다.
