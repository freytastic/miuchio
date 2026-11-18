# Development

How to run Miuchio locally, configure the server, make store builds and run the tests. For how to propose a change, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Run it locally

### What you need

- Docker with Docker Compose
- [Flutter](https://docs.flutter.dev/get-started/install) 3.44 or newer on the stable channel, with Dart 3.12 or newer
- For Android: Android Studio or the Android SDK, and a phone or emulator
- For iPhone: a Mac with Xcode, and a phone or simulator
- Go 1.26.1 or newer, only if you want to run the server or its tests outside Docker

The app builds libsodium from source on the first build, using the normal build tools of your platform.

### 1. Start the server

```bash
cp .env.example .env
```

In `.env`, set `S3_PUBLIC_ENDPOINT` to your computer's LAN IP, for example `http://192.168.1.10:9000`. The phone downloads photos from that address, so it has to be reachable from the phone.

```bash
docker compose up --build
```

This starts Postgres, Redis, MinIO and the server on port 8080, with live reload when you edit server code. The server applies migrations and creates the storage bucket on start. Check it with:

```bash
curl http://localhost:8080/health
```

`APP_ENV=dev` lets the server start with placeholder keys. Never use it for anything other than a local stack.

### 2. Run the app

```bash
cd client
flutter pub get
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8080/api/v1
```

Use the same LAN IP as in `.env`, so a real phone on the same network can reach the server.

For a real iPhone, open `client/ios/Runner.xcworkspace` in Xcode once and choose your team under Signing & Capabilities.

### 3. Sign in

Enter any email address. When `RESEND_API_KEY` is empty, the server does not send email. It prints the code in its log instead:

```bash
docker compose logs -f server
```

To try invites, removal or safety numbers, sign in on a second phone or emulator with another email and add each other with your Miuchio IDs.

## Store builds

`client/release.sh` makes the files for the stores. It refuses an address that is not `https://…/api/v1` and checks the server answers before building:

```bash
cd client
./release.sh android https://api.example.com/api/v1   # needs android/key.properties with the Play upload key
./release.sh ios https://api.example.com/api/v1
```

## Configuration

The server is configured with environment variables. `.env.example` lists the ones Docker Compose uses.

| Variable | Purpose |
| --- | --- |
| `APP_ENV` | `dev` allows placeholder keys and enables test endpoints |
| `DATABASE_URL`, `REDIS_URL`, `PORT` | Set by `docker-compose.yml`. `REDIS_URL` is a `host:port` address |
| `RESEND_API_KEY` | Sends sign in codes through [Resend](https://resend.com). Required outside dev. In dev, leaving it empty prints codes to the log |
| `EMAIL_FROM` | Sender address on a domain verified with Resend. Required outside dev |
| `MIUCHIO_EMAIL_HMAC_KEY` | Keys the hash that stands in for email addresses. Required outside dev |
| `MIUCHIO_USER_LINK_KEY` | Keys the encrypted link between accounts and album memberships. Required outside dev |
| `S3_ENDPOINT`, `S3_PUBLIC_ENDPOINT` | Storage address for the server, and the one used in links handed to phones. The second is optional when phones can reach the first |
| `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`, `S3_REGION`, `USE_PATH_STYLE` | Storage credentials and options |
| `USER_STORAGE_QUOTA_MB`, `TOTAL_STORAGE_LIMIT_GB` | Upload limits per account and for the whole server, 1536 MB and 100 GB by default. `0` turns one off |
| `MODERATION_EMAIL` | Receives a short alert, with no report content, when someone files a report. Optional |
| `REVIEW_EMAIL`, `REVIEW_CODE` | A fixed sign in for app store reviewers. Off unless both are set, see `.env.example` for the required shape |

Generate the two Miuchio keys with `openssl rand -base64 32`. Treat them like a database password and never change them on a server with real data: changing either one disconnects every existing account from its albums.

## Tests

```bash
cd server
go vet ./...
go test ./...

cd ../client
flutter analyze
flutter test
```

Run `flutter test` from `client/`, because the cross-language tests read `../test_vectors/crypto_kat.json`.

Some server tests need a real Postgres and Redis and skip themselves otherwise. They cover the album lock, races and replay, which mocks cannot. To run them, create a separate test database, apply the migrations to it and pass both addresses:

```bash
docker compose up -d postgres redis
docker compose exec -T postgres createdb -U postgres miuchio_test
for f in server/migrations/*.up.sql; do
  docker compose exec -T postgres psql -U postgres -d miuchio_test -v ON_ERROR_STOP=1 -q < "$f"
done

cd server
MIUCHIO_TEST_DATABASE_URL="postgres://postgres:password@localhost:5432/miuchio_test?sslmode=disable" \
MIUCHIO_TEST_REDIS_URL="localhost:6379" \
go test ./...
```

`MIUCHIO_TEST_REDIS_URL` is a `host:port` address, not a `redis://` URL. With the wrong form the Redis tests skip silently.

