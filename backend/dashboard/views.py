from datetime import timedelta

from django.contrib.auth import authenticate, login, logout
from django.contrib.auth.decorators import login_required
from django.db.models import Count, Q
from django.shortcuts import redirect, render, get_object_or_404
from django.utils import timezone
from django.views.decorators.http import require_POST
from django.views.decorators.csrf import csrf_exempt

from .models import Report, ReportUpdate, User, Notification, ActivityLog, Message, SystemSettings, NotificationComment, Category, Location


def _log(request, action, description=""):
    try:
        username = request.user.username if request.user.is_authenticated else "anonymous"
        ip = request.META.get("REMOTE_ADDR", "")
        ActivityLog.objects.create(
            admin_username=username,
            action=action,
            description=description,
            ip_address=ip,
        )
    except Exception:
        pass


def _notify(report, title, message):
    if not report.user_id:
        return
    try:
        Notification.objects.create(
            id=f"n_admin_{int(timezone.now().timestamp() * 1000000)}",
            user_id=report.user_id,
            title=title,
            message=message,
            type="status",
            report_id=report.id,
            read=False,
            created_at=timezone.now(),
        )
    except Exception:
        pass


def _advance(request, report, new_status, note=""):
    report.status = new_status
    report.updated_at = timezone.now()
    report.save(update_fields=["status", "updated_at"])

    label = new_status.replace("underReview", "Under Review").replace("inProgress", "In Progress").capitalize()
    description = note.strip() or f"Status changed to {label}"
    ReportUpdate.objects.create(
        report_id=report.id,
        status=new_status,
        description=description,
        timestamp=timezone.now(),
    )
    _notify(report, "Report status changed", f"{report.id} is now {label}. {note}".strip())
    _log(request, f"REPORT_{new_status.upper()}", f"{report.id} -> {new_status}")


def login_view(request):
    if request.user.is_authenticated:
        return redirect("dashboard:home")
    error = None
    if request.method == "POST":
        username = request.POST.get("username", "")
        password = request.POST.get("password", "")
        user = authenticate(request, username=username, password=password)
        if user is not None:
            login(request, user)
            _log(request, "LOGIN", f"{username} signed in")
            return redirect(request.GET.get("next") or "dashboard:home")
        error = "Invalid username or password."
    return render(request, "dashboard/login.html", {"error": error})


@login_required(login_url="/admin-dashboard/login/")
def logout_view(request):
    _log(request, "LOGOUT", f"{request.user.username} signed out")
    logout(request)
    return redirect("dashboard:login")


@login_required(login_url="/admin-dashboard/login/")
def dashboard_home(request):
    total_reports = Report.objects.count()
    pending = Report.objects.filter(status="pending").count()
    in_progress = Report.objects.filter(status="inProgress").count()
    resolved = Report.objects.filter(status="resolved").count()
    users_total = User.objects.count()
    critical = Report.objects.filter(priority="Critical").count()

    recent_reports = Report.objects.all()[:10]
    recent_activity = ActivityLog.objects.all()[:10]

    by_category = (
        Report.objects.values("category").annotate(n=Count("id")).order_by("-n")[:8]
    )

    today = timezone.now().date()
    last_7 = []
    for i in range(6, -1, -1):
        day = today - timedelta(days=i)
        count = Report.objects.filter(created_at__date=day).count()
        last_7.append({"day": day.strftime("%a"), "n": count})

    context = {
        "total_reports": total_reports,
        "pending": pending,
        "in_progress": in_progress,
        "resolved": resolved,
        "users_total": users_total,
        "critical": critical,
        "recent_reports": recent_reports,
        "recent_activity": recent_activity,
        "by_category": list(by_category),
        "last_7": last_7,
    }
    return render(request, "dashboard/index.html", context)


