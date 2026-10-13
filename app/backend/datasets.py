"""Whitelisted datasets and metrics. Only expressions defined here are ever interpolated into SQL.
CATALOG seeds app.layer_catalog, which drives the drag-and-drop Data Catalog panel."""

METROS = [
    {"code": "MUM", "name": "Mumbai MMR", "region": "West", "lat": 19.10, "lon": 72.92, "zoom": 10.2},
    {"code": "PUN", "name": "Pune", "region": "West", "lat": 18.54, "lon": 73.84, "zoom": 10.6},
    {"code": "AMD", "name": "Ahmedabad", "region": "West", "lat": 23.03, "lon": 72.58, "zoom": 10.7},
    {"code": "DEL", "name": "Delhi NCR", "region": "North", "lat": 28.60, "lon": 77.20, "zoom": 9.8},
    {"code": "BLR", "name": "Bengaluru", "region": "South", "lat": 12.97, "lon": 77.62, "zoom": 10.5},
    {"code": "HYD", "name": "Hyderabad", "region": "South", "lat": 17.41, "lon": 78.46, "zoom": 10.5},
    {"code": "CHE", "name": "Chennai", "region": "South", "lat": 13.03, "lon": 80.20, "zoom": 10.6},
    {"code": "KOL", "name": "Kolkata", "region": "East", "lat": 22.57, "lon": 88.38, "zoom": 10.6},
]


def _m(label, expr, unit="", fmt="num", palette="seq", better="high"):
    return {"label": label, "expr": expr, "unit": unit, "fmt": fmt, "palette": palette, "better": better}


def _w(col):
    return f"sum({col} * subscribers) / nullif(sum(subscribers), 0)"


H3_DATASETS = {
    "retail_demand": {
        "view": "secure.retail_hex_monthly", "time": "month", "time_kind": "month",
        "metrics": {
            "revenue": _m("Revenue (12m)", "sum(revenue)", "INR", "inr"),
            "orders": _m("Orders", "sum(orders)"),
            "active_customers": _m("Active customers / month", "sum(active_customers)::float / count(DISTINCT month)"),
            "avg_order_value": _m("Avg order value", "sum(revenue) / nullif(sum(orders), 0)", "INR", "inr"),
            "jiomart_share_pct": _m("JioMart online share", "100.0 * sum(rev_jiomart) / nullif(sum(revenue), 0)", "%", "pct"),
            "rev_grocery": _m("Grocery revenue", "sum(rev_grocery)", "INR", "inr"),
            "rev_fresh": _m("Fresh revenue", "sum(rev_fresh)", "INR", "inr"),
            "rev_fashion": _m("Fashion revenue", "sum(rev_fashion)", "INR", "inr"),
            "rev_home": _m("Home revenue", "sum(rev_home)", "INR", "inr"),
            "rev_beauty": _m("Beauty revenue", "sum(rev_beauty)", "INR", "inr"),
            "rev_electronics": _m("Electronics revenue", "sum(rev_electronics)", "INR", "inr"),
            "rev_jewellery": _m("Jewellery revenue", "sum(rev_jewellery)", "INR", "inr"),
        },
    },
    "retail_market": {
        "view": "secure.retail_hex_profile", "time": None,
        "metrics": {
            "households": _m("Households", "max(households)"),
            "population": _m("Population", "max(population)"),
            "affluence_index": _m("Affluence index", "max(affluence_index)", "", "dec"),
            "median_hh_income_lakh": _m("Median HH income", "max(median_hh_income_lakh)", "lakh/yr", "dec"),
            "customers": _m("Reliance One customers", "max(customers)"),
            "penetration_pct": _m("Customer penetration", "max(penetration_pct)", "%", "pct"),
            "revenue_per_hh": _m("Revenue per household", "max(revenue_per_hh)", "INR", "inr"),
            "whitespace_score": _m("White-space score", "max(whitespace_score)", "", "num", "heat"),
            "competitors": _m("Competitor outlets", "max(competitors)", "", "num", "heat", "low"),
        },
    },
    "fiber_health": {
        "view": "secure.fiber_hex_daily", "time": "day", "time_kind": "day",
        "metrics": {
            "health_score": _m("Network health score", _w("health_score"), "/100", "dec", "div"),
            "uptime_pct": _m("Uptime", _w("uptime_pct"), "%", "pct3", "div"),
            "pct_ont_low_power": _m("ONTs with low optical power", _w("pct_ont_low_power"), "%", "pct", "div", "low"),
            "avg_rx_power_dbm": _m("Avg ONT Rx power", _w("avg_rx_power_dbm"), "dBm", "dec", "div"),
            "avg_latency_ms": _m("Latency", _w("avg_latency_ms"), "ms", "dec", "div", "low"),
            "packet_loss_pct": _m("Packet loss", _w("packet_loss_pct"), "%", "pct3", "div", "low"),
            "throughput_pct": _m("Throughput vs plan", "100 * " + _w("throughput_vs_plan"), "%", "pct", "div"),
            "tickets_per_1k": _m("Tickets per 1k subs / day", "1000.0 * sum(tickets) / nullif(sum(subscribers), 0)", "", "dec", "div", "low"),
            "tickets": _m("Trouble tickets", "sum(tickets)", "", "num", "heat", "low"),
            "incidents": _m("Incidents", "sum(incidents)", "", "num", "heat", "low"),
            "homes_impacted": _m("Homes impacted by outages", "sum(homes_impacted)", "", "num", "heat", "low"),
        },
    },
    "fiber_coverage": {
        "view": "secure.fiber_hex_profile", "time": None,
        "metrics": {
            "homes_connected": _m("Homes connected", "max(homes_connected)"),
            "penetration_pct": _m("Penetration of homes passed", "max(penetration_pct)", "%", "pct"),
            "coverage_pct": _m("Homes passed / households", "max(coverage_pct)", "%", "pct"),
            "unconnected_homes_passed": _m("Sales opportunity: passed, not connected", "max(unconnected_homes_passed)", "", "num", "heat"),
            "homes_not_passed": _m("Build-out opportunity: not yet passed", "max(homes_not_passed)", "", "num", "heat"),
            "premium_plan_pct": _m("Premium plans (300M+)", "max(premium_plan_pct)", "%", "pct"),
            "gbps_share_pct": _m("1 Gbps plans", "max(gbps_share_pct)", "%", "pct"),
            "health_7d": _m("Health score (7d)", "max(health_7d)", "/100", "dec", "div"),
            "tickets_7d": _m("Tickets (7d)", "max(tickets_7d)", "", "num", "heat", "low"),
            "cross_sell_prospects": _m("Reliance Retail customers without Jio Fiber", "max(cross_sell_prospects)", "", "num", "heat"),
            "avg_tenure_months": _m("Avg subscriber tenure", "max(avg_tenure_months)", "months", "dec"),
        },
    },
}

