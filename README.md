# jena-file

원격 파일 전송과 터미널을 한 화면에서 — SFTP · FTP/FTPS · bastion 경유 접속을 지원하는 macOS(이후 Windows) 네이티브 앱.

> Remote file transfer and terminal in one window. Native macOS (Windows later) client for SFTP / FTP / FTPS with built-in bastion (jump host) support.

## 왜 만드나

bastion 뒤 서버에 파일을 올리려면 지금은 터미널에서 `ssh -L`로 터널을 열고, FileZilla로 `localhost`에 다시 접속해야 한다. 창 두 개, 접속 두 번. jena-file은 **한 번의 접속으로 같은 창에 파일 창과 터미널을 함께** 연다. 로컬 포트를 열지 않고 bastion을 거친다.

## 상태

**개발 초기** — 기획·기술 검증·구조 설계를 마치고 MVP 1차 구현 중(M0 뼈대 완료).

| 문서 | 내용 |
|---|---|
| [docs/기획서.md](docs/기획서.md) | 기획서(범위·화면·기능 요구사항·수용 기준·결정 기록) |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 기술 구조 설계(모듈·연결 모델·동시성·저장·MVP 작업 순서) |
| [docs/spike/2026-11-01-russh.md](docs/spike/2026-11-01-russh.md) | russh 검증 — 직접/경유 SFTP, 인증, 처리량 |
| [docs/spike/2026-11-01-uniffi.md](docs/spike/2026-11-01-uniffi.md) | Swift ↔ Rust(UniFFI) 연결, SwiftTerm 한글 입력 |

## 빌드

필요: macOS 13+, Xcode(Swift 6), Rust(rustup).

처음 한 번, `make run` 전에 Rust를 설치한다(`cargo: command not found`가 나면 이 단계가 빠진 것):

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # 기본 옵션으로 설치
. "$HOME/.cargo/env"                                             # 또는 터미널 새로 열기
cargo --version                                                  # 설치 확인
```

`brew install rust`가 아니라 rustup을 쓴다. 빌드 스크립트가 `~/.cargo/env`를 직접 불러오므로 PATH 설정 전이어도 동작한다. 첫 빌드는 의존성 컴파일로 몇 분 걸린다.

```sh
make run        # Rust 핵심 → xcframework → 앱 빌드(build/JenaFile.app) → 실행
make test       # cargo test + swift test
```

시험용 SSH 서버: [tests/docker/README.md](tests/docker/README.md)

## 구조

- **핵심** (`core/`): Rust — [russh](https://github.com/Eugeny/russh) 기반 SSH/SFTP, 연결·전송 대기열·서버 목록
- **화면** (`apps/macos/`): macOS는 Swift/AppKit + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), Windows는 C# 네이티브(이후)
- **연결**: [UniFFI](https://github.com/mozilla/uniffi-rs)로 Rust 핵심을 Swift에서 호출

`spike/`는 기술 검증용 코드이며 제품 코드가 아니다. 다시 돌리는 법은 [spike/README.md](spike/README.md).

## 라이선스

[MIT](LICENSE) © 2026 JenaLab