@login_required(login_url="/admin-dashboard/login/")
def report_list(request):
    qs = Report.objects.all()
    status = request.GET.get("status", "")
    priority = request.GET.get("priority", "")
    category = request.GET.get("category", "")
    query = request.GET.get("q", "").strip()
    if status:
        qs = qs.filter(status=status)
    if priority:
        qs = qs.filter(priority=priority)
    if category:
        qs = qs.filter(category=category)
    if query:
        qs = qs.filter(
            Q(id__icontains=query)
            | Q(title__icontains=query)
            | Q(category__icontains=query)
            | Q(location_description__icontains=query)
            | Q(manual_district__icontains=query)
        )
    categories = Report.objects.values_list("category", flat=True).distinct().order_by("category")
    context = {
        "reports": qs[:200],
        "status": status,
        "priority": priority,
        "category": category,
        "query": query,
        "categories": categories,
    }
    return render(request, "dashboard/report_list.html", context)


@login_required(login_url="/admin-dashboard/login/")
def report_detail(request, report_id):
    report = get_object_or_404(Report, id=report_id)
    reporter = User.objects.filter(id=report.user_id).first()
    timeline = ReportUpdate.objects.filter(report_id=report_id)

    attachments = []
    if report.attachment_paths:
        for p in report.attachment_paths:
            if isinstance(p, str) and p:
                attachments.append({
                    "path": p,
                    "name": p.split("/")[-1].split("\\")[-1],
                })

    dynamic = []
    if report.dynamic_fields:
        for k, v in report.dynamic_fields.items():
            dynamic.append({"key": k, "value": v})

    context = {
        "report": report,
        "reporter": reporter,
        "timeline": timeline,
        "attachments": attachments,
        "dynamic": dynamic,
    }
    return render(request, "dashboard/report_detail.html", context)


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def report_action(request, report_id, action):
    report = get_object_or_404(Report, id=report_id)
    note = request.POST.get("note", "").strip()

    if action == "approve":
        _advance(request, report, "assigned", note or "Report approved and assigned for action.")
    elif action == "progress":
        _advance(request, report, "inProgress", note or "Investigation started.")
    elif action == "resolve":
        _advance(request, report, "resolved", note or "Report resolved.")
    elif action == "reject":
        _advance(request, report, "rejected", note or "Report rejected.")
    elif action == "reopen":
        _advance(request, report, "underReview", note or "Report reopened for review.")
    elif action == "note":
        if note:
            ReportUpdate.objects.create(
                report_id=report.id,
                status=report.status,
                description=note,
                timestamp=timezone.now(),
            )
            _log(request, "REPORT_NOTE", f"{report.id}: {note[:60]}")

    return redirect("dashboard:report_detail", report_id=report.id)


@login_required(login_url="/admin-dashboard/login/")
def user_list(request):
    qs = User.objects.all()
    query = request.GET.get("q", "").strip()
    if query:
        qs = qs.filter(
            Q(full_name__icontains=query)
            | Q(email__icontains=query)
            | Q(phone__icontains=query)
        )
    context = {"users": qs[:200], "query": query}
    return render(request, "dashboard/user_list.html", context)


@login_required(login_url="/admin-dashboard/login/")
def user_detail(request, user_id):
    user = get_object_or_404(User, id=user_id)
    reports = Report.objects.filter(user_id=user_id)
    context = {"profile": user, "reports": reports}
    return render(request, "dashboard/user_detail.html", context)


@login_required(login_url="/admin-dashboard/login/")
def activity_log(request):
    logs = ActivityLog.objects.all()[:500]
    return render(request, "dashboard/activity_log.html", {"logs": logs})


# ---------- Direct messages (Option B) ----------

@login_required(login_url="/admin-dashboard/login/")
def message_inbox(request):
    """List all users who have messaged, with unread counts and last message."""
    from django.db.models import Max, Q

    rows = (
        Message.objects
        .values("user_id")
        .annotate(
            last_at=Max("created_at"),
            unread=Count("id", filter=Q(sender="user", read=False)),
        )
        .order_by("-last_at")
    )

    conversations = []
    for r in rows:
        u = User.objects.filter(id=r["user_id"]).first()
        last = Message.objects.filter(user_id=r["user_id"]).order_by("-created_at").first()
        conversations.append({
            "user": u,
            "user_id": r["user_id"],
            "unread": r["unread"],
            "last_message": last.body if last else "",
            "last_at": last.created_at if last else r["last_at"],
            "last_sender": last.sender if last else "",
        })

    return render(request, "dashboard/message_inbox.html", {
        "conversations": conversations,
    })


