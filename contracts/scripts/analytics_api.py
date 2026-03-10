"""
analytics_api.py — FastAPI analytics REST API for the HTTPayer protocol.

Serves data from the SQLite database populated by analytics_indexer.py.

Usage:
  uv run uvicorn analytics_api:app --reload --port 8000
"""

from __future__ import annotations

import sqlite3
import subprocess
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Generator, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

DB_PATH: Path = Path(__file__).parent / "analytics.db"

app = FastAPI(title="HTTPayer Analytics API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# DB helpers
# ---------------------------------------------------------------------------


def _make_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


@contextmanager
def db() -> Generator[sqlite3.Connection, None, None]:
    conn = _make_conn()
    try:
        yield conn
    finally:
        conn.close()


def usdc(raw: int | None) -> str:
    if raw is None:
        return "0.00"
    return f"{raw / 1e6:.2f}"


def amount_pair(raw: int | None) -> dict[str, Any]:
    r = raw or 0
    return {"raw": r, "usdc": usdc(r)}


# ---------------------------------------------------------------------------
# GET /overview
# ---------------------------------------------------------------------------


@app.get("/overview")
def overview() -> dict[str, Any]:
    with db() as conn:
        provider_count = conn.execute("SELECT COUNT(*) FROM providers").fetchone()[0]
        endpoint_count = conn.execute("SELECT COUNT(*) FROM endpoints").fetchone()[0]

        staked_row = conn.execute(
            "SELECT COALESCE(SUM(amount),0) FROM stakes"
        ).fetchone()
        withdrawn_row = conn.execute(
            "SELECT COALESCE(SUM(amount),0) FROM withdrawals"
        ).fetchone()
        total_staked_raw = (staked_row[0] or 0) - (withdrawn_row[0] or 0)

        total_revenue_raw = conn.execute(
            "SELECT COALESCE(SUM(total),0) FROM distributions"
        ).fetchone()[0] or 0

        vault_tvl_raw = conn.execute(
            """
            SELECT
                COALESCE((SELECT SUM(assets) FROM vault_deposits), 0)
              + COALESCE((SELECT SUM(vault_share) FROM distributions), 0)
              - COALESCE((SELECT SUM(assets) FROM vault_withdrawals), 0)
            """
        ).fetchone()[0] or 0

        ch_total = conn.execute("SELECT COUNT(*) FROM challenges").fetchone()[0]
        ch_pending = conn.execute(
            "SELECT COUNT(*) FROM challenges WHERE status = 0"
        ).fetchone()[0]
        ch_valid = conn.execute(
            "SELECT COUNT(*) FROM challenges WHERE status = 1"
        ).fetchone()[0]
        ch_invalid = conn.execute(
            "SELECT COUNT(*) FROM challenges WHERE status = 2"
        ).fetchone()[0]
        slash_count = conn.execute("SELECT COUNT(*) FROM slashes").fetchone()[0]
        slash_rate = round(slash_count / ch_total, 4) if ch_total > 0 else 0.0

        sync_row = conn.execute(
            "SELECT MAX(last_block) FROM sync_state"
        ).fetchone()
        last_indexed_block = sync_row[0] or 0

        # Approximate last_indexed_ts from the most recent event ts
        ts_row = conn.execute(
            """
            SELECT MAX(ts) FROM (
                SELECT ts FROM providers UNION ALL
                SELECT ts FROM endpoints UNION ALL
                SELECT ts FROM distributions
            )
            """
        ).fetchone()
        last_indexed_ts = ts_row[0] or 0

    return {
        "providers": provider_count,
        "endpoints": endpoint_count,
        "total_staked_raw": total_staked_raw,
        "total_staked_usdc": usdc(total_staked_raw),
        "total_revenue_raw": total_revenue_raw,
        "total_revenue_usdc": usdc(total_revenue_raw),
        "vault_tvl_raw": vault_tvl_raw,
        "vault_tvl_usdc": usdc(vault_tvl_raw),
        "challenges": {
            "total": ch_total,
            "pending": ch_pending,
            "valid": ch_valid,
            "invalid": ch_invalid,
            "slash_rate": slash_rate,
        },
        "last_indexed_block": last_indexed_block,
        "last_indexed_ts": last_indexed_ts,
    }


# ---------------------------------------------------------------------------
# GET /providers
# ---------------------------------------------------------------------------


@app.get("/providers")
def list_providers() -> list[dict[str, Any]]:
    with db() as conn:
        rows = conn.execute(
            "SELECT id, owner, vault, splitter, revenue_share, ts FROM providers ORDER BY id"
        ).fetchall()

        result = []
        for row in rows:
            pid = row["id"]
            vault = row["vault"]
            splitter = row["splitter"]

            ep_count = conn.execute(
                "SELECT COUNT(*) FROM endpoints WHERE provider_id = ?", (pid,)
            ).fetchone()[0]

            vault_dep = conn.execute(
                "SELECT COALESCE(SUM(assets),0) FROM vault_deposits WHERE vault = ?",
                (vault,),
            ).fetchone()[0] or 0
            vault_revenue = conn.execute(
                "SELECT COALESCE(SUM(vault_share),0) FROM distributions WHERE splitter = ?",
                (splitter,),
            ).fetchone()[0] or 0
            vault_wd = conn.execute(
                "SELECT COALESCE(SUM(assets),0) FROM vault_withdrawals WHERE vault = ?",
                (vault,),
            ).fetchone()[0] or 0
            vault_tvl_raw = vault_dep + vault_revenue - vault_wd

            total_revenue_raw = conn.execute(
                "SELECT COALESCE(SUM(total),0) FROM distributions WHERE splitter = ?",
                (splitter,),
            ).fetchone()[0] or 0

            ch_count = conn.execute(
                """
                SELECT COUNT(*) FROM challenges c
                JOIN endpoints e ON c.endpoint_id = e.endpoint_id
                WHERE e.provider_id = ?
                """,
                (pid,),
            ).fetchone()[0]

            slash_count = conn.execute(
                "SELECT COUNT(*) FROM slashes WHERE provider = ?",
                (row["owner"],),
            ).fetchone()[0]

            result.append({
                "id": pid,
                "owner": row["owner"],
                "vault": vault,
                "splitter": splitter,
                "revenue_share": row["revenue_share"],
                "endpoint_count": ep_count,
                "vault_tvl_raw": vault_tvl_raw,
                "vault_tvl_usdc": usdc(vault_tvl_raw),
                "total_revenue_raw": total_revenue_raw,
                "total_revenue_usdc": usdc(total_revenue_raw),
                "challenge_count": ch_count,
                "slash_count": slash_count,
                "deployed_ts": row["ts"],
            })

    return result


# ---------------------------------------------------------------------------
# GET /providers/{id}
# ---------------------------------------------------------------------------


@app.get("/providers/{provider_id}")
def get_provider(provider_id: int) -> dict[str, Any]:
    with db() as conn:
        row = conn.execute(
            "SELECT * FROM providers WHERE id = ?", (provider_id,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Provider not found")

        provider = dict(row)

        endpoints = conn.execute(
            "SELECT * FROM endpoints WHERE provider_id = ?", (provider_id,)
        ).fetchall()
        provider["endpoints"] = [dict(e) for e in endpoints]

        # 30-day revenue timeline (daily sums)
        timeline_rows = conn.execute(
            """
            SELECT
                date(ts, 'unixepoch') AS day,
                SUM(total) AS total_raw
            FROM distributions
            WHERE provider_id = ?
              AND ts >= strftime('%s', 'now', '-30 days')
            GROUP BY day
            ORDER BY day
            """,
            (provider_id,),
        ).fetchall()
        provider["revenue_timeline_30d"] = [
            {"date": r["day"], "total_raw": r["total_raw"], "total_usdc": usdc(r["total_raw"])}
            for r in timeline_rows
        ]

    return provider


# ---------------------------------------------------------------------------
# GET /endpoints
# ---------------------------------------------------------------------------


@app.get("/endpoints")
def list_endpoints(
    provider_id: Optional[int] = Query(default=None),
) -> list[dict[str, Any]]:
    with db() as conn:
        if provider_id is not None:
            rows = conn.execute(
                "SELECT * FROM endpoints WHERE provider_id = ? ORDER BY block_number",
                (provider_id,),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM endpoints ORDER BY block_number"
            ).fetchall()

        result = []
        for row in rows:
            eid = row["endpoint_id"]

            ch_count = conn.execute(
                "SELECT COUNT(*) FROM challenges WHERE endpoint_id = ?", (eid,)
            ).fetchone()[0]

            last_status_row = conn.execute(
                """
                SELECT status FROM challenges
                WHERE endpoint_id = ?
                ORDER BY opened_block DESC
                LIMIT 1
                """,
                (eid,),
            ).fetchone()
            last_challenge_status = last_status_row[0] if last_status_row else None

            ep = dict(row)
            ep["challenge_count"] = ch_count
            ep["last_challenge_status"] = last_challenge_status
            result.append(ep)

    return result


# ---------------------------------------------------------------------------
# GET /endpoints/{endpoint_id}
# ---------------------------------------------------------------------------


@app.get("/endpoints/{endpoint_id:path}")
def get_endpoint(endpoint_id: str) -> dict[str, Any]:
    with db() as conn:
        row = conn.execute(
            "SELECT * FROM endpoints WHERE endpoint_id = ?", (endpoint_id,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Endpoint not found")

        ep = dict(row)
        challenges = conn.execute(
            "SELECT * FROM challenges WHERE endpoint_id = ? ORDER BY opened_block",
            (endpoint_id,),
        ).fetchall()
        ep["challenges"] = [dict(c) for c in challenges]

    return ep


# ---------------------------------------------------------------------------
# GET /challenges
# ---------------------------------------------------------------------------


@app.get("/challenges")
def list_challenges(
    status: Optional[str] = Query(default=None, description="pending|valid|invalid"),
    provider_id: Optional[int] = Query(default=None),
    limit: int = Query(default=50, ge=1, le=500),
) -> list[dict[str, Any]]:
    status_map = {"pending": 0, "valid": 1, "invalid": 2}

    with db() as conn:
        where_clauses: list[str] = []
        params: list[Any] = []

        if status is not None:
            s = status_map.get(status.lower())
            if s is None:
                raise HTTPException(status_code=400, detail="status must be pending, valid, or invalid")
            where_clauses.append("c.status = ?")
            params.append(s)

        if provider_id is not None:
            where_clauses.append("e.provider_id = ?")
            params.append(provider_id)

        where_sql = ("WHERE " + " AND ".join(where_clauses)) if where_clauses else ""

        rows = conn.execute(
            f"""
            SELECT c.*, e.provider_id, e.path AS ep_path
            FROM challenges c
            LEFT JOIN endpoints e ON c.endpoint_id = e.endpoint_id
            {where_sql}
            ORDER BY c.opened_block DESC
            LIMIT ?
            """,
            params + [limit],
        ).fetchall()

        result = []
        for row in rows:
            ch = dict(row)
            if ch.get("resolved_ts") and ch.get("opened_ts"):
                ch["resolution_time_seconds"] = ch["resolved_ts"] - ch["opened_ts"]
            else:
                ch["resolution_time_seconds"] = None
            result.append(ch)

    return result


# ---------------------------------------------------------------------------
# GET /staking
# ---------------------------------------------------------------------------


@app.get("/staking")
def staking_summary() -> dict[str, Any]:
    with db() as conn:
        total_staked_raw = conn.execute(
            "SELECT COALESCE(SUM(amount),0) FROM stakes"
        ).fetchone()[0] or 0
        total_withdrawn_raw = conn.execute(
            "SELECT COALESCE(SUM(amount),0) FROM withdrawals"
        ).fetchone()[0] or 0
        net_staked_raw = total_staked_raw - total_withdrawn_raw

        total_slashed_raw = conn.execute(
            "SELECT COALESCE(SUM(slash_amount),0) FROM slashes"
        ).fetchone()[0] or 0

        # Per-staker aggregates
        staker_rows = conn.execute(
            """
            SELECT
                address,
                COALESCE(SUM(amount), 0) AS staked
            FROM stakes
            GROUP BY address
            """
        ).fetchall()

        stakers = []
        for sr in staker_rows:
            addr = sr["address"]
            staked = sr["staked"] or 0

            wd = conn.execute(
                "SELECT COALESCE(SUM(amount),0) FROM withdrawals WHERE address = ?",
                (addr,),
            ).fetchone()[0] or 0
            net = staked - wd

            slash_count = conn.execute(
                "SELECT COUNT(*) FROM slashes WHERE provider = ?", (addr,)
            ).fetchone()[0]
            slashed_raw = conn.execute(
                "SELECT COALESCE(SUM(slash_amount),0) FROM slashes WHERE provider = ?",
                (addr,),
            ).fetchone()[0] or 0

            stakers.append({
                "address": addr,
                "net_staked_raw": net,
                "net_staked_usdc": usdc(net),
                "slash_count": slash_count,
                "slashed_raw": slashed_raw,
                "slashed_usdc": usdc(slashed_raw),
            })

    return {
        "total_staked_raw": net_staked_raw,
        "total_staked_usdc": usdc(net_staked_raw),
        "total_slashed_raw": total_slashed_raw,
        "total_slashed_usdc": usdc(total_slashed_raw),
        "stakers": stakers,
    }


# ---------------------------------------------------------------------------
# GET /revenue
# ---------------------------------------------------------------------------


@app.get("/revenue")
def revenue_summary(
    provider_id: Optional[int] = Query(default=None),
    days: int = Query(default=30, ge=1, le=365),
) -> dict[str, Any]:
    with db() as conn:
        where_clauses: list[str] = [
            f"ts >= strftime('%s', 'now', '-{days} days')"
        ]
        params: list[Any] = []

        if provider_id is not None:
            where_clauses.append("provider_id = ?")
            params.append(provider_id)

        where_sql = "WHERE " + " AND ".join(where_clauses)

        total_raw = conn.execute(
            f"SELECT COALESCE(SUM(total),0) FROM distributions {where_sql}",
            params,
        ).fetchone()[0] or 0

        by_provider_rows = conn.execute(
            f"""
            SELECT
                provider_id,
                SUM(total) AS total_raw,
                SUM(protocol_share) AS protocol_share,
                SUM(vault_share) AS vault_share,
                SUM(rev_share_share) AS rev_share,
                SUM(provider_share) AS provider_direct
            FROM distributions
            {where_sql}
            GROUP BY provider_id
            ORDER BY total_raw DESC
            """,
            params,
        ).fetchall()

        by_provider = [
            {
                "provider_id": r["provider_id"],
                "total_raw": r["total_raw"] or 0,
                "total_usdc": usdc(r["total_raw"]),
                "protocol_share": r["protocol_share"] or 0,
                "vault_share": r["vault_share"] or 0,
                "rev_share": r["rev_share"] or 0,
                "provider_direct": r["provider_direct"] or 0,
            }
            for r in by_provider_rows
        ]

        timeline_rows = conn.execute(
            f"""
            SELECT
                date(ts, 'unixepoch') AS day,
                SUM(total) AS total_raw
            FROM distributions
            {where_sql}
            GROUP BY day
            ORDER BY day
            """,
            params,
        ).fetchall()

        timeline = [
            {"date": r["day"], "total_raw": r["total_raw"] or 0, "total_usdc": usdc(r["total_raw"])}
            for r in timeline_rows
        ]

    return {
        "total_raw": total_raw,
        "total_usdc": usdc(total_raw),
        "by_provider": by_provider,
        "timeline": timeline,
    }


# ---------------------------------------------------------------------------
# GET /vault/{vault_address}
# ---------------------------------------------------------------------------


@app.get("/vault/{vault_address}")
def vault_detail(vault_address: str) -> dict[str, Any]:
    with db() as conn:
        provider_row = conn.execute(
            "SELECT id, splitter FROM providers WHERE LOWER(vault) = LOWER(?)", (vault_address,)
        ).fetchone()
        provider_id = provider_row["id"] if provider_row else None
        splitter_address = provider_row["splitter"] if provider_row else None

        dep_row = conn.execute(
            """
            SELECT
                COALESCE(SUM(assets),0) AS total_deposited,
                COUNT(*) AS deposit_count
            FROM vault_deposits WHERE LOWER(vault) = LOWER(?)
            """,
            (vault_address,),
        ).fetchone()

        wd_row = conn.execute(
            """
            SELECT
                COALESCE(SUM(assets),0) AS total_withdrawn,
                COUNT(*) AS withdraw_count
            FROM vault_withdrawals WHERE LOWER(vault) = LOWER(?)
            """,
            (vault_address,),
        ).fetchone()

        revenue_raw = 0
        if splitter_address:
            revenue_row = conn.execute(
                "SELECT COALESCE(SUM(vault_share),0) FROM distributions WHERE LOWER(splitter) = LOWER(?)",
                (splitter_address,),
            ).fetchone()
            revenue_raw = revenue_row[0] or 0

        total_deposited = dep_row["total_deposited"] or 0
        total_withdrawn = wd_row["total_withdrawn"] or 0
        tvl_raw = total_deposited + revenue_raw - total_withdrawn

    return {
        "vault": vault_address,
        "provider_id": provider_id,
        "tvl_raw": tvl_raw,
        "tvl_usdc": usdc(tvl_raw),
        "total_deposited": total_deposited,
        "total_withdrawn": total_withdrawn,
        "revenue_inflow_raw": revenue_raw,
        "revenue_inflow_usdc": usdc(revenue_raw),
        "deposit_count": dep_row["deposit_count"] or 0,
        "withdraw_count": wd_row["withdraw_count"] or 0,
    }


# ---------------------------------------------------------------------------
# GET /sync/status
# ---------------------------------------------------------------------------


@app.get("/sync/status")
def sync_status() -> dict[str, Any]:
    with db() as conn:
        rows = conn.execute("SELECT key, last_block, events_indexed FROM sync_state").fetchall()
        contracts = {r["key"]: {"last_block": r["last_block"], "events_indexed": r["events_indexed"]} for r in rows}
        last_block = max((r["last_block"] for r in rows), default=0) if rows else 0

    return {
        "contracts": contracts,
        "last_indexed_block": last_block,
    }


# ---------------------------------------------------------------------------
# POST /sync
# ---------------------------------------------------------------------------


@app.post("/sync")
def trigger_sync() -> dict[str, Any]:
    try:
        result = subprocess.run(
            ["uv", "run", "python", "analytics_indexer.py", "--once"],
            capture_output=True,
            timeout=120,
            cwd=str(Path(__file__).parent),
        )
        stdout = (result.stdout or b"").decode("utf-8", errors="replace")
        stderr = (result.stderr or b"").decode("utf-8", errors="replace")
        output = (stdout + stderr).strip()
        if result.returncode == 0:
            return {"status": "ok", "message": output}
        else:
            return {"status": "error", "message": output}
    except subprocess.TimeoutExpired:
        return {"status": "error", "message": "Sync timed out after 120s"}
    except Exception as exc:
        return {"status": "error", "message": str(exc)}
