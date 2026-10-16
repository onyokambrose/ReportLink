from django.conf import settings


def webpush_keys(request):
    ws = getattr(settings, "WEBPUSH_SETTINGS", {})
    return {"webpush_public_key": ws.get("VAPID_PUBLIC_KEY", "")}