@login_required(login_url="/admin-dashboard/login/")
def message_thread(request, user_id):
    """View one user's thread with the admin and reply."""
    reporter = User.objects.filter(id=user_id).first()
    thread = Message.objects.filter(user_id=user_id).order_by("created_at")

    # Mark user messages as read on the admin side
    Message.objects.filter(user_id=user_id, sender="user", read=False).update(read=True)

    return render(request, "dashboard/message_thread.html", {
        "reporter": reporter,
        "user_id": user_id,
        "thread": thread,
    })


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def message_send(request, user_id):
    """Admin sends a message to a user."""
    body = request.POST.get("body", "").strip()
    if body:
        Message.objects.create(
            user_id=user_id,
            sender="admin",
            body=body,
            read=False,
            created_at=timezone.now(),
        )
        # Also push a notification so it shows up in the app's bell
        try:
            Notification.objects.create(
                id=f"n_msg_{int(timezone.now().timestamp() * 1000000)}",
                user_id=user_id,
                title="New message from admin",
                message=body[:100],
                type="message",
                report_id=None,
                read=False,
                created_at=timezone.now(),
            )
        except Exception:
            pass
        _log(request, "MESSAGE_SENT", f"To user {user_id}: {body[:60]}")

    return redirect("dashboard:message_thread", user_id=user_id)



# ---------- Profile picture upload ----------

import os
import uuid
from django.core.files.storage import default_storage
from django.core.files.base import ContentFile
from django.http import JsonResponse


def _profile_image_url(request, path):
    if not path:
        return ""
    if path.startswith("http://") or path.startswith("https://"):
        return path
    return request.build_absolute_uri(f"/media/{path.lstrip('/')}")


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def upload_profile_image(request, user_id):
    """Receives a profile picture for a user (from the Flutter app or dashboard)."""
    user = User.objects.filter(id=user_id).first()
    if user is None:
        return JsonResponse({"ok": False, "error": "User not found"}, status=404)

    upload = request.FILES.get("image")
    if upload is None:
        return JsonResponse({"ok": False, "error": "No image provided"}, status=400)

    # Validate type
    if upload.content_type not in ("image/jpeg", "image/png", "image/webp"):
        return JsonResponse({"ok": False, "error": "Unsupported image type"}, status=400)

    # Cap size at 5 MB
    if upload.size > 5 * 1024 * 1024:
        return JsonResponse({"ok": False, "error": "Image too large (max 5 MB)"}, status=400)

    ext = os.path.splitext(upload.name)[1].lower() or ".jpg"
    filename = f"profiles/{user_id}_{uuid.uuid4().hex[:12]}{ext}"

    # Save file
    saved_path = default_storage.save(filename, ContentFile(upload.read()))

    # Delete old file if it exists and lives in our media folder
    old = user.profile_image_path
    if old and not old.startswith("http"):
        try:
            if default_storage.exists(old):
                default_storage.delete(old)
        except Exception:
            pass

    # Update the row
    user.profile_image_path = saved_path
    user.save(update_fields=["profile_image_path"])

    _log(request, "PROFILE_IMAGE", f"{user_id} uploaded {saved_path}")

    return JsonResponse({
        "ok": True,
        "path": saved_path,
        "url": _profile_image_url(request, saved_path),
    })


@login_required(login_url="/admin-dashboard/login/")
def serve_profile_image(request, user_id):
    """Convenience endpoint: returns the user's current profile image URL."""
    user = User.objects.filter(id=user_id).first()
    if user is None:
        return JsonResponse({"ok": False, "error": "User not found"}, status=404)
    return JsonResponse({
        "ok": True,
        "path": user.profile_image_path or "",
        "url": _profile_image_url(request, user.profile_image_path),
    })


