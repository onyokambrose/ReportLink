from datetime import datetime
from functools import wraps

import psycopg2
import psycopg2.extras
from flask import Flask, jsonify, render_template, request, session, redirect, url_for

app = Flask(__name__)
app.secret_key = "reportlink-secret-change-me-12345"

DB_CONFIG = {
    "host": "localhost",
    "port": 5432,
    "database": "reportlink",
    "user": "postgres",
    "password": "2Keroos@4",
}

ADMIN_USER = "admin"
ADMIN_PASS = "reportlink2026"


def db():
    conn = psycopg2.connect(**DB_CONFIG)
    conn.autocommit = True
    return conn


def login_required(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return wrapper


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        u = request.form.get("username", "")
        p = request.form.get("password", "")
        if u == ADMIN_USER and p == ADMIN_PASS:
            session["logged_in"] = True
            return redirect(url_for("index"))
        return render_template("dashboard.html", error="Invalid credentials", logged_in=False)
    return render_template("dashboard.html", logged_in=False)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/")
@login_required
def index():
    return render_template("dashboard.html", logged_in=True)


@app.route("/api/stats")
@login_required
def api_stats():
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT COUNT(*) AS n FROM users")
        users_total = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM reports")
        reports_total = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM reports WHERE status = 'resolved'")
        resolved = cur.fetchone()["n"]
        cur.execute("SELECT COUNT(*) AS n FROM notifications WHERE read = FALSE")
        unread = cur.fetchone()["n"]
        cur.execute("""
            SELECT COUNT(*) AS n FROM reports
            WHERE priority = 'Critical'
              AND status IN ('pending','underReview','assigned','inProgress')
        """)
        critical_open = cur.fetchone()["n"]

        cur.execute("SELECT status, COUNT(*) AS n FROM reports GROUP BY status")
        by_status = {row["status"]: row["n"] for row in cur.fetchall()}

        cur.execute("SELECT category, COUNT(*) AS n FROM reports GROUP BY category ORDER BY n DESC")
        by_category = [{"category": r["category"], "n": r["n"]} for r in cur.fetchall()]

        cur.execute("SELECT priority, COUNT(*) AS n FROM reports GROUP BY priority")
        by_priority = [{"priority": r["priority"], "n": r["n"]} for r in cur.fetchall()]

        cur.execute("""
            SELECT DATE(created_at) AS day, COUNT(*) AS n
            FROM reports WHERE created_at >= NOW() - INTERVAL '30 days'
            GROUP BY day ORDER BY day
        """)
        by_day = [{"day": str(r["day"]), "n": r["n"]} for r in cur.fetchall()]

        cur.execute("""
            SELECT manual_district, COUNT(*) AS n FROM reports
            WHERE manual_district <> '' GROUP BY manual_district
            ORDER BY n DESC LIMIT 10
        """)
        by_district = [{"district": r["manual_district"], "n": r["n"]} for r in cur.fetchall()]

    return jsonify({
        "users_total": users_total,
        "reports_total": reports_total,
        "resolved": resolved,
        "unread": unread,
        "critical_open": critical_open,
        "by_status": by_status,
        "by_category": by_category,
        "by_priority": by_priority,
        "by_day": by_day,
        "by_district": by_district,
    })


@app.route("/api/critical")
@login_required
def api_critical():
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT r.id, r.title, r.category, r.subcategory, r.priority, r.status,
                   r.contact, r.location_description, r.manual_area, r.manual_district,
                   r.manual_landmark, r.latitude, r.longitude, r.created_at,
                   u.full_name AS reporter, u.phone AS reporter_phone, u.email AS reporter_email
            FROM reports r
            LEFT JOIN users u ON u.id = r.user_id
            WHERE r.priority = 'Critical'
              AND r.status IN ('pending','underReview','assigned','inProgress')
            ORDER BY r.created_at ASC
        """)
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
    return jsonify(rows)


@app.route("/api/users")
@login_required
def api_users():
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT id, full_name, phone, email, location, profile_info, created_at, is_admin
            FROM users ORDER BY created_at DESC
        """)
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
    return jsonify(rows)