POINT_DATASETS = {
    "stores": {
        "sql": """SELECT store_code AS id, store_name AS name, format, latitude, longitude, round(revenue_12m) AS revenue_12m,
                         perf_band, growth_3m_pct, metro_code, carpet_area_sqft, top_category
                  FROM secure.retail_stores""",
        "color_by": "format", "size_by": "revenue_12m",
    },
    "competitors": {
        "sql": "SELECT outlet_id AS id, brand AS name, brand, category_group, latitude, longitude, metro_code FROM secure.retail_competitors",
        "color_by": "category_group", "size_by": None,
    },
    "plots": {
        "sql": """SELECT plot_id AS id, concat(locality, ' ', plot_id) AS name, centroid_lat AS latitude, centroid_lon AS longitude,
                         best_score, recommended_format, plot_status, area_sqm, est_annual_revenue_cr, metro_code
                  FROM secure.retail_plots""",
        "color_by": "recommended_format", "size_by": "best_score",
    },
    "olts": {
        "sql": """SELECT olt_id AS id, olt_name AS name, latitude, longitude, pon_fill_pct, capacity_status, current_status,
                         health_7d, open_incidents, homes_connected, util_now, peak_util_7d, metro_code
                  FROM secure.fiber_olts""",
        "color_by": "capacity_status", "size_by": "homes_connected",
    },
    "fdh": {
        "sql": """SELECT fdh_id AS id, fdh_id AS name, latitude, longitude, health_7d, open_incidents, homes_connected, metro_code
                  FROM secure.fiber_fdh""",
        "color_by": "health_7d", "size_by": "homes_connected",
    },
    "incidents_30d": {
        "sql": """SELECT incident_id AS id, incident_type AS name, incident_type, severity, latitude, longitude, homes_impacted,
                         outage_min, status, sla_breached, root_cause, metro_code
                  FROM secure.fiber_incidents""",
        "color_by": "incident_type", "size_by": "homes_impacted",
    },
}

MVT_DATASETS = {
    "plots": {
        "view": "secure.retail_plots", "layer": "plots",
        "props": "plot_id, best_score, recommended_format, plot_status, area_sqm, est_annual_revenue_cr, zoning",
        "min_zoom": 8,
    },
    "routes": {
        "view": "secure.fiber_routes", "layer": "routes",
        "props": "route_id, route_type, cuts_30d, route_km, laid_year",
        "min_zoom": 8, "zoom_filter": "(route_type = 'Feeder' OR %(z)s >= 12)",
    },
}


def _h3(key, solution, title, desc, dataset, metric, group, order, style=None):
    return {"layer_key": key, "solution": solution, "title": title, "description": desc, "kind": "h3", "dataset": dataset,
            "default_metric": metric, "metrics": list(H3_DATASETS[dataset]["metrics"]), "default_style": style or {},
            "group_name": group, "sort_order": order}


def _pt(key, solution, title, desc, dataset, kind, group, order, style=None):
    return {"layer_key": key, "solution": solution, "title": title, "description": desc, "kind": kind, "dataset": dataset,
            "default_metric": None, "metrics": [], "default_style": style or {}, "group_name": group, "sort_order": order}


