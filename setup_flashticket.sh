#!/usr/bin/env bash
# ==============================================================================
# FlashTicket Concert - Automated Setup Script for Ubuntu Server 24.04
# Description: Deploys FastAPI, PostgreSQL 16, Prometheus, Node Exporter, and Grafana
# Note: Strictly zero emojis across script, logs, and output.
# ==============================================================================

set -euo pipefail

TARGET_DIR="${HOME}/flashticket"

echo "================================================================================"
echo " FlashTicket Concert - DevOps Demonstration Environment Setup"
echo " Target Directory: ${TARGET_DIR}"
echo "================================================================================"

# ------------------------------------------------------------------------------
# 1. Docker and Docker Compose Verification
# ------------------------------------------------------------------------------
echo "[1/4] Checking Docker environment..."

if ! command -v docker >/dev/null 2>&1; then
    echo "[!] Docker is not installed."
    echo "    Installing Docker automatically using official Docker repository..."
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin apache2-utils
    sudo usermod -aG docker "$USER" || true
    echo "[OK] Docker and Docker Compose plugin installed."
else
    echo "[OK] Docker is installed: $(docker --version)"
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "[!] Docker Compose plugin not found. Installing docker-compose-plugin..."
    sudo apt-get update -y && sudo apt-get install -y docker-compose-plugin apache2-utils
    echo "[OK] Docker Compose plugin installed."
else
    echo "[OK] Docker Compose is available: $(docker compose version)"
fi

# Ensure apache2-utils is installed for ab (Apache Bench)
if ! command -v ab >/dev/null 2>&1; then
    echo "[*] Installing apache2-utils for Apache Bench (ab) load testing tool..."
    sudo apt-get update -y && sudo apt-get install -y apache2-utils curl
    echo "[OK] apache2-utils installed."
fi

# ------------------------------------------------------------------------------
# 2. Directory Structure Creation
# ------------------------------------------------------------------------------
echo "[2/4] Creating project directory structure at ${TARGET_DIR}..."
mkdir -p "${TARGET_DIR}/app"
mkdir -p "${TARGET_DIR}/prometheus"

# ------------------------------------------------------------------------------
# 3. File Generation
# ------------------------------------------------------------------------------
echo "[3/4] Generating deployment files and application source..."

# 3.1 app/requirements.txt
cat <<'EOF' > "${TARGET_DIR}/app/requirements.txt"
fastapi==0.110.0
uvicorn[standard]==0.29.0
prometheus-fastapi-instrumentator==7.0.0
psycopg2-binary==2.9.9
pydantic==2.6.4
EOF

# 3.2 app/Dockerfile
cat <<'EOF' > "${TARGET_DIR}/app/Dockerfile"
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# 3.3 app/main.py
cat <<'EOF' > "${TARGET_DIR}/app/main.py"
import hashlib
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, status
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel
import psycopg2
from psycopg2 import pool, extras
from prometheus_fastapi_instrumentator import Instrumentator

# Logging configuration (No emojis allowed)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("flashticket")

# Database configuration
DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "flashticket_db")
DB_USER = os.getenv("DB_USER", "flashticket")
DB_PASSWORD = os.getenv("DB_PASSWORD", "flashticket_secure_pass")

db_pool: Optional[pool.ThreadedConnectionPool] = None


def init_db_pool(max_retries: int = 15, delay: int = 2) -> pool.ThreadedConnectionPool:
    """Initialize connection pool with retry mechanism for container startup."""
    global db_pool
    for attempt in range(1, max_retries + 1):
        try:
            logger.info("Connecting to PostgreSQL at %s:%s (attempt %d/%d)...", DB_HOST, DB_PORT, attempt, max_retries)
            p = pool.ThreadedConnectionPool(
                minconn=2,
                maxconn=30,
                host=DB_HOST,
                port=DB_PORT,
                dbname=DB_NAME,
                user=DB_USER,
                password=DB_PASSWORD,
                connect_timeout=5
            )
            logger.info("Database connection pool established successfully.")
            return p
        except Exception as exc:
            logger.warning("Database not ready yet (%s). Retrying in %ds...", exc, delay)
            time.sleep(delay)
    raise RuntimeError(f"Could not connect to PostgreSQL after {max_retries} attempts.")


