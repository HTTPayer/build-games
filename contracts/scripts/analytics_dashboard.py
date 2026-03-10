"""
analytics_dashboard.py — Streamlit analytics dashboard for the HTTPayer protocol.

Usage:
  uv run streamlit run analytics_dashboard.py
"""

from __future__ import annotations

import os
from datetime import datetime
from typing import Any, Optional

import plotly.express as px
import requests
import streamlit as st

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

API_BASE: str = os.getenv("ANALYTICS_API_URL", "http://localhost:8000")

st.set_page_config(
    page_title="HTTPayer Analytics",
    page_icon="📡",
    layout="wide",
)

# ---------------------------------------------------------------------------
# API helper
# ---------------------------------------------------------------------------


def api(path: str, **params: Any) -> Any:
    try:
        resp = requests.get(f"{API_BASE}{path}", params=params, timeout=10)
        resp.raise_for_status()
        return resp.json()
    except Exception as exc:
        st.error(f"API error ({path}): {exc}")
        return None


# ---------------------------------------------------------------------------
# Sidebar
# ---------------------------------------------------------------------------

st.sidebar.title("HTTPayer Analytics")

page = st.sidebar.radio(
    "Navigate",
    ["Overview", "Providers", "Endpoints", "Challenges", "Revenue", "Staking"],
)

st.sidebar.divider()

sync_status = api("/sync/status")
if sync_status:
    last_block = sync_status.get("last_indexed_block", 0)
    st.sidebar.caption(f"Last indexed block: **{last_block:,}**")
else:
    st.sidebar.caption("Last indexed block: —")

if st.sidebar.button("Sync Now", use_container_width=True):
    with st.spinner("Syncing…"):
        try:
            r = requests.post(f"{API_BASE}/sync", timeout=130)
            result = r.json()
            if result.get("status") == "ok":
                st.sidebar.success("Sync complete")
            else:
                st.sidebar.error(f"Sync failed: {result.get('message', '')[:200]}")
        except Exception as exc:
            st.sidebar.error(f"Sync error: {exc}")
    st.rerun()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def trunc(s: Optional[str], n: int = 12) -> str:
    if not s:
        return ""
    return s[:n] + "…" if len(s) > n else s


def status_label(code: Optional[int]) -> str:
    return {0: "Pending", 1: "Valid", 2: "Invalid"}.get(code, "Unknown")  # type: ignore[arg-type]


def ts_to_date(ts: Optional[int]) -> str:
    if not ts:
        return ""
    return datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


# ---------------------------------------------------------------------------
# Page: Overview
# ---------------------------------------------------------------------------

if page == "Overview":
    st.title("Overview")

    data = api("/overview")
    if data is None:
        st.info("No data available yet. Run a sync first.")
        st.stop()

    # KPI row 1
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Total Providers", data.get("providers", 0))
    c2.metric("Total Endpoints", data.get("endpoints", 0))
    c3.metric("Total Staked (USDC)", f"${data.get('total_staked_usdc', '0.00')}")
    c4.metric("Revenue Distributed (USDC)", f"${data.get('total_revenue_usdc', '0.00')}")

    # KPI row 2
    c5, c6, c7 = st.columns(3)
    ch = data.get("challenges", {})
    c5.metric("Open Challenges", ch.get("pending", 0))
    c6.metric("Vault TVL (USDC)", f"${data.get('vault_tvl_usdc', '0.00')}")
    c7.metric("Slash Rate", f"{ch.get('slash_rate', 0):.1%}")

    st.divider()

    col_left, col_right = st.columns(2)

    # Challenge outcome pie
    with col_left:
        st.subheader("Challenge Outcomes")
        ch_data = {
            "Status": ["Pending", "Valid", "Invalid"],
            "Count": [ch.get("pending", 0), ch.get("valid", 0), ch.get("invalid", 0)],
        }
        total_ch = sum(ch_data["Count"])
        if total_ch == 0:
            st.info("No challenges recorded yet.")
        else:
            fig = px.pie(
                ch_data,
                names="Status",
                values="Count",
                color="Status",
                color_discrete_map={"Pending": "#f59e0b", "Valid": "#10b981", "Invalid": "#ef4444"},
            )
            fig.update_layout(margin=dict(t=20, b=20))
            st.plotly_chart(fig, use_container_width=True)

    # 30-day revenue bar chart
    with col_right:
        st.subheader("30-Day Revenue (USDC)")
        rev_data = api("/revenue", days=30)
        if rev_data and rev_data.get("timeline"):
            timeline = rev_data["timeline"]
            fig = px.bar(
                timeline,
                x="date",
                y="total_raw",
                labels={"date": "Date", "total_raw": "Revenue (raw USDC units)"},
            )
            fig.update_traces(
                hovertemplate="Date: %{x}<br>Revenue: $%{customdata:.2f}<extra></extra>",
                customdata=[r["total_raw"] / 1e6 for r in timeline],
            )
            fig.update_layout(margin=dict(t=20, b=20))
            st.plotly_chart(fig, use_container_width=True)
        else:
            st.info("No revenue data in the last 30 days.")