# ---------- API token for the Flutter app ----------
API_TOKEN = "reportlink-app-token-change-me"


def _api_authorized(request):
    """Allows either a logged-in dashboard user OR the app token."""
    if request.user.is_authenticated:
        return True
    token = request.headers.get("X-ReportLink-Token") or request.META.get("HTTP_X_REPORTLINK_TOKEN")
    return token == API_TOKEN



@require_POST
@csrf_exempt
def api_upload_profile_image(request, user_id):
    """App-facing upload endpoint. Auth via X-ReportLink-Token header."""
    if not _api_authorized(request):
        return JsonResponse({"ok": False, "error": "Unauthorized"}, status=401)

    user = User.objects.filter(id=user_id).first()
    if user is None:
        return JsonResponse({"ok": False, "error": "User not found"}, status=404)

    upload = request.FILES.get("image")
    if upload is None:
        return JsonResponse({"ok": False, "error": "No image provided"}, status=400)

    if upload.content_type not in ("image/jpeg", "image/png", "image/webp"):
        return JsonResponse({"ok": False, "error": "Unsupported image type"}, status=400)

    if upload.size > 5 * 1024 * 1024:
        return JsonResponse({"ok": False, "error": "Image too large (max 5 MB)"}, status=400)

    ext = os.path.splitext(upload.name)[1].lower() or ".jpg"
    filename = f"profiles/{user_id}_{uuid.uuid4().hex[:12]}{ext}"
    saved_path = default_storage.save(filename, ContentFile(upload.read()))

    old = user.profile_image_path
    if old and not old.startswith("http"):
        try:
            if default_storage.exists(old):
                default_storage.delete(old)
        except Exception:
            pass

    user.profile_image_path = saved_path
    user.save(update_fields=["profile_image_path"])

    _log(request, "PROFILE_IMAGE", f"{user_id} uploaded via API")

    return JsonResponse({
        "ok": True,
        "path": saved_path,
        "url": request.build_absolute_uri(f"/media/{saved_path}"),
    })


@csrf_exempt
def api_get_profile_image(request, user_id):
    """App-facing fetch. Returns {ok, url} for a user's picture."""
    if not _api_authorized(request):
        return JsonResponse({"ok": False, "error": "Unauthorized"}, status=401)

    user = User.objects.filter(id=user_id).first()
    if user is None:
        return JsonResponse({"ok": False, "error": "User not found"}, status=404)

    path = user.profile_image_path or ""
    return JsonResponse({
        "ok": True,
        "path": path,
        "url": request.build_absolute_uri(f"/media/{path}") if path else "",
    })





# ---------- System Settings ----------

@login_required(login_url="/admin-dashboard/login/")
def settings_page(request):
    s = SystemSettings.get()
    return render(request, "dashboard/settings.html", {"settings": s})


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def settings_save(request):
    s = SystemSettings.get()
    s.app_name = request.POST.get("app_name", "ReportLink").strip() or "ReportLink"
    s.support_email = request.POST.get("support_email", "").strip()
    s.support_phone = request.POST.get("support_phone", "").strip()
    s.maintenance_mode = request.POST.get("maintenance_mode") == "on"
    s.maintenance_message = request.POST.get(
        "maintenance_message",
        "The application is under maintenance. We apologize for the inconvenience.",
    ).strip() or "The application is under maintenance. We apologize for the inconvenience."
    s.emergency_number = request.POST.get("emergency_number", "").strip()
    s.save()
    _log(request, "SETTINGS_UPDATED", f"maintenance={s.maintenance_mode}")
    return redirect("dashboard:settings_page")


@csrf_exempt
def api_public_settings(request):
    s = SystemSettings.get()
    return JsonResponse({
        "app_name": s.app_name,
        "support_email": s.support_email,
        "support_phone": s.support_phone,
        "maintenance_mode": s.maintenance_mode,
        "maintenance_message": s.maintenance_message,
        "emergency_number": s.emergency_number,
    })