def setup_database_schema(p: pool.ThreadedConnectionPool):
    """Create tickets and bookings tables and seed initial inventory."""
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            # Create tickets table
            cur.execute("""
                CREATE TABLE IF NOT EXISTS tickets (
                    zone VARCHAR(50) PRIMARY KEY,
                    total_seats INT NOT NULL,
                    available_seats INT NOT NULL
                );
            """)

            # Seed initial tickets (10,000 seats for VIP-ZONE)
            cur.execute("""
                INSERT INTO tickets (zone, total_seats, available_seats)
                VALUES ('VIP-ZONE', 10000, 10000)
                ON CONFLICT (zone) DO NOTHING;
            """)

            # Create bookings table
            cur.execute("""
                CREATE TABLE IF NOT EXISTS bookings (
                    id SERIAL PRIMARY KEY,
                    zone VARCHAR(50) NOT NULL,
                    buyer_name VARCHAR(100) NOT NULL,
                    tx_hash VARCHAR(64) NOT NULL,
                    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
                );
            """)
            conn.commit()
            logger.info("Database tables verified and seeded.")
    except Exception as exc:
        conn.rollback()
        logger.error("Failed to initialize database schema: %s", exc)
        raise
    finally:
        p.putconn(conn)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global db_pool
    db_pool = init_db_pool()
    setup_database_schema(db_pool)
    yield
    if db_pool:
        db_pool.closeall()
        logger.info("Database connection pool closed.")


app = FastAPI(
    title="FlashTicket Concert API",
    description="High-performance ticketing service with Prometheus metrics",
    version="1.0.0",
    lifespan=lifespan
)

# Prometheus instrumentation on /metrics
Instrumentator().instrument(app).expose(app, endpoint="/metrics")


class BookingRequest(BaseModel):
    buyer_name: str = "Concert Attendee"
    zone: str = "VIP-ZONE"


def get_db():
    if not db_pool:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Database pool not initialized"
        )
    conn = db_pool.getconn()
    try:
        return conn
    except Exception as exc:
        db_pool.putconn(conn)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Connection pool error: {str(exc)}"
        )


@app.get("/api/status")
def get_status():
    """Return available ticket count and latest 5 bookings."""
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=extras.DictCursor) as cur:
            cur.execute("SELECT zone, total_seats, available_seats FROM tickets WHERE zone = %s;", ("VIP-ZONE",))
            ticket_row = cur.fetchone()

            cur.execute("""
                SELECT id, zone, buyer_name, tx_hash, created_at
                FROM bookings
                ORDER BY id DESC
                LIMIT 5;
            """)
            recent_rows = cur.fetchall()

            total = ticket_row["total_seats"] if ticket_row else 10000
            available = ticket_row["available_seats"] if ticket_row else 0
            booked = total - available

            recent_bookings = [
                {
                    "id": row["id"],
                    "zone": row["zone"],
                    "buyer_name": row["buyer_name"],
                    "tx_hash": row["tx_hash"],
                    "created_at": row["created_at"].strftime("%Y-%m-%d %H:%M:%S")
                }
                for row in recent_rows
            ]

            return {
                "status": "healthy",
                "zone": ticket_row["zone"] if ticket_row else "VIP-ZONE",
                "total_seats": total,
                "available_seats": available,
                "booked_seats": booked,
                "recent_bookings": recent_bookings
            }
    finally:
        db_pool.putconn(conn)


