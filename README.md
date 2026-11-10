# FlashTicket Concert - DevOps & Load Testing Demonstration Stack

Production-ready DevOps stack built for demonstration on Ubuntu Server 24.04 (VirtualBox).
Features a high-throughput concert ticketing web service, database persistence, Prometheus & Node Exporter monitoring, Grafana visualization, and simulated heavy CPU workload for live load testing.

---

## Architecture Overview

- **Web Service (`web`)**: Python 3.12 + FastAPI + Uvicorn with `prometheus-fastapi-instrumentator==7.0.0`
- **Database (`db`)**: PostgreSQL 16 Alpine (`tickets` and `bookings` tables with atomic transaction locking)
- **Host Metrics (`node-exporter`)**: Prometheus Node Exporter v1.7.0 (CPU, Memory, Disk, Network)
- **Metrics Collector (`prometheus`)**: Prometheus v2.51.0 (2-second scrape interval for fast graph updates)
- **Metrics Visualizer (`grafana`)**: Grafana v10.4.0 (Default credentials: `admin` / `admin`)

---

## Directory Structure

```
flashticket/
├── docker-compose.yml        # Orchestration of all 5 services
├── prometheus/
│   └── prometheus.yml        # Scraper configuration (2s interval)
└── app/
    ├── Dockerfile            # Python 3.12-slim container definition
    ├── requirements.txt      # Pinned pip dependencies
    └── main.py               # FastAPI application with dark mode UI and 35k SHA-256 workload
```

---

## Quick Start on Ubuntu Server 24.04

### Step 1: Run the Automated Setup Script
Copy `setup_flashticket.sh` to your Ubuntu Server and execute:

```bash
chmod +x setup_flashticket.sh
./setup_flashticket.sh
```

The script verifies Docker and Docker Compose, installs `apache2-utils`, creates `~/flashticket`, and writes all configuration files.

### Step 2: Start the Stack

```bash
cd ~/flashticket
docker compose up -d --build
```

Verify that all 5 containers are running and healthy:

```bash
docker compose ps
```

---

## Service Endpoints

Replace `<SERVER_IP>` with your Ubuntu Server IP (obtain via `ip -br a`):

| Service | URL | Notes |
|---|---|---|
| FlashTicket Web UI | `http://<SERVER_IP>:8000` | Real-time seat counters, booking form, recent bookings table |
| Metrics Endpoint | `http://<SERVER_IP>:8000/metrics` | Prometheus metrics exported by FastAPI |
| Prometheus | `http://<SERVER_IP>:9090` | Metrics explorer & target status |
| Grafana | `http://<SERVER_IP>:3000` | Username: `admin`, Password: `admin` |
| Node Exporter | `http://<SERVER_IP>:9100/metrics` | Raw host machine metrics |

*(Note: If using VirtualBox with NAT Network, configure Port Forwarding for ports 8000, 9090, 3000, 9100, or switch network adapter to Bridged Adapter).*

---

## Load Testing & Heavy Workload Simulation

The `POST /api/book` endpoint executes 35,000 iterations of SHA-256 before writing to PostgreSQL, simulating real-world cryptographic proof and generating clear CPU spikes on Grafana.

### 1. Single Booking Test (cURL)

```bash
curl -X POST http://localhost:8000/api/book \
  -H "Content-Type: application/json" \
  -d '{"buyer_name": "Demo User", "zone": "VIP-ZONE"}'
```

### 2. Heavy Load Test (Apache Bench)

Generate 500 requests with 20 concurrent connections:

```bash
echo '{"buyer_name": "LoadTester", "zone": "VIP-ZONE"}' > /tmp/payload.json
ab -n 500 -c 20 -p /tmp/payload.json -T "application/json" http://localhost:8000/api/book
```

Stress test with 1,000 requests and 30 concurrency:

```bash
ab -n 1000 -c 30 -p /tmp/payload.json -T "application/json" http://localhost:8000/api/book
```

---

## Recommended PromQL Queries for Recording

### 1. Host CPU Busy Percentage (%)
```promql
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[30s])) * 100)
```

### 2. FastAPI Request Rate (Requests / sec)
```promql
sum(rate(http_requests_total[30s])) by (handler)
```

### 3. FastAPI p95 Latency (Seconds)
```promql
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[30s])) by (le))
```

### 4. FastAPI Request Duration Average (ms)
```promql
(sum(rate(http_request_duration_seconds_sum[30s])) / sum(rate(http_request_duration_seconds_count[30s]))) * 1000
```
