# ReportLink — Project Documentation

Full-stack incident reporting system.
A Flutter mobile app for reporters, a Django admin dashboard for managers,
and a PostgreSQL database shared between them.

Last updated: 2026-09-21

---

## 1. Overview

ReportLink lets community members report incidents (medical, fire, crime,
infrastructure, etc.) from a mobile app. Admins manage those reports from a
web dashboard: approve, reject, assign, resolve, chat with reporters, and
control app-wide settings such as maintenance mode.

### Architecture

    ┌────────────────────┐        ┌─────────────────────────┐
    │  Flutter app       │        │  Django admin dashboard │
    │  (Android/ITEL)    │        │  (browser on PC)        │
    └─────┬──────────────┘        └──────────┬──────────────┘
          │                                  │
          │  TCP (dev: adb reverse)          │  HTTP
          │                                  │
          ▼                                  ▼
    ┌───────────────────────────────────────────────────┐
    │           PostgreSQL 18.6   (localhost:5432)      │
    │         database: reportlink                       │
    └───────────────────────────────────────────────────┘

    Optional secondary path:
    Flutter --HTTP--> Django /api/public-settings/ (port 8000)

---

## 2. Technology Stack

| Layer      | Technology                              |
|------------|-----------------------------------------|
| Mobile     | Flutter 3.47.2 (Dart 3.13.2)            |
| Dashboard  | Django 6.1.1, Django Templates, Chart.js |
| Database   | PostgreSQL 18.6                         |
| HTTP client| Python: none (Flask variant retired)     |
|            | Dart: package http ^1.6.0               |
| Other pkgs | postgres 3.5, shared_preferences,       |
|            | image_picker, geolocator, geocoding,    |
|            | crypto                                  |

---

## 3. Repository Layout

    C:\Users\Personal\Downloads\ReportLink\
    ├── lib\                          Flutter app
    │   ├── main.dart                 Entry point, AppState, all screens
    │   ├── database.dart             Postgres connection wrapper
    │   ├── messages.dart             Message model + DB helpers
    │   ├── messages_screen.dart      Chat UI
    │   ├── settings_service.dart     HTTP fetch of public settings
    │   └── maintenance_screen.dart   Maintenance overlay
    │
    ├── android\                      Android build config
    ├── assets\                       App assets (logo, etc.)
    ├── pubspec.yaml                  Flutter deps
    │
    ├── reportlink_backend\           Django project
    │   ├── settings.py               DB config, media config
    │   └── urls.py                   Root URL routing
    │
    ├── dashboard\                    Django app
    │   ├── models.py                 Models for all tables
    │   ├── views.py                  All dashboard views + API
    │   ├── urls.py                   URL routes
    │   ├── templates\dashboard\      HTML templates
    │   │   ├── base.html             Sidebar + topbar layout
    │   │   ├── login.html            Custom login page
    │   │   ├── index.html            Dashboard home
    │   │   ├── report_list.html      All reports with filters
    │   │   ├── report_detail.html    Single report + approval actions
    │   │   ├── user_list.html        Users list
    │   │   ├── user_detail.html      Single user + their reports
    │   │   ├── message_inbox.html    Admin's chat inbox
    │   │   ├── message_thread.html   Single conversation
    │   │   ├── settings.html         App-wide settings
    │   │   └── activity_log.html     Audit trail
    │   └── static\dashboard\
    │       ├── css\style.css         Orange/blue brand palette
    │       └── img\logo.png          App logo
    │
    ├── media\                        User uploads
    │   └── profiles\                 Profile pictures
    │
    ├── venv\                         Python virtual environment
    └── docs\                         This documentation

---

## 4. Database Schema

Database: `reportlink` (PostgreSQL 18.6)

### Table: users
Managed by Flutter app. Django reads it (managed = False).

| Column             | Type                     | Notes              |
|--------------------|--------------------------|--------------------|
| id                 | TEXT PRIMARY KEY         | u_<timestamp>      |
| full_name          | TEXT NOT NULL            |                    |
| phone              | TEXT NOT NULL UNIQUE     |                    |
| email              | TEXT NOT NULL UNIQUE     |                    |
| password_salt      | TEXT NOT NULL            |                    |
| password_hash      | TEXT NOT NULL            |                    |
| location           | TEXT                     |                    |
| profile_info       | TEXT                     |                    |
| created_at         | TIMESTAMPTZ NOT NULL     |                    |
| is_admin           | BOOLEAN NOT NULL         | default false      |
| profile_image_path | TEXT                     | relative path      |