@app.post("/api/book")
def book_ticket(req: BookingRequest):
    """
    Handle ticket reservation with simulated CPU-heavy workload.
    1. Computes 35,000 SHA-256 rounds to simulate cryptographic proof & generate CPU spike.
    2. Atomically decrements ticket count and inserts reservation record in PostgreSQL.
    """
    # 1. Heavy Workload: 35,000 SHA-256 iterations to generate CPU load
    seed = f"{req.buyer_name}:{req.zone}:{time.time_ns()}".encode("utf-8")
    payload = seed
    for _ in range(35000):
        payload = hashlib.sha256(payload).digest()
    tx_hash = payload.hex()

    # 2. Database atomic update & booking insertion
    conn = get_db()
    try:
        with conn.cursor(cursor_factory=extras.DictCursor) as cur:
            # Atomic update returning remaining seats (prevents race conditions)
            cur.execute("""
                UPDATE tickets
                SET available_seats = available_seats - 1
                WHERE zone = %s AND available_seats > 0
                RETURNING available_seats;
            """, (req.zone,))
            row = cur.fetchone()

            if not row:
                conn.rollback()
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="Tickets sold out or zone unavailable"
                )

            remaining_seats = row["available_seats"]

            # Record the successful booking
            cur.execute("""
                INSERT INTO bookings (zone, buyer_name, tx_hash)
                VALUES (%s, %s, %s)
                RETURNING id, created_at;
            """, (req.zone, req.buyer_name, tx_hash))
            booking_row = cur.fetchone()

            conn.commit()

            return {
                "status": "success",
                "message": "Ticket reservation confirmed",
                "booking_id": booking_row["id"],
                "zone": req.zone,
                "buyer_name": req.buyer_name,
                "remaining_seats": remaining_seats,
                "tx_hash": tx_hash,
                "created_at": booking_row["created_at"].isoformat()
            }
    except HTTPException:
        raise
    except Exception as exc:
        conn.rollback()
        logger.error("Booking transaction failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Booking error: {str(exc)}"
        )
    finally:
        db_pool.putconn(conn)