# ---------- Notification Comments (per-notification thread) ----------

@login_required(login_url="/admin-dashboard/login/")
def notification_detail(request, notification_id):
    """Admin view: one notification + its comment thread."""
    n = Notification.objects.filter(id=notification_id).first()
    if n is None:
        return render(request, "dashboard/notification_detail.html", {
            "notification": None,
            "comments": [],
        })
    comments = NotificationComment.objects.filter(notification_id=notification_id)
    reporter = User.objects.filter(id=n.user_id).first()
    return render(request, "dashboard/notification_detail.html", {
        "notification": n,
        "comments": comments,
        "reporter": reporter,
    })


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def notification_comment_post(request, notification_id):
    """Admin posts a comment on a notification."""
    body = request.POST.get("body", "").strip()
    if body:
        n = Notification.objects.filter(id=notification_id).first()
        if n is not None:
            NotificationComment.objects.create(
                notification_id=notification_id,
                user_id=n.user_id,
                sender="admin",
                body=body,
                created_at=timezone.now(),
            )
            _log(request, "NOTIF_COMMENT", f"on {notification_id}: {body[:60]}")
    return redirect("dashboard:notification_detail", notification_id=notification_id)


# ---------- API for the Flutter app ----------

@csrf_exempt
def api_notification_comments(request, notification_id):
    """Returns all comments for one notification. Used by the app."""
    comments = NotificationComment.objects.filter(notification_id=notification_id)
    return JsonResponse({
        "ok": True,
        "comments": [
            {
                "id": c.id,
                "sender": c.sender,
                "user_id": c.user_id,
                "body": c.body,
                "created_at": c.created_at.isoformat(),
            }
            for c in comments
        ],
    })


@csrf_exempt
@require_POST
def api_notification_comment_post(request, notification_id):
    """App posts a comment on a notification."""
    import json as _json
    try:
        data = _json.loads(request.body.decode("utf-8"))
    except Exception:
        return JsonResponse({"ok": False, "error": "Invalid JSON"}, status=400)

    body = (data.get("body") or "").strip()
    user_id = (data.get("user_id") or "").strip()
    if not body or not user_id:
        return JsonResponse({"ok": False, "error": "Missing body or user_id"}, status=400)

    n = Notification.objects.filter(id=notification_id).first()
    if n is None:
        return JsonResponse({"ok": False, "error": "Notification not found"}, status=404)

    c = NotificationComment.objects.create(
        notification_id=notification_id,
        user_id=user_id,
        sender="user",
        body=body,
        created_at=timezone.now(),
    )
    return JsonResponse({
        "ok": True,
        "comment": {
            "id": c.id,
            "sender": c.sender,
            "user_id": c.user_id,
            "body": c.body,
            "created_at": c.created_at.isoformat(),
        },
    })



# ---------- Web Push subscription ----------

import json as _json_wp
from webpush.models import PushInformation, SubscriptionInfo, Group


def _webpush_admin_group():
    grp, _ = Group.objects.get_or_create(name="admins")
    return grp


@csrf_exempt
@require_POST
def webpush_subscribe(request):
    try:
        data = _json_wp.loads(request.body.decode("utf-8"))
    except Exception:
        return JsonResponse({"ok": False, "error": "Invalid JSON"}, status=400)

    endpoint = data.get("endpoint")
    keys = data.get("keys") or {}
    p256dh = keys.get("p256dh")
    auth = keys.get("auth")

    if not (endpoint and p256dh and auth):
        return JsonResponse({"ok": False, "error": "Missing fields"}, status=400)

    from django.contrib.auth.models import User as DjangoUser
    user = request.user if request.user.is_authenticated else None
    if user is None or not user.is_authenticated:
        user = DjangoUser.objects.filter(username="ReportLink").first() or DjangoUser.objects.first()

    sub_info, _ = SubscriptionInfo.objects.get_or_create(
        endpoint=endpoint,
        defaults={"p256dh": p256dh, "auth": auth},
    )
    if sub_info.p256dh != p256dh or sub_info.auth != auth:
        sub_info.p256dh = p256dh
        sub_info.auth = auth
        sub_info.save()

    grp = _webpush_admin_group()
    grp.subscription_info.add(sub_info)

    PushInformation.objects.get_or_create(
        user=user,
        subscription=sub_info,
        defaults={"group": grp},
    )

    return JsonResponse({"ok": True})