# ---------------------------------------------------------------------------
# Page: Providers
# ---------------------------------------------------------------------------

elif page == "Providers":
    st.title("Providers")

    providers = api("/providers")
    if not providers:
        st.info("No providers indexed yet.")
        st.stop()

    table_data = [
        {
            "ID": p.get("id"),
            "Owner": trunc(p.get("owner"), 14),
            "Endpoints": p.get("endpoint_count", 0),
            "Vault TVL (USDC)": f"${p.get('vault_tvl_usdc', '0.00')}",
            "Revenue (USDC)": f"${p.get('total_revenue_usdc', '0.00')}",
            "Challenges": p.get("challenge_count", 0),
            "Slashes": p.get("slash_count", 0),
            "Deployed": ts_to_date(p.get("deployed_ts")),
        }
        for p in providers
    ]
    st.dataframe(table_data, use_container_width=True)

    st.divider()
    st.subheader("Provider Detail")

    provider_ids = [p["id"] for p in providers if p.get("id") is not None]
    if not provider_ids:
        st.info("No provider IDs available.")
        st.stop()

    selected_id = st.selectbox("Select Provider ID", provider_ids)
    if selected_id is not None:
        detail = api(f"/providers/{selected_id}")
        if detail:
            col1, col2 = st.columns(2)
            col1.write(f"**Vault:** `{detail.get('vault', '')}`")
            col1.write(f"**Splitter:** `{detail.get('splitter', '')}`")
            col2.write(f"**Revenue Share:** `{detail.get('revenue_share', '')}`")

            endpoints = detail.get("endpoints", [])
            if endpoints:
                st.subheader("Endpoints")
                ep_table = [
                    {
                        "Endpoint ID": trunc(e.get("endpoint_id"), 18),
                        "Path": e.get("path", ""),
                        "Method": e.get("method", ""),
                    }
                    for e in endpoints
                ]
                st.dataframe(ep_table, use_container_width=True)
            else:
                st.info("No endpoints for this provider.")

            timeline = detail.get("revenue_timeline_30d", [])
            if timeline:
                st.subheader("30-Day Revenue Timeline")
                fig = px.line(
                    timeline,
                    x="date",
                    y="total_raw",
                    labels={"date": "Date", "total_raw": "Revenue (raw)"},
                    markers=True,
                )
                fig.update_layout(margin=dict(t=20, b=20))
                st.plotly_chart(fig, use_container_width=True)
            else:
                st.info("No revenue data in the last 30 days for this provider.")

# ---------------------------------------------------------------------------
# Page: Endpoints
# ---------------------------------------------------------------------------

elif page == "Endpoints":
    st.title("Endpoints")

    providers = api("/providers") or []
    provider_options: list[Any] = [None] + [p["id"] for p in providers if p.get("id") is not None]
    provider_labels = ["All Providers"] + [str(pid) for pid in provider_options[1:]]

    selected_label = st.selectbox("Filter by Provider", provider_labels)
    selected_provider = None if selected_label == "All Providers" else int(selected_label)

    params: dict[str, Any] = {}
    if selected_provider is not None:
        params["provider_id"] = selected_provider

    endpoints = api("/endpoints", **params)
    if not endpoints:
        st.info("No endpoints found.")
        st.stop()

    table = [
        {
            "Endpoint ID": trunc(e.get("endpoint_id"), 20),
            "Path": e.get("path", ""),
            "Method": e.get("method", ""),
            "Provider ID": e.get("provider_id"),
            "Challenges": e.get("challenge_count", 0),
            "Last Challenge": status_label(e.get("last_challenge_status")),
        }
        for e in endpoints
    ]
    st.dataframe(table, use_container_width=True)

# ---------------------------------------------------------------------------
# Page: Challenges
# ---------------------------------------------------------------------------