### Table: reports
| Column                | Type                  | Notes                        |
|-----------------------|-----------------------|------------------------------|
| id                    | TEXT PRIMARY KEY      | RL-<year>-<seq>              |
| user_id               | TEXT FK -> users(id)  | ON DELETE CASCADE            |
| report_type           | TEXT                  |                              |
| category              | TEXT                  |                              |
| subcategory           | TEXT                  |                              |
| title                 | TEXT                  |                              |
| description           | TEXT                  |                              |
| priority              | TEXT                  | Low / Medium / High / Critical |
| contact               | TEXT                  |                              |
| latitude              | DOUBLE PRECISION      |                              |
| longitude             | DOUBLE PRECISION      |                              |
| location_description  | TEXT                  |                              |
| manual_area           | TEXT                  |                              |
| manual_town           | TEXT                  |                              |
| manual_parish         | TEXT                  |                              |
| manual_district       | TEXT                  |                              |
| manual_landmark       | TEXT                  |                              |
| manual_directions     | TEXT                  |                              |
| attachment_paths      | TEXT[]                | list of file paths           |
| status                | TEXT                  | pending / underReview /      |
|                       |                       | assigned / inProgress /      |
|                       |                       | resolved / rejected          |
| dynamic_fields        | JSONB                 | incident-specific extras     |
| created_at            | TIMESTAMPTZ           |                              |
| updated_at            | TIMESTAMPTZ           |                              |

### Table: report_updates
| Column      | Type               | Notes                 |
|-------------|--------------------|-----------------------|
| id          | BIGSERIAL PK       |                       |
| report_id   | TEXT FK -> reports | ON DELETE CASCADE     |
| status      | TEXT               |                       |
| description | TEXT               | admin note / message  |
| timestamp   | TIMESTAMPTZ        |                       |

### Table: notifications
| Column     | Type                | Notes                    |
|------------|---------------------|--------------------------|
| id         | TEXT PK             | n_<micros> or n_admin_.. |
| user_id    | TEXT FK -> users    | ON DELETE CASCADE        |
| title      | TEXT                |                          |
| message    | TEXT                |                          |
| type       | TEXT                | account / report / status|
| report_id  | TEXT                | nullable                 |
| read       | BOOLEAN             | default false            |
| created_at | TIMESTAMPTZ         |                          |

### Table: messages  (chat between app user and admin)
| Column     | Type              | Notes              |
|------------|-------------------|--------------------|
| id         | BIGSERIAL PK      |                    |
| user_id    | TEXT FK -> users  | ON DELETE CASCADE  |
| sender     | TEXT CHECK        | 'user' or 'admin'  |
| body       | TEXT              |                    |
| read       | BOOLEAN           | default false      |
| created_at | TIMESTAMPTZ       |                    |

### Table: admin_categories
Managed by Django (created via migrations).

| Column      | Type                    |
|-------------|-------------------------|
| id          | BIGSERIAL PK            |
| name        | VARCHAR(120) UNIQUE     |
| description | TEXT                    |
| icon        | VARCHAR(60)             |
| color       | VARCHAR(20)             |
| is_active   | BOOLEAN                 |
| created_at  | TIMESTAMPTZ             |

### Table: admin_locations
| Column      | Type               |
|-------------|--------------------|
| id          | BIGSERIAL PK       |
| district    | VARCHAR(120)       |
| city_town   | VARCHAR(120)       |
| division    | VARCHAR(120)       |
| area        | VARCHAR(120)       |
| latitude    | DOUBLE PRECISION   |
| longitude   | DOUBLE PRECISION   |
| created_at  | TIMESTAMPTZ        |

### Table: admin_activity_log
| Column         | Type              | Notes                     |
|----------------|-------------------|---------------------------|
| id             | BIGSERIAL PK      |                           |
| admin_username | VARCHAR(120)      | Django admin username     |
| action         | VARCHAR(80)       | e.g. LOGIN, REPORT_APPROVE|
| description    | TEXT              |                           |
| ip_address     | VARCHAR(60)       |                           |
| created_at     | TIMESTAMPTZ       |                           |

### Table: system_settings
Single-row table (id = 1).

| Column               | Type            | Notes                     |
|----------------------|-----------------|---------------------------|
| id                   | INTEGER PK      | always 1                  |
| app_name             | TEXT            | "ReportLink"              |
| support_email        | TEXT            |                           |
| support_phone        | TEXT            |                           |
| maintenance_mode     | BOOLEAN         |                           |
| maintenance_message  | TEXT            |                           |
| updated_at           | TIMESTAMPTZ     |                           |

---

## 5. Feature Inventory

### Mobile app (Flutter)

- Registration + login (SHA-256 hashed passwords with per-user salt)
- Onboarding screen for first-time users
- Dashboard with KPIs and recent reports
- Report submission flow (3 steps: type/category → details/location → review)
- Image attachment (camera or gallery)
- Geolocation with reverse geocoding
- Manual location entry (area, town, parish, district, landmark, directions)
- Report timeline with status history
- Notifications list
- Two-way chat with admin (Messages screen)
- Profile editing, password change, delete account
- Dark mode, language setting
- Admin mode toggle (via admin key)
- Profile picture upload (backend ready; app wiring pending)

### Admin dashboard (Django)