@app.get("/", response_class=HTMLResponse)
def index_page():
    """Dark Mode Concert Ticketing Interface with Real-time Updates (Strictly No Emojis)."""
    return """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>FlashTicket Concert - Live Booking & Monitoring</title>
  <style>
    :root {
      --bg-main: #0a0e17;
      --bg-card: #111827;
      --bg-card-hover: #1f2937;
      --border-color: #2d3748;
      --primary: #00d2ff;
      --primary-glow: rgba(0, 210, 255, 0.25);
      --secondary: #9d4edd;
      --accent-green: #10b981;
      --accent-red: #ef4444;
      --text-main: #f9fafb;
      --text-muted: #9ca3af;
    }

    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
    }

    body {
      background-color: var(--bg-main);
      color: var(--text-main);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 24px 16px;
      background-image: 
        radial-gradient(circle at 15% 15%, rgba(157, 78, 221, 0.12) 0%, transparent 40%),
        radial-gradient(circle at 85% 20%, rgba(0, 210, 255, 0.12) 0%, transparent 40%);
    }

    .container {
      width: 100%;
      max-width: 1080px;
    }

    /* Header */
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-bottom: 24px;
      border-bottom: 1px solid var(--border-color);
      margin-bottom: 32px;
      flex-wrap: wrap;
      gap: 16px;
    }

    .logo-area {
      display: flex;
      align-items: center;
      gap: 14px;
    }

    .logo-icon {
      width: 44px;
      height: 44px;
      background: linear-gradient(135deg, var(--primary), var(--secondary));
      border-radius: 10px;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 0 16px var(--primary-glow);
    }

    .logo-icon svg {
      width: 24px;
      height: 24px;
      fill: none;
      stroke: #0a0e17;
      stroke-width: 2;
    }

    .title-group h1 {
      font-size: 26px;
      font-weight: 700;
      letter-spacing: -0.5px;
      background: linear-gradient(90deg, #ffffff, var(--primary));
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
    }

    .title-group p {
      font-size: 13px;
      color: var(--text-muted);
    }

    .badge-status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 14px;
      border-radius: 20px;
      background: rgba(16, 185, 129, 0.1);
      border: 1px solid rgba(16, 185, 129, 0.3);
      font-size: 12px;
      font-weight: 600;
      color: var(--accent-green);
    }

    .dot {
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background-color: var(--accent-green);
      box-shadow: 0 0 8px var(--accent-green);
    }

    /* Grid Layout */
    .dashboard-grid {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 24px;
      margin-bottom: 32px;
    }

    @media (max-width: 768px) {
      .dashboard-grid {
        grid-template-columns: 1fr;
      }
    }

    .card {
      background: var(--bg-card);
      border: 1px solid var(--border-color);
      border-radius: 12px;
      padding: 24px;
      position: relative;
      overflow: hidden;
    }

    .card-title {
      font-size: 14px;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: var(--text-muted);
      margin-bottom: 12px;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .card-title svg {
      width: 16px;
      height: 16px;
      stroke: var(--primary);
      stroke-width: 2;
      fill: none;
    }

    /* Ticket Counters */
    .stat-number {
      font-size: 44px;
      font-weight: 800;
      color: #ffffff;
      line-height: 1;
      margin-bottom: 8px;
      font-variant-numeric: tabular-nums;
    }

    .stat-sub {
      font-size: 13px;
      color: var(--text-muted);
      margin-bottom: 16px;
    }

    .progress-bar-bg {
      width: 100%;
      height: 8px;
      background: #1f2937;
      border-radius: 4px;
      overflow: hidden;
      margin-bottom: 8px;
    }

    .progress-bar-fill {
      height: 100%;
      background: linear-gradient(90deg, var(--secondary), var(--primary));
      width: 0%;
      transition: width 0.4s ease;
    }

    /* Booking Form */
    .form-group {
      margin-bottom: 18px;
    }

    label {
      display: block;
      font-size: 13px;
      font-weight: 500;
      color: var(--text-muted);
      margin-bottom: 6px;
    }

    input, select {
      width: 100%;
      padding: 12px 14px;
      border-radius: 8px;
      background: #1a2234;
      border: 1px solid var(--border-color);
      color: #fff;
      font-size: 14px;
      outline: none;
      transition: border-color 0.2s, box-shadow 0.2s;
    }

    input:focus, select:focus {
      border-color: var(--primary);
      box-shadow: 0 0 0 2px var(--primary-glow);
    }

    .btn-book {
      width: 100%;
      padding: 14px;
      background: linear-gradient(90deg, #00d2ff, #7928ca);
      border: none;
      border-radius: 8px;
      color: #ffffff;
      font-size: 15px;
      font-weight: 700;
      letter-spacing: 0.5px;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      transition: transform 0.15s ease, box-shadow 0.15s ease;
    }

    .btn-book:hover {
      box-shadow: 0 0 20px rgba(0, 210, 255, 0.4);
    }

    .btn-book:active {
      transform: scale(0.98);
    }

    .btn-book:disabled {
      opacity: 0.6;
      cursor: not-allowed;
    }

    .btn-book svg {
      width: 18px;
      height: 18px;
      stroke: #fff;
      stroke-width: 2.2;
      fill: none;
    }

    /* Notification Box */
    .alert-box {
      margin-top: 16px;
      padding: 12px 14px;
      border-radius: 8px;
      font-size: 12px;
      line-height: 1.5;
      display: none;
      word-break: break-all;
    }

    .alert-box.success {
      display: block;
      background: rgba(16, 185, 129, 0.12);
      border: 1px solid rgba(16, 185, 129, 0.3);
      color: #a7f3d0;
    }

    .alert-box.error {
      display: block;
      background: rgba(239, 68, 68, 0.12);
      border: 1px solid rgba(239, 68, 68, 0.3);
      color: #fca5a5;
    }

    /* Bookings Table */
    .table-container {
      margin-top: 8px;
      overflow-x: auto;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      text-align: left;
      font-size: 13px;
    }

    th {
      padding: 10px 14px;
      color: var(--text-muted);
      font-weight: 600;
      border-bottom: 1px solid var(--border-color);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }

    td {
      padding: 12px 14px;
      border-bottom: 1px solid #1e293b;
      color: #e2e8f0;
    }

    tr:hover td {
      background: var(--bg-card-hover);
    }

    .tx-code {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      color: var(--primary);
      font-size: 12px;
      background: rgba(0, 210, 255, 0.08);
      padding: 2px 6px;
      border-radius: 4px;
    }

    /* Quick Links Bar */
    .links-bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-top: 24px;
      padding: 14px 20px;
      background: #0d1321;
      border: 1px solid var(--border-color);
      border-radius: 8px;
      font-size: 13px;
      color: var(--text-muted);
      flex-wrap: wrap;
      gap: 12px;
    }

    .nav-links {
      display: flex;
      gap: 16px;
    }

    .nav-links a {
      color: var(--primary);
      text-decoration: none;
      font-weight: 600;
      display: inline-flex;
      align-items: center;
      gap: 6px;
    }

    .nav-links a:hover {
      text-decoration: underline;
    }

    .nav-links svg {
      width: 14px;
      height: 14px;
      stroke: currentColor;
      stroke-width: 2;
      fill: none;
    }
  </style>
</head>
<body>
  <div class="container">
    <!-- Header -->
    <header>
      <div class="logo-area">
        <div class="logo-icon">
          <svg viewBox="0 0 24 24">
            <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>
          </svg>
        </div>
        <div class="title-group">
          <h1>FlashTicket Concert 2026</h1>
          <p>DevOps Live Demonstration System | Web Service &bull; PostgreSQL &bull; Prometheus &bull; Grafana</p>
        </div>
      </div>
      <div class="badge-status">
        <span class="dot"></span>
        <span>SERVICES OPERATIONAL</span>
      </div>
    </header>

    <!-- Main Grid -->
    <div class="dashboard-grid">
      <!-- Seat Availability Card -->
      <div class="card">
        <div class="card-title">
          <svg viewBox="0 0 24 24">
            <rect x="2" y="7" width="20" height="14" rx="2" ry="2"></rect>
            <path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"></path>
          </svg>
          Ticket Inventory Status
        </div>
        <div class="stat-number" id="available-count">10,000</div>
        <div class="stat-sub">Available seats remaining out of 10,000 in <strong id="zone-display">VIP-ZONE</strong></div>
        <div class="progress-bar-bg">
          <div class="progress-bar-fill" id="progress-fill"></div>
        </div>
        <div style="display: flex; justify-content: space-between; font-size: 12px; color: var(--text-muted); margin-top: 6px;">
          <span>Booked: <strong id="booked-count" style="color: #fff;">0</strong></span>
          <span id="pct-display">0% Sold</span>
        </div>
      </div>

      <!-- Instant Booking Card -->
      <div class="card">
        <div class="card-title">
          <svg viewBox="0 0 24 24">
            <path d="M16 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
            <circle cx="8.5" cy="7" r="4"></circle>
            <line x1="20" y1="8" x2="20" y2="14"></line>
            <line x1="23" y1="11" x2="17" y2="11"></line>
          </svg>
          Instant Ticket Booking (Heavy Load Simulator)
        </div>
        <form id="book-form" onsubmit="handleBooking(event)">
          <div class="form-group">
            <label for="buyer_name">Buyer Name</label>
            <input type="text" id="buyer_name" value="Demo Attendee" required>
          </div>
          <div class="form-group">
            <label for="zone">Ticket Zone</label>
            <select id="zone">
              <option value="VIP-ZONE">VIP-ZONE (Front Stage Premium)</option>
            </select>
          </div>
          <button type="submit" class="btn-book" id="btn-submit">
            <svg viewBox="0 0 24 24">
              <polyline points="20 6 9 17 4 12"></polyline>
            </svg>
            Confirm Reservation (SHA-256 x 35,000)
          </button>
        </form>
        <div id="booking-alert" class="alert-box"></div>
      </div>
    </div>

    <!-- Recent Bookings Table Card -->
    <div class="card">
      <div class="card-title">
        <svg viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10"></circle>
          <polyline points="12 6 12 12 16 14"></polyline>
        </svg>
        Latest 5 Successful Bookings (PostgreSQL Transaction Log)
      </div>
      <div class="table-container">
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Buyer Name</th>
              <th>Zone</th>
              <th>Transaction Security Hash (SHA-256)</th>
              <th>Timestamp</th>
            </tr>
          </thead>
          <tbody id="bookings-tbody">
            <tr>
              <td colspan="5" style="text-align: center; color: var(--text-muted); padding: 24px;">No reservations recorded yet. Ready for load testing.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <!-- Links Bar -->
    <div class="links-bar">
      <span>Monitoring Endpoints:</span>
      <div class="nav-links">
        <a href="/metrics" target="_blank">
          <svg viewBox="0 0 24 24"><line x1="18" y1="20" x2="18" y2="10"></line><line x1="12" y1="20" x2="12" y2="4"></line><line x1="6" y1="20" x2="6" y2="14"></line></svg>
          /metrics (Prometheus)
        </a>
        <a href="http://localhost:9090" target="_blank">
          <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
          Prometheus Dashboard (9090)
        </a>
        <a href="http://localhost:3000" target="_blank">
          <svg viewBox="0 0 24 24"><polygon points="12 2 2 7 12 12 22 7 12 2"></polygon><polyline points="2 17 12 22 22 17"></polyline><polyline points="2 12 12 17 22 12"></polyline></svg>
          Grafana (3000)
        </a>
      </div>
    </div>
  </div>

  <script>
    async function fetchStatus() {
      try {
        const res = await fetch('/api/status');
        if (!res.ok) return;
        const data = await res.json();
        
        document.getElementById('available-count').textContent = data.available_seats.toLocaleString();
        document.getElementById('booked-count').textContent = data.booked_seats.toLocaleString();
        document.getElementById('zone-display').textContent = data.zone;

        const pct = ((data.booked_seats / data.total_seats) * 100).toFixed(1);
        document.getElementById('progress-fill').style.width = pct + '%';
        document.getElementById('pct-display').textContent = pct + '% Sold';

        const tbody = document.getElementById('bookings-tbody');
        if (data.recent_bookings && data.recent_bookings.length > 0) {
          tbody.innerHTML = data.recent_bookings.map(b => `
            <tr>
              <td>#${b.id}</td>
              <td><strong>${escapeHtml(b.buyer_name)}</strong></td>
              <td><span style="color: var(--text-muted);">${b.zone}</span></td>
              <td><span class="tx-code">${b.tx_hash.substring(0, 16)}...${b.tx_hash.substring(48)}</span></td>
              <td style="color: var(--text-muted);">${b.created_at}</td>
            </tr>
          `).join('');
        }
      } catch (err) {
        console.error('Failed to update status', err);
      }
    }

    async function handleBooking(e) {
      e.preventDefault();
      const btn = document.getElementById('btn-submit');
      const alertBox = document.getElementById('booking-alert');
      const buyerName = document.getElementById('buyer_name').value.trim() || 'Demo Attendee';
      const zone = document.getElementById('zone').value;

      btn.disabled = true;
      btn.innerHTML = 'Computing Proof & Reserving...';
      alertBox.className = 'alert-box';
      alertBox.style.display = 'none';

      try {
        const startTime = performance.now();
        const res = await fetch('/api/book', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ buyer_name: buyerName, zone: zone })
        });
        const elapsed = (performance.now() - startTime).toFixed(1);
        const data = await res.json();

        if (res.ok) {
          alertBox.className = 'alert-box success';
          alertBox.innerHTML = `<strong>Booking Confirmed (#${data.booking_id})</strong><br>Transaction: ${data.tx_hash}<br>Remaining: ${data.remaining_seats} seats | Compute time: ${elapsed}ms`;
          fetchStatus();
        } else {
          alertBox.className = 'alert-box error';
          alertBox.innerHTML = `<strong>Reservation Failed:</strong> ${data.detail || 'Unknown error'}`;
        }
      } catch (err) {
        alertBox.className = 'alert-box error';
        alertBox.innerHTML = `<strong>Network Error:</strong> ${err.message}`;
      } finally {
        btn.disabled = false;
        btn.innerHTML = `<svg viewBox="0 0 24 24"><polyline points="20 6 9 17 4 12"></polyline></svg> Confirm Reservation (SHA-256 x 35,000)`;
      }
    }

    function escapeHtml(str) {
      return str.replace(/[&<>'"]/g, tag => ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        "'": '&#39;',
        '"': '&quot;'
      }[tag] || tag));
    }

    // Poll status every 2.5 seconds
    fetchStatus();
    setInterval(fetchStatus, 2500);
  </script>
</body>
</html>
"""
EOF