elif page == "Challenges":
    st.title("Challenges")

    status_filter = st.radio(
        "Status",
        ["All", "Pending", "Valid", "Invalid"],
        horizontal=True,
    )

    params: dict[str, Any] = {"limit": 200}
    if status_filter != "All":
        params["status"] = status_filter.lower()

    challenges = api("/challenges", **params)
    if not challenges:
        st.info("No challenges found.")
        st.stop()

    table = [
        {
            "ID": c.get("id"),
            "Endpoint Path": c.get("path") or c.get("ep_path", ""),
            "Challenger": trunc(c.get("challenger"), 14),
            "Status": status_label(c.get("status")),
            "Opened": ts_to_date(c.get("opened_ts")),
            "Resolution Time": (
                f"{c['resolution_time_seconds']}s"
                if c.get("resolution_time_seconds") is not None
                else "—"
            ),
        }
        for c in challenges
    ]
    st.dataframe(table, use_container_width=True)

    # Challenge volume per day bar chart
    st.subheader("Challenge Volume per Day")
    from collections import Counter

    date_counts: Counter[str] = Counter()
    for c in challenges:
        ts = c.get("opened_ts")
        if ts:
            day = datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d")
            date_counts[day] += 1

    if date_counts:
        sorted_days = sorted(date_counts.keys())
        fig = px.bar(
            x=sorted_days,
            y=[date_counts[d] for d in sorted_days],
            labels={"x": "Date", "y": "Challenges"},
        )
        fig.update_layout(margin=dict(t=20, b=20))
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No timestamped challenge data available.")

# ---------------------------------------------------------------------------
# Page: Revenue
# ---------------------------------------------------------------------------

elif page == "Revenue":
    st.title("Revenue")

    days = st.slider("Days to show", min_value=7, max_value=365, value=30, step=7)
    rev_data = api("/revenue", days=days)

    if not rev_data:
        st.info("No revenue data available.")
        st.stop()

    total_usdc = rev_data.get("total_usdc", "0.00")
    st.metric(f"Total Revenue ({days}d) USDC", f"${total_usdc}")

    st.divider()
    col_left, col_right = st.columns(2)

    # Area chart: revenue over time, stacked by provider
    with col_left:
        st.subheader("Revenue Over Time")
        timeline = rev_data.get("timeline", [])
        if timeline:
            fig = px.area(
                timeline,
                x="date",
                y="total_raw",
                labels={"date": "Date", "total_raw": "Revenue (raw)"},
            )
            fig.update_layout(margin=dict(t=20, b=20))
            st.plotly_chart(fig, use_container_width=True)
        else:
            st.info("No timeline data available.")

    # Horizontal bar: per-provider total revenue
    with col_right:
        st.subheader("Revenue by Provider")
        by_provider = rev_data.get("by_provider", [])
        if by_provider:
            fig = px.bar(
                by_provider,
                x="total_raw",
                y=[str(r.get("provider_id", "?")) for r in by_provider],
                orientation="h",
                labels={"x": "Revenue (raw)", "y": "Provider ID"},
            )
            fig.update_layout(margin=dict(t=20, b=20))
            st.plotly_chart(fig, use_container_width=True)
        else:
            st.info("No per-provider revenue data.")

    # Pie: revenue split
    st.subheader("Revenue Split (Aggregate)")
    if by_provider:
        protocol_total = sum(r.get("protocol_share", 0) for r in by_provider)
        vault_total = sum(r.get("vault_share", 0) for r in by_provider)
        rev_share_total = sum(r.get("rev_share", 0) for r in by_provider)
        provider_direct_total = sum(r.get("provider_direct", 0) for r in by_provider)

        split_data = {
            "Category": ["Protocol", "Vault", "Rev Share", "Provider Direct"],
            "Amount": [protocol_total, vault_total, rev_share_total, provider_direct_total],
        }
        fig = px.pie(
            split_data,
            names="Category",
            values="Amount",
        )
        fig.update_layout(margin=dict(t=20, b=20))
        st.plotly_chart(fig, use_container_width=True)
    else:
        st.info("No data for revenue split chart.")

# ---------------------------------------------------------------------------
# Page: Staking
# ---------------------------------------------------------------------------

elif page == "Staking":
    st.title("Staking")

    staking = api("/staking")
    if not staking:
        st.info("No staking data available.")
        st.stop()

    st.metric("Total Net Staked (USDC)", f"${staking.get('total_staked_usdc', '0.00')}")
    st.metric("Total Slashed (USDC)", f"${staking.get('total_slashed_usdc', '0.00')}")

    st.divider()
    st.subheader("Stakers")

    stakers = staking.get("stakers", [])
    if not stakers:
        st.info("No stakers recorded yet.")
    else:
        table = [
            {
                "Address": s.get("address", ""),
                "Net Staked (USDC)": f"${s.get('net_staked_usdc', '0.00')}",
                "Slash Count": s.get("slash_count", 0),
                "Slashed (USDC)": f"${s.get('slashed_usdc', '0.00')}",
            }
            for s in stakers
        ]
        st.dataframe(table, use_container_width=True)