# ---------- Categories CRUD ----------

@login_required(login_url="/admin-dashboard/login/")
def category_list(request):
    cats = Category.objects.all().order_by("name")

    # Count reports per category name
    from django.db.models import Count
    counts = dict(
        Report.objects.values_list("category")
        .annotate(n=Count("id"))
    )

    rows = []
    for c in cats:
        rows.append({
            "obj": c,
            "report_count": counts.get(c.name, 0),
        })

    return render(request, "dashboard/category_list.html", {
        "rows": rows,
        "total": cats.count(),
    })


@login_required(login_url="/admin-dashboard/login/")
def category_create(request):
    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        description = request.POST.get("description", "").strip()
        icon = request.POST.get("icon", "").strip() or "fa-folder"
        color = request.POST.get("color", "").strip() or "#E15712"
        is_active = request.POST.get("is_active") == "on"

        if name:
            if Category.objects.filter(name__iexact=name).exists():
                return render(request, "dashboard/category_form.html", {
                    "mode": "create",
                    "error": "A category with that name already exists.",
                    "form": {"name": name, "description": description, "icon": icon, "color": color, "is_active": is_active},
                })
            Category.objects.create(
                name=name,
                description=description,
                icon=icon,
                color=color,
                is_active=is_active,
            )
            _log(request, "CATEGORY_CREATE", name)
            return redirect("dashboard:category_list")

    return render(request, "dashboard/category_form.html", {
        "mode": "create",
        "form": {"is_active": True, "icon": "fa-folder", "color": "#E15712"},
    })


@login_required(login_url="/admin-dashboard/login/")
def category_edit(request, cat_id):
    cat = get_object_or_404(Category, id=cat_id)

    if request.method == "POST":
        name = request.POST.get("name", "").strip()
        if name:
            if Category.objects.filter(name__iexact=name).exclude(id=cat.id).exists():
                return render(request, "dashboard/category_form.html", {
                    "mode": "edit",
                    "cat": cat,
                    "error": "A category with that name already exists.",
                })
            cat.name = name
            cat.description = request.POST.get("description", "").strip()
            cat.icon = request.POST.get("icon", "").strip() or "fa-folder"
            cat.color = request.POST.get("color", "").strip() or "#E15712"
            cat.is_active = request.POST.get("is_active") == "on"
            cat.save()
            _log(request, "CATEGORY_EDIT", f"{cat.id}: {cat.name}")
            return redirect("dashboard:category_list")

    return render(request, "dashboard/category_form.html", {"mode": "edit", "cat": cat})


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def category_delete(request, cat_id):
    cat = get_object_or_404(Category, id=cat_id)
    name = cat.name
    cat.delete()
    _log(request, "CATEGORY_DELETE", name)
    return redirect("dashboard:category_list")


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def category_toggle(request, cat_id):
    cat = get_object_or_404(Category, id=cat_id)
    cat.is_active = not cat.is_active
    cat.save(update_fields=["is_active"])
    _log(request, "CATEGORY_TOGGLE", f"{cat.name} -> {cat.is_active}")
    return redirect("dashboard:category_list")



# ---------- Locations CRUD ----------

@login_required(login_url="/admin-dashboard/login/")
def location_list(request):
    locs = Location.objects.all().order_by("district", "city_town")
    query = request.GET.get("q", "").strip()
    if query:
        from django.db.models import Q
        locs = locs.filter(
            Q(district__icontains=query)
            | Q(city_town__icontains=query)
            | Q(area__icontains=query)
        )
    return render(request, "dashboard/location_list.html", {
        "locations": locs[:300],
        "query": query,
        "total": locs.count(),
    })