CATALOG = [
    _h3("retail_revenue", "retail", "Customer demand", "Revenue by where customers live (home H3 cell)", "retail_demand", "revenue", "Demand", 10),
    _h3("retail_category", "retail", "Category demand", "Revenue for one category: Grocery, Fashion, Electronics...", "retail_demand", "rev_fashion", "Demand", 11),
    _h3("retail_jiomart", "retail", "JioMart online share", "Share of revenue ordered online and delivered from stores", "retail_demand", "jiomart_share_pct", "Demand", 12),
    _h3("retail_households", "retail", "Households", "Residential households (census-style surface)", "retail_market", "households", "Market", 20),
    _h3("retail_affluence", "retail", "Affluence", "Affluence index 0-1 and median household income", "retail_market", "affluence_index", "Market", 21),
    _h3("retail_penetration", "retail", "Customer penetration", "Reliance One customers per 100 households", "retail_market", "penetration_pct", "Market", 22),
    _h3("retail_whitespace", "retail", "White space", "Untapped demand: households x affluence, low penetration, few stores", "retail_market", "whitespace_score", "Expansion", 30),
    _pt("retail_stores", "retail", "Reliance stores", "All formats, sized by 12-month revenue", "stores", "points", "Network", 40, {"color_by": "format", "size_by": "revenue_12m"}),
    _pt("retail_competitors", "retail", "Competitors", "DMart, Zudio, Croma, dark stores and more", "competitors", "points", "Network", 41, {"color_by": "category_group"}),
    _pt("retail_plots", "retail", "Candidate plots", "Land bank parcels (PostGIS vector tiles), coloured by site score", "plots", "mvt", "Expansion", 31, {"color_by": "best_score"}),
    _h3("retail_fiber_xsell", "retail", "Jio Fiber cross-sell", "Reliance Retail customers in homes without Jio Fiber", "fiber_coverage", "cross_sell_prospects", "Cross-business", 50),

    _h3("fiber_health", "fiber", "Network health score", "0-100 composite: uptime, optical margin, latency, loss, throughput, tickets", "fiber_health", "health_score", "Experience", 10),
    _h3("fiber_uptime", "fiber", "Uptime", "Subscriber-weighted availability", "fiber_health", "uptime_pct", "Experience", 11),
    _h3("fiber_optical", "fiber", "Optical power", "Share of ONTs below -27 dBm (fiber degradation)", "fiber_health", "pct_ont_low_power", "Experience", 12),
    _h3("fiber_latency", "fiber", "Latency", "Average round-trip latency, ms", "fiber_health", "avg_latency_ms", "Experience", 13),
    _h3("fiber_tickets", "fiber", "Trouble tickets", "Tickets per 1,000 subscribers per day", "fiber_health", "tickets_per_1k", "Experience", 14),
    _h3("fiber_outage_impact", "fiber", "Outage impact", "Homes impacted by incidents", "fiber_health", "homes_impacted", "Experience", 15),
    _h3("fiber_penetration", "fiber", "Penetration", "Homes connected / homes passed", "fiber_coverage", "penetration_pct", "Growth", 20),
    _h3("fiber_sales_opp", "fiber", "Sales opportunity", "Homes passed but not connected", "fiber_coverage", "unconnected_homes_passed", "Growth", 21),
    _h3("fiber_buildout", "fiber", "Build-out opportunity", "Households not yet passed by fiber", "fiber_coverage", "homes_not_passed", "Growth", 22),
    _h3("fiber_premium", "fiber", "Premium plan mix", "Share of 300 Mbps and 1 Gbps plans", "fiber_coverage", "premium_plan_pct", "Growth", 23),
    _h3("fiber_xsell", "fiber", "Retail cross-sell", "Reliance Retail customers without Jio Fiber", "fiber_coverage", "cross_sell_prospects", "Growth", 24),
    _pt("fiber_live_incidents", "fiber", "Live incidents", "Open incidents (NOC + live feed), pulsing by severity", "live_incidents", "live", "Operations", 1, {"color_by": "severity", "size_by": "homes_impacted"}),
    _pt("fiber_technicians", "fiber", "Field technicians", "Live positions and status", "technicians", "live", "Operations", 2, {"color_by": "status"}),
    _pt("fiber_olts", "fiber", "OLTs", "Optical Line Terminals by capacity status", "olts", "points", "Network", 30, {"color_by": "capacity_status", "size_by": "homes_connected"}),
    _pt("fiber_fdh", "fiber", "FDH cabinets", "Splitter cabinets coloured by 7-day health", "fdh", "points", "Network", 31, {"color_by": "health_7d"}),
    _pt("fiber_routes", "fiber", "Fiber routes", "Feeder and distribution cables (PostGIS vector tiles), cuts highlighted", "routes", "mvt", "Network", 32, {"color_by": "cuts_30d"}),
    _pt("fiber_incident_history", "fiber", "Incident history (30d)", "All incidents in the last 30 days by type", "incidents_30d", "points", "Operations", 3, {"color_by": "incident_type", "size_by": "homes_impacted"}),
]