# 3.4 prometheus/prometheus.yml
cat <<'EOF' > "${TARGET_DIR}/prometheus/prometheus.yml"
global:
  scrape_interval: 2s
  evaluation_interval: 2s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node-exporter"
    static_configs:
      - targets: ["node-exporter:9100"]

  - job_name: "web-fastapi"
    metrics_path: "/metrics"
    static_configs:
      - targets: ["web:8000"]
EOF

# 3.5 docker-compose.yml
cat <<'EOF' > "${TARGET_DIR}/docker-compose.yml"
version: "3.8"

services:
  db:
    image: postgres:16-alpine
    container_name: flashticket-db
    restart: always
    environment:
      POSTGRES_USER: flashticket
      POSTGRES_PASSWORD: flashticket_secure_pass
      POSTGRES_DB: flashticket_db
    ports:
      - "5432:5432"
    volumes:
      - flashticket_db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U flashticket -d flashticket_db"]
      interval: 3s
      timeout: 3s
      retries: 10
    networks:
      - flashticket-net

  web:
    build:
      context: ./app
      dockerfile: Dockerfile
    container_name: flashticket-web
    restart: always
    environment:
      DB_HOST: db
      DB_PORT: 5432
      DB_NAME: flashticket_db
      DB_USER: flashticket
      DB_PASSWORD: flashticket_secure_pass
    ports:
      - "8000:8000"
    depends_on:
      db:
        condition: service_healthy
    networks:
      - flashticket-net

  node-exporter:
    image: prom/node-exporter:v1.7.0
    container_name: flashticket-node-exporter
    restart: always
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    networks:
      - flashticket-net

  prometheus:
    image: prom/prometheus:v2.51.0
    container_name: flashticket-prometheus
    restart: always
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - flashticket_prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
    depends_on:
      - web
      - node-exporter
    networks:
      - flashticket-net

  grafana:
    image: grafana/grafana:10.4.0
    container_name: flashticket-grafana
    restart: always
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - flashticket_grafana_data:/var/lib/grafana
    depends_on:
      - prometheus
    networks:
      - flashticket-net

