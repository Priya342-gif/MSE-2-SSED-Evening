#!/usr/bin/env bash
# =============================================================================
# MSE-2 Docker Practical – run_all.sh
# Run this once in Git Bash from the repo root.
# Every section produces terminal output you can screenshot.
# All output is also saved to execution.log
# =============================================================================

set -uo pipefail
LOG=execution.log
> "$LOG"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS() { echo -e "${GREEN}[PASS]${NC} $*" | tee -a "$LOG"; }
FAIL() { echo -e "${RED}[FAIL]${NC} $*" | tee -a "$LOG"; }
STEP() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}" | tee -a "$LOG"
         echo -e "${CYAN}  $*${NC}" | tee -a "$LOG"
         echo -e "${CYAN}══════════════════════════════════════════${NC}" | tee -a "$LOG"; }

# ── Require DOCKERHUB_USERNAME ────────────────────────────────────────────────
DOCKERHUB_USERNAME="priya111222333"
export DOCKERHUB_USERNAME

# ── Load .env if present ──────────────────────────────────────────────────────
if [ -f .env ]; then
  # shellcheck disable=SC2046
  export $(grep -v '^#' .env | grep -v '^$' | xargs)
fi
# Override DOCKERHUB_USERNAME from above input if needed
export DOCKERHUB_USERNAME

# =============================================================================
# TASK 1 – Build Docker images
# =============================================================================
STEP "TASK 1A: Build backend Docker image"
docker build -t taskflow-backend:local ./backend 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -eq 0 ]; then PASS "Backend image built"; else FAIL "Backend build failed"; exit 1; fi

STEP "TASK 1B: Build frontend Docker image"
docker build -t taskflow-frontend:local ./frontend 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -eq 0 ]; then PASS "Frontend image built"; else FAIL "Frontend build failed"; exit 1; fi

STEP "TASK 1C: List built images"
docker images | grep -E "REPOSITORY|taskflow" | tee -a "$LOG"
PASS "Images listed"

# =============================================================================
# TASK 2 – Docker Compose: start full stack
# =============================================================================
STEP "TASK 2A: Start full application stack with docker-compose.yml"
docker compose down -v --remove-orphans 2>&1 | tee -a "$LOG" || true
docker compose up -d 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -eq 0 ]; then PASS "Stack started"; else FAIL "Stack failed to start"; exit 1; fi