@app.route("/api/reports")
@login_required
def api_reports():
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT r.id, r.user_id,
                   u.full_name AS reporter, u.email AS reporter_email, u.phone AS reporter_phone,
                   r.report_type, r.category, r.subcategory, r.title, r.description,
                   r.priority, r.contact, r.latitude, r.longitude,
                   r.location_description, r.manual_area, r.manual_town,
                   r.manual_parish, r.manual_district, r.manual_landmark,
                   r.manual_directions, r.status, r.created_at, r.updated_at
            FROM reports r
            LEFT JOIN users u ON u.id = r.user_id
            ORDER BY r.created_at DESC
        """)
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
        r["updated_at"] = r["updated_at"].isoformat()
    return jsonify(rows)


@app.route("/api/notifications")
@login_required
def api_notifications():
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT id, user_id, title, message, type, report_id, read, created_at
            FROM notifications ORDER BY created_at DESC LIMIT 500
        """)
        rows = cur.fetchall()
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
    return jsonify(rows)


@app.route("/api/report_updates/<report_id>")
@login_required
def api_report_updates(report_id):
    with db() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT id, status, description, timestamp
            FROM report_updates WHERE report_id = %s ORDER BY timestamp ASC
        """, (report_id,))
        rows = cur.fetchall()
    for r in rows:
        r["timestamp"] = r["timestamp"].isoformat()
    return jsonify(rows)


@app.route("/api/update_report", methods=["POST"])
@login_required
def api_update_report():
    data = request.get_json() or {}
    report_id = data.get("id")
    if not report_id:
        return jsonify({"error": "missing id"}), 400

    fields = ["title", "description", "priority", "status", "contact", "location_description"]
    updates = {k: data[k] for k in fields if k in data}
    if not updates:
        return jsonify({"error": "nothing to update"}), 400

    note = (data.get("note") or "").strip()

    with db() as conn, conn.cursor() as cur:
        set_clause = ", ".join(f"{k} = %s" for k in updates)
        values = list(updates.values()) + [report_id]
        cur.execute(f"UPDATE reports SET {set_clause}, updated_at = NOW() WHERE id = %s", values)

        if "status" in updates:
            status_val = updates["status"]
            description = note or f"Status set to {status_val}"
            cur.execute("""
                INSERT INTO report_updates (report_id, status, description, timestamp)
                VALUES (%s, %s, %s, NOW())
            """, (report_id, status_val, description))

            cur.execute("SELECT user_id FROM reports WHERE id = %s", (report_id,))
            row = cur.fetchone()
            if row:
                user_id = row[0]
                notif_id = f"n_admin_{int(datetime.now().timestamp() * 1000)}"
                cur.execute("""
                    INSERT INTO notifications (id, user_id, title, message, type, report_id, read, created_at)
                    VALUES (%s, %s, %s, %s, 'status', %s, FALSE, NOW())
                """, (
                    notif_id,
                    user_id,
                    "Report status changed",
                    f"{report_id} is now {status_val}. {note}".strip(),
                    report_id,
                ))
    return jsonify({"ok": True})


@app.route("/api/delete_user/<user_id>", methods=["DELETE"])
@login_required
def api_delete_user(user_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM users WHERE id = %s", (user_id,))
    return jsonify({"ok": True})


@app.route("/api/delete_report/<report_id>", methods=["DELETE"])
@login_required
def api_delete_report(report_id):
    with db() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM reports WHERE id = %s", (report_id,))
    return jsonify({"ok": True})


if __name__ == "__main__":
    print("ReportLink Admin Dashboard -> http://localhost:5000")
    app.run(host="127.0.0.1", port=5000, debug=True)
