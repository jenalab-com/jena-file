# spike — 0단계 기술 검증

결과 보고서: `../docs/spike/2026-11-01-russh.md`

## 다시 돌리기

```sh
cd docker
ssh-keygen -q -t ed25519 -N "" -C spike -f ./spike_key   # 처음 한 번 (키는 git 제외)
docker compose -p jenafile-spike up -d --build
cd ../russh-spike && cargo build --release
export SPIKE_PASSWORD=jena-test   # 시험용 컨테이너 전용 비밀번호
B=target/release/russh-spike
$B direct 127.0.0.1:2201                   # 직접 SFTP + 같은 세션 셸
$B --kbd jump 127.0.0.1:2201 app01:22      # bastion 경유, keyboard-interactive
$B --inflight 64 --write-kib 128 --window-mib 32 --file /tmp/1g.bin direct 127.0.0.1:2201
```

지연 시험: `docker compose -p jenafile-spike exec bastion tc qdisc add dev eth0 root netem delay 20ms`
(끄기: `... tc qdisc del dev eth0 root`) · `docker/ssh_config`는 비교용 OpenSSH(`scp -F docker/ssh_config`) 설정.

시험용 서버는 `127.0.0.1`에만 열린다. 실제 서버 주소·계정은 이 폴더에 쓰지 않는다.

## Swift ↔ Rust (UniFFI)

```sh
core-ffi/build.sh                        # Rust → 바인딩 → xcframework → swift-host 빌드
SPIKE_PASSWORD=jena-test swift-host/.build/release/SpikeHost 127.0.0.1 2201 jena
SPIKE_PASSWORD=jena-test swift-host/.build/release/SpikeHost app01 22 jena --via 127.0.0.1 2201 jena
```

## SwiftTerm 한글 입력

```sh
cd term-host && swift build -c release && .build/release/TermHost
```