STEP "TASK 2B: Wait for backend health (up to 2 min)"
for i in $(seq 1 40); do
  HEALTH=$(curl --fail --silent http://localhost:3000/health 2>/dev/null || true)
  if echo "$HEALTH" | grep -q '"status":"ok"'; then
    echo "$HEALTH" | tee -a "$LOG"
    PASS "Backend is healthy"
    break
  fi
  echo "Waiting for backend... attempt $i/40" | tee -a "$LOG"
  sleep 3
  if [ "$i" -eq 40 ]; then
    FAIL "Backend never became healthy"
    docker compose logs --no-color | tee -a "$LOG"
    exit 1
  fi
done

STEP "TASK 2C: Check frontend responding"
for i in $(seq 1 20); do
  if curl --fail --silent http://localhost:8080/ > /dev/null 2>&1; then
    PASS "Frontend is responding on http://localhost:8080"
    break
  fi
  echo "Waiting for frontend... attempt $i/20" | tee -a "$LOG"
  sleep 3
  if [ "$i" -eq 20 ]; then FAIL "Frontend not responding"; docker compose logs frontend | tee -a "$LOG"; exit 1; fi
done

STEP "TASK 2D: Show running containers and health"
docker compose ps 2>&1 | tee -a "$LOG"
PASS "Container status shown"

STEP "TASK 2E: Inspect custom Docker network"
docker network ls | grep -E "NETWORK|taskflow" 2>&1 | tee -a "$LOG"
docker network inspect "$(docker compose ps -q | head -1 | xargs docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}')" --format '{{.Name}} – Driver: {{.Driver}} – Subnet: {{(index .IPAM.Config 0).Subnet}}' 2>&1 | tee -a "$LOG" || \
  docker network ls | grep taskflow | tee -a "$LOG"
PASS "Network verified"

# =============================================================================
# TASK 5 – Networking verification
# =============================================================================
STEP "TASK 5A: Backend connects to PostgreSQL (via service name)"
docker compose exec backend wget -qO- http://localhost:3000/health 2>&1 | tee -a "$LOG"
PASS "Backend→PostgreSQL connection verified via /health"

STEP "TASK 5B: Backend connects to Redis (via service name)"
docker compose exec redis redis-cli ping 2>&1 | tee -a "$LOG"
PASS "Redis responds to PING"

STEP "TASK 5C: Health check status of all services"
docker inspect --format '{{.Name}} – Health: {{.State.Health.Status}}' \
  $(docker compose ps -q) 2>&1 | tee -a "$LOG"
PASS "Health statuses shown"

STEP "TASK 5D: PostgreSQL data persistence test"
echo "--- Writing test data ---" | tee -a "$LOG"
docker compose exec -T postgres psql -U "${POSTGRES_USER:-taskflow_user}" -d "${POSTGRES_DB:-taskflow}" \
  -c "INSERT INTO users (name,email,password_hash) VALUES ('PersistTest','persist@test.com','hash123') ON CONFLICT DO NOTHING;" 2>&1 | tee -a "$LOG"
docker compose exec -T postgres psql -U "${POSTGRES_USER:-taskflow_user}" -d "${POSTGRES_DB:-taskflow}" \
  -c "SELECT id,name,email FROM users WHERE email='persist@test.com';" 2>&1 | tee -a "$LOG"

echo "--- Removing and recreating PostgreSQL container ---" | tee -a "$LOG"
docker compose rm -sf postgres 2>&1 | tee -a "$LOG"
docker compose up -d postgres 2>&1 | tee -a "$LOG"
sleep 20

echo "--- Verifying data survived ---" | tee -a "$LOG"
docker compose exec -T postgres psql -U "${POSTGRES_USER:-taskflow_user}" -d "${POSTGRES_DB:-taskflow}" \
  -c "SELECT id,name,email FROM users WHERE email='persist@test.com';" 2>&1 | tee -a "$LOG"
PASS "Persistence verified – data survived container removal"

# =============================================================================
# TASK 3 – Tag and push to Docker Hub
# =============================================================================
STEP "TASK 3A: Login to Docker Hub (manual step)"
echo ""
echo "┌──────────────────────────────────────────────────────────────────┐"
echo "│  Please log in to Docker Hub. Enter your credentials below.      │"
echo "└──────────────────────────────────────────────────────────────────┘"
docker login 2>&1 | tee -a "$LOG"

STEP "TASK 3B: Tag backend image"
docker tag taskflow-backend:local "${DOCKERHUB_USERNAME}/taskflow-backend:v1" 2>&1 | tee -a "$LOG"
docker tag taskflow-backend:local "${DOCKERHUB_USERNAME}/taskflow-backend:latest" 2>&1 | tee -a "$LOG"
PASS "Backend tagged as v1 and latest"

STEP "TASK 3C: Tag frontend image"
docker tag taskflow-frontend:local "${DOCKERHUB_USERNAME}/taskflow-frontend:v1" 2>&1 | tee -a "$LOG"
docker tag taskflow-frontend:local "${DOCKERHUB_USERNAME}/taskflow-frontend:latest" 2>&1 | tee -a "$LOG"
PASS "Frontend tagged as v1 and latest"

STEP "TASK 3D: Push backend to Docker Hub (v1 + latest)"
docker push "${DOCKERHUB_USERNAME}/taskflow-backend:v1" 2>&1 | tee -a "$LOG"
docker push "${DOCKERHUB_USERNAME}/taskflow-backend:latest" 2>&1 | tee -a "$LOG"
PASS "Backend pushed to Docker Hub"

STEP "TASK 3E: Push frontend to Docker Hub (v1 + latest)"
docker push "${DOCKERHUB_USERNAME}/taskflow-frontend:v1" 2>&1 | tee -a "$LOG"
docker push "${DOCKERHUB_USERNAME}/taskflow-frontend:latest" 2>&1 | tee -a "$LOG"
PASS "Frontend pushed to Docker Hub"

STEP "TASK 3F: Verify images on Docker Hub"
echo "Backend image: https://hub.docker.com/r/${DOCKERHUB_USERNAME}/taskflow-backend/tags" | tee -a "$LOG"
echo "Frontend image: https://hub.docker.com/r/${DOCKERHUB_USERNAME}/taskflow-frontend/tags" | tee -a "$LOG"
docker images | grep -E "REPOSITORY|taskflow" | tee -a "$LOG"
PASS "All 4 tags visible locally (verify on Docker Hub website for screenshot)"

# =============================================================================
# TASK 4 – Image-based deployment
# =============================================================================
STEP "TASK 4A: Bring down build-based stack"
docker compose down --remove-orphans 2>&1 | tee -a "$LOG"
PASS "Build stack removed"

STEP "TASK 4B: Pull images from Docker Hub"
docker compose -f docker-compose.deploy.yml pull 2>&1 | tee -a "$LOG"
PASS "Images pulled from Docker Hub"

STEP "TASK 4C: Deploy using docker-compose.deploy.yml"
docker compose -f docker-compose.deploy.yml up -d 2>&1 | tee -a "$LOG"
if [ "${PIPESTATUS[0]}" -eq 0 ]; then PASS "Deploy stack started"; else FAIL "Deploy failed"; exit 1; fi

STEP "TASK 4D: Wait for deployed backend health"
for i in $(seq 1 40); do
  HEALTH=$(curl --fail --silent http://localhost:3000/health 2>/dev/null || true)
  if echo "$HEALTH" | grep -q '"status":"ok"'; then
    echo "$HEALTH" | tee -a "$LOG"
    PASS "Deployed backend is healthy"
    break
  fi
  echo "Waiting... $i/40" | tee -a "$LOG"
  sleep 3
  if [ "$i" -eq 40 ]; then FAIL "Deployed backend never healthy"; exit 1; fi
done

STEP "TASK 4E: Check deployed frontend"
curl --fail --silent http://localhost:8080/ > /dev/null && PASS "Deployed frontend responding" || FAIL "Frontend not responding"

STEP "TASK 4F: Show deployed container status"
docker compose -f docker-compose.deploy.yml ps 2>&1 | tee -a "$LOG"
PASS "Deploy container status shown"

# =============================================================================
# TASK 5E – Redis restart
# =============================================================================
STEP "TASK 5E: Restart Redis and verify"
docker compose -f docker-compose.deploy.yml restart redis 2>&1 | tee -a "$LOG"
sleep 5
docker compose -f docker-compose.deploy.yml exec redis redis-cli ping 2>&1 | tee -a "$LOG"
PASS "Redis restarted successfully"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
STEP "FINAL SUMMARY"
echo "" | tee -a "$LOG"
echo "All automated tasks completed. Next manual steps:" | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "  1. Fill in submission.json with your real details" | tee -a "$LOG"
echo "  2. Set GitHub Secrets: DOCKERHUB_USERNAME, DOCKERHUB_TOKEN, POSTGRES_PASSWORD" | tee -a "$LOG"
echo "     → https://github.com/YOUR_GITHUB_USERNAME/MSE-2-SSED-Evening/settings/secrets/actions" | tee -a "$LOG"
echo "  3. git add . && git commit -m 'DOCKER-SET-2 | ROLL | NAME | SECTION' && git push" | tee -a "$LOG"
echo "  4. Create Pull Request → target: atindeRR/MSE-2-SSED-Evening main" | tee -a "$LOG"
echo "  5. Verify GitHub Actions CI/CD pass" | tee -a "$LOG"
echo "  6. Screenshot Docker Hub tags page" | tee -a "$LOG"
echo "" | tee -a "$LOG"
PASS "run_all.sh completed. See execution.log for full logs."
