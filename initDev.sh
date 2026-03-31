#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "  Development Environment Initialization"
echo "=========================================="
echo ""
echo "This script will:"
echo "  - Create a .env file with all necessary configurations"
echo "  - Set up MinIO"
echo "  - Set up the backend database (via migrations)"
echo "  - Set up Keycloak"
echo ""
read -p "$(cat <<'EOF'
Do you want to proceed with the initialization?
This will set up the complete development environment.
Type 'y' to continue or any other key to cancel:
EOF
)" -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Initialization cancelled."
  exit 0
fi

echo ""
read -p "$(cat <<'EOF'
Before we proceed, please confirm that your /etc/hosts file contains the necessary entries:

127.0.0.1  auth.cut-dana-platform.local
127.0.0.1  app.cut-dana-platform.local
127.0.0.1  minio.cut-dana-platform.local

Type 'y' to confirm or any other key to cancel:
EOF
)" -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Initialization cancelled."
  exit 0
fi

# Remove existing .env file if it exists
if [ -f .env ]; then
  echo "Remove existing .env file to initialize the project again."
  exit 0
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
  echo "Error: jq is not installed. Please install jq to continue."
  echo "On Ubuntu/Debian: sudo apt-get install jq"
  exit 1
fi

# Copy env.example to .env if it does not exist
if [ ! -f .env ]; then
  cp .env.example .env
fi

# Parse --data-narrator-backend-dir, --data-narrator-mp-dir and --data-narrator-mp-addon-dir
# parameters or prompt if not provided
CUT_DANA_BACKEND_DIR=
CUT_DANA_MP_DIR=""
CUT_DANA_MP_ADDON_DIR=""
for arg in "$@"; do
  case $arg in
    --data-narrator-backend-dir=*)
      CUT_DANA_BACKEND_DIR="${arg#*=}"
      shift
      ;;
    --data-narrator-mp-dir=*)
      CUT_DANA_MP_DIR="${arg#*=}"
      shift
      ;;
    --data-narrator-mp-addon-dir=*)
      CUT_DANA_MP_ADDON_DIR="${arg#*=}"
      shift
      ;;
  esac
done

if [ -z "$CUT_DANA_BACKEND_DIR" ]; then
  read -p "Enter the base directory of data narrator backend: " CUT_DANA_BACKEND_DIR
fi

if [ -z "$CUT_DANA_MP_DIR" ]; then
  read -p "Enter the base directory of data narrator masterportal: " CUT_DANA_MP_DIR
fi

if [ -z "$CUT_DANA_MP_ADDON_DIR" ]; then
  read -p "Enter the base directory of data narrator masterportal addon: " CUT_DANA_MP_ADDON_DIR
fi

HOST_IP=$(ip route get 1 | awk '{gsub("^.*src ",""); print $1; exit}')
sed -i -E "s/HOST_IP=(.+)/HOST_IP=${HOST_IP}/" .env
sed -i -E "s/DATABASE_PASSWORD=(.+)/DATABASE_PASSWORD=$(pwgen 19 1 -s)/" .env
sed -i -E "s/KEYCLOAK_DATABASE_PASSWORD=(.+)/KEYCLOAK_DATABASE_PASSWORD=$(pwgen 19 1 -s)/" .env
sed -i -E "s/KEYCLOAK_PASSWORD=(.+)/KEYCLOAK_PASSWORD=$(pwgen 19 1 -s)/" .env
sed -i -E "s/CUT_DANA_BACKEND_DIR=(.+)/CUT_DANA_BACKEND_DIR=$(echo $CUT_DANA_BACKEND_DIR | sed 's_/_\\/_g')/" .env
sed -i -E "s/CUT_DANA_MP_DIR=(.+)/CUT_DANA_MP_DIR=$(echo $CUT_DANA_MP_DIR | sed 's_/_\\/_g')/" .env
sed -i -E "s/CUT_DANA_MP_ADDON_DIR=(.+)/CUT_DANA_MP_ADDON_DIR=$(echo $CUT_DANA_MP_ADDON_DIR | sed 's_/_\\/_g')/" .env

# load predefined environment variables from .env file
ENV_FILE=".env"
set -o allexport
source "$ENV_FILE"
set +o allexport

# Generate garage tokens and update garage.toml
cp ./garage/garage.toml.example ./garage/garage.toml
GARAGE_TOKEN=$(openssl rand -base64 32 | tr '/+' '_-' | tr -d '=')
sed -i "s/admin_token = \".*\"/admin_token = \"$GARAGE_TOKEN\"/" ./garage/garage.toml
GARAGE_TOKEN=$(openssl rand -base64 32 | tr '/+' '_-' | tr -d '=')
sed -i "s/metrics_token = \".*\"/metrics_token = \"$GARAGE_TOKEN\"/" ./garage/garage.toml
GARAGE_TOKEN=$(openssl rand -hex 32 | tr '/+' '_-' | tr -d '=')
sed -i "s/rpc_secret = \".*\"/rpc_secret = \"$GARAGE_TOKEN\"/" ./garage/garage.toml