networks:
  flashticket-net:
    driver: bridge

volumes:
  flashticket_db_data:
  flashticket_prometheus_data:
  flashticket_grafana_data:
EOF

# ------------------------------------------------------------------------------
# 4. Final Instructions and Commands
# ------------------------------------------------------------------------------
echo "[4/4] Installation and configuration completed successfully!"
echo ""
echo "================================================================================"
echo " FlashTicket Concert Deployment Instructions"
echo "================================================================================"
echo ""
echo "1. Navigate to the project directory:"
echo "   cd ${TARGET_DIR}"
echo ""
echo "2. Build and launch all services in background:"
echo "   docker compose up -d --build"
echo ""
echo "3. Verify running containers:"
echo "   docker compose ps"
echo ""
echo "4. Access the web dashboards (replace <SERVER_IP> with Ubuntu IP, e.g., 192.168.x.x):"
echo "   - FlashTicket Web Service UI : http://<SERVER_IP>:8000"
echo "   - Prometheus Scraper & Query : http://<SERVER_IP>:9090"
echo "   - Grafana Dashboard          : http://<SERVER_IP>:3000 (User: admin / Pass: admin)"
echo "   - FastAPI Prometheus Metrics : http://<SERVER_IP>:8000/metrics"
echo ""
echo "5. Test single booking via curl:"
echo '   curl -s -X POST http://localhost:8000/api/book \'
echo '     -H "Content-Type: application/json" \'
echo '     -d "{\"buyer_name\": \"Demo User\", \"zone\": \"VIP-ZONE\"}" | jq .'
echo ""
echo "6. Run Heavy Workload Load Testing via Apache Bench (ab):"
echo '   # Prepare payload file'
echo '   echo '\''{"buyer_name": "LoadTester", "zone": "VIP-ZONE"}'\'' > /tmp/book_load.json'
echo ''
echo '   # Execute 500 requests with 20 concurrency (will create noticeable CPU spike on Grafana):'
echo '   ab -n 500 -c 20 -p /tmp/book_load.json -T "application/json" http://localhost:8000/api/book'
echo ''
echo '   # Execute 1000 requests with 30 concurrency:'
echo '   ab -n 1000 -c 30 -p /tmp/book_load.json -T "application/json" http://localhost:8000/api/book'
echo ""
echo "7. Recommended PromQL Queries for Demonstration Video (Grafana / Prometheus):"
echo '   - Host CPU Busy Rate (%):'
echo '     100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[30s])) * 100)'
echo ''
echo '   - FastAPI HTTP Request Rate (RPS):'
echo '     sum(rate(http_requests_total[30s])) by (handler)'
echo ''
echo '   - FastAPI p95 Latency (Seconds):'
echo '     histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[30s])) by (le))'
echo ""
echo "================================================================================"