@login_required(login_url="/admin-dashboard/login/")
def location_create(request):
    if request.method == "POST":
        district = request.POST.get("district", "").strip()
        if district:
            Location.objects.create(
                district=district,
                city_town=request.POST.get("city_town", "").strip(),
                division=request.POST.get("division", "").strip(),
                area=request.POST.get("area", "").strip(),
                latitude=float(request.POST.get("latitude") or 0) or None,
                longitude=float(request.POST.get("longitude") or 0) or None,
            )
            _log(request, "LOCATION_CREATE", district)
            return redirect("dashboard:location_list")
    return render(request, "dashboard/location_form.html", {"mode": "create"})


@login_required(login_url="/admin-dashboard/login/")
def location_edit(request, loc_id):
    loc = get_object_or_404(Location, id=loc_id)
    if request.method == "POST":
        loc.district = request.POST.get("district", "").strip()
        loc.city_town = request.POST.get("city_town", "").strip()
        loc.division = request.POST.get("division", "").strip()
        loc.area = request.POST.get("area", "").strip()
        lat = request.POST.get("latitude", "").strip()
        lng = request.POST.get("longitude", "").strip()
        loc.latitude = float(lat) if lat else None
        loc.longitude = float(lng) if lng else None
        loc.save()
        _log(request, "LOCATION_EDIT", f"{loc.id}: {loc.district}")
        return redirect("dashboard:location_list")
    return render(request, "dashboard/location_form.html", {"mode": "edit", "loc": loc})


@require_POST
@login_required(login_url="/admin-dashboard/login/")
def location_delete(request, loc_id):
    loc = get_object_or_404(Location, id=loc_id)
    name = loc.district
    loc.delete()
    _log(request, "LOCATION_DELETE", name)
    return redirect("dashboard:location_list")


# ---------- Notifications list + broadcast ----------

@login_required(login_url="/admin-dashboard/login/")
def notification_list(request):
    qs = Notification.objects.all().order_by("-created_at")

    read_filter = request.GET.get("read", "")
    type_filter = request.GET.get("type", "")
    query = request.GET.get("q", "").strip()

    if read_filter == "unread":
        qs = qs.filter(read=False)
    elif read_filter == "read":
        qs = qs.filter(read=True)

    if type_filter:
        qs = qs.filter(type=type_filter)

    if query:
        from django.db.models import Q
        qs = qs.filter(
            Q(title__icontains=query)
            | Q(message__icontains=query)
            | Q(user_id__icontains=query)
        )

    types = Notification.objects.values_list("type", flat=True).distinct().order_by("type")

    return render(request, "dashboard/notification_list.html", {
        "notifications": qs[:300],
        "read_filter": read_filter,
        "type_filter": type_filter,
        "query": query,
        "types": types,
        "total": qs.count(),
    })


@login_required(login_url="/admin-dashboard/login/")
def notification_broadcast(request):
    if request.method == "POST":
        title = request.POST.get("title", "").strip()
        body = request.POST.get("message", "").strip()
        target = request.POST.get("target", "all")

        if title and body:
            targets = []
            if target == "all":
                targets = list(User.objects.all())
            elif target == "admins":
                targets = list(User.objects.filter(is_admin=True))
            elif target == "regular":
                targets = list(User.objects.filter(is_admin=False))

            import time as _t
            now = timezone.now()
            created = 0
            for u in targets:
                try:
                    Notification.objects.create(
                        id=f"n_bcast_{int(now.timestamp()*1000000)}_{created}",
                        user_id=u.id,
                        title=title,
                        message=body,
                        type="broadcast",
                        report_id=None,
                        read=False,
                        created_at=now,
                    )
                    created += 1
                except Exception:
                    pass

            _log(request, "NOTIFICATION_BROADCAST", f"{created} users: {title[:60]}")
            return redirect("dashboard:notification_list")

    return render(request, "dashboard/notification_broadcast.html", {
        "user_count": User.objects.count(),
    })