docker compose up -d garage

sleep 2

echo "Waiting for garage to become healthy 😴…"
until docker compose ps | grep garage | grep -q "(healthy)"; do
  sleep 5
  echo "Waiting 5 sec for garage health check ⏱️…"
done

HOST=${HOST:-'http://localhost:3903'}
GARAGE_NODE_ID=$(docker compose exec garage /garage status 2>&1 | awk '/^[a-f0-9]{16}/ {print $1}')
echo "Node ID: ${GARAGE_NODE_ID}"

docker compose exec garage /garage layout assign -c 1G -z dc1 ${GARAGE_NODE_ID}
docker compose exec garage /garage layout apply --version 1

KEY_OUTPUT=$(docker compose exec garage /garage key create ${MINIO_DEFAULT_BUCKET}-key)
GARAGE_KEY_ID=$(echo "$KEY_OUTPUT" | awk '/Key ID:/ {print $3}')
GARAGE_SECRET_KEY=$(echo "$KEY_OUTPUT" | awk '/Secret key:/ {print $3}')
echo "Generated Garage Key with ID: ${GARAGE_KEY_ID}"

sed -i -E "s/MINIO_ACCESS_KEY=(.+)/MINIO_ACCESS_KEY=$(echo $GARAGE_KEY_ID | sed 's_/_\\/_g')/" .env
sed -i -E "s/MINIO_SECRET_KEY=(.+)/MINIO_SECRET_KEY=$(echo $GARAGE_SECRET_KEY | sed 's_/_\\/_g')/" .env

docker compose exec garage /garage bucket create ${MINIO_DEFAULT_BUCKET}
docker compose exec garage /garage bucket allow --read --write --owner ${MINIO_DEFAULT_BUCKET} --key ${MINIO_DEFAULT_BUCKET}-key

echo "garage bucket '${MINIO_DEFAULT_BUCKET}' created successfully! 🎉"
docker compose down

docker compose up -d
sleep 5

echo "Waiting for keycloak to become healthy 😴..."
until docker compose ps | grep -w keycloak-app | grep -q "(healthy)"; do
  sleep 5
  echo "Waiting 5 sec for keycloak health check ⏱️..."
   if ! docker compose ps | grep nginx | grep -q "Up"; then
     echo "nginx is not running. Starting nginx with docker compose..."
     docker compose up -d nginx
   fi
done

echo "[*] Authenticating in keycloak with dummy secret ..."
KC_ACCESS_TOKEN=$(curl \
  -s \
  -k \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${KEYCLOAK_CLIENT_ID}" \
  -d "client_secret=${KEYCLOAK_CLIENT_SECRET}" \
  "${KEYCLOAK_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" | jq -r ".access_token")
echo "[*] Retrieved access_token for Keycloak admin API: ${KC_ACCESS_TOKEN}"

# The client ID is fixed as per the exported Keycloak configuration
KC_CLIENT_SECRET=$(curl \
  -X POST \
  -s \
  -k \
  -H "Authorization: Bearer ${KC_ACCESS_TOKEN}" \
  "${KEYCLOAK_URL%/}/admin/realms/${KEYCLOAK_REALM}/clients/41710855-cc85-4baf-b2cf-29b282983914/client-secret" | jq -r ".value")

sed -i -E "s/KEYCLOAK_CLIENT_SECRET=(.+)/KEYCLOAK_CLIENT_SECRET=$(echo $KC_CLIENT_SECRET | sed 's_/_\\/_g')/" .env

echo "Keycloak initialized successfully! 🎉"

echo "Running database migrations…"
echo "" | docker compose run --rm -T backend bun run reset-db --skip-generate --force
echo "Database migrations completed successfully! 🎉"

echo "Adding the default Keycloak setup for the backend…"
docker compose exec db psql -U ${DATABASE_USER} -d ${DATABASE_DB} -c "
INSERT INTO \"KeycloakSetup\" (\"authUri\", \"tokenUri\", \"clientId\", \"scope\", \"redirectUri\") VALUES (
  '${KEYCLOAK_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/auth',
  '${KEYCLOAK_URL%/}/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token',
  '${KEYCLOAK_FRONTEND_CLIENT_ID}',
  'profile email openid',
  'https://app.${HOSTNAME}/portal/stories'
);"
echo "Success! 🎉"

docker compose down
echo "Project initialized successfully! 🎉"
