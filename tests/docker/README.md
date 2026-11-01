# 시험용 SSH 서버

```sh
docker compose -f tests/docker/compose.yml up -d --build
# bastion: 127.0.0.1:2201 · 내부 서버: app01:22 (bastion 경유로만)
# 계정 jena / jena-test, expired / old-pass-1 (비밀번호 만료 상태 — 시험 전용)
docker compose -f tests/docker/compose.yml down
```

- 호스트 키는 컨테이너가 시작될 때마다 새로 만들어진다. 다시 만들면(`up -d --force-recreate app01`) "호스트 키 바뀜"(AC-6) 시험이 된다.
- 지연 시험: `docker compose -f tests/docker/compose.yml exec bastion tc qdisc add dev eth0 root netem delay 20ms`
