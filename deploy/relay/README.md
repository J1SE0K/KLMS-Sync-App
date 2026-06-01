# KLMS Sync Relay Deployment

이 배포 템플릿은 Windows/iPhone이 같은 네트워크 밖에서도 Mac에 동기화 요청을 보낼 수 있게 하는 HTTPS 릴레이 서버다.

구조:

```text
Windows/iPhone -> https://sync.example.com -> Caddy HTTPS -> relay + SQLite -> Mac 앱 polling -> KLMS 동기화
```

Mac이 실제 KLMS, Notes, Calendar, Reminders 작업을 실행한다. 서버는 실행 요청, 요약 숫자, sanitized 항목 목록만 저장한다.

## 방식 1: VPS + Caddy

1. DNS에서 `sync.example.com` 같은 서브도메인을 VPS IP로 연결한다.
2. VPS에 Docker와 Docker Compose를 설치한다.
3. 이 repo를 VPS에 복사하거나 clone한다.
4. 환경 파일을 만든다.

```sh
cd deploy/relay
./init_env.sh sync.example.com
```

출력된 토큰을 저장해 둔다. iPhone/Windows에는 클라이언트 토큰을 넣고, Mac 앱에는 Mac worker 토큰을 넣는다.

5. 서버를 실행한다.

```sh
./deploy.sh
```

6. 확인한다.

```sh
./status.sh
```

Docker가 없다면 Ubuntu VPS에서 먼저 실행한다.

```sh
./bootstrap_ubuntu.sh
```

## 앱 연결값

iPhone/Windows에는 아래 값을 넣는다.

```text
서버 주소: https://sync.example.com
클라이언트 토큰: <KLMS_RELAY_CLIENT_TOKEN>
```

서브패스로 분리하고 싶으면 Caddyfile이 `/relay/*`도 지원하므로 아래 주소도 된다.

```text
서버 주소: https://sync.example.com/relay
클라이언트 토큰: <KLMS_RELAY_CLIENT_TOKEN>
```

Mac 앱에는 같은 서버 주소와 `<KLMS_RELAY_WORKER_TOKEN>`을 입력한다.

## Mac 쪽 조건

- Mac 앱에서 `서버 릴레이 사용`을 켠다.
- 서버 주소와 Mac worker 토큰을 입력한다.
- Mac 앱이 켜져 있어야 Windows/iPhone 요청을 가져가 실행한다.
- Mac이 잠자기 상태면 요청은 서버 DB에 남고, Mac이 깨어난 뒤 처리된다.

## 보안 원칙

- 외부 공개 주소는 HTTPS만 쓴다.
- Mac의 로컬 포트를 인터넷에 직접 열지 않는다.
- 토큰을 바꾸면 클라이언트 앱에는 새 클라이언트 토큰을, Mac 앱에는 새 worker 토큰을 다시 입력한다.
- SQLite DB는 Docker volume `relay-data`에 저장된다.

## 업데이트

repo를 갱신한 뒤:

```sh
cd deploy/relay
./deploy.sh
```

DB volume은 유지된다.

DB 백업:

```sh
./backup_db.sh
```

## 방식 2: Cloudflare Tunnel

VPS 없이 Mac이나 작은 서버에서 터널로 HTTPS 주소를 만들 수도 있다.

1. Cloudflare Zero Trust에서 Tunnel을 만든다.
2. Public hostname을 만든다.
3. Service는 아래처럼 둔다.

```text
http://relay:18484
```

4. Tunnel token을 복사한다.
5. 환경 파일을 만든다.

```sh
cd deploy/relay
cp relay.cloudflare.env.example .env.cloudflare
openssl rand -hex 32
```

`.env.cloudflare`를 수정한다.

```sh
KLMS_RELAY_CLIENT_TOKEN=<client openssl 출력값>
KLMS_RELAY_WORKER_TOKEN=<worker openssl 출력값>
CLOUDFLARE_TUNNEL_TOKEN=<Cloudflare tunnel token>
```

6. 실행한다.

```sh
docker compose -f docker-compose.cloudflared.yml up -d --build
```

7. 앱 연결값은 Cloudflare Public hostname을 쓴다.

```text
서버 주소: https://sync.example.com
클라이언트 토큰: <KLMS_RELAY_CLIENT_TOKEN>
```

Mac 앱에는 같은 서버 주소와 `<KLMS_RELAY_WORKER_TOKEN>`을 넣는다. Cloudflare Tunnel 방식은 포트를 열지 않아도 된다. 다만 터널을 실행하는 Mac/서버가 꺼져 있으면 Windows/iPhone 요청은 처리되지 않는다.