- Custom login (username + password)
- Overview KPIs: total / pending / in progress / resolved / users / critical
- Line chart: reports last 7 days
- Doughnut chart: reports by category
- Recent reports + recent activity feed
- Reports list with search + status/priority/category filters
- Report detail page:
    - All report fields
    - Reporter info
    - Location + OpenStreetMap embed + Google Maps link
    - Attachments list
    - Dynamic fields grid
    - Timeline
    - Approve / Start Progress / Resolve / Reject / Reopen buttons
    - Internal notes
- Users list + search
- User detail with their reports
- Messages inbox + per-user threads + reply
- Activity log (audit trail)
- Settings page: app name, support contact, maintenance mode

### API endpoints (used by the app)

| Method | Path                                                     | Purpose                 |
|--------|----------------------------------------------------------|-------------------------|
| POST   | /admin-dashboard/api/upload-profile/<user_id>/           | Upload profile picture  |
| GET    | /admin-dashboard/api/profile-image/<user_id>/            | Get current image URL   |
| GET    | /admin-dashboard/api/public-settings/                    | Maintenance + branding  |

Auth for API calls: header `X-ReportLink-Token: reportlink-app-token-change-me`.

---

## 6. Running the System (development)

### Prerequisites

- Python 3.13 (venv at .\venv)
- PostgreSQL 18.6 running on localhost:5432
- Database `reportlink` created
- Flutter 3.47+ with Android SDK
- ADB on PATH

### Terminal 1 — Django dashboard

    cd C:\Users\Personal\Downloads\ReportLink
    .\venv\Scripts\Activate.ps1
    python manage.py runserver

Dashboard: http://localhost:8000/admin-dashboard/
Login:     ReportLink / 2Keroos@4

### Terminal 2 — Flutter app on the phone

    cd C:\Users\Personal\Downloads\ReportLink
    $env:Path += ";C:\Users\Personal\AppData\Local\Android\sdk\platform-tools"
    adb -s 119986443D000411 reverse tcp:5432 tcp:5432
    adb -s 119986443D000411 reverse tcp:8000 tcp:8000
    flutter run -d 119986443D000411

### Terminal 3 — Ad-hoc shell commands

    cd C:\Users\Personal\Downloads\ReportLink
    .\venv\Scripts\Activate.ps1

---

## 7. Known Limitations / TODO

### Security
- [ ] Postgres password is embedded in the Flutter app (lib/database.dart)
      This must be removed before any public distribution.
- [ ] Admin login is a single hardcoded password. Replace with Django users.
- [ ] No HTTPS in development (HTTP only)
- [ ] API token is hardcoded and shared (fine for dev, must rotate for prod)

### Architecture
- [ ] Flutter talks directly to Postgres. Move to REST API (DRF) for production.
- [ ] No offline queue for reports submitted while disconnected.
- [ ] No push notifications (Firebase Cloud Messaging).

### Features in progress
- [ ] Maintenance mode: Django side works; app fetch/wiring needs debugging.
- [ ] Profile picture upload: Django endpoint ready; Flutter UI not wired.
- [ ] Categories CRUD (admin adds categories that appear in the app).
- [ ] Locations CRUD.
- [ ] Notifications broadcast from admin.
- [ ] Role-based admin accounts (Super Admin / Moderator / Analyst).

### Operations
- [ ] No automated tests.
- [ ] No error monitoring.
- [ ] No automated backups.
- [ ] Single-instance dev server (not gunicorn/nginx).

---

## 8. Deployment Checklist (not yet done)

Before this can serve real users on the internet:

1. Add Django REST Framework and expose /api/ endpoints
2. Rewrite Flutter to use HTTP API instead of direct Postgres
3. Remove Postgres credentials from the app
4. Move Postgres to a hosted provider (Render / Railway / DO / RDS)
5. Run Django under gunicorn + nginx
6. Provision HTTPS (Let''s Encrypt)
7. Replace hardcoded admin with real auth + strong password + 2FA
8. Set up daily Postgres backups
9. Add error monitoring (Sentry)
10. Add push notifications (FCM)

Estimated: ~10 working days full-time, or 4–6 weeks part-time.

---

## 9. Build & Verify Commands

    # Check Django configuration
    python manage.py check

    # Apply DB migrations
    python manage.py migrate

    # Dart static analysis
    flutter analyze

    # Rebuild and run on phone
    flutter clean
    flutter pub get
    flutter run -d 119986443D000411

    # List adb tunnels
    adb -s 119986443D000411 reverse --list

---

## 10. Change Log (this build session)

- Initial Flutter app with local SharedPreferences storage
- Added PostgreSQL backend and rewired AppState to read/write DB
- Added Messages table + chat screen on the app
- Built Django admin backend from scratch
- Wired admin to same Postgres tables
- Added approve/reject/resolve workflow
- Added activity logging
- Added maintenance mode settings (Django side)
- Added profile picture upload endpoint (Django side)
- Documentation added
