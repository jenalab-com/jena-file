# jena-file 스크린샷과 캡처 영상

2026-11-12 촬영. `jena-image/assets`, `jena-note/assets`와 같은 구성으로 PNG와 반복 재생 GIF를 두고, 별도 재생용 MP4를 함께 제공한다.

## 산출물

| 파일 | 내용 | 크기 / 길이 |
|---|---|---|
| `01-workspace.png` | bastion 경유 접속, 로컬·원격 폴더 트리, 통합 터미널 | 2560 × 1800 |
| `02-transfer.png` | 폴더 업로드 2건 완료와 원격 파일 내용 확인 | 2560 × 1800 |
| `03-servers.png` | 서버 그룹과 내부 서버의 경유 설정 | 1800 × 1024 |
| `04-ssh-command.png` | `ssh -J` 명령 붙여넣기 입력창 | 1800 × 1024 |
| `05-settings.png` | 동시 전송 수, 이름 충돌 처리, 시작 폴더 | 1040 × 524 |
| `transfer.mp4` / `transfer.gif` | 폴더 드래그 업로드 → 셸에서 목록·설정 내용 확인 | MP4 1280 × 900 / 24초 |
| `terminal.mp4` / `terminal.gif` | bastion과 내부 서버의 셸 탭 전환, `hostname` 실행 | MP4 1280 × 900 / 20초 |
| `servers.mp4` / `servers.gif` | 저장된 서버 설정과 ssh 명령 입력창 | MP4 1200 × 682 / 16초 |

GIF는 메인 화면 960 × 675, 서버 관리 900 × 512, 초당 10프레임이다. MP4는 H.264, yuv420p, 초당 30프레임이며 소리는 없다. 녹화 중 제목 표시줄의 화면 공유 표시는 macOS의 실제 캡처 표시다. 대기 시간 배속은 적용하지 않았다.

## 촬영 환경과 재촬영

- macOS 26.5.2, 한국어 UI, 밝은 화면, 메인 창 1280 × 900pt / Retina 2배.
- 저장소 `a8a0e81` 시점의 `build/JenaFile.app` 실행 파일을 사용했다. 별도 실행본은 번들 식별자만 `com.jenalab.jenafile.capture`로 분리했다. 앱 소스와 실행 파일은 바꾸지 않았다.
- [시험용 SSH 서버](../tests/docker/README.md): `127.0.0.1:2201`의 bastion → Docker 내부 `app01:22`. 실제 운영 서버는 사용하지 않았다.
- 로컬 촬영 파일은 `/Users/Shared/JenaFile-Demo`, 원격 촬영 폴더는 `/home/jena/workspace`. 문서와 설정은 촬영용 예제다.
- `JENAFILE_DATA_DIR`로 데모 서버 목록·known_hosts·전송 기록을 격리했다. 기존 개발용 `JENAFILE_DEV_PROFILE`, `JENAFILE_DEV_PASSWORD`, `JENAFILE_DEV_VIA_PASSWORD`로 시험 서버에 접속했다. 비밀번호는 미디어·서버 목록·이 문서에 기록하지 않았다.
- PNG는 `screencapture -x -o -l<window-id>`, 원본 영상은 `screencapture -x -o -v -l<window-id> -V <seconds>`로 실제 창을 캡처했다. Orca Computer Use로 창을 조작했다.
- FFmpeg로 MP4를 H.264/faststart로 변환하고, `palettegen` / `paletteuse`로 GIF를 만들었다. 원본 MOV는 Git에서 제외되는 `build/captures/2026-11-12/`에 보관한다.

## 검증

- 업로드된 `deploy/app.conf`, `deploy/deploy.sh`의 로컬·원격 SHA-256 일치 확인.
- PNG 5장, 영상별 대표 프레임을 직접 열어 화면·데모 데이터 확인.
- MP4/GIF 6개 모두 ffprobe로 형식·크기·길이를 확인하고, FFmpeg 전체 디코딩 오류가 없음을 확인.
- README의 로컬 미디어 링크 확인. 앱 코드 변경이 없는 미디어 작업으로 빌드·단위 테스트는 다시 실행하지 않았다.
